#!/bin/bash
# 把手表上的采集文件导出到 data/captures。用法：scripts/pull-captures.sh <手表 UDID>
set -euo pipefail

cd "$(dirname "$0")/.."
DEVICE="${1:?请传手表 UDID，可用 xcrun devicectl list devices 查看}"
mkdir -p data/captures
xcrun devicectl device copy from --device "$DEVICE" \
  --domain-type appDataContainer --domain-identifier com.chening.watchmouse.watchkitapp \
  --source Documents/captures --destination data/captures
ls -la data/captures
