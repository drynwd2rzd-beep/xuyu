#!/bin/bash
# 用 GitHub Secrets 里的 p12 证书和描述文件给 .app 签名。
# 需要的 Secrets：P12_BASE64、P12_PASSWORD、PROFILE_BASE64。没有就保持未签名。
set -euo pipefail
APP="$1"

if [ -z "${P12_BASE64:-}" ] || [ -z "${PROFILE_BASE64:-}" ]; then
  echo "没有配置签名证书，输出未签名的 IPA。"
  exit 0
fi

TMP="${RUNNER_TEMP:-/tmp}/xuyu-sign"
mkdir -p "$TMP"
KC="$TMP/sign.keychain-db"
KCPW="$(uuidgen)"

security create-keychain -p "$KCPW" "$KC"
security set-keychain-settings -lut 21600 "$KC"
security unlock-keychain -p "$KCPW" "$KC"
echo "$P12_BASE64" | base64 --decode > "$TMP/cert.p12"
security import "$TMP/cert.p12" -P "${P12_PASSWORD:-}" -A -t cert -f pkcs12 -k "$KC" >/dev/null
security list-keychains -d user -s "$KC" $(security list-keychains -d user | sed 's/"//g')
security set-key-partition-list -S apple-tool:,apple: -s -k "$KCPW" "$KC" >/dev/null
IDENTITY=$(security find-identity -v -p codesigning "$KC" | awk 'NR==1 {print $2}')
if [ -z "$IDENTITY" ]; then
  echo "::error::证书里没有找到可用的签名身份，请检查 p12 和密码。"
  exit 1
fi

echo "$PROFILE_BASE64" | base64 --decode > "$TMP/profile.mobileprovision"
security cms -D -i "$TMP/profile.mobileprovision" > "$TMP/profile.plist"
/usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$TMP/profile.plist" > "$TMP/entitlements.plist"
APPID=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$TMP/profile.plist")
TEAM="${APPID%%.*}"
PROFILE_BUNDLE="${APPID#*.}"

# 描述文件是通配符（*）就用我们自己的包名；是固定包名就跟着描述文件走
case "$PROFILE_BUNDLE" in
  "*") BUNDLE="app.xuyu.ios" ;;
  *'*') BUNDLE="${PROFILE_BUNDLE%\*}xuyu" ;;
  *) BUNDLE="$PROFILE_BUNDLE" ;;
esac
echo "签名包名：${BUNDLE}（团队 ${TEAM}）"

plutil -replace CFBundleIdentifier -string "$BUNDLE" "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Set :application-identifier $TEAM.$BUNDLE" "$TMP/entitlements.plist"
cp "$TMP/profile.mobileprovision" "$APP/embedded.mobileprovision"

find "$APP" -name "*.dylib" -o -name "*.framework" | while read -r item; do
  codesign --force --sign "$IDENTITY" --timestamp=none "$item"
done
codesign --force --sign "$IDENTITY" --entitlements "$TMP/entitlements.plist" --timestamp=none --generate-entitlement-der "$APP"
codesign --verify --strict --verbose=2 "$APP"
EXPIRES=$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$TMP/profile.plist")
echo "签名完成。描述文件到期时间：${EXPIRES}"
security delete-keychain "$KC" || true
