#!/bin/bash
# ccwatch を .app にビルドする。`swift build` だけだと生の実行ファイルが
# 出るだけで、Dockアイコンが出る・bundle identifierが無い・署名が無い状態
# になる — 実際にこの手順を毎回手作業でやっていて、リポジトリのどこにも
# 残っていなかった(git cloneした別の人が再現できない)。
set -euo pipefail
cd "$(dirname "$0")"

echo "==> swift build -c release"
swift build -c release

APP="dist/ccwatch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ccwatch "$APP/Contents/MacOS/ccwatch"
cp Info.plist "$APP/Contents/Info.plist"

# アイコンはコードから生成する(make-icon.swift が SF Symbol を描く)ので、
# 画像ファイルの出どころが分からなくなることがない。icns が無ければ作る。
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
echo "インストール:"
echo "  cp -r $APP ~/Applications/"
echo "  open ~/Applications/ccwatch.app"
echo ""
echo "ログイン項目に登録(常駐させる場合):"
echo '  osascript -e '"'"'tell application "System Events" to make login item at end with properties {path:"'"$HOME"'/Applications/ccwatch.app", hidden:false}'"'"''
