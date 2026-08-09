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
# Target OUR cloudflared by its bundle path. `killall cloudflared` also
# killed slapp's tunnel, which is a different service that merely shares
# this machine — it survived only because slapp's launchd job has
# KeepAlive=true, i.e. by luck rather than by design.
killall Ratbat 2>/dev/null || true
pkill -f '/Applications/Ratbat.app/Contents/Resources/cloudflared' 2>/dev/null || true

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
if ! "$REPO/scripts/verify-listening.sh" "${RATBAT_PUBLIC_URL:-https://radio.jonasjohansson.se}" 120; then
  echo "✗ Ratbat is installed and running, but the public radio is NOT serving audio." >&2
  echo "  The deploy is NOT complete. Check the tunnel:" >&2
  echo "    log show --last 15m --predicate 'subsystem == \"se.jonasjohansson.ratbat\"' --info" >&2
  exit 1
fi

echo "✓ Ratbat installed, launched, and audible at the public URL."
