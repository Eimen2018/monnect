#!/bin/bash
# monnect – unpair the shared peripherals from THIS Mac so the other one
# can claim them. Run locally or via ssh from the other Mac.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

load_config
find_blueutil

for addr in "${DEVICES[@]}"; do
  release_device "$addr"
done
