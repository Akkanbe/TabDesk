import CoreGraphics
import Foundation
import Testing
@testable import TabDeskCore

// 2 画面構成のフィクスチャ(AX 座標)。主画面 1920×1200(サイドバー 240px を除く)、
// 右隣に外部 2560×1440。displayID は再起動で安定する UUID 文字列の代わりに固定文字列を使う。
private let fixtureFrames = [
    CGRect(x: 0, y: 0, width: 1920, height: 1200),
    CGRect(x: 1920, y: 0, width: 2560, height: 1440),
]
private let fixtureParkPoints = ScreenGeometry.parkPoints(forDisplayFrames: fixtureFrames)
private let mainDisplay = DisplayLayout(
    id: "main",
    frame: fixtureFrames[0],
    contentArea: CGRect(x: 240, y: 30, width: 1680, height: 1090),
    parkPoint: fixtureParkPoints[0])
private let secondDisplay = DisplayLayout(
    id: "second",
    frame: fixtureFrames[1],
    contentArea: CGRect(x: 1920, y: 0, width: 2560, height: 1440),
    parkPoint: fixtureParkPoints[1])
private let soloMainDisplay = DisplayLayout(
    id: mainDisplay.id,
    frame: mainDisplay.frame,
    contentArea: mainDisplay.contentArea,
    parkPoint: ScreenGeometry.parkPoints(forDisplayFrames: [mainDisplay.frame])[0])

private func identity(_ name: String) -> WindowIdentity {
    WindowIdentity(bundleID: "test.\(name)", appName: name, title: name, registeredSize: CGSize(width: 800, height: 600))
}

@MainActor
private func makeEngine(maxRestoreAttempts: Int = 3) -> (TabEngine, FakeWindowDriver, MutableScreenLayout) {
    let driver = FakeWindowDriver()
    let layout = MutableScreenLayout(displays: [mainDisplay, secondDisplay])
    var config = TabEngine.Configuration()
    config.debounce = .milliseconds(20)
    config.maxRestoreAttempts = maxRestoreAttempts
    let engine = TabEngine(driver: driver, layout: layout, configuration: config)
    return (engine, driver, layout)
}

/// マルチディスプレイ(段階 D)の検証。
@MainActor
struct MultiDisplayTests {
    /// 外部ディスプレイの窓は登録しても主ディスプレイへ引き込まれず、所属が記録される。
    @Test func registeringOnSecondaryKeepsWindowThere() async throws {
        let (engine, driver, _) = makeEngine()
        let tab = engine.createTab(name: "A")
        let frame = CGRect(x: 2400, y: 200, width: 800, height: 600)
        driver.add(1, frame: frame)
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: frame, into: tab.id)
        #expect(managed.displayID == "second")
        #expect(driver.currentFrame(1) == frame, "外部ディスプレイに留まる")
    }

    /// 主ディスプレイの窓は従来どおりサイドバーを避けた領域へ寄せられる。
    @Test func registeringOnPrimaryStillAvoidsSidebar() async throws {
        let (engine, driver, _) = makeEngine()
        let tab = engine.createTab(name: "A")
        driver.add(1, frame: CGRect(x: 100, y: 100, width: 800, height: 600))
        let managed = try await engine.register(
            windowID: 1, pid: 100, identity: identity("a"),
            frame: CGRect(x: 100, y: 100, width: 800, height: 600), into: tab.id)
        #expect(managed.displayID == "main")
        #expect(driver.currentFrame(1)?.minX == 240, "サイドバー分だけ右へ寄る")
    }

    /// 退避は画面配置から計算した安全な隅へ。右隣がある主画面は配置外縁へ fallback する。
    @Test func parkingUsesSafeDisplayParkPoints() async throws {
        let (engine, driver, _) = makeEngine()
        let a = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(1, frame: CGRect(x: 300, y: 100, width: 500, height: 400))
        driver.add(2, frame: CGRect(x: 2400, y: 200, width: 800, height: 600))
        try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: CGRect(x: 300, y: 100, width: 500, height: 400), into: a.id)
        try await engine.register(windowID: 2, pid: 200, identity: identity("ext"), frame: CGRect(x: 2400, y: 200, width: 800, height: 600), into: a.id)
        driver.add(3, frame: CGRect(x: 300, y: 100, width: 500, height: 400))
        try await engine.register(windowID: 3, pid: 300, identity: identity("b"), frame: CGRect(x: 300, y: 100, width: 500, height: 400), into: b.id)

        try await engine.activate(b.id)
        #expect(driver.currentFrame(1)?.origin == mainDisplay.parkPoint)
        #expect(driver.currentFrame(2)?.origin == secondDisplay.parkPoint)
    }

    /// 「隅にいる」判定は自分のディスプレイの隅 x と比較する。正しく退避済みの窓を reconcile が動かさない。
    ///
    /// 注意: parkPoints で導出した退避点は仕組み上どの画面でも x が同じになる(自画面の隅を使えるのは
    /// 配置右端に届く画面だけで、その x は fallback と一致する)ため、導出値ではこの規則を検証できない。
    /// ここでは**画面ごとに隅 x が異なる退避点を手書き**して、エンジンの比較規則そのものを固定する。
    @Test func reconcileDoesNotReparkWindowsAtTheirOwnCorner() async throws {
        let customMain = DisplayLayout(
            id: "main", frame: fixtureFrames[0],
            contentArea: mainDisplay.contentArea, parkPoint: CGPoint(x: 1919, y: 1199))
        let customSecond = DisplayLayout(
            id: "second", frame: fixtureFrames[1],
            contentArea: secondDisplay.contentArea, parkPoint: CGPoint(x: 4479, y: 1439))
        let driver = FakeWindowDriver()
        let engine = TabEngine(driver: driver, layout: MutableScreenLayout(displays: [customMain, customSecond]))
        let a = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(1, frame: CGRect(x: 2400, y: 200, width: 800, height: 600))
        try await engine.register(windowID: 1, pid: 100, identity: identity("ext"), frame: CGRect(x: 2400, y: 200, width: 800, height: 600), into: b.id)
        _ = a
        #expect(driver.currentFrame(1)?.origin == customSecond.parkPoint, "非アクティブタブへの登録で外部の隅へ退避")

        let before = driver.callCount("setPosition")
        for _ in 0..<3 {
            await engine.reconcile(liveWindowIDs: [1], livePIDs: [100])
        }
        #expect(driver.callCount("setPosition") == before, "主ディスプレイの隅 x (1919) と比較していれば毎回再退避してしまう")
    }

    /// ディスプレイが切断されても、記録 frame・所属・実窓は凍結される(v3 段階 D3 = 切断退避)。
    @Test func disconnectedDisplayPreservesRecordedFrame() async throws {
        let (engine, driver, layout) = makeEngine()
        let tab = engine.createTab(name: "A")
        let frame = CGRect(x: 2400, y: 200, width: 800, height: 600)
        driver.add(1, frame: frame)
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("ext"), frame: frame, into: tab.id)
        let writesBefore = driver.callCount("setFrame") + driver.callCount("setPosition")

        layout.change(displays: [soloMainDisplay])
        await engine.reapplyLayout()

        let window = try #require(engine.state.managedWindow(id: managed.id)?.window)
        #expect(window.frame == frame, "記録 frame は凍結")
        #expect(window.displayID == "second", "所属も凍結")
        #expect(driver.currentFrame(1) == frame, "実窓に op を発行しない")
        #expect(driver.callCount("setFrame") + driver.callCount("setPosition") == writesBefore)
    }

    /// 再接続すると、次の reapplyLayout の通常経路が記録 frame へ復元する(電源サイクル往復の回帰)。
    @Test func reconnectRestoresOriginalFrame() async throws {
        let (engine, driver, layout) = makeEngine()
        let tab = engine.createTab(name: "A")
        let frame = CGRect(x: 2400, y: 200, width: 800, height: 600)
        driver.add(1, frame: frame)
        try await engine.register(windowID: 1, pid: 100, identity: identity("ext"), frame: frame, into: tab.id)

        layout.change(displays: [soloMainDisplay])
        await engine.reapplyLayout()
        // macOS が切断時に窓を主画面へ動かした状況を模す(偽ドライバは OS クランプを持たないため)。
        driver.moveExternally(1, to: CGRect(x: 400, y: 100, width: 800, height: 600))

        layout.change(displays: [mainDisplay, secondDisplay])
        await engine.reapplyLayout()

        #expect(driver.currentFrame(1) == frame, "再接続後は元の外部座標へ戻る")
        #expect(engine.state.allWindows.first?.frame == frame)
    }

    /// 未復元(unbound)エントリの保存 frame も切断で書き換えない(精査 High の unbound 経路)。
    @Test func disconnectedUnboundEntryKeepsFrame() async throws {
        let (engine, driver, layout) = makeEngine()
        let tab = engine.createTab(name: "A")
        let frame = CGRect(x: 2400, y: 200, width: 800, height: 600)
        driver.add(1, frame: frame)
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("ext"), frame: frame, into: tab.id)
        engine.unbindWindows(pid: 100)

        layout.change(displays: [soloMainDisplay])
        await engine.reapplyLayout()

        #expect(engine.state.managedWindow(id: managed.id)?.window.frame == frame)
        #expect(engine.state.managedWindow(id: managed.id)?.window.displayID == "second")
    }

    /// 切断中の解除は実窓を動かさず(macOS が置いた場所のまま)、登録だけ手放す。
    @Test func unregisterDisconnectedWindowLeavesItInPlace() async throws {
        let (engine, driver, layout) = makeEngine()
        _ = engine.createTab(name: "A")
        let inactive = engine.createTab(name: "B")
        let externalFrame = CGRect(x: 2400, y: 200, width: 800, height: 600)
        driver.add(1, frame: externalFrame)
        let managed = try await engine.register(
            windowID: 1, pid: 100, identity: identity("ext"), frame: externalFrame, into: inactive.id)

        layout.change(displays: [soloMainDisplay])
        // macOS の切断時クランプを模す(実窓はどこかの生きている画面に置かれる)。
        let osPlaced = CGRect(x: 500, y: 200, width: 800, height: 600)
        driver.moveExternally(1, to: osPlaced)
        let writesBefore = driver.callCount("setFrame") + driver.callCount("setPosition")

        try await engine.unregister(managed.id)

        #expect(engine.state.allWindows.isEmpty, "登録は解除される")
        #expect(driver.currentFrame(1) == osPlaced, "実窓は OS が置いた場所のまま")
        #expect(driver.callCount("setFrame") + driver.callCount("setPosition") == writesBefore, "書き込み op なし")
        #expect(engine.parkedWindowIDs.isEmpty)
    }

    /// editMode 中でも、画面切断に伴う OS の移動(遅延通知含む)で凍結した frame と所属を上書きしない。
    /// OS 移動とユーザードラッグは通知から区別できないため、切断中は編集モードでも一切記録しない(D3)。
    @Test func layoutTransitionDoesNotRecordOSMoveAsDisplayEdit() async throws {
        let (engine, driver, layout) = makeEngine()
        let tab = engine.createTab(name: "A")
        let externalFrame = CGRect(x: 2400, y: 200, width: 800, height: 600)
        driver.add(1, frame: externalFrame)
        let managed = try await engine.register(
            windowID: 1, pid: 100, identity: identity("ext"), frame: externalFrame, into: tab.id)
        engine.editMode = true

        layout.change(displays: [soloMainDisplay])
        engine.beginLayoutTransition()
        // macOS が reapply より先に窓を主画面へ移した状況を模す。
        driver.moveExternally(1, to: CGRect(x: 300, y: 100, width: 800, height: 600))
        engine.windowFrameDidChange(windowID: 1)
        await engine.reapplyLayout()
        engine.endLayoutTransition()
        // barrier 解除後に届く遅延 moved 通知も、切断中は編集として扱わない。
        engine.windowFrameDidChange(windowID: 1)
        try await Task.sleep(for: .milliseconds(100))

        let current = try #require(engine.state.managedWindow(id: managed.id)?.window)
        #expect(current.displayID == "second", "再接続時に元ディスプレイを識別できるよう所属を保持する")
        #expect(current.frame == externalFrame, "凍結した記録 frame は遅延通知でも上書きされない")
    }

    /// 通常のユーザードラッグでは、従来どおり移動先ディスプレイへ所属を更新する。
    @Test func editModeStillRecordsIntentionalCrossDisplayMove() async throws {
        let (engine, driver, _) = makeEngine()
        let tab = engine.createTab(name: "A")
        let primaryFrame = CGRect(x: 300, y: 100, width: 800, height: 600)
        driver.add(1, frame: primaryFrame)
        let managed = try await engine.register(
            windowID: 1, pid: 100, identity: identity("main"), frame: primaryFrame, into: tab.id)
        engine.editMode = true

        let externalFrame = CGRect(x: 2400, y: 200, width: 800, height: 600)
        driver.moveExternally(1, to: externalFrame)
        engine.windowFrameDidChange(windowID: 1)
        try await Task.sleep(for: .milliseconds(100))

        let current = try #require(engine.state.managedWindow(id: managed.id)?.window)
        #expect(current.displayID == "second")
        #expect(current.frame == externalFrame)
    }

    /// 終了時の全解放も切断中の窓には触らず、記録 frame を次回起動の復元材料として残す。
    @Test func shutdownReleaseKeepsDisconnectedFrames() async throws {
        let (engine, driver, layout) = makeEngine()
        _ = engine.createTab(name: "A")
        let inactive = engine.createTab(name: "B")
        let externalFrame = CGRect(x: 2400, y: 200, width: 800, height: 600)
        driver.add(1, frame: externalFrame)
        let managed = try await engine.register(
            windowID: 1, pid: 100, identity: identity("ext"), frame: externalFrame, into: inactive.id)
        #expect(engine.parkedWindowIDs.contains(managed.id))

        layout.change(displays: [soloMainDisplay])
        let osPlaced = CGRect(x: 500, y: 200, width: 800, height: 600)
        driver.moveExternally(1, to: osPlaced)
        await engine.releaseAllParkedWindows()

        #expect(engine.state.managedWindow(id: managed.id)?.window.frame == externalFrame, "保存値は凍結のまま")
        #expect(driver.currentFrame(1) == osPlaced, "実窓は動かさない")
        #expect(engine.parkedWindowIDs.isEmpty, "退避フラグは畳んで手放す")
    }

    /// fullscreen確認の待機中に切断された場合、その確認後に新しいrestoreを発行しない。
    @Test func shutdownDoesNotStartRestoreAfterDisconnectDuringProbe() async throws {
        let (engine, driver, layout) = makeEngine()
        _ = engine.createTab(name: "A")
        let inactive = engine.createTab(name: "B")
        let externalFrame = CGRect(x: 2400, y: 200, width: 800, height: 600)
        driver.add(1, frame: externalFrame, delay: 0.08)
        let managed = try await engine.register(
            windowID: 1, pid: 100, identity: identity("ext"), frame: externalFrame, into: inactive.id)
        let probesBefore = driver.callCount("isFullscreen:1")
        let writesBefore = driver.callCount("setFrame:1")

        let release = Task { await engine.releaseAllParkedWindows() }
        try await withDeadline {
            while driver.callCount("isFullscreen:1") == probesBefore {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
        layout.change(displays: [soloMainDisplay])
        let osPlaced = CGRect(x: 500, y: 200, width: 800, height: 600)
        driver.moveExternally(1, to: osPlaced)
        await release.value

        #expect(driver.callCount("setFrame:1") == writesBefore)
        #expect(driver.currentFrame(1) == osPlaced)
        #expect(engine.state.managedWindow(id: managed.id)?.window.frame == externalFrame)
        #expect(!engine.parkedWindowIDs.contains(managed.id))
    }

    /// 復元 IPC の開始後にディスプレイが切断されても、到達 frame を保存値へ採用しない。
    @Test func shutdownReleaseDoesNotAdoptFrameAfterMidIPCDisconnect() async throws {
        let (engine, driver, layout) = makeEngine()
        _ = engine.createTab(name: "A")
        let inactive = engine.createTab(name: "B")
        let externalFrame = CGRect(x: 2400, y: 200, width: 800, height: 600)
        driver.add(1, frame: externalFrame, delay: 0.15)
        let managed = try await engine.register(
            windowID: 1, pid: 100, identity: identity("ext"), frame: externalFrame, into: inactive.id)
        driver.setMinSize(CGSize(width: 900, height: 0), of: 1)

        let writesBefore = driver.callCount("setFrame:1")
        let release = Task { await engine.releaseAllParkedWindows() }
        try await withDeadline {
            while driver.callCount("setFrame:1") == writesBefore {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
        // setFrame は既に IPC 中。macOS がその途中で外部画面を切断した状況を模す。
        layout.change(displays: [soloMainDisplay])
        await release.value

        #expect(driver.currentFrame(1)?.width == 900, "開始済み IPC 自体は取り消せない")
        #expect(engine.state.managedWindow(id: managed.id)?.window.frame == externalFrame,
            "切断後の到達 frame を保存値へ採用しない")
        #expect(!engine.parkedWindowIDs.contains(managed.id))
    }

    /// スナップバック最終試行のIPC中に切断されても、制約後の到達frameを保存しない。
    @Test func snapbackDoesNotAdoptFrameAfterMidIPCDisconnect() async throws {
        let (engine, driver, layout) = makeEngine(maxRestoreAttempts: 1)
        let tab = engine.createTab(name: "A")
        let externalFrame = CGRect(x: 2400, y: 200, width: 800, height: 600)
        driver.add(1, frame: externalFrame, delay: 0.08)
        let managed = try await engine.register(
            windowID: 1, pid: 100, identity: identity("ext"), frame: externalFrame, into: tab.id)
        driver.setMinSize(CGSize(width: 900, height: 0), of: 1)
        driver.moveExternally(1, to: CGRect(x: 2500, y: 300, width: 800, height: 600))

        let writesBefore = driver.callCount("setFrame:1")
        engine.windowFrameDidChange(windowID: 1)
        engine.flushPendingRestores()
        try await withDeadline {
            while driver.callCount("setFrame:1") == writesBefore {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
        layout.change(displays: [soloMainDisplay])
        // restore が持つ直列区間の完了を待つ。reconcile 自体は切断中なのでopを出さない。
        await engine.reconcile(liveWindowIDs: [1], livePIDs: [100])

        #expect(driver.currentFrame(1)?.width == 900, "開始済みIPC自体は取り消せない")
        #expect(engine.state.managedWindow(id: managed.id)?.window.frame == externalFrame)
    }

    /// 編集モードのclamp IPC中に切断されても、OS側の到達値と所属を編集結果として採用しない。
    @Test func editClampDoesNotAdoptFrameAfterMidIPCDisconnect() async throws {
        let (engine, driver, layout) = makeEngine()
        let tab = engine.createTab(name: "A")
        let externalFrame = CGRect(x: 2400, y: 200, width: 800, height: 600)
        driver.add(1, frame: externalFrame, delay: 0.08)
        let managed = try await engine.register(
            windowID: 1, pid: 100, identity: identity("ext"), frame: externalFrame, into: tab.id)
        engine.editMode = true
        let outside = CGRect(x: 4300, y: 1200, width: 800, height: 600)
        driver.moveExternally(1, to: outside)

        let writesBefore = driver.callCount("setFrame:1")
        engine.windowFrameDidChange(windowID: 1)
        engine.flushPendingRestores()
        try await withDeadline {
            while driver.callCount("setFrame:1") == writesBefore {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
        layout.change(displays: [soloMainDisplay])
        await engine.reconcile(liveWindowIDs: [1], livePIDs: [100])

        let saved = try #require(engine.state.managedWindow(id: managed.id)?.window)
        #expect(driver.currentFrame(1) != outside, "開始済みclamp IPC自体は取り消せない")
        #expect(saved.frame == externalFrame)
        #expect(saved.displayID == secondDisplay.id)
    }

    /// 失敗opの読み戻し中に切断された場合も、D3として手放しfailure/parkedを残さない。
    @Test func failedRestoreReadbackHandlesMidIPCDisconnect() async throws {
        let (engine, driver, layout) = makeEngine()
        _ = engine.createTab(name: "A")
        let inactive = engine.createTab(name: "B")
        let externalFrame = CGRect(x: 2400, y: 200, width: 800, height: 600)
        driver.add(1, frame: externalFrame, delay: 0.08)
        let managed = try await engine.register(
            windowID: 1, pid: 100, identity: identity("ext"), frame: externalFrame, into: inactive.id)
        driver.setFailWrites(1)

        let readsBefore = driver.callCount("frame:1")
        let activation = Task { try await engine.activate(inactive.id) }
        try await withDeadline {
            while driver.callCount("frame:1") == readsBefore {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
        layout.change(displays: [soloMainDisplay])
        let report = try await activation.value

        #expect(report.failures.isEmpty)
        #expect(!engine.parkedWindowIDs.contains(managed.id))
        #expect(engine.state.managedWindow(id: managed.id)?.window.frame == externalFrame)
    }

    /// reconcile は切断中の窓に補正 op を出さない(park 再試行・ずれ検知・フラグ修復すべて対象外)。
    @Test func reconcileEmitsNoOpsForDisconnectedWindows() async throws {
        let (engine, driver, layout) = makeEngine()
        _ = engine.createTab(name: "A")
        let inactive = engine.createTab(name: "B")
        let frame = CGRect(x: 2400, y: 200, width: 800, height: 600)
        driver.add(1, frame: frame)
        try await engine.register(windowID: 1, pid: 100, identity: identity("ext"), frame: frame, into: inactive.id)

        layout.change(displays: [soloMainDisplay])
        driver.moveExternally(1, to: CGRect(x: 500, y: 200, width: 800, height: 600))  // 隅から外れた状態
        let before = driver.callCount("setFrame") + driver.callCount("setPosition")
        for _ in 0..<3 {
            await engine.reconcile(liveWindowIDs: [1], livePIDs: [100])
        }
        #expect(driver.callCount("setFrame") + driver.callCount("setPosition") == before)
    }

    /// タブ切替は切断中の窓を復元も退避もせず、同じタブの生きている窓だけを扱う。
    @Test func activateSkipsDisconnectedWindows() async throws {
        let (engine, driver, layout) = makeEngine()
        let a = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        let extFrame = CGRect(x: 2400, y: 200, width: 800, height: 600)
        let mainFrame = CGRect(x: 300, y: 100, width: 500, height: 400)
        driver.add(1, frame: extFrame)
        driver.add(2, frame: mainFrame)
        driver.add(3, frame: mainFrame)
        try await engine.register(windowID: 1, pid: 100, identity: identity("ext"), frame: extFrame, into: a.id)
        try await engine.register(windowID: 2, pid: 200, identity: identity("m"), frame: mainFrame, into: a.id)
        try await engine.register(windowID: 3, pid: 300, identity: identity("b"), frame: mainFrame, into: b.id)

        layout.change(displays: [soloMainDisplay])
        let osPlaced = CGRect(x: 500, y: 200, width: 800, height: 600)
        driver.moveExternally(1, to: osPlaced)

        try await engine.activate(b.id)
        #expect(driver.currentFrame(1) == osPlaced, "切断中の窓は退避しない")
        #expect(driver.currentFrame(2)?.origin == soloMainDisplay.parkPoint, "生きている窓は退避する")

        try await engine.activate(a.id)
        #expect(driver.currentFrame(1) == osPlaced, "切断中の窓は復元もしない")
        #expect(driver.currentFrame(2) == mainFrame, "生きている窓は復元する")
    }

    /// スナップバックは切断中の窓を無視する(採用によるframe破壊も起きない)。
    @Test func snapbackIgnoresDisconnectedWindow() async throws {
        let (engine, driver, layout) = makeEngine()
        let tab = engine.createTab(name: "A")
        let frame = CGRect(x: 2400, y: 200, width: 800, height: 600)
        driver.add(1, frame: frame)
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("ext"), frame: frame, into: tab.id)

        layout.change(displays: [soloMainDisplay])
        driver.moveExternally(1, to: CGRect(x: 700, y: 300, width: 800, height: 600))
        engine.windowFrameDidChange(windowID: 1)
        try await Task.sleep(for: .milliseconds(150))

        #expect(driver.currentFrame(1) == CGRect(x: 700, y: 300, width: 800, height: 600), "戻さない")
        #expect(engine.state.managedWindow(id: managed.id)?.window.frame == frame, "記録も変えない")
    }

    /// 編集モードでも切断中の窓のドラッグは記録しない(凍結は凍結)。
    @Test func editModeDragDoesNotRecordDisconnectedWindow() async throws {
        let (engine, driver, layout) = makeEngine()
        let tab = engine.createTab(name: "A")
        let frame = CGRect(x: 2400, y: 200, width: 800, height: 600)
        driver.add(1, frame: frame)
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("ext"), frame: frame, into: tab.id)
        engine.editMode = true

        layout.change(displays: [soloMainDisplay])
        driver.moveExternally(1, to: CGRect(x: 300, y: 100, width: 800, height: 600))
        engine.windowFrameDidChange(windowID: 1)
        try await Task.sleep(for: .milliseconds(150))

        let window = try #require(engine.state.managedWindow(id: managed.id)?.window)
        #expect(window.frame == frame)
        #expect(window.displayID == "second")
    }

    /// columns の列計算から切断中の窓は除外され、主画面へタイルされない。
    @Test func columnsExcludeDisconnectedWindows() async throws {
        let (engine, driver, layout) = makeEngine()
        let tab = engine.createTab(name: "A")
        let m1 = CGRect(x: 300, y: 100, width: 500, height: 400)
        let m2 = CGRect(x: 900, y: 200, width: 500, height: 400)
        let ext = CGRect(x: 2400, y: 200, width: 800, height: 600)
        driver.add(1, frame: m1)
        driver.add(2, frame: m2)
        driver.add(3, frame: ext)
        try await engine.register(windowID: 1, pid: 100, identity: identity("m1"), frame: m1, into: tab.id)
        try await engine.register(windowID: 2, pid: 200, identity: identity("m2"), frame: m2, into: tab.id)
        let extManaged = try await engine.register(windowID: 3, pid: 300, identity: identity("ext"), frame: ext, into: tab.id)
        try await engine.setTabLayout(tab.id, .columns)

        layout.change(displays: [soloMainDisplay])
        await engine.reapplyLayout()

        let area = soloMainDisplay.contentArea
        let half = area.width / 2
        #expect(driver.currentFrame(1) == CGRect(x: area.minX, y: area.minY, width: half, height: area.height), "主画面は 2 窓で等分")
        #expect(driver.currentFrame(2) == CGRect(x: area.minX + half, y: area.minY, width: half, height: area.height))
        #expect(engine.state.managedWindow(id: extManaged.id)?.window.frame == secondDisplay.contentArea, "切断中の窓は列に入らず記録も凍結")
    }

    /// 切断中エントリへの bind は配置(place)を省略し、記録 frame を保ったまま紐付けだけ行う。
    @Test func bindToDisconnectedEntrySkipsPlacement() async throws {
        let (engine, driver, layout) = makeEngine()
        let tab = engine.createTab(name: "A")
        let frame = CGRect(x: 2400, y: 200, width: 800, height: 600)
        driver.add(1, frame: frame)
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("ext"), frame: frame, into: tab.id)
        engine.unbindWindows(pid: 100)
        layout.change(displays: [soloMainDisplay])

        driver.add(9, frame: CGRect(x: 500, y: 200, width: 800, height: 600))  // 再起動後の同じ窓(別 ID)
        let writesBefore = driver.callCount("setFrame") + driver.callCount("setPosition")
        try await engine.bind(managed.id, windowID: 9, pid: 100)

        let window = try #require(engine.state.managedWindow(id: managed.id)?.window)
        #expect(window.isBound)
        #expect(window.frame == frame, "記録 frame は凍結のまま")
        #expect(driver.callCount("setFrame") + driver.callCount("setPosition") == writesBefore, "place の IPC なし")
        #expect(!engine.parkedWindowIDs.contains(managed.id), "非アクティブ扱いでも退避フラグは立てない")
    }

    /// columns はディスプレイごとに独立して等分する(画面をまたいだ 1 本の列にはしない)。
    @Test func columnsTilePerDisplay() async throws {
        let (engine, driver, _) = makeEngine()
        let tab = engine.createTab(name: "A")
        driver.add(1, frame: CGRect(x: 300, y: 100, width: 500, height: 400))
        driver.add(2, frame: CGRect(x: 900, y: 200, width: 500, height: 400))
        driver.add(3, frame: CGRect(x: 2400, y: 200, width: 800, height: 600))
        try await engine.register(windowID: 1, pid: 100, identity: identity("m1"), frame: CGRect(x: 300, y: 100, width: 500, height: 400), into: tab.id)
        try await engine.register(windowID: 2, pid: 200, identity: identity("m2"), frame: CGRect(x: 900, y: 200, width: 500, height: 400), into: tab.id)
        try await engine.register(windowID: 3, pid: 300, identity: identity("ext"), frame: CGRect(x: 2400, y: 200, width: 800, height: 600), into: tab.id)

        try await engine.setTabLayout(tab.id, .columns)

        let area = mainDisplay.contentArea
        let half = area.width / 2
        #expect(driver.currentFrame(1) == CGRect(x: area.minX, y: area.minY, width: half, height: area.height))
        #expect(driver.currentFrame(2) == CGRect(x: area.minX + half, y: area.minY, width: half, height: area.height))
        #expect(driver.currentFrame(3) == secondDisplay.contentArea, "外部側は 1 窓なので外部の全面")
    }

    /// アプリごと終了(unbind)でも columns は次の reconcile で列を組み直す(レビュー指摘)。
    @Test func appQuitRetilesColumnsOnNextReconcile() async throws {
        let (engine, driver, _) = makeEngine()
        let tab = engine.createTab(name: "A")
        driver.add(1, frame: CGRect(x: 300, y: 100, width: 500, height: 400))
        driver.add(2, frame: CGRect(x: 900, y: 200, width: 500, height: 400))
        try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: CGRect(x: 300, y: 100, width: 500, height: 400), into: tab.id)
        try await engine.register(windowID: 2, pid: 200, identity: identity("b"), frame: CGRect(x: 900, y: 200, width: 500, height: 400), into: tab.id)
        try await engine.setTabLayout(tab.id, .columns)

        driver.kill(2)
        engine.unbindWindows(pid: 200)  // NSWorkspace のアプリ終了通知経路
        await engine.reconcile(liveWindowIDs: [1], livePIDs: [100])
        #expect(driver.currentFrame(1) == mainDisplay.contentArea, "残った bound 1 窓で全面")
        #expect(engine.state.tab(withID: tab.id)?.windows.count == 2, "未復元エントリは保持される")
    }

    /// destroyed 通知後に pid ごと消えた(vanish → アプリ終了と確定)場合も列を組み直す(レビュー指摘)。
    @Test func vanishedThenDeadPIDRetilesColumns() async throws {
        let (engine, driver, _) = makeEngine()
        let tab = engine.createTab(name: "A")
        driver.add(1, frame: CGRect(x: 300, y: 100, width: 500, height: 400))
        driver.add(2, frame: CGRect(x: 900, y: 200, width: 500, height: 400))
        try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: CGRect(x: 300, y: 100, width: 500, height: 400), into: tab.id)
        try await engine.register(windowID: 2, pid: 200, identity: identity("b"), frame: CGRect(x: 900, y: 200, width: 500, height: 400), into: tab.id)
        try await engine.setTabLayout(tab.id, .columns)

        driver.kill(2)
        engine.noteWindowDestroyed(windowID: 2)  // 猶予つきの vanish 保留に入る
        await engine.reconcile(liveWindowIDs: [1], livePIDs: [100])  // pid 200 が消えた → アプリ終了と確定
        #expect(driver.currentFrame(1) == mainDisplay.contentArea)
    }

    /// displayID の無い v1 の JSON は nil(= 主ディスプレイ)として読める。
    @Test func decodingV1WindowWithoutDisplayIDDefaultsToNil() throws {
        let json = """
            {"id": "\(UUID().uuidString)", "frame": [[240, 30], [800, 600]], "identity": \
            {"bundleID": "test.a", "appName": "A", "title": "T", "registeredSize": [800, 600]}}
            """
        let window = try JSONDecoder().decode(ManagedWindow.self, from: Data(json.utf8))
        #expect(window.displayID == nil)
    }

    /// displayID は保存・復元される。
    @Test func displayIDRoundTripsThroughCoding() throws {
        let window = ManagedWindow(
            frame: CGRect(x: 2400, y: 200, width: 800, height: 600),
            identity: identity("ext"), windowID: 1, pid: 100, displayID: "second")
        let data = try JSONEncoder().encode(window)
        let decoded = try JSONDecoder().decode(ManagedWindow.self, from: data)
        #expect(decoded.displayID == "second")
    }
}

/// 退避点の配置ジオメトリ(レビュー指摘: 右隣に画面がある画面の隅は「内側」なので窓が丸見えになる)。
struct ParkPointGeometryTests {
    private let left = CGRect(x: 0, y: 0, width: 1920, height: 1200)
    private let right = CGRect(x: 1920, y: 0, width: 2560, height: 1440)

    @Test func singleDisplayUsesOwnCorner() {
        let points = ScreenGeometry.parkPoints(forDisplayFrames: [left])
        #expect(points == [CGPoint(x: 1919, y: 1199)])
    }

    /// 右隣がある画面は配置全体の外縁(右下)へ、右端の画面は自画面の隅のまま。
    @Test func innerDisplayFallsBackToArrangementCorner() {
        let points = ScreenGeometry.parkPoints(forDisplayFrames: [left, right])
        #expect(points[0] == CGPoint(x: 4479, y: 1439), "左画面の隅 (1919,1199) は右画面上の合法な座標なので使わない")
        #expect(points[1] == CGPoint(x: 4479, y: 1439))
    }

    /// 等幅の縦積み(上下)ではどちらも配置の右端に達するので、自画面の隅でよい
    /// (下の画面へ 1px 列がまたがるだけで、窓本体は見えない)。
    @Test func verticalStackKeepsOwnCorners() {
        let top = CGRect(x: 0, y: 0, width: 1920, height: 1200)
        let bottom = CGRect(x: 0, y: 1200, width: 1920, height: 1200)
        let points = ScreenGeometry.parkPoints(forDisplayFrames: [top, bottom])
        #expect(points[0] == CGPoint(x: 1919, y: 1199))
        #expect(points[1] == CGPoint(x: 1919, y: 2399))
    }

    /// 下側の画面が横に広い場合、上画面の右下から窓本体が下画面へ露出するので右端へ逃がす。
    @Test func widerLowerDisplayUsesGlobalRightEdge() {
        let top = CGRect(x: 320, y: 0, width: 1920, height: 1080)
        let bottom = CGRect(x: 0, y: 1080, width: 2560, height: 1440)
        let points = ScreenGeometry.parkPoints(forDisplayFrames: [top, bottom])
        let safe = CGPoint(x: 2559, y: 2519)
        #expect(points == [safe, safe])
    }

    /// maxX/maxY を別画面から合成せず、L 字配置でも実在する右端画面の隅を使う。
    @Test func lShapedArrangementUsesAnActualDisplayCorner() {
        let upperLeft = CGRect(x: 0, y: 0, width: 1920, height: 1200)
        let upperRight = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        let lowerLeft = CGRect(x: 0, y: 1200, width: 1920, height: 1080)
        let frames = [upperLeft, upperRight, lowerLeft]
        let points = ScreenGeometry.parkPoints(forDisplayFrames: frames)
        let safe = CGPoint(x: 3839, y: 1079)
        #expect(points == [safe, safe, safe])
        #expect(frames.contains { $0.contains(safe) })
    }

    /// 3 枚横並び: 右端だけ自画面の隅、それ以外はフォールバック。
    @Test func threeInARowOnlyRightmostKeepsCorner() {
        let mid = CGRect(x: 1920, y: 0, width: 1920, height: 1200)
        let rightmost = CGRect(x: 3840, y: 0, width: 1920, height: 1200)
        let points = ScreenGeometry.parkPoints(forDisplayFrames: [left, mid, rightmost])
        #expect(points[0] == CGPoint(x: 5759, y: 1199))
        #expect(points[1] == CGPoint(x: 5759, y: 1199))
        #expect(points[2] == CGPoint(x: 5759, y: 1199))
    }
}

/// v4 段階 0: setFrame の IPC 後チェック順の統一(切断の凍結を fullscreen より先に確認する)。
@MainActor
struct SetFrameMidIPCOrderTests {
    /// IPC 中に「fullscreen 進入(書き込みが飲み込まれる)」と「ディスプレイ切断」が同時に起きた場合、
    /// 切断の凍結が勝つ(修正前は fullscreen 分岐が先で、凍結すべき記録へ要求値を書いていた)。
    @Test func setFrameFreezesWhenDisplayDisconnectsMidIPC() async throws {
        let (engine, driver, layout) = makeEngine()
        let tab = engine.createTab(name: "A")
        let frame = CGRect(x: 2400, y: 200, width: 800, height: 600)
        driver.add(1, frame: frame)
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("ext"), frame: frame, into: tab.id)
        // reconcile 前に fullscreen へ進入(集合は未更新なので setFrame のガードは素通りする)。
        driver.setFullscreen(1)
        driver.setDelay(1, 0.15)

        async let result = engine.setFrame(CGRect(x: 2500, y: 250, width: 800, height: 600), of: managed.id)
        try await Task.sleep(for: .milliseconds(50))  // setFrame の IPC 中に…
        layout.change(displays: [soloMainDisplay])    // …ディスプレイが切断される
        let returned = try await result

        #expect(returned == frame, "凍結された従来値が返る")
        let recorded = engine.state.managedWindow(id: managed.id)?.window.frame
        #expect(recorded == frame, "要求値もフルスクリーン寸法も記録しない(凍結が最優先)")
    }
}
