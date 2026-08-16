#!/usr/bin/env bash
# Rebuild + install Ratbat.app to /Applications.
# Usage: ./install.sh

set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO"

echo "→ Regenerating Xcode project…"
xcodegen generate >/dev/null

echo "→ Building RatbatMac…"
xcodebuild -scheme RatbatMac -destination 'platform=macOS' -configuration Debug \
  build CODE_SIGNING_ALLOWED=NO -derivedDataPath ./build >/dev/null

BUILD="$REPO/build/Build/Products/Debug/Ratbat.app"
if [ ! -d "$BUILD" ]; then
  echo "Build output missing: $BUILD" >&2
  exit 1
fi

echo "→ Stopping running instance…"
# A cloudflared we don't own, connected to the same named tunnel, will
# happily serve traffic after the deploy — so the outside-in check at the
# end passes and reports a green deploy even if the new app's own tunnel
# never came up. `pkill` below only reaps the /Applications child, and the
# wait loop only watches Ratbat and the TCP port, so nothing else would
# notice. Refuse to deploy into that state rather than be lied to.
# Match on the EXECUTABLE (ps comm), not the command line. Matching the
# command line flags any process that merely mentions "cloudflared" —
# including the shell running this very script — which would refuse every
# deploy for no reason.
FOREIGN=""
for _pid in $(ps -eo pid=,comm= | awk '{ n = split($2, p, "/"); if (p[n] == "cloudflared") print $1 }'); do
  _args=$(ps -o args= -p "$_pid" 2>/dev/null || true)
  case "$_args" in
    *slapp/scripts/cloudflared.yml*) continue ;;
    */Applications/Ratbat.app/Contents/Resources/cloudflared*) continue ;;
  esac
  FOREIGN="$FOREIGN $_pid"
done
FOREIGN=$(echo "$FOREIGN" | xargs || true)
if [ -n "$FOREIGN" ]; then
  echo "Refusing to deploy: cloudflared processes running that are neither" >&2
  echo "Ratbat's nor slapp's. One of these can serve the tunnel after the" >&2
  echo "deploy and make a broken deploy look green:" >&2
  ps -o pid,etime,args -p $FOREIGN >&2
  echo "Stop them (or confirm they are unrelated) and re-run." >&2
  exit 1
fi

killall Ratbat 2>/dev/null || true

# Wait for the port to actually be released instead of assuming a fixed
# `sleep 1` is enough. If the old process still holds :18000 when the new
# one binds, the listener fails and the radio comes back silent.
PORT="${RATBAT_PORT:-18000}"
for _ in $(seq 1 40); do
  if ! pgrep -x Ratbat >/dev/null 2>&1 && ! lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done
if pgrep -x Ratbat >/dev/null 2>&1; then
  echo "Ratbat did not exit; refusing to overwrite a running app" >&2
  exit 1
fi
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Port $PORT is still held after 20s:" >&2
  lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >&2
  exit 1
fi

# Only now that we've committed to proceeding. Killing the connector
# before the go/no-go meant an aborted deploy exited having already taken
# the tunnel down, with nothing to put it back.
pkill -f '/Applications/Ratbat.app/Contents/Resources/cloudflared' 2>/dev/null || true

echo "→ Installing to /Applications/Ratbat.app…"
if [ -d /Applications/Ratbat.app ]; then
  rm -rf /Applications/Ratbat.app
fi
cp -R "$BUILD" /Applications/

echo "→ Launching…"
# -n forces a new instance. Plain `open` is a no-op against an already
# running app, so a failed kill above would silently leave the OLD build
# running and the deploy would still report success.
open -n /Applications/Ratbat.app

# The whole point. A check that hits localhost passes whenever the app is
# up — which it was throughout the outage. Prove a listener can hear it.
echo "→ Verifying a listener can actually hear it…"
# `set -e` is active, so capture the status inside an `if` — a bare call
# followed by `$?` would abort the script before the code could be read,
# and the operator would get no diagnosis at all.
if "$REPO/scripts/verify-listening.sh" "${RATBAT_PUBLIC_URL:-https://radio.jonasjohansson.se}" 120; then
  VERIFY_RC=0
else
  VERIFY_RC=$?
fi
if [ "$VERIFY_RC" -ne 0 ]; then
  echo "✗ Ratbat is installed and running, but the public radio is NOT serving audio." >&2
  echo "  The deploy is NOT complete." >&2
  # verify-listening.sh returns distinct codes precisely so the operator
  # is not sent to the wrong place. Discarding them and always saying
  # "check the tunnel" wasted the only structured diagnosis available.
  case "$VERIFY_RC" in
    2) echo "  → The public endpoint is unreachable: DNS, Cloudflare, or the tunnel." >&2
       echo "    /usr/bin/log show --last 15m --predicate 'subsystem == \"se.jonasjohansson.ratbat\" AND category == \"tunnel\"'" >&2
       ;;
    3) echo "  → The tunnel is UP; no station is broadcasting. This is a station" >&2
       echo "    problem, not a network one — check resume and the encode loop." >&2
       echo "    /usr/bin/log show --last 15m --predicate 'subsystem == \"se.jonasjohansson.ratbat\" AND category BEGINSWITH \"broadcaster\"'" >&2
       ;;
    4) echo "  → A station is live but produced no usable audio. Check the source" >&2
       echo "    and the library path, not the tunnel." >&2
       echo "    /usr/bin/log show --last 15m --predicate 'subsystem == \"se.jonasjohansson.ratbat\" AND category == \"broadcaster.encode\"'" >&2
       ;;
    *) echo "  → verify-listening.sh exited $VERIFY_RC." >&2 ;;
  esac
  echo "  Verdict history: ${RATBAT_VERIFY_LOG:-$HOME/Library/Logs/ratbat-verify.log}" >&2
  exit 1
fi

echo "✓ Ratbat installed, launched, and audible at the public URL."
