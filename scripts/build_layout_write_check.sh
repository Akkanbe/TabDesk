#!/usr/bin/env bash
# 製品と同じCoreをリンクし、専用Fixtureの窓だけで操作・復旧を検証する。
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product TabDesk
BIN_DIR="$(swift build --show-bin-path)"
mkdir -p build/public-ax-probe
for CHECK in LayoutWriteCheck ReferenceEngineCheck; do
  swiftc -swift-version 6 -parse-as-library -I "$BIN_DIR/Modules" \
    "Tools/PublicAXProbe/$CHECK.swift" "$BIN_DIR"/TabDeskCore.build/*.o \
    -o "build/public-ax-probe/$CHECK"
  echo "built: $PWD/build/public-ax-probe/$CHECK"
done
