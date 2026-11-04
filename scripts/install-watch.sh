#!/bin/bash
# 构建手表应用并装到真机。用法：scripts/install-watch.sh <手表 UDID>
set -euo pipefail

cd "$(dirname "$0")/.."
DEVICE="${1:?请传手表 UDID，可用 xcrun devicectl list devices 查看}"
xcodegen generate
xcodebuild -project WatchMouse.xcodeproj -scheme WatchMouse -configuration Debug \
  -destination "id=$DEVICE" -derivedDataPath build/DerivedData -allowProvisioningUpdates build
APP=build/DerivedData/Build/Products/Debug-watchos/WatchMouse.app
xcrun devicectl device install app --device "$DEVICE" "$APP"
xcrun devicectl device process launch --device "$DEVICE" com.chening.watchmouse.watchkitapp
