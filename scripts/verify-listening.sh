#!/usr/bin/env bash
# Verify that a listener — someone who is NOT on the mac-mini — can
# actually hear the radio.
#
# This exists because the previous deploy check ran on the box and hit
# localhost:18000. That passes whenever the app is up, which it was for
# the entire outage: radio.jonasjohansson.se returned 530 for days while
# every local check stayed green. localhost proves the encoder works. It
# proves nothing about whether anyone can listen.
#
# So: resolve the public hostname, go out through Cloudflare, come back
# through the tunnel, and confirm real AAC bytes arrive.
#
# Every broadcasting station is checked, not just the first one. Checking
# one meant a deploy went green while a second station was silent.
#
# Each run appends a one-line verdict to $RATBAT_VERIFY_LOG (default
# ~/Library/Logs/ratbat-verify.log) so there is an artifact afterwards:
# a check that leaves no trace can only ever answer "is it up right now",
# never "when did it break".
#
# Usage:
#   scripts/verify-listening.sh [BASE_URL] [TIMEOUT_SECONDS]
#
# Exit codes are distinct so a caller can tell the failures apart:
#   0  audio is flowing
#   1  usage / missing dependency
#   2  the public endpoint never answered (DNS, Cloudflare, or tunnel down)
#   3  it answered, but no station is broadcasting
#   4  a station is live but the stream produced no usable audio
#   5  a station never resolved a first track within the startup budget

set -uo pipefail

BASE="${1:-https://radio.jonasjohansson.se}"
DEADLINE_SECS="${2:-90}"

# A station that is broadcasting but has no current track has not failed
# — it is still resolving one. NTS has to reach the API, choose a show
# and pull the track through yt-dlp before a single byte is encoded, and
# on a cold start that runs well past the deadline above.
#
# Spending the same budget on it as on "the tunnel is down" is what made
# every deploy from 2026-08-24 on report a failure that never happened:
# four runs in a row, always /stream/nts-disco.aac, always HTTP 000 —
# curl hanging up on a connection the origin was holding open with
# nothing yet to send. The audio was fine minutes later, every time.
#
# So: a separate, longer patience, spent only while the one thing
# outstanding is a station waiting on its first track.
STARTUP_DEADLINE_SECS="${RATBAT_STARTUP_DEADLINE_SECS:-480}"

# A few seconds of AAC. Small enough to be quick, large enough that a
# stalled or empty stream can't pass by dribbling out a header.
MIN_BYTES=16384
SAMPLE_SECS=6

VERIFY_LOG="${RATBAT_VERIFY_LOG:-$HOME/Library/Logs/ratbat-verify.log}"
mkdir -p "$(dirname "$VERIFY_LOG")" 2>/dev/null || true

# One line per run, appended. Survives reboots and log rotation windows,
# which the unified log does not reliably do for a once-per-deploy event.
record() {
  printf '%s base=%s verdict=%s code=%s detail=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BASE" "$1" "$2" "$3" >> "$VERIFY_LOG" 2>/dev/null || true
}

command -v curl >/dev/null || { echo "verify-listening: curl not found" >&2; exit 1; }
command -v python3 >/dev/null || { echo "verify-listening: python3 not found" >&2; exit 1; }

echo "→ Verifying from outside: $BASE (up to ${DEADLINE_SECS}s)"

started=$(date +%s)
attempt=0
last_reason="never attempted"
last_code=2
# Set at the bottom of a pass when every audible station was audible and
# the only thing left is one still resolving its first track. It selects
# which budget the next pass is measured against.
waiting_on_startup=0
last_progress=-1

while :; do
  attempt=$((attempt + 1))
  elapsed=$(( $(date +%s) - started ))
  if [ "$waiting_on_startup" -eq 1 ]; then
    budget="$STARTUP_DEADLINE_SECS"
  else
    budget="$DEADLINE_SECS"
  fi
  if [ "$elapsed" -ge "$budget" ]; then
    echo "✗ giving up after ${elapsed}s / ${attempt} attempts: ${last_reason}" >&2
    record fail "$last_code" "$(printf '%s' "$last_reason" | tr ' ' '-')"
    exit "$last_code"
  fi

  # --- 1. Can we reach the origin at all, through the public name? ---
  #
  # The status code matters, not just whether curl succeeded. When the
  # tunnel is down Cloudflare answers 530 with an error page: curl exits
  # 0 and hands back a non-empty body. Treating that as "reached the
  # origin" misreports a dead tunnel as a live one with no stations,
  # which is exactly the confusion this script exists to prevent.
  body_file="/tmp/verify-now.$$"
  http_code=$(curl -sS -o "$body_file" -w '%{http_code}' --max-time 10 "$BASE/now.json" 2>/dev/null)
  curl_status=$?
  now_json=$(cat "$body_file" 2>/dev/null)
  rm -f "$body_file"

  if [ $curl_status -ne 0 ] || [ "$http_code" != "200" ] || [ -z "$now_json" ]; then
    last_reason="public endpoint unhealthy (curl=$curl_status, http=${http_code:-000}) — DNS, Cloudflare or the tunnel is down"
    last_code=2
    echo "  attempt ${attempt}: ${last_reason}"
    sleep 5
    continue
  fi

  # --- 2. Is anything actually broadcasting, where, and is it ready? ---
  #
  # `broadcasting` means the pipeline exists, NOT that audio is flowing.
  # A station with no `currentTrack` has not resolved anything to play
  # yet, so asking it for bytes can only ever time out. That difference
  # is already on the wire; reading it is the whole fix.
  station_rows=$(printf '%s' "$now_json" | python3 -c '
import json, sys
try:
    doc = json.load(sys.stdin)
except Exception:
    sys.exit(0)
# Every broadcasting station. Verifying only the first one meant a green
# deploy while another station was silent — and which station came first
# was an accident of ordering, not a decision.
for s in doc.get("stations", []):
    if s.get("broadcasting") and s.get("streamURL"):
        state = "ready" if s.get("currentTrack") else "starting"
        print("\t".join([state, s["streamURL"], s.get("name") or "?"]))
' 2>/dev/null)

  if [ -z "$station_rows" ]; then
    last_reason="reached the origin, but no station reports broadcasting"
    last_code=3
    waiting_on_startup=0
    echo "  attempt ${attempt}: ${last_reason}"
    sleep 5
    continue
  fi

  stream_paths=$(printf '%s\n' "$station_rows" | awk -F'\t' '$1 == "ready" { print $2 }')
  starting=$(printf '%s\n' "$station_rows" | awk -F'\t' '$1 == "starting" { print $3 }' | paste -sd', ' -)

  # --- 3. Do real audio bytes arrive, for EVERY live station? ---
  # curl exits 28 when the range request is still streaming at the
  # timeout, which is the healthy case for a live stream — so read the
  # observed values rather than trusting the exit code.
  all_ok=1
  results=""
  while IFS= read -r stream_path; do
    [ -n "$stream_path" ] || continue
    read -r code ctype bytes <<<"$(curl -sS \
        -o /tmp/verify-listening.$$ \
        -w '%{http_code} %{content_type} %{size_download}' \
        --max-time "$SAMPLE_SECS" \
        -r 0-$((MIN_BYTES * 8)) \
        "$BASE$stream_path" 2>/dev/null)"
    rm -f "/tmp/verify-listening.$$"

    code="${code:-000}"; ctype="${ctype:-none}"; bytes="${bytes:-0}"

    if [ "$code" != "200" ] && [ "$code" != "206" ]; then
      last_reason="$stream_path returned HTTP $code"
      last_code=4; all_ok=0
      results="${results}    ✗ ${stream_path} status=${code}\n"
      continue
    fi
    case "$ctype" in
      audio/*) ;;
      *)
        last_reason="$stream_path returned content-type '$ctype', expected audio/*"
        last_code=4; all_ok=0
        results="${results}    ✗ ${stream_path} content-type=${ctype}\n"
        continue
        ;;
    esac
    if [ "$bytes" -lt "$MIN_BYTES" ]; then
      last_reason="$stream_path sent only ${bytes} bytes in ${SAMPLE_SECS}s (need >= ${MIN_BYTES}) — live but silent"
      last_code=4; all_ok=0
      results="${results}    ✗ ${stream_path} bytes=${bytes} (live but silent)\n"
      continue
    fi
    results="${results}    ✓ ${stream_path} status=${code} ${ctype} ${bytes}B/${SAMPLE_SECS}s\n"
  done <<EOF
$stream_paths
EOF

  if [ "$all_ok" -ne 1 ]; then
    # A station with a track that still sends no bytes is broken, not
    # slow — fail it on the short budget, as before.
    waiting_on_startup=0
    echo "  attempt ${attempt}: ${last_reason}"
    printf '%b' "$results"
    sleep 5
    continue
  fi

  # --- 4. Anything still resolving its first track? ---
  # Every station that HAS something to play is audible. If one is still
  # looking, keep waiting on the long budget rather than calling the
  # deploy broken — but say so, distinctly, so an operator watching a
  # slow NTS cold start knows nothing is wrong.
  if [ -n "$starting" ]; then
    waiting_on_startup=1
    last_reason="still resolving a first track after ${elapsed}s: ${starting}"
    last_code=5
    # One line every 30s, not one every attempt: a four-minute cold start
    # would otherwise bury the deploy in fifty identical lines.
    progress=$(( elapsed / 30 ))
    if [ "$progress" -ne "$last_progress" ]; then
      last_progress="$progress"
      echo "  waiting ${elapsed}s/${STARTUP_DEADLINE_SECS}s for a first track: ${starting}"
    fi
    sleep 10
    continue
  fi

  station_count=$(printf '%s\n' "$stream_paths" | grep -c .)
  echo "✓ listening confirmed from outside — ${station_count} station(s) in ${elapsed}s"
  printf '%b' "$results"
  record ok 0 "${station_count}-stations-audible"
  exit 0
done
