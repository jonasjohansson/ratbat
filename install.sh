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
killall Ratbat 2>/dev/null || true
killall cloudflared 2>/dev/null || true
sleep 1

echo "→ Installing to /Applications/Ratbat.app…"
if [ -d /Applications/Ratbat.app ]; then
  rm -rf /Applications/Ratbat.app
fi
cp -R "$BUILD" /Applications/

echo "→ Launching…"
open /Applications/Ratbat.app

echo "✓ Ratbat installed + launched."
