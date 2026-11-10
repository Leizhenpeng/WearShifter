#!/bin/bash
# 打包 Mac 应用的 DMG。默认只有开发证书，没有公证，其他 Mac 上会被系统拦截。
set -euo pipefail

cd "$(dirname "$0")/.."
./scripts/build-app.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' build/WatchMouse.app/Contents/Info.plist)
STAGE=build/dmg
OUTPUT="build/WatchMouse-$VERSION.dmg"
rm -rf "$STAGE" "$OUTPUT"
mkdir -p "$STAGE"
cp -R build/WatchMouse.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname WatchMouse -srcfolder "$STAGE" -ov -format UDZO "$OUTPUT" >/dev/null
rm -rf "$STAGE"
echo "$PWD/$OUTPUT"
