#!/bin/bash
# 归档并上传到 App Store Connect。每次重新上传前先递增 project.yml 的 CURRENT_PROJECT_VERSION。
set -euo pipefail

cd "$(dirname "$0")/.."
swift test
xcodegen generate
xcodebuild -project WatchMouse.xcodeproj -scheme WatchMouse -configuration Release \
  -destination 'generic/platform=watchOS' -archivePath build/release/WatchMouse.xcarchive \
  -derivedDataPath build/release/DerivedData -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath build/release/WatchMouse.xcarchive \
  -exportPath build/release/TestFlight -exportOptionsPlist Release/ExportOptions.plist \
  -allowProvisioningUpdates
