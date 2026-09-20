// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TabDesk",
    defaultLocalization: "ja",
    platforms: [.macOS(.v15)],
    targets: [
        // Accessibility API のラッパー群。v1 本体でも再利用する。
        .target(
            name: "TabDeskCore",
            path: "Sources/TabDeskCore",
            resources: [.process("Resources")]
        ),
        // 本体アプリ(サイドバー UI + AX 配線)。
        .executableTarget(
            name: "TabDesk",
            dependencies: ["TabDeskCore"],
            path: "Sources/TabDesk"
        ),
        // v0 技術検証用の GUI アプリ。
        .executableTarget(
            name: "TabDeskPoC",
            dependencies: ["TabDeskCore"],
            path: "Sources/TabDeskPoC"
        ),
        // Accessibility 権限なしで動くユニットテスト(WindowDriver を偽物に差し替える)。
        .testTarget(
            name: "TabDeskCoreTests",
            dependencies: ["TabDeskCore"],
            path: "Tests/TabDeskCoreTests"
        ),
        .testTarget(
            name: "TabDeskTests",
            dependencies: ["TabDesk"],
            path: "Tests/TabDeskTests"
        ),
    ]
)
