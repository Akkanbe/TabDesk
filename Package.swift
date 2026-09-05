// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TabDesk",
    platforms: [.macOS(.v15)],
    targets: [
        // 私有関数 _AXUIElementGetWindow を dlsym で解決する最小限の C ターゲット。
        // 私有 API への依存をこの 1 箇所に閉じ込める。
        .target(
            name: "AXShim",
            path: "Sources/AXShim"
        ),
        // Accessibility API のラッパー群。v1 本体でも再利用する。
        .target(
            name: "TabDeskCore",
            dependencies: ["AXShim"],
            path: "Sources/TabDeskCore"
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
