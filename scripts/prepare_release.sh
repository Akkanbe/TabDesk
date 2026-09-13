#!/usr/bin/env bash
# 加入前のローカル検証用。Developer ID署名・公証・公開は行わない。
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -ne 0 ]]; then
  echo "Usage: $0 (no arguments)" >&2
  exit 1
fi
if [[ "$(uname -m)" != arm64 ]]; then
  echo "Release preparation currently targets native Apple Silicon only." >&2
  exit 1
fi

mkdir -p build/release-preparation
OUTPUT="$(mktemp -d "$PWD/build/release-preparation/TabDesk.XXXXXX")"
echo "Preparing an unnotarized local preview: $OUTPUT"
trap 'echo "Preparation failed; do not distribute partial output: $OUTPUT" >&2' ERR

CONFIG=release PRODUCT=TabDesk APP_OUTPUT_DIR="$OUTPUT" ./scripts/build_app.sh 2>&1 | tee "$OUTPUT/build.log"
APP="$OUTPUT/TabDesk.app"
PLIST="$APP/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")"
ARCH="$(lipo -archs "$APP/Contents/MacOS/TabDesk")"
if [[ "$ARCH" != arm64 ]]; then
  echo "Unexpected binary architecture: $ARCH" >&2
  exit 1
fi
# Info.plist由来の値を安全なファイル名として扱えることを確認する。
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Expected numeric version (x.y.z) and build number." >&2
  exit 1
fi

ARCHIVE="TabDesk-$VERSION-build$BUILD_NUMBER-arm64-unnotarized.zip"
codesign --verify --deep --strict "$APP"
codesign -d --verbose=4 "$APP" 2> "$OUTPUT/signature.txt"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT/$ARCHIVE"
cp docs/user_guide.md "$OUTPUT/USER_GUIDE.md"
DIRTY=false
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
  DIRTY=true
fi
{
  echo "distribution_status=local-preview-unnotarized"
  echo "version=$VERSION"
  echo "build_number=$BUILD_NUMBER"
  echo "architecture=$ARCH"
  echo "minimum_macos=$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$PLIST")"
  echo "source_commit=$(git rev-parse HEAD)"
  echo "working_tree_dirty=$DIRTY"
  echo "built_at_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "build_macos=$(sw_vers -productVersion)"
  swift --version 2>&1
} > "$OUTPUT/build-info.txt"
(
  cd "$OUTPUT"
  shasum -a 256 "$ARCHIVE" > SHA256SUMS
  shasum -a 256 -c SHA256SUMS
)
cat > "$OUTPUT/README.txt" <<'EOF'
TabDesk — 配布準備用 / Local preview

未公証。一般公開用の完成版ではありません。
ZIPはRelease最適化のローカル検証用です。公証と別のMacでの導入確認は未完了です。
This is an unnotarized local preview, not a public release.

USER_GUIDE.md: 導入・更新・バックアップ・復旧の案内
build-info.txt: バージョン、CPU、ソースコミット、未コミット変更の有無
signature.txt: 実際の署名情報（Developer ID署名・公証を保証しません）
build.log: ビルド記録（ローカルパスが含まれます。共有前に確認してください）
SHA256SUMS: ZIPのSHA-256。shasum -a 256 -c SHA256SUMS で確認できます。

テストは別途 ./scripts/test.sh で実行してください。
working_tree_dirty=true の場合、source_commitだけではビルド元を再現できません。
EOF
trap - ERR
echo "Prepared (not notarized): $OUTPUT"
