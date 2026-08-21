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
        // v0 技術検証用の GUI アプリ。
        .executableTarget(
            name: "TabDeskPoC",
            dependencies: ["TabDeskCore"],
            path: "Sources/TabDeskPoC"
        ),
    ]
)
