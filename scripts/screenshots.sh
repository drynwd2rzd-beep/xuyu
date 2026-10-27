#!/bin/bash
# 在模拟器里用示例数据打开各个页面并截图，用来在没有 Mac 的情况下检查界面
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate

DEVICES=$(xcrun simctl list devices available -j)
UDID=$(echo "$DEVICES" | jq -r '[.devices | to_entries[] | select(.key | test("iOS")) | .value[] | select(.name | test("^iPhone [0-9]+ Pro$"))] | last | .udid')
if [ -z "$UDID" ] || [ "$UDID" = "null" ]; then
  UDID=$(echo "$DEVICES" | jq -r '[.devices | to_entries[] | select(.key | test("iOS")) | .value[] | select(.name | test("^iPhone"))] | last | .udid')
fi
echo "模拟器：$UDID"

set +e
xcodebuild -project Xuyu.xcodeproj -scheme Xuyu -configuration Debug \
  -destination "id=$UDID" -derivedDataPath build-sim CODE_SIGNING_ALLOWED=NO build > sim-build.log 2>&1
status=$?
set -e
if [ $status -ne 0 ]; then
  grep -E "error:" sim-build.log | sort -u | head -60 || true
  exit $status
fi

APP=build-sim/Build/Products/Debug-iphonesimulator/Xuyu.app
xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 || true
xcrun simctl install "$UDID" "$APP"

mkdir -p shots
shoot() {
  local name=$1 screen=$2
  xcrun simctl terminate "$UDID" app.xuyu.ios >/dev/null 2>&1 || true
  xcrun simctl launch "$UDID" app.xuyu.ios -demo YES -demoScreen "$screen" >/dev/null
  sleep 5
  xcrun simctl io "$UDID" screenshot "shots/$name.png" >/dev/null
  echo "已截图 $name"
}

for mode in light dark; do
  xcrun simctl ui "$UDID" appearance "$mode"
  shoot "$mode-1-home" home
  shoot "$mode-2-chats" chats
  shoot "$mode-3-chat" chat
  shoot "$mode-4-group" group
  shoot "$mode-5-todo" todo
  shoot "$mode-6-settings" settings
  shoot "$mode-7-persona" persona
done
