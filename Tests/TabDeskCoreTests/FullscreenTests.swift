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

    /// AXFullScreen の読み取り失敗(nil)はメンバーシップを維持し、復元も採用もしない(レビュー指摘)。
    /// false に潰すと、忙しいアプリの一時的なタイムアウト 1 回で集合から外れ、直後の即時復元が
    /// 飲み込まれてフルスクリーン寸法を記録に採用してしまう。
    @Test func unreadableFullscreenProbeKeepsMembershipAndFrames() async throws {
        let (engine, driver) = makeEngine()
        _ = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        let recorded = CGRect(x: 300, y: 100, width: 500, height: 400)
        driver.add(1, frame: recorded)
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("b"), frame: recorded, into: b.id)
        #expect(engine.parkedWindowIDs.contains(managed.id), "非アクティブ登録で退避フラグが立つ")

        driver.setFullscreen(1)
        driver.moveExternally(1, to: fullscreenRect)
        await engine.reconcile(liveWindowIDs: [1], livePIDs: [100])
        #expect(engine.fullscreenWindowIDs.contains(managed.id))
        // タブを表示(fullscreen 窓は復元 op を出さないので退避フラグは残る = 危険な組み合わせ)。
        try await engine.activate(b.id)
        #expect(engine.parkedWindowIDs.contains(managed.id))

        driver.setFullscreenReadFails(1)
        let writesBefore = driver.callCount("setFrame") + driver.callCount("setPosition")
        for _ in 0..<3 {
            await engine.reconcile(liveWindowIDs: [1], livePIDs: [100])
        }
        #expect(engine.fullscreenWindowIDs.contains(managed.id), "読めない間は前回判定を維持")
        #expect(driver.callCount("setFrame") + driver.callCount("setPosition") == writesBefore, "op を出さない")
        #expect(engine.state.managedWindow(id: managed.id)?.window.frame == recorded, "記録 frame を破壊しない")
    }

    /// setFrame はフルスクリーン中、記録のみ更新して IPC を出さない(レビュー指摘: ゲート漏れの回帰)。
    @Test func setFrameRecordsOnlyWhileFullscreen() async throws {
        let (engine, driver) = makeEngine()
        let tab = engine.createTab(name: "A")
        driver.add(1, frame: CGRect(x: 300, y: 100, width: 500, height: 400))
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: CGRect(x: 300, y: 100, width: 500, height: 400), into: tab.id)
        driver.setFullscreen(1)
        driver.moveExternally(1, to: fullscreenRect)
        await engine.reconcile(liveWindowIDs: [1], livePIDs: [100])
        #expect(engine.fullscreenWindowIDs.contains(managed.id))

        let requested = CGRect(x: 400, y: 200, width: 600, height: 500)
        let writesBefore = driver.callCount("setFrame")
        let result = try await engine.setFrame(requested, of: managed.id)
        #expect(result == requested, "clamp 済み要求値が記録される")
        #expect(engine.state.managedWindow(id: managed.id)?.window.frame == requested)
        #expect(driver.callCount("setFrame") == writesBefore, "IPC は出さない(飲み込まれた読み戻し値を記録しない)")
        #expect(driver.currentFrame(1) == fullscreenRect)
    }

    /// 登録の配置 IPC 中に fullscreen へ入っても、その寸法を初期の固定 frame にしない。
    @Test func registerDuringFullscreenEntryKeepsLogicalFrame() async throws {
        let (engine, driver) = makeEngine()
        let tab = engine.createTab(name: "A")
        let recorded = CGRect(x: 300, y: 100, width: 500, height: 400)
        driver.add(1, frame: recorded, delay: 0.08)

        let registration = Task {
            try await engine.register(
                windowID: 1, pid: 100, identity: identity("a"), frame: recorded, into: tab.id)
        }
        try await withDeadline {
            while driver.callCount("setFrame:1") == 0 {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
        driver.setFullscreen(1)
        driver.moveExternally(1, to: fullscreenRect)
        let managed = try await registration.value

        #expect(managed.frame == recorded)
        #expect(engine.state.managedWindow(id: managed.id)?.window.frame == recorded)
        #expect(engine.fullscreenWindowIDs.contains(managed.id))
        #expect(driver.currentFrame(1) == fullscreenRect)
    }

    /// 保存エントリの bind 中に fullscreen へ入っても、現在領域へclampした論理frameを保持する。
    @Test func bindDuringFullscreenEntryKeepsClampedLogicalFrame() async throws {
        let driver = FakeWindowDriver()
        let saved = CGRect(x: 2_500, y: 900, width: 800, height: 600)
        let managed = ManagedWindow(
            frame: saved, identity: identity("old"), windowID: nil, pid: nil)
        let tab = Tab(name: "A", windows: [managed])
        let engine = TabEngine(
            driver: driver,
            layout: FixedScreenLayout(parkPoint: park, contentArea: content),
            initialState: WorkspaceState(tabs: [tab], activeTabID: tab.id))
        driver.add(11, frame: CGRect(x: 0, y: 0, width: 640, height: 480), delay: 0.08)

        let binding = Task { try await engine.bind(managed.id, windowID: 11, pid: 110) }
        try await withDeadline {
            while driver.callCount("setFrame:11") == 0 {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
        driver.setFullscreen(11)
        driver.moveExternally(11, to: fullscreenRect)
        try await binding.value

        let expected = CGRect(x: 1_120, y: 520, width: 800, height: 600)
        #expect(engine.state.managedWindow(id: managed.id)?.window.frame == expected)
        #expect(engine.fullscreenWindowIDs.contains(managed.id))
        #expect(driver.currentFrame(11) == fullscreenRect)
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

    /// reconcile の次回 tick より先に終了しても、フルスクリーン寸法を保存値へ採用しない。
    @Test func shutdownBeforeReconcileDoesNotAdoptFullscreenFrame() async throws {
        let (engine, driver) = makeEngine()
        _ = engine.createTab(name: "A")
        let inactive = engine.createTab(name: "B")
        let recorded = CGRect(x: 300, y: 100, width: 500, height: 400)
        driver.add(1, frame: recorded)
        let managed = try await engine.register(
            windowID: 1, pid: 100, identity: identity("b"), frame: recorded, into: inactive.id)
        #expect(engine.parkedWindowIDs.contains(managed.id))

        // fullscreen 集合を更新する reconcile より先に終了する。
        driver.setFullscreen(1)
        driver.moveExternally(1, to: fullscreenRect)
        let writesBefore = driver.callCount("setFrame") + driver.callCount("setPosition")
        await engine.releaseAllParkedWindows()

        #expect(engine.state.managedWindow(id: managed.id)?.window.frame == recorded)
        #expect(driver.currentFrame(1) == fullscreenRect)
        #expect(driver.callCount("setFrame") + driver.callCount("setPosition") == writesBefore,
            "終了処理は未検出のフルスクリーン窓にも書き込まない")
    }

    /// release直前の属性読取りが失敗しても、既知fullscreenの前回判定を維持して触らない。
    @Test func shutdownKeepsKnownFullscreenWhenProbeIsUnreadable() async throws {
        let (engine, driver) = makeEngine()
        _ = engine.createTab(name: "A")
        let inactive = engine.createTab(name: "B")
        let recorded = CGRect(x: 300, y: 100, width: 500, height: 400)
        driver.add(1, frame: recorded)
        let managed = try await engine.register(
            windowID: 1, pid: 100, identity: identity("b"), frame: recorded, into: inactive.id)
        driver.setFullscreen(1)
        driver.moveExternally(1, to: fullscreenRect)
        await engine.reconcile(liveWindowIDs: [1], livePIDs: [100])
        driver.setFullscreenReadFails(1)
        let writesBefore = driver.callCount("setFrame") + driver.callCount("setPosition")

        await engine.releaseAllParkedWindows()

        #expect(engine.state.managedWindow(id: managed.id)?.window.frame == recorded)
        #expect(driver.currentFrame(1) == fullscreenRect)
        #expect(driver.callCount("setFrame") + driver.callCount("setPosition") == writesBefore)
        #expect(!engine.parkedWindowIDs.contains(managed.id))
    }

    /// 復元不要な表示中の窓はfullscreen preflight対象にせず、終了期限を消費しない。
    @Test func shutdownDoesNotProbeUnchangedActiveWindows() async throws {
        let (engine, driver) = makeEngine()
        let tab = engine.createTab(name: "A")
        let recorded = CGRect(x: 300, y: 100, width: 500, height: 400)
        driver.add(1, frame: recorded)
        try await engine.register(
            windowID: 1, pid: 100, identity: identity("a"), frame: recorded, into: tab.id)
        let probesBefore = driver.callCount("isFullscreen:1")

        await engine.releaseAllParkedWindows()

        #expect(driver.callCount("isFullscreen:1") == probesBefore)
        #expect(driver.currentFrame(1) == recorded)
    }

    /// 同一アプリに復元候補が複数あっても、全窓のpreflight待ちで最初の復元を遅らせない。
    @Test func shutdownInterleavesFullscreenProbeAndRestorePerPID() async throws {
        let (engine, driver) = makeEngine()
        _ = engine.createTab(name: "A")
        let inactive = engine.createTab(name: "B")
        let first = CGRect(x: 300, y: 100, width: 500, height: 400)
        let second = CGRect(x: 900, y: 200, width: 500, height: 400)
        driver.add(1, frame: first)
        driver.add(2, frame: second)
        try await engine.register(
            windowID: 1, pid: 100, identity: identity("one"), frame: first, into: inactive.id)
        try await engine.register(
            windowID: 2, pid: 100, identity: identity("two"), frame: second, into: inactive.id)
        let callsBefore = driver.totalCallCount()

        await engine.releaseAllParkedWindows()

        let releaseCalls = Array(driver.callLog().dropFirst(callsBefore))
        let firstRestore = try #require(releaseCalls.firstIndex(of: "setFrame:1"))
        let secondProbe = try #require(releaseCalls.firstIndex(of: "isFullscreen:2"))
        #expect(firstRestore < secondProbe, "probe→restoreを窓ごとに進める")
        #expect(driver.currentFrame(1) == first)
        #expect(driver.currentFrame(2) == second)
    }

    /// 古い実窓の観測結果を、同じ managed ID に再紐付けされた新しい実窓へ適用しない。
    @Test func staleReconcileObservationDoesNotAffectReboundWindow() async throws {
        let (engine, driver) = makeEngine()
        _ = engine.createTab(name: "A")
        let inactive = engine.createTab(name: "B")
        let recorded = CGRect(x: 300, y: 100, width: 500, height: 400)
        let staleFrame = CGRect(x: 700, y: 300, width: 500, height: 400)
        driver.add(1, frame: recorded, delay: 0.08)
        let managed = try await engine.register(
            windowID: 1, pid: 100, identity: identity("old"), frame: recorded, into: inactive.id)
        driver.setFullscreen(1)
        driver.moveExternally(1, to: staleFrame)

        // frame + fullscreen の遅い読み取り中に、同じ entry を別の通常窓へ再紐付けする。
        let readsBefore = driver.callCount("frame:1")
        let reconciliation = Task {
            await engine.reconcile(liveWindowIDs: [1], livePIDs: [100, 200])
        }
        try await withDeadline {
            while driver.callCount("frame:1") == readsBefore {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
        engine.unbindWindows(pid: 100)
        driver.add(2, frame: recorded)
        try await engine.bind(managed.id, windowID: 2, pid: 200)
        let parksAfterBind = driver.callCount("setPosition:2")
        await reconciliation.value

        #expect(engine.state.managedWindow(id: managed.id)?.window.windowID == 2)
        #expect(!engine.fullscreenWindowIDs.contains(managed.id),
            "旧窓の fullscreen=true を新しい binding へ持ち越さない")
        #expect(driver.callCount("setPosition:2") == parksAfterBind,
            "旧窓の frame を新しい binding の退避ずれ判定に使わない")
    }

    /// destroyed で binding を外した時点で、binding 固有の runtime 状態も破棄する。
    @Test func vanishedWindowClearsFullscreenAndRestoreTracking() async throws {
        let (engine, driver) = makeEngine(debounceMs: 500)
        let tab = engine.createTab(name: "A")
        let recorded = CGRect(x: 300, y: 100, width: 500, height: 400)
        driver.add(1, frame: recorded)
        let managed = try await engine.register(
            windowID: 1, pid: 100, identity: identity("a"), frame: recorded, into: tab.id)
        engine.windowFrameDidChange(windowID: 1)  // restoreGeneration を作る
        driver.setFullscreen(1)
        driver.moveExternally(1, to: fullscreenRect)
        await engine.reconcile(liveWindowIDs: [1], livePIDs: [100])
        #expect(engine.fullscreenWindowIDs.contains(managed.id))
        #expect(engine.restoreGenerationCountForTesting > 0)

        engine.noteWindowDestroyed(windowID: 1)

        #expect(engine.state.managedWindow(id: managed.id)?.window.isBound == false)
        #expect(!engine.fullscreenWindowIDs.contains(managed.id))
        #expect(engine.restoreGenerationCountForTesting == 0)
    }

    /// タブを丸ごと削除する経路も、窓ごとの runtime 状態を残さない。
    @Test func deletingTabClearsFullscreenAndRestoreTracking() async throws {
        let (engine, driver) = makeEngine(debounceMs: 500)
        _ = engine.createTab(name: "A")
        let doomed = engine.createTab(name: "B")
        let recorded = CGRect(x: 300, y: 100, width: 500, height: 400)
        driver.add(1, frame: recorded)
        let managed = try await engine.register(
            windowID: 1, pid: 100, identity: identity("b"), frame: recorded, into: doomed.id)
        driver.setFullscreen(1)
        driver.moveExternally(1, to: fullscreenRect)
        await engine.reconcile(liveWindowIDs: [1], livePIDs: [100])
        #expect(engine.fullscreenWindowIDs.contains(managed.id))

        _ = try await engine.deleteTab(doomed.id)

        #expect(engine.state.managedWindow(id: managed.id) == nil)
        #expect(!engine.fullscreenWindowIDs.contains(managed.id))
        #expect(engine.restoreGenerationCountForTesting == 0)
    }
}
