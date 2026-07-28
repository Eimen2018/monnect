#!/bin/bash

# Raycast script command – add this file's folder in Raycast under
# Settings > Extensions > Script Commands > Add Directories, then you can
# trigger "Grab Input" from Raycast (and give it a hotkey).

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Grab Input
# @raycast.mode compact

# Optional parameters:
# @raycast.icon ⌨️
# @raycast.packageName monnect

exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/switch.sh"
