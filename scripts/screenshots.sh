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
  shoot "$mode-8-stickers" stickers
  shoot "$mode-9-calendar" calendar
  shoot "$mode-10-backup" backup
  shoot "$mode-11-moments" moments
  shoot "$mode-12-profile" profile
done
# 动画录屏：深色模式、照片背景下跑一遍演示剧本（进出聊天、发消息、回复、侧滑），之后逐帧检查
xcrun simctl ui "$UDID" appearance dark
xcrun simctl terminate "$UDID" app.xuyu.ios >/dev/null 2>&1 || true
xcrun simctl io "$UDID" recordVideo --codec h264 --force shots/motion.mp4 &
REC=$!
sleep 2
xcrun simctl launch "$UDID" app.xuyu.ios -demo YES -demoScreen motion >/dev/null
sleep 34
kill -INT $REC || true
wait $REC || true
xcrun simctl terminate "$UDID" app.xuyu.ios >/dev/null 2>&1 || true
echo "已录屏 motion.mp4"
xcrun simctl ui "$UDID" appearance light

# 自动操作测试：把主要流程点一遍（闪退会让这一步失败）
set +e
xcodebuild test -project Xuyu.xcodeproj -scheme Xuyu -destination "id=$UDID" -derivedDataPath build-sim \
  CODE_SIGNING_ALLOWED=NO > ui-test.log 2>&1
test_status=$?
set -e
grep -E "Test Case|error:|failed|闪退|没有出现" ui-test.log | tail -120 || true
if [ $test_status -ne 0 ]; then
  echo "自动操作测试没通过"
  exit $test_status
fi
