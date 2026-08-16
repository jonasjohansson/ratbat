#!/usr/bin/env bash
# Run the outside-in check on a schedule, not just at deploy time.
#
# verify-listening.sh proves a listener can hear the radio *at the moment
# it runs*. Running it only from install.sh means the one question it can
# answer is "did this deploy work" — and the outage that started all of
# this began hours after a deploy that was genuinely fine. Nothing looked
# again until a human happened to notice.
#
# This wrapper answers the other question: "when did it stop". One line
# per check in $RATBAT_VERIFY_LOG, so the answer is a grep away instead of
# a guess.
#
# Usage:
#   scripts/watch-listening.sh [INTERVAL_SECONDS] [BASE_URL]
#
# Install it as a LaunchAgent (NOT done automatically — that is a
# deliberate operator action):
#   cp docs/launchagents/se.jonasjohansson.ratbat.watch.plist \
#      ~/Library/LaunchAgents/
#   launchctl load ~/Library/LaunchAgents/se.jonasjohansson.ratbat.watch.plist

set -uo pipefail

INTERVAL="${1:-300}"
BASE="${2:-https://radio.jonasjohansson.se}"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "watch-listening: checking $BASE every ${INTERVAL}s"

while :; do
  # Short deadline: this is a health check, not a deploy gate. If it can't
  # confirm audio in 45s, that is the answer.
  if "$HERE/verify-listening.sh" "$BASE" 45 >/dev/null 2>&1; then
    :
  else
    rc=$?
    # Only failures go to stderr; the artifact log records every run
    # either way, so a quiet stderr means a quiet radio in the good sense.
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) verify-listening failed rc=$rc" >&2
  fi
  sleep "$INTERVAL"
done
