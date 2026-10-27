#!/bin/bash
# 云端打包：编译 Release 版 → 有证书就签名 → 打成 IPA
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate

set +e
xcodebuild -project Xuyu.xcodeproj -scheme Xuyu -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build > build.log 2>&1
status=$?
set -e
if [ $status -ne 0 ]; then
  echo "::group::编译错误"
  grep -E "error:|fatal error" build.log | sort -u | head -80 || true
  echo "::endgroup::"
  tail -40 build.log
  exit $status
fi
grep -E "warning:" build.log | grep -v "deprecated" | sort -u | head -30 || true

APP=build/Build/Products/Release-iphoneos/Xuyu.app
bash scripts/sign.sh "$APP"

rm -rf dist && mkdir -p dist/Payload
cp -R "$APP" dist/Payload/
NAME="Xuyu-unsigned.ipa"
if [ -n "${P12_BASE64:-}" ] && [ -n "${PROFILE_BASE64:-}" ]; then NAME="Xuyu.ipa"; fi
(cd dist && zip -qry "$NAME" Payload && rm -rf Payload)
ls -lh dist
