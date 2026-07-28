#!/bin/bash
# monnect – shared helpers. Sourced by the other scripts, not run directly.

CONFIG_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"

die() { echo "error: $*" >&2; exit 1; }

load_config() {
  [ -f "$CONFIG_FILE" ] || die "no config found. Run ./setup.sh first."
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
  [ ${#DEVICES[@]} -gt 0 ] || die "no devices configured in $CONFIG_FILE"
}

find_blueutil() {
  BLUEUTIL="$(command -v blueutil || true)"
  [ -n "$BLUEUTIL" ] || BLUEUTIL="$(ls /opt/homebrew/bin/blueutil /usr/local/bin/blueutil 2>/dev/null | head -1)"
  [ -n "$BLUEUTIL" ] || die "blueutil not found. Install with: brew install blueutil"
}

is_connected() { [ "$("$BLUEUTIL" --is-connected "$1" 2>/dev/null)" = "1" ]; }

# Magic devices hold exactly ONE pairing. Switching hosts means the old host
# must UNPAIR (not just disconnect) — only then will the device accept a
# pairing from the new host.

# Give up ownership of one device so another Mac can pair with it.
release_device() {
  local addr="$1"
  "$BLUEUTIL" --unpair "$addr" >/dev/null 2>&1 || true
  echo "released $addr"
}

# Take ownership of all devices: clear stale pairing records, then keep
# attempting to pair each one for up to 90s. Magic devices accept a new host
# in the moments right after being power-cycled, so the ritual is: run the
# switch, then flip each device off -> wait 3s -> on. The loop interleaves
# all devices, so power-cycle them in any order.
claim_all() {
  local end=$((SECONDS+90)) addr done_flag rc
  for addr in "$@"; do
    is_connected "$addr" || "$BLUEUTIL" --unpair "$addr" >/dev/null 2>&1 || true
  done
  while [ $SECONDS -lt $end ]; do
    done_flag=1
    for addr in "$@"; do
      is_connected "$addr" && continue
      done_flag=0
      "$BLUEUTIL" --pair "$addr" >/dev/null 2>&1 || true
      is_connected "$addr" || "$BLUEUTIL" --connect "$addr" >/dev/null 2>&1 || true
      is_connected "$addr" && echo "connected $addr"
    done
    [ $done_flag -eq 1 ] && return 0
    sleep 1
  done
  rc=0
  for addr in "$@"; do
    if is_connected "$addr"; then
      echo "connected $addr"
    else
      echo "FAILED to claim $addr — power-cycle it (off, 3s, on) and rerun" >&2
      rc=1
    fi
  done
  return $rc
}
