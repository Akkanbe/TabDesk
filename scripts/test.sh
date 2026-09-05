#!/usr/bin/env bash
# ユニットテストを実行する(Accessibility 権限不要)。
#
# Command Line Tools だけの環境では Swift Testing のフレームワークとランタイムライブラリが
# SwiftPM の既定の検索パスに入っていないため、明示的に渡す(フル Xcode があれば `swift test` だけで動く)。
set -euo pipefail
cd "$(dirname "$0")/.."

CLT="$(xcode-select -p)"
FW="$CLT/Library/Developer/Frameworks"
INTEROP_DIR="$CLT/Library/Developer/usr/lib"

TEST_ARGS=()
if [[ -d "$FW/Testing.framework" ]]; then
  TEST_ARGS+=(
    -Xswiftc "-F$FW"
    -Xlinker "-F$FW" -Xlinker -rpath -Xlinker "$FW"
    -Xlinker -rpath -Xlinker "$INTEROP_DIR"
  )
fi

if [[ $# -gt 0 ]]; then
  exec swift test "${TEST_ARGS[@]}" "$@"
fi

# AppKit の初期化・描画を、Core の MainActor 応答時間テストと同時に走らせない。
# 全テストを実行するが、UI を含むターゲットは別プロセスで検証する。
swift test "${TEST_ARGS[@]}" --skip TabDeskTests
exec swift test "${TEST_ARGS[@]}" --skip-build --filter TabDeskTests
