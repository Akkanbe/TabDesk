#!/usr/bin/env bash
# 既存PNGをmacOS標準ツールでサイズ変換する。図案や元画像は変更しない。
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <new-iconset-directory> <output.icns>" >&2
  exit 1
fi
ICONSET="$1"
OUTPUT="$2"
if [[ "$ICONSET" != *.iconset || "$OUTPUT" != *.icns ]]; then
  echo "Expected .iconset directory and .icns output." >&2
  exit 1
fi
# 既存の素材や成果物を引数の間違いで上書きしない。
if [[ -e "$ICONSET" || -L "$ICONSET" || -e "$OUTPUT" || -L "$OUTPUT" ]]; then
  echo "Icon outputs already exist." >&2
  exit 1
fi
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
  sips -z "$SIZE" "$SIZE" Resources/TabDesk/Brand/logo.png --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  sips -z "$((SIZE * 2))" "$((SIZE * 2))" Resources/TabDesk/Brand/logo.png --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$OUTPUT"
