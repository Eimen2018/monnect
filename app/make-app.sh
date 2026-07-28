#!/bin/bash
# Build Monnect.app into dist/. Ad-hoc signed; same bundle works on any
# Apple Silicon Mac.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=dist/Monnect.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Monnect "$APP/Contents/MacOS/Monnect"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force -s - "$APP"
echo "built $APP"
