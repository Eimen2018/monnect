#!/bin/bash
# monnect – connect the shared peripherals to THIS Mac.
# Assumes the other Mac has already released them (switch.sh handles that).
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

load_config
find_blueutil

claim_all "${DEVICES[@]}"
