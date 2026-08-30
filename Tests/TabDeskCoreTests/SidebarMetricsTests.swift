import CoreGraphics
import Foundation
import Testing
@testable import TabDeskCore

/// サイドバー幅・折りたたみ設定(v3 段階 3)の検証。
struct SidebarMetricsTests {
    private func makeMetrics() -> (SidebarMetrics, UserDefaults, String) {
        let suite = "tabdesk-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (SidebarMetrics(defaults: defaults), defaults, suite)
    }

    @Test func defaultsAreRegistered() {
        let (metrics, defaults, suite) = makeMetrics()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(metrics.expandedWidth == SidebarMetrics.defaultWidth)
        #expect(metrics.isCollapsed == false)
        #expect(metrics.effectiveWidth == SidebarMetrics.defaultWidth)
    }

    @Test func widthIsClampedOnWriteAndRead() {
        let (metrics, defaults, suite) = makeMetrics()
        defer { defaults.removePersistentDomain(forName: suite) }
        metrics.expandedWidth = 100
        #expect(metrics.expandedWidth == SidebarMetrics.minWidth)
        metrics.expandedWidth = 999
        #expect(metrics.expandedWidth == SidebarMetrics.maxWidth)
        // 手書きの defaults(範囲外の値)にも読み取り側の丸めで耐える。
        defaults.set(5.0, forKey: "SidebarExpandedWidth")
        #expect(metrics.expandedWidth == SidebarMetrics.minWidth)
    }

    @Test func effectiveWidthFollowsCollapse() {
        let (metrics, defaults, suite) = makeMetrics()
        defer { defaults.removePersistentDomain(forName: suite) }
        metrics.expandedWidth = 320
        metrics.isCollapsed = true
        #expect(metrics.effectiveWidth == SidebarMetrics.collapsedWidth)
        metrics.isCollapsed = false
        #expect(metrics.effectiveWidth == 320)
    }

    /// 実体は UserDefaults なので、別インスタンス(= 別コピー)からも同じ値が見える。
    @Test func copiesShareTheSameBackingStore() {
        let (metrics, defaults, suite) = makeMetrics()
        defer { defaults.removePersistentDomain(forName: suite) }
        metrics.expandedWidth = 300
        let another = SidebarMetrics(defaults: defaults)
        #expect(another.expandedWidth == 300)
    }
}

/// サイドバー幅の変更がコンテンツ領域に波及することの物語テスト(240 → 160 → 折りたたみ 16 相当)。
@MainActor
struct SidebarWidthReflowTests {
    @Test func contentAreaWidthChangeReflowsColumnsAndClampsFree() async throws {
        let park = CGPoint(x: 1919, y: 1199)
        func area(sidebar: CGFloat) -> CGRect {
            CGRect(x: sidebar, y: 30, width: 1920 - sidebar, height: 1090)
        }
        let driver = FakeWindowDriver()
        let layout = MutableScreenLayout(parkPoint: park, contentArea: area(sidebar: 240))
        let engine = TabEngine(driver: driver, layout: layout)
        let free = engine.createTab(name: "Free")
        let cols = engine.createTab(name: "Cols")
        driver.add(1, frame: CGRect(x: 240, y: 100, width: 500, height: 400))
        driver.add(2, frame: CGRect(x: 300, y: 100, width: 500, height: 400))
        driver.add(3, frame: CGRect(x: 900, y: 200, width: 500, height: 400))
        let freeWindow = try await engine.register(windowID: 1, pid: 100, identity: id("f"), frame: CGRect(x: 240, y: 100, width: 500, height: 400), into: free.id)
        try await engine.register(windowID: 2, pid: 200, identity: id("c1"), frame: CGRect(x: 300, y: 100, width: 500, height: 400), into: cols.id)
        try await engine.register(windowID: 3, pid: 300, identity: id("c2"), frame: CGRect(x: 900, y: 200, width: 500, height: 400), into: cols.id)
        try await engine.setTabLayout(cols.id, .columns)

        // 狭める(240 → 160): free のアクティブ窓は左端が新しい境界へ寄る。
        layout.change(parkPoint: park, contentArea: area(sidebar: 160))
        await engine.reapplyLayout()
        #expect(driver.currentFrame(1)?.minX == 240, "free は位置 clamp のみ(領域内ならそのまま)")
        #expect(engine.state.managedWindow(id: freeWindow.id)?.window.frame.minX == 240)

        // 折りたたみ相当(160 → 16): columns タブへ切り替えると新しい領域で等分される。
        layout.change(parkPoint: park, contentArea: area(sidebar: 16))
        try await engine.activate(cols.id)
        let a = area(sidebar: 16)
        let half = a.width / 2
        #expect(driver.currentFrame(2) == CGRect(x: a.minX, y: a.minY, width: half, height: a.height))
        #expect(driver.currentFrame(3) == CGRect(x: a.minX + half, y: a.minY, width: half, height: a.height))
    }

    private func id(_ name: String) -> WindowIdentity {
        WindowIdentity(bundleID: "test.\(name)", appName: name, title: name, registeredSize: CGSize(width: 500, height: 400))
    }
}
