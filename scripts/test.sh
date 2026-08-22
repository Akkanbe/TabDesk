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

if [[ -d "$FW/Testing.framework" ]]; then
  exec swift test \
    -Xswiftc "-F$FW" \
    -Xlinker "-F$FW" -Xlinker -rpath -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$INTEROP_DIR" \
    "$@"
else
  exec swift test "$@"
fi
