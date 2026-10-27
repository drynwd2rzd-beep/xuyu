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
rm -rf dist && mkdir -p dist

# 1. 未签名版：公开发布，用手机上的自签 App 签名安装
mkdir -p dist/Payload
cp -R "$APP" dist/Payload/
(cd dist && zip -qry Xuyu-unsigned.ipa Payload && rm -rf Payload)

# 2. 签名版：只放在需要登录才能下载的构建产物里
if [ -n "${P12_BASE64:-}" ] && [ -n "${PROFILE_BASE64:-}" ]; then
  bash scripts/sign.sh "$APP"
  mkdir -p dist/signed/Payload
  cp -R "$APP" dist/signed/Payload/
  (cd dist/signed && zip -qry Xuyu.ipa Payload && rm -rf Payload)
fi
ls -lhR dist
