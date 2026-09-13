#!/usr/bin/env bash
# アプリをビルドして build/<PRODUCT>.app に .app バンドルとして組み立てる。
#   ./scripts/build_app.sh              # 本体 TabDesk
#   PRODUCT=TabDeskPoC ./scripts/build_app.sh   # v0 検証アプリ
# APP_OUTPUT_DIR で出力先を変更できる(相対パスはリポジトリ基準)。
# Accessibility 権限(TCC)はバンドル単位で付与されるため、素のバイナリではなく .app にする。
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-debug}"
PRODUCT="${PRODUCT:-TabDesk}"
case "$PRODUCT" in
  TabDesk|TabDeskPoC) ;;
  *) echo "Unsupported product: $PRODUCT" >&2; exit 1 ;;
esac
case "$CONFIG" in
  debug|release) ;;
  *) echo "Unsupported configuration: $CONFIG" >&2; exit 1 ;;
esac
PLIST="Resources/$PRODUCT/Info.plist"
OUTPUT_DIR="${APP_OUTPUT_DIR:-build}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
APP="$OUTPUT_DIR/$PRODUCT.app"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$PLIST")"

swift build -c "$CONFIG" --product "$PRODUCT"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/$PRODUCT"

# 検証前には既存アプリを触らない。失敗時の組み立て途中の内容も調査用に残す。
STAGING="$(mktemp -d "$OUTPUT_DIR/.assemble-$PRODUCT.XXXXXX")"
STAGED_APP="$STAGING/$PRODUCT.app"
trap 'echo "Assembly failed; existing app is preserved. Inspect: $STAGING" >&2' ERR
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
# SwiftPM の翻訳リソースも同梱し、開発ディレクトリ外でも言語を切り替えられるようにする。
cp -R "$(dirname "$BIN")/TabDesk_TabDeskCore.bundle" "$STAGED_APP/Contents/Resources/"
cp "$BIN" "$STAGED_APP/Contents/MacOS/$PRODUCT"
cp "$PLIST" "$STAGED_APP/Contents/Info.plist"
printf 'APPL????' > "$STAGED_APP/Contents/PkgInfo"
if [[ "$PRODUCT" == TabDesk ]]; then
  ./scripts/build_icon.sh "$STAGING/TabDesk.iconset" "$STAGED_APP/Contents/Resources/TabDesk.icns"
fi
plutil -lint "$STAGED_APP/Contents/Info.plist"

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
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"

# 古い成果物は削除せず退避する。配布準備は専用出力先を使うため稼働版を動かさない。
if [[ -e "$APP" || -L "$APP" ]]; then
  mv "$APP" "$STAGING/previous-$PRODUCT.app"
fi
if ! mv "$STAGED_APP" "$APP"; then
  if [[ -e "$STAGING/previous-$PRODUCT.app" || -L "$STAGING/previous-$PRODUCT.app" ]]; then
    mv "$STAGING/previous-$PRODUCT.app" "$APP"
  fi
  echo "Failed to install assembled app. Inspect: $STAGING" >&2
  exit 1
fi
trap - ERR
echo "signed with: $IDENTITY"
if [[ -e "$STAGING/previous-$PRODUCT.app" || -L "$STAGING/previous-$PRODUCT.app" ]]; then
  echo "previous app: $STAGING/previous-$PRODUCT.app"
fi

echo "built: $APP"
