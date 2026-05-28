#!/bin/bash
# Whisky Wallpaper — end-to-end installer.
# 1. Build Release with Xcode
# 2. Codesign with stable self-signed identity if present (else ad-hoc fallback)
# 3. Quit any running instance + copy to /Applications/Whisky Wallpaper.app
# 4. Launch + register as a Login Item
# Idempotent — safe to re-run.

INSTALLER_VERSION="1.2.1"

set -euo pipefail
cd "$(dirname "$0")/.."

echo "Whisky Wallpaper installer v${INSTALLER_VERSION}"

PROJECT="WhiskyWallpaper.xcodeproj"
SCHEME="WhiskyWallpaper"
TARGET_NAME="Whisky Wallpaper"        # display name with space
SOURCE_APP="build/Build/Products/Release/WhiskyWallpaper.app"
RENAMED_APP="build/Build/Products/Release/${TARGET_NAME}.app"
INSTALL_PATH="/Applications/${TARGET_NAME}.app"

echo "→ generating Release build"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -derivedDataPath build \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
    clean build | tail -5

if [ ! -d "$SOURCE_APP" ]; then
    echo "✗ build output missing at $SOURCE_APP" >&2
    exit 1
fi

# Rename the product on disk so /Applications/Whisky Wallpaper.app matches
# the display name. Work on a copy so we don't disturb the original build
# output Xcode might re-touch on incremental rebuilds.
rm -rf "$RENAMED_APP"
cp -R "$SOURCE_APP" "$RENAMED_APP"

echo "→ codesign"
# Use stable self-signed identity if present so the binary's designated
# requirement (and therefore TCC grants) survive reinstalls. Falls back to
# ad-hoc if the cert was removed from the keychain.
SIGN_ID="Ahmad Sharaf Code Signing"
if security find-certificate -c "$SIGN_ID" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1; then
    codesign --force --deep --sign "$SIGN_ID" "$RENAMED_APP"
else
    echo "  (cert '$SIGN_ID' not found — falling back to ad-hoc; TCC grants will reset)"
    codesign --force --deep --sign - "$RENAMED_APP"
fi

echo "→ installing to /Applications"
osascript -e "tell application \"${TARGET_NAME}\" to quit" 2>/dev/null || true
sleep 0.5

# If the previously-installed binary was signed with a DIFFERENT identity
# (e.g. ad-hoc → stable cert, or rotating certs), stale TCC grants keyed to
# the old designated requirement will silently fail at runtime. Reset only
# when DRs differ, otherwise let grants persist (the point of stable certs).
NEW_DR=$(codesign -d -r- "$RENAMED_APP" 2>&1 | sed -n 's/^designated => //p')
OLD_DR=""
if [ -d "$INSTALL_PATH" ]; then
    OLD_DR=$(codesign -d -r- "$INSTALL_PATH" 2>&1 | sed -n 's/^designated => //p')
fi
if [ -n "$OLD_DR" ] && [ "$OLD_DR" != "$NEW_DR" ]; then
    echo "→ signing identity changed — resetting TCC grants so they re-bind"
    BUNDLE_ID=$(plutil -extract CFBundleIdentifier raw "$RENAMED_APP/Contents/Info.plist" 2>/dev/null || echo "com.ahmadsharaf.WhiskyWallpaper")
    for service in Accessibility AppleEvents Microphone SpeechRecognition ScreenCapture InputMonitoring AudioCapture; do
        tccutil reset "$service" "$BUNDLE_ID" >/dev/null 2>&1 || true
    done
    echo "  (you'll be prompted once for each permission on first launch — grants will persist after that)"
fi

rm -rf "$INSTALL_PATH"
cp -R "$RENAMED_APP" "$INSTALL_PATH"

# Clean up build artifacts so Spotlight only surfaces the /Applications copy.
rm -rf "$SOURCE_APP" "$RENAMED_APP"

echo "→ launching"
open "$INSTALL_PATH"

echo "→ registering Login Item"
osascript <<EOF
tell application "System Events"
    if not (exists login item "${TARGET_NAME}") then
        make login item at end with properties {path:"${INSTALL_PATH}", hidden:false}
    end if
end tell
EOF

cat <<EOF

✓ Installed.
  App:        ${INSTALL_PATH}
  Login Item: registered, will auto-launch each login

Next: drop video files into ~/Downloads, then click the ✨ menu bar icon.
      Free 4K wallpapers: https://moewalls.com  ·  https://pixabay.com/videos

Uninstall:   ./scripts/uninstall.sh
EOF
