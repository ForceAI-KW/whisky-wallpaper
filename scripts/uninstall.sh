#!/bin/bash
# Whisky Wallpaper — reverse install.sh.
# 1. Quit running instance
# 2. Remove /Applications/Whisky Wallpaper.app
# 3. Remove Login Item
# 4. Remove UserDefaults (com.ahmadsharaf.WhiskyWallpaper)
# Idempotent — silent on already-clean state.

set -uo pipefail

TARGET_NAME="Whisky Wallpaper"
INSTALL_PATH="/Applications/${TARGET_NAME}.app"
BUNDLE_ID="com.ahmadsharaf.WhiskyWallpaper"

echo "→ quitting running instance (if any)"
osascript -e "tell application \"${TARGET_NAME}\" to quit" 2>/dev/null || true
sleep 0.5
killall WhiskyWallpaper 2>/dev/null || true

echo "→ removing ${INSTALL_PATH}"
rm -rf "$INSTALL_PATH"

echo "→ removing Login Item"
osascript <<EOF 2>/dev/null || true
tell application "System Events"
    if exists login item "${TARGET_NAME}" then
        delete login item "${TARGET_NAME}"
    end if
end tell
EOF

echo "→ clearing UserDefaults (${BUNDLE_ID})"
defaults delete "$BUNDLE_ID" 2>/dev/null || true

cat <<EOF

✓ Uninstalled.
  Your video files in ~/Downloads (or wherever you kept them) are untouched.
EOF
