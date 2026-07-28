#!/bin/bash
# Build Monnect.app into dist/.
#
# Default: ad-hoc signed (fine for building on your own Mac).
# For a distributable, notarized build set:
#   MONNECT_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   MONNECT_NOTARY_PROFILE="your-notarytool-keychain-profile"
set -euo pipefail
cd "$(dirname "$0")"

SIGN_IDENTITY="${MONNECT_SIGN_IDENTITY:--}"
NOTARY_PROFILE="${MONNECT_NOTARY_PROFILE:-}"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)

swift build -c release

APP=dist/Monnect.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Monnect "$APP/Contents/MacOS/Monnect"
cp Info.plist "$APP/Contents/Info.plist"

if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force -s - "$APP"
  echo "built $APP (ad-hoc signed)"
else
  codesign --force --options runtime --timestamp -s "$SIGN_IDENTITY" "$APP"
  echo "built $APP (signed: $SIGN_IDENTITY)"
fi

if [ -n "$NOTARY_PROFILE" ]; then
  [ "$SIGN_IDENTITY" = "-" ] && { echo "notarization requires a real signing identity" >&2; exit 1; }
  ZIP="dist/Monnect-$VERSION.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "submitting to Apple notary service..."
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  # Re-zip so the download contains the stapled ticket.
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "notarized and stapled: $ZIP"
fi
