#!/bin/bash
# Builds ccwatch into a .app. `swift build` alone leaves a bare executable that
# shows a Dock icon, has no bundle identifier and is unsigned; these steps were
# being done by hand and were not in the repository, so a clone could not
# reproduce the app.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> swift build -c release"
swift build -c release

APP="dist/ccwatch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ccwatch "$APP/Contents/MacOS/ccwatch"
cp Info.plist "$APP/Contents/Info.plist"

# The icon is generated from code, so its origin never goes missing.
if [ ! -f AppIcon.icns ]; then
  echo "==> generate AppIcon.icns"
  swift make-icon.swift
  iconutil -c icns AppIcon.iconset -o AppIcon.icns
fi
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "==> codesign (ad-hoc)"
codesign --force --deep -s - "$APP"

echo "==> done: $APP"
echo ""
echo "Install:"
echo "  cp -r $APP ~/Applications/"
echo "  open ~/Applications/ccwatch.app"
echo ""
echo "Add as a login item (to keep it running):"
echo '  osascript -e '"'"'tell application "System Events" to make login item at end with properties {path:"'"$HOME"'/Applications/ccwatch.app", hidden:false}'"'"''
