#!/usr/bin/env bash
# AXShimをリンクしない独立実行ファイルで、公開APIのみの経路を検証する。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/public-ax-probe
swiftc -swift-version 6 -parse-as-library \
  Sources/TabDeskCore/AXWindowReferenceStore.swift \
  Sources/TabDeskCore/WindowLayoutAccess.swift \
  Sources/TabDeskCore/AXCallError.swift \
  Sources/TabDeskCore/AXAttributes.swift \
  Sources/TabDeskCore/AppWindowObserver.swift \
  Tools/PublicAXProbe/Probe.swift \
  -o build/public-ax-probe/PublicAXProbe
swiftc -swift-version 6 -parse-as-library Tools/PublicAXProbe/Fixture.swift \
  -o build/public-ax-probe/PublicAXFixture
mkdir -p build/public-ax-probe/PublicAXFixture.app/Contents/MacOS
cp build/public-ax-probe/PublicAXFixture build/public-ax-probe/PublicAXFixture.app/Contents/MacOS/
cp Tools/PublicAXProbe/Fixture-Info.plist build/public-ax-probe/PublicAXFixture.app/Contents/Info.plist
codesign --force --sign - build/public-ax-probe/PublicAXFixture.app
codesign --verify --deep --strict build/public-ax-probe/PublicAXFixture.app
echo "built: $PWD/build/public-ax-probe/PublicAXProbe"
echo "built: $PWD/build/public-ax-probe/PublicAXFixture.app"
