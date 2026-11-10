#!/bin/bash
# 蓝牙权限要求 Info.plist 里有 NSBluetoothAlwaysUsageDescription，所以必须打成 .app 运行。
set -euo pipefail

cd "$(dirname "$0")/.."
# 同时支持 Apple 芯片和 Intel。
BUILD_ARGS=(-c release --arch arm64 --arch x86_64)
swift build "${BUILD_ARGS[@]}" --product WatchMouseMac

APP=build/WatchMouse.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/WatchMouseMac" "$APP/Contents/MacOS/WatchMouse"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>WatchMouse</string>
    <key>CFBundleIdentifier</key><string>local.watchmouse.mac</string>
    <key>CFBundleName</key><string>WatchMouse</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSBluetoothAlwaysUsageDescription</key><string>接收 Apple Watch 发来的手腕运动数据，用来移动光标。</string>
</dict>
</plist>
PLIST
# 有开发者证书就用证书：临时签名每次构建都会变，系统会要求重新授予辅助功能权限。
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -nE 's/.*"(Apple Development:[^"]+)".*/\1/p' | head -1)}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "$PWD/$APP"
