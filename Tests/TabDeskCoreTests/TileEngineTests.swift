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

/// columns レイアウト(段階 C2)のエンジン結合の検証。
@MainActor
struct TileEngineTests {
    /// 2 窓のタブを columns にすると、その場で等幅カラムが適用され、記録 frame も列になる。
    @Test func setColumnsTilesActiveTabImmediately() async throws {
        let (engine, driver) = makeEngine()
        let tab = engine.createTab(name: "A")
        driver.add(1, frame: CGRect(x: 300, y: 100, width: 500, height: 400))
        driver.add(2, frame: CGRect(x: 900, y: 200, width: 500, height: 400))
        let w1 = try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: CGRect(x: 300, y: 100, width: 500, height: 400), into: tab.id)
        let w2 = try await engine.register(windowID: 2, pid: 200, identity: identity("b"), frame: CGRect(x: 900, y: 200, width: 500, height: 400), into: tab.id)

        try await engine.setTabLayout(tab.id, .columns)

        let half = content.width / 2
        let left = CGRect(x: content.minX, y: content.minY, width: half, height: content.height)
        let right = CGRect(x: content.minX + half, y: content.minY, width: half, height: content.height)
        #expect(driver.currentFrame(1) == left)
        #expect(driver.currentFrame(2) == right)
        #expect(engine.state.managedWindow(id: w1.id)?.window.frame == left)
        #expect(engine.state.managedWindow(id: w2.id)?.window.frame == right)
        #expect(engine.state.tab(withID: tab.id)?.layout == .columns)
    }

    /// 非アクティブな columns タブへの切替は、記録 frame ではなく列で復元する。
    @Test func activatingColumnsTabRestoresIntoColumns() async throws {
        let (engine, driver) = makeEngine()
        let a = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(1, frame: content)
        driver.add(2, frame: CGRect(x: 300, y: 100, width: 500, height: 400))
        driver.add(3, frame: CGRect(x: 900, y: 200, width: 500, height: 400))
        try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: content, into: a.id)
        try await engine.register(windowID: 2, pid: 200, identity: identity("b1"), frame: CGRect(x: 300, y: 100, width: 500, height: 400), into: b.id)
        try await engine.register(windowID: 3, pid: 200, identity: identity("b2"), frame: CGRect(x: 900, y: 200, width: 500, height: 400), into: b.id)
        try await engine.setTabLayout(b.id, .columns)  // 非アクティブなので実窓は動かない(退避中のまま)
        #expect(driver.currentFrame(2)?.origin == park)

        try await engine.activate(b.id)

        let half = content.width / 2
        #expect(driver.currentFrame(2) == CGRect(x: content.minX, y: content.minY, width: half, height: content.height))
        #expect(driver.currentFrame(3) == CGRect(x: content.minX + half, y: content.minY, width: half, height: content.height))
    }

    /// アクティブな columns タブへの登録は全体を組み直し、解除は残りで組み直す。
    @Test func registerAndUnregisterRetile() async throws {
        let (engine, driver) = makeEngine()
        let tab = engine.createTab(name: "A")
        driver.add(1, frame: CGRect(x: 300, y: 100, width: 500, height: 400))
        try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: CGRect(x: 300, y: 100, width: 500, height: 400), into: tab.id)
        try await engine.setTabLayout(tab.id, .columns)
        #expect(driver.currentFrame(1) == content, "1 窓の列は全面")

        driver.add(2, frame: CGRect(x: 900, y: 200, width: 500, height: 400))
        let w2 = try await engine.register(windowID: 2, pid: 200, identity: identity("b"), frame: CGRect(x: 900, y: 200, width: 500, height: 400), into: tab.id)
        let half = content.width / 2
        #expect(driver.currentFrame(1) == CGRect(x: content.minX, y: content.minY, width: half, height: content.height))
        #expect(driver.currentFrame(2) == CGRect(x: content.minX + half, y: content.minY, width: half, height: content.height))
        #expect(w2.frame == engine.state.managedWindow(id: w2.id)?.window.frame, "register は retile 後の状態を返す")
        #expect(w2.frame == driver.currentFrame(2))

        try await engine.unregister(w2.id)
        #expect(driver.currentFrame(1) == content, "解除後は残り 1 窓で全面に戻る")
    }

    /// 窓の消滅(destroyed 通知)は同期経路なので、次の reconcile が 1 回だけ列を組み直す。
    @Test func destroyedWindowRetilesOnNextReconcile() async throws {
        let (engine, driver) = makeEngine()
        engine.vanishGracePeriod = .zero
        let tab = engine.createTab(name: "A")
        driver.add(1, frame: CGRect(x: 300, y: 100, width: 500, height: 400))
        driver.add(2, frame: CGRect(x: 900, y: 200, width: 500, height: 400))
        try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: CGRect(x: 300, y: 100, width: 500, height: 400), into: tab.id)
        try await engine.register(windowID: 2, pid: 200, identity: identity("b"), frame: CGRect(x: 900, y: 200, width: 500, height: 400), into: tab.id)
        try await engine.setTabLayout(tab.id, .columns)

        driver.kill(2)
        engine.noteWindowDestroyed(windowID: 2)
        // 1 回目: 猶予 0 なので「閉じられた」と確定 → 除去 → 予約された列の組み直しを同じ reconcile が消化する。
        await engine.reconcile(liveWindowIDs: [1], livePIDs: [100, 200])
        await engine.reconcile(liveWindowIDs: [1], livePIDs: [100, 200])
        #expect(driver.currentFrame(1) == content, "残り 1 窓で全面")
        #expect(engine.state.tab(withID: tab.id)?.windows.count == 1)
    }

    /// destroyed の猶予中も消えた窓は bound 列に数えず、次の reconcile で残りを組み直す。
    @Test func vanishedWindowRetilesBeforeGraceExpires() async throws {
        let (engine, driver) = makeEngine()
        engine.vanishGracePeriod = .seconds(60)
        let tab = engine.createTab(name: "A")
        driver.add(1, frame: CGRect(x: 300, y: 100, width: 500, height: 400))
        driver.add(2, frame: CGRect(x: 900, y: 200, width: 500, height: 400))
        try await engine.register(
            windowID: 1, pid: 100, identity: identity("a"),
            frame: CGRect(x: 300, y: 100, width: 500, height: 400), into: tab.id)
        let vanished = try await engine.register(
            windowID: 2, pid: 200, identity: identity("b"),
            frame: CGRect(x: 900, y: 200, width: 500, height: 400), into: tab.id)
        try await engine.setTabLayout(tab.id, .columns)

        driver.kill(2)
        engine.noteWindowDestroyed(windowID: 2)
        await engine.reconcile(liveWindowIDs: [1], livePIDs: [100, 200])

        #expect(driver.currentFrame(1) == content)
        #expect(engine.state.tab(withID: tab.id)?.windows.count == 2, "猶予中は entry を保持する")
        #expect(engine.state.managedWindow(id: vanished.id)?.window.isBound == false)
    }

    /// 最小サイズ制約の窓は到達 frame を採用して終わり。reconcile を繰り返しても再適用しない(発振回帰)。
    @Test func minSizeWindowDoesNotOscillate() async throws {
        let (engine, driver) = makeEngine()
        let tab = engine.createTab(name: "A")
        driver.add(1, frame: CGRect(x: 300, y: 100, width: 500, height: 400))
        driver.add(2, frame: CGRect(x: 900, y: 200, width: 940, height: 400), minSize: CGSize(width: 940, height: 0))
        let w2 = try await engine.register(windowID: 2, pid: 200, identity: identity("docker"), frame: CGRect(x: 900, y: 200, width: 940, height: 400), into: tab.id)
        try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: CGRect(x: 300, y: 100, width: 500, height: 400), into: tab.id)

        try await engine.setTabLayout(tab.id, .columns)
        let half = content.width / 2  // 840 < 940 なので幅は制約に負ける
        let recorded = engine.state.managedWindow(id: w2.id)?.window.frame
        #expect(recorded?.width == 940, "到達 frame(最小幅)が新しい基準になる")
        #expect(driver.currentFrame(2)?.width == 940)
        _ = half

        let before = driver.callCount("setFrame")
        for _ in 0..<5 {
            await engine.reconcile(liveWindowIDs: [1, 2], livePIDs: [100, 200])
        }
        #expect(driver.callCount("setFrame") == before, "理想列の再適用ループ(発振)が起きない")
    }

    /// columns の窓をドラッグしても、静止後に列の frame へスナップバックする。
    @Test func draggedTiledWindowSnapsBackToItsColumn() async throws {
        let (engine, driver) = makeEngine()
        let tab = engine.createTab(name: "A")
        driver.add(1, frame: CGRect(x: 300, y: 100, width: 500, height: 400))
        driver.add(2, frame: CGRect(x: 900, y: 200, width: 500, height: 400))
        let w1 = try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: CGRect(x: 300, y: 100, width: 500, height: 400), into: tab.id)
        try await engine.register(windowID: 2, pid: 200, identity: identity("b"), frame: CGRect(x: 900, y: 200, width: 500, height: 400), into: tab.id)
        try await engine.setTabLayout(tab.id, .columns)
        let column = engine.state.managedWindow(id: w1.id)!.window.frame

        driver.moveExternally(1, to: CGRect(x: 700, y: 300, width: 500, height: 400))
        engine.windowFrameDidChange(windowID: 1)
        try await Task.sleep(for: .milliseconds(150))
        #expect(driver.currentFrame(1) == column)
    }

    /// 編集モードでも columns のタブでは記録せず、常にスナップバックする。
    @Test func editModeDoesNotRecordIntoColumnsTab() async throws {
        let (engine, driver) = makeEngine()
        let tab = engine.createTab(name: "A")
        driver.add(1, frame: CGRect(x: 300, y: 100, width: 500, height: 400))
        let w1 = try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: CGRect(x: 300, y: 100, width: 500, height: 400), into: tab.id)
        try await engine.setTabLayout(tab.id, .columns)
        let column = engine.state.managedWindow(id: w1.id)!.window.frame

        engine.editMode = true
        driver.moveExternally(1, to: CGRect(x: 700, y: 300, width: 500, height: 400))
        engine.windowFrameDidChange(windowID: 1)
        try await Task.sleep(for: .milliseconds(150))
        #expect(driver.currentFrame(1) == column, "編集モードでも列に戻る")
        #expect(engine.state.managedWindow(id: w1.id)?.window.frame == column, "動かした位置は記録されない")
    }

    /// 画面構成が変わったら、columns は新しいコンテンツ領域で列を計算し直す。
    @Test func reapplyLayoutRetilesIntoNewArea() async throws {
        let driver = FakeWindowDriver()
        let layout = MutableScreenLayout(parkPoint: park, contentArea: content)
        let engine = TabEngine(driver: driver, layout: layout)
        let tab = engine.createTab(name: "A")
        driver.add(1, frame: CGRect(x: 300, y: 100, width: 500, height: 400))
        driver.add(2, frame: CGRect(x: 900, y: 200, width: 500, height: 400))
        try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: CGRect(x: 300, y: 100, width: 500, height: 400), into: tab.id)
        try await engine.register(windowID: 2, pid: 200, identity: identity("b"), frame: CGRect(x: 900, y: 200, width: 500, height: 400), into: tab.id)
        try await engine.setTabLayout(tab.id, .columns)

        let newArea = CGRect(x: 300, y: 30, width: 1140, height: 800)
        layout.change(parkPoint: CGPoint(x: 1439, y: 899), contentArea: newArea)
        await engine.reapplyLayout()

        let half = newArea.width / 2
        #expect(driver.currentFrame(1) == CGRect(x: newArea.minX, y: newArea.minY, width: half, height: newArea.height))
        #expect(driver.currentFrame(2) == CGRect(x: newArea.minX + half, y: newArea.minY, width: half, height: newArea.height))
    }

    /// 一覧の並べ替えは columns の列順を入れ替え、その場で列を組み直す。範囲外は throw。
    @Test func moveWindowReordersColumns() async throws {
        let (engine, driver) = makeEngine()
        let tab = engine.createTab(name: "A")
        driver.add(1, frame: CGRect(x: 300, y: 100, width: 500, height: 400))
        driver.add(2, frame: CGRect(x: 900, y: 200, width: 500, height: 400))
        let w1 = try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: CGRect(x: 300, y: 100, width: 500, height: 400), into: tab.id)
        try await engine.register(windowID: 2, pid: 200, identity: identity("b"), frame: CGRect(x: 900, y: 200, width: 500, height: 400), into: tab.id)
        try await engine.setTabLayout(tab.id, .columns)

        try await engine.moveWindow(w1.id, offset: 1)

        let half = content.width / 2
        #expect(driver.currentFrame(2) == CGRect(x: content.minX, y: content.minY, width: half, height: content.height), "先頭になった窓が左列")
        #expect(driver.currentFrame(1) == CGRect(x: content.minX + half, y: content.minY, width: half, height: content.height))
        await #expect(throws: TabEngine.EngineError.self) { try await engine.moveWindow(w1.id, offset: 1) }
    }

    /// free に戻すと現在の列 frame がそのまま自由配置の固定 frame になり、以後は自由に編集できる。
    @Test func switchingBackToFreeKeepsCurrentFrames() async throws {
        let (engine, driver) = makeEngine()
        let tab = engine.createTab(name: "A")
        driver.add(1, frame: CGRect(x: 300, y: 100, width: 500, height: 400))
        let w1 = try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: CGRect(x: 300, y: 100, width: 500, height: 400), into: tab.id)
        try await engine.setTabLayout(tab.id, .columns)
        #expect(driver.currentFrame(1) == content)

        try await engine.setTabLayout(tab.id, .free)
        #expect(engine.state.tab(withID: tab.id)?.layout == .free)
        #expect(engine.state.managedWindow(id: w1.id)?.window.frame == content, "列の frame が引き継がれる")
        #expect(driver.currentFrame(1) == content, "free への切替では窓は動かない")
    }

    /// 個別 frame API から columns の唯一の正を崩せない。
    @Test func setFrameRejectsColumnsLayout() async throws {
        let (engine, driver) = makeEngine()
        let tab = engine.createTab(name: "A")
        driver.add(1, frame: CGRect(x: 300, y: 100, width: 500, height: 400))
        let window = try await engine.register(
            windowID: 1, pid: 100, identity: identity("a"),
            frame: CGRect(x: 300, y: 100, width: 500, height: 400), into: tab.id)
        try await engine.setTabLayout(tab.id, .columns)
        let tiled = try #require(driver.currentFrame(1))
        let requested = CGRect(x: 700, y: 300, width: 500, height: 400)

        await #expect(throws: TabEngine.EngineError.self) {
            try await engine.setFrame(requested, of: window.id)
        }
        #expect(driver.currentFrame(1) == tiled)
        #expect(engine.state.managedWindow(id: window.id)?.window.frame == tiled)
    }

    /// inactive columns も画面変更時に論理列を更新し、free 化しても旧領域を固定しない。
    @Test func reapplyUpdatesInactiveColumnsBeforeSwitchingToFree() async throws {
        let driver = FakeWindowDriver()
        let layout = MutableScreenLayout(parkPoint: park, contentArea: content)
        let engine = TabEngine(driver: driver, layout: layout)
        _ = engine.createTab(name: "A")
        let inactive = engine.createTab(name: "B")
        driver.add(1, frame: CGRect(x: 300, y: 100, width: 500, height: 400))
        driver.add(2, frame: CGRect(x: 900, y: 200, width: 500, height: 400))
        let w1 = try await engine.register(
            windowID: 1, pid: 100, identity: identity("b1"),
            frame: CGRect(x: 300, y: 100, width: 500, height: 400), into: inactive.id)
        let w2 = try await engine.register(
            windowID: 2, pid: 200, identity: identity("b2"),
            frame: CGRect(x: 900, y: 200, width: 500, height: 400), into: inactive.id)
        try await engine.setTabLayout(inactive.id, .columns)

        let newArea = CGRect(x: 300, y: 30, width: 1140, height: 800)
        layout.change(parkPoint: CGPoint(x: 1439, y: 899), contentArea: newArea)
        await engine.reapplyLayout()
        try await engine.setTabLayout(inactive.id, .free)

        let half = newArea.width / 2
        #expect(engine.state.managedWindow(id: w1.id)?.window.frame ==
            CGRect(x: newArea.minX, y: newArea.minY, width: half, height: newArea.height))
        #expect(engine.state.managedWindow(id: w2.id)?.window.frame ==
            CGRect(x: newArea.minX + half, y: newArea.minY, width: half, height: newArea.height))
    }
}
