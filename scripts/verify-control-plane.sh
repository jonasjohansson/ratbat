#!/usr/bin/env bash
# Verify that the OWNER — someone who is NOT on the mac-mini — can still
# steer the radio: create a station, edit it, start it, stop it, delete
# it, all through the public origin.
#
# verify-listening.sh proves a listener can hear the radio. It proves
# nothing about the control plane: every /stations/* route could 404 (or
# worse, answer without auth) while audio flows happily. This script is
# the other half of the same outside-in philosophy — through Cloudflare,
# never localhost — because the only owner surface that matters is the
# one reachable from a phone on the couch.
#
# The write tests run against a THROWAWAY station created for the run and
# deleted at the end. A trap deletes it even when a mid-flight step fails,
# because the station file is Drive-synced: leftovers don't just litter
# the sidebar on the Mini, they sync to every machine.
#
# Auth: the owner passcode comes from $RATBAT_OWNER_TOKEN or, failing
# that, a mode-600 ~/.ratbat-owner-token file (override the path with
# $RATBAT_OWNER_TOKEN_FILE). With neither, the write tests are SKIPPED
# loudly and only /health is asserted — a deploy without a token on the
# box goes green-with-a-warning, never green-by-omission.
#
# Each run appends a one-line verdict to $RATBAT_VERIFY_LOG (default
# ~/Library/Logs/ratbat-verify.log), same artifact discipline as
# verify-listening.sh: a check that leaves no trace can only answer
# "is it working right now", never "when did it break".
#
# Usage:
#   scripts/verify-control-plane.sh [BASE_URL]
#
# BASE_URL falls back to $RATBAT_ORIGIN, then the production origin.
# Pointing BASE_URL at a local stub server is also how the cleanup trap
# is tested — see the trap-path note above cleanup().
#
# Exit codes are distinct so a caller (install.sh) can diagnose:
#   0  control plane verified (or write tests skipped — see above)
#   1  usage / missing dependency
#   2  /health absent, unhealthy, or missing the stations capability
#   3  auth broken: right passcode rejected, or wrong passcode accepted
#   4  /stations/create failed
#   5  /stations/list or /stations/update failed (incl. projection leak)
#   6  /stations/start failed
#   7  /stations/stop failed
#   8  /stations/delete failed, or the station survived deletion

set -uo pipefail

BASE="${1:-${RATBAT_ORIGIN:-https://radio.jonasjohansson.se}}"

VERIFY_LOG="${RATBAT_VERIFY_LOG:-$HOME/Library/Logs/ratbat-verify.log}"
mkdir -p "$(dirname "$VERIFY_LOG")" 2>/dev/null || true

# One line per run, appended — surface=control-plane so this script's
# verdicts and verify-listening's share one history file without
# ambiguity about which check said what.
record() {
  printf '%s surface=control-plane base=%s verdict=%s code=%s detail=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BASE" "$1" "$2" "$3" >> "$VERIFY_LOG" 2>/dev/null || true
}

command -v curl >/dev/null || { echo "verify-control-plane: curl not found" >&2; exit 1; }
command -v python3 >/dev/null || { echo "verify-control-plane: python3 not found" >&2; exit 1; }

# ---------------------------------------------------------------------------
# HTTP + JSON helpers
# ---------------------------------------------------------------------------

# POST a JSON body; leaves the status in HTTP_CODE and the body in
# HTTP_BODY. The status code is read from -w, not curl's exit status —
# a 403 is a *successful* transfer as far as curl is concerned, and
# several steps below deliberately expect non-2xx answers.
HTTP_CODE=""
HTTP_BODY=""
http_post() {
  local path="$1" body="$2" max_time="${3:-15}"
  local out="/tmp/verify-cp.$$"
  HTTP_CODE=$(curl -sS -o "$out" -w '%{http_code}' --max-time "$max_time" \
    -H 'Content-Type: application/json' --data "$body" \
    "$BASE$path" 2>/dev/null)
  local rc=$?
  HTTP_BODY=$(cat "$out" 2>/dev/null || true)
  rm -f "$out"
  [ $rc -eq 0 ] || HTTP_CODE="000"
}

http_get() {
  local path="$1" max_time="${2:-15}"
  local out="/tmp/verify-cp.$$"
  HTTP_CODE=$(curl -sS -o "$out" -w '%{http_code}' --max-time "$max_time" \
    "$BASE$path" 2>/dev/null)
  local rc=$?
  HTTP_BODY=$(cat "$out" 2>/dev/null || true)
  rm -f "$out"
  [ $rc -eq 0 ] || HTTP_CODE="000"
}

# JSON-quote an arbitrary string. The passcode is human-chosen and may
# contain quotes or backslashes; interpolating it raw into a JSON literal
# would turn an exotic passcode into a parse error that reads as "auth
# broken", which is the one misdiagnosis this script must not make.
json_string() {
  python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$1"
}

fail() {
  local code="$1" reason="$2"
  echo "✗ $reason" >&2
  record fail "$code" "$(printf '%s' "$reason" | tr ' ' '-')"
  exit "$code"
}

# ---------------------------------------------------------------------------
# Cleanup trap
# ---------------------------------------------------------------------------

STATION_ID=""
STATION_NAME=""
STATION_DELETED=0
TOKEN_JSON=""

# Runs on EVERY exit path once a throwaway station exists. A failed step
# between create and delete must not strand the station: the file it
# lives in is Drive-synced, so a leftover propagates to every machine
# and — worse — a `zz-verify-*` station with auto-resume semantics could
# end up on air.
#
# Trap-path testing: point BASE at a local stub that fails a mid-flight
# step (e.g. answer /stations/update with 500) and assert the stub still
# received /stations/delete afterwards. `scripts/` has no test harness of
# its own, so this is exercised manually; the stub run for this script's
# introduction is recorded in the commit message.
cleanup() {
  local rc=$?
  if [ -n "$STATION_ID" ] && [ "$STATION_DELETED" -ne 1 ]; then
    echo "→ cleanup: removing throwaway station '$STATION_NAME' ($STATION_ID)"
    # Stop first, delete second. The delete route stops server-side too,
    # but belt-and-braces costs one request and covers a server old
    # enough to have delete without the stop-first behavior.
    http_post "/stations/stop" \
      "{\"token\":$TOKEN_JSON,\"station\":\"$STATION_ID\"}" 15 || true
    http_post "/stations/delete" \
      "{\"token\":$TOKEN_JSON,\"station\":\"$STATION_ID\"}" 15 || true
    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "410" ]; then
      echo "  ✓ throwaway station removed"
    else
      # The one state this script must never leave silently: tell the
      # operator exactly what to delete by hand.
      echo "  ✗ could NOT delete throwaway station '$STATION_NAME' (HTTP $HTTP_CODE)." >&2
      echo "    Remove it manually in the Ratbat sidebar on the Mini." >&2
      record fail 8 "cleanup-left-station-$STATION_NAME"
    fi
  fi
  exit "$rc"
}
trap cleanup EXIT
# Convert signals into an exit so the EXIT trap always runs — an
# interrupted verify is precisely when a throwaway is most likely live.
trap 'exit 130' INT TERM

# ---------------------------------------------------------------------------
# Step 1 — /health: is the control plane there at all?
# ---------------------------------------------------------------------------

echo "→ Verifying control plane from outside: $BASE"

http_get "/health" 15
if [ "$HTTP_CODE" != "200" ]; then
  fail 2 "GET /health answered HTTP $HTTP_CODE — control plane absent (old build deployed?)"
fi

health_check=$(printf '%s' "$HTTP_BODY" | python3 -c '
import json, sys
try:
    doc = json.load(sys.stdin)
except Exception:
    print("unparseable"); sys.exit(0)
if doc.get("status") != "ok":
    # "degraded" means the app is up but storeless — a real deploy
    # problem this script should fail on, distinctly worded.
    print("status:" + str(doc.get("status"))); sys.exit(0)
caps = doc.get("capabilities") or []
if not caps:
    print("no-capabilities"); sys.exit(0)
if "stations" not in caps:
    print("no-stations-capability"); sys.exit(0)
print("ok " + str(doc.get("version")))
' 2>/dev/null)

case "$health_check" in
  ok\ *)
    echo "  ✓ /health ok (version ${health_check#ok })"
    ;;
  no-stations-capability)
    # The build this script ships with advertises `stations`; its absence
    # means an older build answered — the deploy did not actually land.
    fail 2 "/health lacks the stations capability — an old build is serving"
    ;;
  *)
    fail 2 "/health unhealthy: $health_check"
    ;;
esac

# ---------------------------------------------------------------------------
# Token — env first, then the file. No token: skip loudly, exit green.
# ---------------------------------------------------------------------------

TOKEN="${RATBAT_OWNER_TOKEN:-}"
TOKEN_FILE="${RATBAT_OWNER_TOKEN_FILE:-$HOME/.ratbat-owner-token}"
if [ -z "$TOKEN" ] && [ -f "$TOKEN_FILE" ]; then
  TOKEN=$(head -n1 "$TOKEN_FILE" | tr -d '[:space:]')
fi
if [ -z "$TOKEN" ]; then
  echo "⚠ SKIPPED write tests: no owner token." >&2
  echo "  Provide RATBAT_OWNER_TOKEN or a mode-600 $TOKEN_FILE to exercise" >&2
  echo "  the authed create→update→start→stop→delete round trip." >&2
  record skip 0 "no-owner-token"
  exit 0
fi
TOKEN_JSON=$(json_string "$TOKEN")

# ---------------------------------------------------------------------------
# Step 2 — /auth: both directions of the gate
# ---------------------------------------------------------------------------

http_post "/auth" "{\"token\":$TOKEN_JSON}" 15
if [ "$HTTP_CODE" != "200" ]; then
  fail 3 "POST /auth rejected the owner token (HTTP $HTTP_CODE) — wrong token, or auth broken"
fi

# The negative case matters as much: a gate that answers 200 to garbage
# is an open door reporting itself locked. Timestamp suffix so the value
# can never collide with a real passcode.
http_post "/auth" "{\"token\":\"wrong-$(date +%s)\"}" 30
if [ "$HTTP_CODE" != "403" ]; then
  fail 3 "POST /auth answered HTTP $HTTP_CODE to a wrong token (expected 403) — the owner gate is open"
fi
echo "  ✓ /auth accepts the owner and rejects a stranger"

# ---------------------------------------------------------------------------
# Step 3 — create a throwaway station
# ---------------------------------------------------------------------------

# zz- prefix so the throwaway sorts to the bottom of every name-ordered
# list it might briefly appear in; epoch suffix so two overlapping runs
# can't collide. NTS kind because it needs no API key to be born.
STATION_NAME="zz-verify-$(date +%s)"
create_body=$(printf '{"token":%s,"kind":"nts","name":"%s","shufflePool":true,"query":{"genreTags":["ambient"],"yearMin":null,"yearMax":null,"regions":[],"tagMatch":"any","popularity":"middle","excludeOwnedLibrary":false,"excludedArtists":[]}}' \
  "$TOKEN_JSON" "$STATION_NAME")
http_post "/stations/create" "$create_body" 30
if [ "$HTTP_CODE" != "201" ]; then
  fail 4 "POST /stations/create answered HTTP $HTTP_CODE (expected 201): $HTTP_BODY"
fi
STATION_ID=$(printf '%s' "$HTTP_BODY" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin)["station"]["id"])
except Exception:
    pass
' 2>/dev/null)
if [ -z "$STATION_ID" ]; then
  fail 4 "create answered 201 but no station.id could be read from: $HTTP_BODY"
fi
echo "  ✓ created throwaway '$STATION_NAME' ($STATION_ID)"

# From here on the trap owns the station's fate on any failure.

# ---------------------------------------------------------------------------
# Step 4 — list-confirm, update, list-confirm the edit
# ---------------------------------------------------------------------------

list_contains() {
  # $1 = station id, $2 = "" or a tag that must be present on it.
  # Also asserts the projection guarantee on the WHOLE body: no route
  # may ever leak a local file path, so `file://` anywhere is a failure
  # regardless of which station it came from.
  printf '%s' "$HTTP_BODY" | python3 -c '
import json, sys
sid, tag = sys.argv[1], sys.argv[2]
raw = sys.stdin.read()
if "file://" in raw:
    print("leak"); sys.exit(0)
try:
    stations = json.loads(raw)["stations"]
except Exception:
    print("unparseable"); sys.exit(0)
for s in stations:
    if s.get("id") == sid:
        if tag and tag not in ((s.get("query") or {}).get("genreTags") or []):
            print("present-without-edit"); sys.exit(0)
        print("present"); sys.exit(0)
print("absent")
' "$1" "${2:-}" 2>/dev/null
}

http_post "/stations/list" "{\"token\":$TOKEN_JSON}" 15
[ "$HTTP_CODE" = "200" ] || fail 5 "POST /stations/list answered HTTP $HTTP_CODE"
case "$(list_contains "$STATION_ID")" in
  present) ;;
  leak)    fail 5 "/stations/list leaked a file:// path — projection broken" ;;
  *)       fail 5 "created station missing from /stations/list" ;;
esac

# Sparse update: replace the query with one more tag, applyNow:false so
# an (idle) throwaway can never interrupt anything audible.
update_body=$(printf '{"token":%s,"station":"%s","applyNow":false,"query":{"genreTags":["ambient","drone"],"yearMin":null,"yearMax":null,"regions":[],"tagMatch":"any","popularity":"middle","excludeOwnedLibrary":false,"excludedArtists":[]}}' \
  "$TOKEN_JSON" "$STATION_ID")
http_post "/stations/update" "$update_body" 30
[ "$HTTP_CODE" = "200" ] || fail 5 "POST /stations/update answered HTTP $HTTP_CODE: $HTTP_BODY"

http_post "/stations/list" "{\"token\":$TOKEN_JSON}" 15
[ "$HTTP_CODE" = "200" ] || fail 5 "POST /stations/list (after update) answered HTTP $HTTP_CODE"
case "$(list_contains "$STATION_ID" "drone")" in
  present) echo "  ✓ create → list → update → list round trip holds" ;;
  leak)    fail 5 "/stations/list leaked a file:// path — projection broken" ;;
  present-without-edit) fail 5 "update answered 200 but the edit is not in /stations/list" ;;
  *)       fail 5 "station vanished from /stations/list after update" ;;
esac

# ---------------------------------------------------------------------------
# Step 5 — start, stop
# ---------------------------------------------------------------------------

# A real start: the throwaway goes on air briefly. That is the point —
# the web stop-the-last-station lockout (the listener-rebind hole) only
# regresses on a real start/stop cycle, and verify-listening.sh has
# already proven the *other* stations' audio, so a short-lived extra
# station is the cheapest honest probe. Generous timeout: an NTS start
# resolves tracks before it reports broadcasting.
http_post "/stations/start" "{\"token\":$TOKEN_JSON,\"station\":\"$STATION_ID\"}" 120
[ "$HTTP_CODE" = "200" ] || fail 6 "POST /stations/start answered HTTP $HTTP_CODE: $HTTP_BODY"

http_post "/stations/stop" "{\"token\":$TOKEN_JSON,\"station\":\"$STATION_ID\"}" 30
[ "$HTTP_CODE" = "200" ] || fail 7 "POST /stations/stop answered HTTP $HTTP_CODE: $HTTP_BODY"
echo "  ✓ start → stop cycle survived"

# ---------------------------------------------------------------------------
# Step 6 — delete, confirm gone
# ---------------------------------------------------------------------------

http_post "/stations/delete" "{\"token\":$TOKEN_JSON,\"station\":\"$STATION_ID\"}" 30
[ "$HTTP_CODE" = "200" ] || fail 8 "POST /stations/delete answered HTTP $HTTP_CODE: $HTTP_BODY"
STATION_DELETED=1

http_post "/stations/list" "{\"token\":$TOKEN_JSON}" 15
[ "$HTTP_CODE" = "200" ] || fail 8 "POST /stations/list (after delete) answered HTTP $HTTP_CODE"
case "$(list_contains "$STATION_ID")" in
  absent) ;;
  *) STATION_DELETED=0; fail 8 "delete answered 200 but the station is still in /stations/list" ;;
esac

echo "✓ control plane verified from outside — create/update/start/stop/delete all answer"
record ok 0 "crud-round-trip-verified"
exit 0
