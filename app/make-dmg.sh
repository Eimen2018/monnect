#!/bin/bash
# Package Monnect.app into a drag-to-Applications DMG.
# Uses create-dmg (brew install create-dmg) for the positioned-icons window;
# falls back to plain hdiutil.
#
# Signing: auto-detects a "Developer ID Application" identity (falls back to
# ad-hoc). Set MONNECT_NOTARY_PROFILE to a notarytool keychain profile to
# notarize and staple the DMG.
# Usage: app/make-dmg.sh   (builds the app first)
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
NOTARY_PROFILE="${MONNECT_NOTARY_PROFILE:-}"

MONNECT_SIGN_IDENTITY="${IDENTITY:--}" ./make-app.sh

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
STAGING=dist/dmg-staging
DMG="dist/Monnect-$VERSION.dmg"

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R dist/Monnect.app "$STAGING/Monnect.app"

if command -v create-dmg >/dev/null; then
    create-dmg \
        --volname "Monnect $VERSION" \
        --volicon Resources/AppIcon.icns \
        --window-size 660 400 \
        --icon-size 128 \
        --icon "Monnect.app" 165 200 \
        --app-drop-link 528 200 \
        --hide-extension "Monnect.app" \
        --no-internet-enable \
        "$DMG" "$STAGING"
else
    echo "create-dmg not found — building plain DMG (brew install create-dmg for the styled one)"
    ln -s /Applications "$STAGING/Applications"
    hdiutil create -volname "Monnect $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
fi
rm -rf "$STAGING"

if [[ -n "$IDENTITY" ]]; then
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
    if [[ -n "$NOTARY_PROFILE" ]]; then
        echo "Submitting to Apple notary service (usually 1-5 minutes)..."
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
        echo "Built $DMG (notarized + stapled)"
    else
        echo "Built $DMG (signed, NOT notarized — set MONNECT_NOTARY_PROFILE)"
    fi
else
    codesign --force --sign - "$DMG"
    echo "Built $DMG (ad-hoc signed)"
fi
