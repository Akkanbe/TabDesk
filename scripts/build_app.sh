#!/usr/bin/env bash
# PoC をビルドして build/TabDeskPoC.app に .app バンドルとして組み立てる。
# Accessibility 権限(TCC)はバンドル単位で付与されるため、素のバイナリではなく .app にする。
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-debug}"
APP="build/TabDeskPoC.app"

swift build -c "$CONFIG" --product TabDeskPoC
BIN="$(swift build -c "$CONFIG" --show-bin-path)/TabDeskPoC"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/TabDeskPoC"
cp Resources/PoC/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 署名 ID の決定: 環境変数 > 自己署名証明書 "WTC Dev"(あれば) > ad-hoc("-")。
# ad-hoc は再ビルドごとに署名ハッシュが変わり TCC の権限が外れる(OFF→ON では直らず「−」→「+」の再登録が必要)。
# 自己署名でも証明書で署名すれば識別情報が安定し、再ビルド後も権限が維持される(README 参照)。
IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q '"WTC Dev"'; then
    IDENTITY="WTC Dev"
  else
    IDENTITY="-"
  fi
fi
codesign --force --sign "$IDENTITY" --identifier io.github.akkanbe.tabdesk.poc "$APP"
echo "signed with: $IDENTITY"

echo "built: $APP"
