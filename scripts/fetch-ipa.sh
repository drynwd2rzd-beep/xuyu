#!/bin/bash
# 在电脑上下载云端打好的 IPA（加密的），用本机的钥匙解密，放进「下载」
# 用法：bash scripts/fetch-ipa.sh [运行编号]（不写就是最新一次）
set -euo pipefail
cd "$(dirname "$0")/.."

REPO=drynwd2rzd-beep/xuyu
KEY_FILE=.secrets/artifact.key
[ -f "$KEY_FILE" ] || { echo "找不到解密钥匙 $KEY_FILE"; exit 1; }

RUN=${1:-$(gh run list -R "$REPO" -L 1 --json databaseId -q '.[0].databaseId')}
rm -rf dist && mkdir -p dist
gh run download "$RUN" -R "$REPO" -n Xuyu-ipa -D dist

KEY=$(tr -d '\r\n' < "$KEY_FILE")
find dist -name "*.ipa.enc" | while read -r f; do
  ARTIFACT_KEY="$KEY" openssl enc -d -aes-256-cbc -md sha256 -pbkdf2 -iter 200000 -in "$f" -out "${f%.enc}" -pass env:ARTIFACT_KEY
  rm -f "$f"
done

SIGNED=dist/signed/Xuyu.ipa
if [ -f "$SIGNED" ]; then
  cp -f "$SIGNED" "$USERPROFILE/Downloads/Xuyu.ipa"
  echo "已放进下载：$USERPROFILE/Downloads/Xuyu.ipa（运行 $RUN）"
else
  echo "这次没有签名版"
fi
ls -l dist dist/signed 2>/dev/null || true
