import CoreGraphics
import Foundation
import Testing
@testable import TabDeskCore

private let park = CGPoint(x: 1919, y: 1199)
private let content = CGRect(x: 240, y: 30, width: 1680, height: 1090)

private func identity(_ name: String) -> WindowIdentity {
    WindowIdentity(bundleID: "test.\(name)", appName: name, title: name, registeredSize: CGSize(width: 800, height: 600))
}

@MainActor
private func makeEngine(debounceMs: Int = 20) -> (TabEngine, FakeWindowDriver) {
    let driver = FakeWindowDriver()
    var config = TabEngine.Configuration()
    config.debounce = .milliseconds(debounceMs)
    let engine = TabEngine(driver: driver, layout: FixedScreenLayout(parkPoint: park, contentArea: content), configuration: config)
    return (engine, driver)
}

private let fullscreenRect = CGRect(x: 0, y: 0, width: 1920, height: 1200)

/// 登録後にネイティブフルスクリーンへ入った窓の扱い(v3 段階 2)。
@MainActor
struct FullscreenTests {
    /// 非アクティブタブのフルスクリーン窓に、reconcile が退避を打ち続けない(修正前は 2 秒ごとに永久リトライ)。
    @Test func fullscreenInactiveWindowIsNotParkedRepeatedly() async throws {
        let (engine, driver) = makeEngine()
        _ = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(1, frame: CGRect(x: 300, y: 100, width: 500, height: 400))
        try await engine.register(windowID: 1, pid: 100, identity: identity("b"), frame: CGRect(x: 300, y: 100, width: 500, height: 400), into: b.id)

        driver.setFullscreen(1)
        driver.moveExternally(1, to: fullscreenRect)
        await engine.reconcile(liveWindowIDs: [1], livePIDs: [100])  // ここで集合に入る
        let before = driver.callCount("setPosition")
        for _ in 0..<3 {
            await engine.reconcile(liveWindowIDs: [1], livePIDs: [100])
        }
        #expect(driver.callCount("setPosition") == before, "フルスクリーン検出後は退避を試みない")
        #expect(engine.fullscreenWindowIDs.count == 1)
    }

    /// スナップバックがフルスクリーン寸法を「到達 frame」として採用しない(破壊の回帰)。
    @Test func fullscreenSnapbackDoesNotAdoptFullscreenFrame() async throws {
        let (engine, driver) = makeEngine()
        let tab = engine.createTab(name: "A")
        let recorded = CGRect(x: 300, y: 100, width: 500, height: 400)
        driver.add(1, frame: recorded)
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: recorded, into: tab.id)

        // フルスクリーン進入: resize 通知は reconcile の集合更新より先に届く。
        driver.setFullscreen(1)
        driver.moveExternally(1, to: fullscreenRect)
        engine.windowFrameDidChange(windowID: 1)
        try await Task.sleep(for: .milliseconds(300))  // デバウンス×最大試行を跨いでも採用しないこと

        #expect(engine.state.managedWindow(id: managed.id)?.window.frame == recorded, "記録 frame を破壊しない")
        #expect(engine.fullscreenWindowIDs.contains(managed.id), "スナップバック経路の読み直しで検出される")
    }

    /// 解除すると次の reconcile で集合から外れ、ずれ検知経路が記録 frame へ復元する。
    @Test func exitingFullscreenResumesManagement() async throws {
        let (engine, driver) = makeEngine()
        let tab = engine.createTab(name: "A")
        let recorded = CGRect(x: 300, y: 100, width: 500, height: 400)
        driver.add(1, frame: recorded)
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: recorded, into: tab.id)
        driver.setFullscreen(1)
        driver.moveExternally(1, to: fullscreenRect)
        await engine.reconcile(liveWindowIDs: [1], livePIDs: [100])
        #expect(engine.fullscreenWindowIDs.contains(managed.id))

        driver.setFullscreen(1, false)
        driver.moveExternally(1, to: CGRect(x: 700, y: 300, width: 500, height: 400))  // 解除後のずれ
        await engine.reconcile(liveWindowIDs: [1], livePIDs: [100])  // 集合から外れ、ずれ検知が復元を予約
        try await Task.sleep(for: .milliseconds(150))
        #expect(engine.fullscreenWindowIDs.isEmpty)
        #expect(driver.currentFrame(1) == recorded, "解除後は記録 frame へ戻る")
    }

    /// タブ切替はフルスクリーン窓を復元も退避もしない(同タブの他の窓は通常どおり)。
    @Test func activateSkipsFullscreenWindows() async throws {
        let (engine, driver) = makeEngine()
        let a = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(1, frame: CGRect(x: 300, y: 100, width: 500, height: 400))
        driver.add(2, frame: CGRect(x: 900, y: 200, width: 500, height: 400))
        driver.add(3, frame: CGRect(x: 300, y: 100, width: 500, height: 400))
        let fsManaged = try await engine.register(windowID: 1, pid: 100, identity: identity("fs"), frame: CGRect(x: 300, y: 100, width: 500, height: 400), into: a.id)
        try await engine.register(windowID: 2, pid: 200, identity: identity("m"), frame: CGRect(x: 900, y: 200, width: 500, height: 400), into: a.id)
        try await engine.register(windowID: 3, pid: 300, identity: identity("b"), frame: CGRect(x: 300, y: 100, width: 500, height: 400), into: b.id)

        driver.setFullscreen(1)
        driver.moveExternally(1, to: fullscreenRect)
        await engine.reconcile(liveWindowIDs: [1, 2, 3], livePIDs: [100, 200, 300])

        try await engine.activate(b.id)
        #expect(driver.currentFrame(1) == fullscreenRect, "退避しない")
        #expect(driver.currentFrame(2)?.origin == park, "通常の窓は退避する")
        try await engine.activate(a.id)
        #expect(driver.currentFrame(1) == fullscreenRect, "復元もしない")
        #expect(driver.currentFrame(2) == CGRect(x: 900, y: 200, width: 500, height: 400))
        #expect(!engine.parkedWindowIDs.contains(fsManaged.id))
    }

    /// フルスクリーン中の解除は実窓に触れず登録だけ手放す。
    @Test func unregisterFullscreenWindowLeavesItAlone() async throws {
        let (engine, driver) = makeEngine()
        let tab = engine.createTab(name: "A")
        driver.add(1, frame: CGRect(x: 300, y: 100, width: 500, height: 400))
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: CGRect(x: 300, y: 100, width: 500, height: 400), into: tab.id)
        driver.setFullscreen(1)
        driver.moveExternally(1, to: fullscreenRect)
        await engine.reconcile(liveWindowIDs: [1], livePIDs: [100])
        let writesBefore = driver.callCount("setFrame") + driver.callCount("setPosition")

        try await engine.unregister(managed.id)
        #expect(engine.state.allWindows.isEmpty)
        #expect(driver.currentFrame(1) == fullscreenRect)
        #expect(driver.callCount("setFrame") + driver.callCount("setPosition") == writesBefore)
        #expect(engine.fullscreenWindowIDs.isEmpty, "集合からも掃除される")
    }

    /// レイアウト再適用は論理 frame(clamp / 列)を更新しつつ、フルスクリーン窓には op を出さない。
    @Test func reapplyLayoutSkipsOpsButUpdatesRecordedFrame() async throws {
        let driver = FakeWindowDriver()
        let layout = MutableScreenLayout(parkPoint: park, contentArea: content)
        let engine = TabEngine(driver: driver, layout: layout)
        let tab = engine.createTab(name: "A")
        driver.add(1, frame: CGRect(x: 300, y: 100, width: 800, height: 600))
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: CGRect(x: 300, y: 100, width: 800, height: 600), into: tab.id)
        driver.setFullscreen(1)
        driver.moveExternally(1, to: fullscreenRect)
        await engine.reconcile(liveWindowIDs: [1], livePIDs: [100])

        let newArea = CGRect(x: 300, y: 30, width: 900, height: 700)
        layout.change(parkPoint: CGPoint(x: 1439, y: 899), contentArea: newArea)
        let writesBefore = driver.callCount("setFrame") + driver.callCount("setPosition")
        await engine.reapplyLayout()

        let recorded = try #require(engine.state.managedWindow(id: managed.id)?.window.frame)
        #expect(newArea.contains(recorded), "論理 frame は新しい領域へ更新される(解除後の戻り先)")
        #expect(driver.callCount("setFrame") + driver.callCount("setPosition") == writesBefore, "実窓には触らない")
        #expect(driver.currentFrame(1) == fullscreenRect)
    }

    /// reconcile はフルスクリーンの出入りに追従して集合を更新する。
    @Test func reconcileRefreshesFullscreenMembership() async throws {
        let (engine, driver) = makeEngine()
        let tab = engine.createTab(name: "A")
        driver.add(1, frame: CGRect(x: 300, y: 100, width: 500, height: 400))
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: CGRect(x: 300, y: 100, width: 500, height: 400), into: tab.id)
        #expect(engine.fullscreenWindowIDs.isEmpty)

        driver.setFullscreen(1)
        await engine.reconcile(liveWindowIDs: [1], livePIDs: [100])
        #expect(engine.fullscreenWindowIDs.contains(managed.id))

        driver.setFullscreen(1, false)
        await engine.reconcile(liveWindowIDs: [1], livePIDs: [100])
        #expect(engine.fullscreenWindowIDs.isEmpty)
    }
}
