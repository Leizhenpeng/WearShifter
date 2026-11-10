#!/bin/bash
# 把 build-app.sh 产出的 .app 打成可拖拽安装的 DMG。
set -euo pipefail

cd "$(dirname "$0")/.."
./scripts/build-app.sh

APP=build/AirPodsMouse.app
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="build/AirPodsMouse-$VERSION.dmg"

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
# ditto 会保留代码签名和扩展属性。
ditto "$APP" "$STAGING/AirPodsMouse.app"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname "AirPodsMouse $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
echo "$PWD/$DMG"
