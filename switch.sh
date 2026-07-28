#!/bin/bash
# monnect – pull the mouse + keyboard over to THIS Mac.
#
# 1. Tells the other Mac (over ssh) to release the peripherals.
# 2. Connects them here.
#
# If the other Mac is unreachable (asleep, off network), it still tries to
# connect locally — a sleeping Mac usually isn't holding the connection anyway.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"

load_config
find_blueutil

echo "after the release below, power-cycle each device (off, 3s, on) — the"
echo "claim loop watches for them for 90s and grabs each as it wakes up"
if [ -n "${PEER_HOST:-}" ]; then
  echo "asking $PEER_HOST to release..."
  if ssh -o BatchMode=yes -o ConnectTimeout=3 "$PEER_HOST" "\"$PEER_MONNECT_DIR/release.sh\""; then
    :
  else
    echo "peer unreachable or release failed — trying to connect anyway" >&2
  fi
else
  echo "no PEER_HOST configured — connecting locally only" >&2
fi

"$DIR/claim.sh"
rc=$?

if [ $rc -eq 0 ]; then
  osascript -e 'display notification "Mouse & keyboard are now on this Mac" with title "monnect"' 2>/dev/null || true
else
  osascript -e 'display notification "Could not grab some devices — see terminal" with title "monnect"' 2>/dev/null || true
fi
exit $rc
