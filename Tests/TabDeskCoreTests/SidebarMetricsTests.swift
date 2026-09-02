import AppKit
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

    @Test func nonFiniteWidthsFallBackToDefault() {
        let (metrics, defaults, suite) = makeMetrics()
        defer { defaults.removePersistentDomain(forName: suite) }

        for invalid in [Double.nan, Double.infinity, -Double.infinity] {
            defaults.set(invalid, forKey: "SidebarExpandedWidth")
            #expect(metrics.expandedWidth == SidebarMetrics.defaultWidth)
        }
        for invalid in [CGFloat.nan, CGFloat.infinity, -CGFloat.infinity] {
            metrics.expandedWidth = invalid
            #expect(metrics.expandedWidth == SidebarMetrics.defaultWidth)
        }
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

        // 狭める(240 → 160): 境界に接していた free の窓は右端固定で境界へ追従する(幅 500 → 580)。
        layout.change(parkPoint: park, contentArea: area(sidebar: 160))
        await engine.reapplyLayout()
        #expect(driver.currentFrame(1) == CGRect(x: 160, y: 100, width: 580, height: 400))
        #expect(engine.state.managedWindow(id: freeWindow.id)?.window.frame == CGRect(x: 160, y: 100, width: 580, height: 400))

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

/// v4 段階 5: 幅は共有・折りたたみは画面ごと。
struct PerDisplaySidebarMetricsTests {
    private func makeSuite() -> (UserDefaults, String) {
        let suite = "tabdesk-test-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test func widthIsSharedAcrossDisplays() {
        let (defaults, suite) = makeSuite()
        defer { defaults.removePersistentDomain(forName: suite) }
        let main = SidebarMetrics(displayID: "main", defaults: defaults)
        let second = SidebarMetrics(displayID: "second", defaults: defaults)
        main.expandedWidth = 320
        #expect(second.expandedWidth == 320, "幅は全画面共有")
    }

    @Test func collapseIsPerDisplay() {
        let (defaults, suite) = makeSuite()
        defer { defaults.removePersistentDomain(forName: suite) }
        let main = SidebarMetrics(displayID: "main", defaults: defaults)
        let second = SidebarMetrics(displayID: "second", defaults: defaults)
        main.isCollapsed = true
        #expect(main.effectiveWidth == SidebarMetrics.collapsedWidth)
        #expect(second.isCollapsed == false, "折りたたみは画面ごとに独立")
        #expect(second.effectiveWidth == SidebarMetrics.defaultWidth)
    }

    /// v3 のグローバル折りたたみキーが、画面別キーの既定値としてシードされる。
    @Test func legacyCollapsedValueSeedsPerDisplayDefault() {
        let (defaults, suite) = makeSuite()
        defer { defaults.removePersistentDomain(forName: suite) }
        SidebarMetrics(defaults: defaults).isCollapsed = true  // v3 の保存値
        let migrated = SidebarMetrics(displayID: "main", defaults: defaults)
        #expect(migrated.isCollapsed == true, "旧キーの値を引き継ぐ")
        migrated.isCollapsed = false
        #expect(SidebarMetrics(displayID: "main", defaults: defaults).isCollapsed == false)
    }
}

/// v4 段階 5: SystemScreenLayout は各画面のコンテンツ領域から画面別の実効幅を除く。
@MainActor
struct SystemScreenLayoutProviderTests {
    @Test func subtractsPerDisplayWidthFromEveryDisplay() {
        guard !NSScreen.screens.isEmpty else { return }  // ヘッドレス環境では判定不能
        let layout = SystemScreenLayout(sidebarWidth: { id in id.hasSuffix("...never...") ? 0 : 100 })
        for display in layout.displays {
            guard let screen = ScreenGeometry.screen(for: display.id) else { continue }
            let visible = ScreenGeometry.visibleFrameAX(of: screen)
            #expect(display.contentArea.minX == visible.minX + 100, "全画面で幅が引かれる")
            #expect(display.contentArea.width == visible.width - 100)
        }
    }

    @Test func providerReceivesEachDisplayID() {
        guard !NSScreen.screens.isEmpty else { return }
        nonisolated(unsafe) var seen: Set<DisplayID> = []
        let lock = NSLock()
        let layout = SystemScreenLayout(sidebarWidth: { id in
            lock.withLock { _ = seen.insert(id) }
            return 0
        })
        let ids = Set(layout.displays.map(\.id))
        #expect(lock.withLock { seen } == ids, "画面ごとに自分の ID で幅を問い合わせる")
    }
}


/// サイドバー境界に接していた free の窓は右端固定で境界へ追従する(2026-09-02 要望)。
@MainActor
struct SidebarEdgeFollowTests {
    private let park = CGPoint(x: 1919, y: 1199)
    private func area(sidebar: CGFloat) -> CGRect {
        CGRect(x: sidebar, y: 30, width: 1920 - sidebar, height: 1090)
    }
    private func id(_ name: String) -> WindowIdentity {
        WindowIdentity(bundleID: "test.\(name)", appName: name, title: name, registeredSize: CGSize(width: 500, height: 400))
    }
    private func makeEngine(edge: CGRect, middle: CGRect) async throws -> (TabEngine, FakeWindowDriver, MutableScreenLayout) {
        let driver = FakeWindowDriver()
        let layout = MutableScreenLayout(parkPoint: park, contentArea: area(sidebar: 240))
        let engine = TabEngine(driver: driver, layout: layout)
        let tab = engine.createTab(name: "Free")
        driver.add(1, frame: edge)
        driver.add(2, frame: middle)
        try await engine.register(windowID: 1, pid: 100, identity: id("edge"), frame: edge, into: tab.id)
        try await engine.register(windowID: 2, pid: 200, identity: id("mid"), frame: middle, into: tab.id)
        return (engine, driver, layout)
    }

    @Test func edgeWindowWidensOnCollapseAndMiddleWindowStays() async throws {
        let edge = CGRect(x: 240, y: 100, width: 500, height: 400)
        let middle = CGRect(x: 900, y: 100, width: 500, height: 400)
        let (engine, driver, layout) = try await makeEngine(edge: edge, middle: middle)

        layout.change(parkPoint: park, contentArea: area(sidebar: 16))
        await engine.reapplyLayout()
        #expect(driver.currentFrame(1) == CGRect(x: 16, y: 100, width: 724, height: 400), "右端 740 を固定して広がる")
        #expect(driver.currentFrame(2) == middle, "中ほどの窓は動かない")
    }

    @Test func roundTripRestoresOriginalFrame() async throws {
        let edge = CGRect(x: 240, y: 100, width: 500, height: 400)
        let middle = CGRect(x: 900, y: 100, width: 500, height: 400)
        let (engine, driver, layout) = try await makeEngine(edge: edge, middle: middle)

        for sidebar in [16.0, 240.0, 16.0, 240.0] as [CGFloat] {
            layout.change(parkPoint: park, contentArea: area(sidebar: sidebar))
            await engine.reapplyLayout()
        }
        #expect(driver.currentFrame(1) == edge, "往復しても育たない")
        #expect(driver.currentFrame(2) == middle)
    }

    @Test func wideningSidebarShrinksEdgeWindowKeepingRightEdge() async throws {
        let edge = CGRect(x: 240, y: 100, width: 500, height: 400)
        let middle = CGRect(x: 900, y: 100, width: 500, height: 400)
        let (engine, driver, layout) = try await makeEngine(edge: edge, middle: middle)

        layout.change(parkPoint: park, contentArea: area(sidebar: 400))
        await engine.reapplyLayout()
        #expect(driver.currentFrame(1) == CGRect(x: 400, y: 100, width: 340, height: 400))
    }

    @Test func tooNarrowResultFallsBackToClamp() async throws {
        let edge = CGRect(x: 240, y: 100, width: 300, height: 400)  // 右端 540
        let middle = CGRect(x: 900, y: 100, width: 500, height: 400)
        let (engine, driver, layout) = try await makeEngine(edge: edge, middle: middle)

        // 追従すると幅 140(< 200)になるので、サイズ維持で押し戻される。
        layout.change(parkPoint: park, contentArea: area(sidebar: 400))
        await engine.reapplyLayout()
        #expect(driver.currentFrame(1) == CGRect(x: 400, y: 100, width: 300, height: 400))
    }
}
