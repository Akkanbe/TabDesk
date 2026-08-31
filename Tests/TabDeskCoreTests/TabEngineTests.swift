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

private func approx(_ a: CGRect, _ b: CGRect) -> Bool {
    ScreenGeometry.approximatelyEqual(a, b)
}

@MainActor
struct TabCRUDTests {
    @Test func createTabActivatesFirstOnly() {
        let (engine, _) = makeEngine()
        let a = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        #expect(engine.state.activeTabID == a.id)
        #expect(engine.state.tabs.map(\.id) == [a.id, b.id])
    }

    @Test func renameAndMove() throws {
        let (engine, _) = makeEngine()
        let a = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        try engine.renameTab(b.id, to: "Work")
        try engine.moveTab(fromIndex: 1, toIndex: 0)
        #expect(engine.state.tabs.map(\.name) == ["Work", "A"])
        #expect(throws: TabEngine.EngineError.self) { try engine.renameTab(UUID(), to: "x") }
        #expect(throws: TabEngine.EngineError.self) { try engine.moveTab(fromIndex: 5, toIndex: 0) }
        _ = a
    }

    @Test func deleteInactiveTabRestoresParkedWindows() async throws {
        let (engine, driver) = makeEngine()
        let a = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(1, frame: CGRect(x: 10, y: 10, width: 500, height: 400))
        let frame = CGRect(x: 300, y: 40, width: 600, height: 500)
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("x"), frame: frame, into: b.id)
        #expect(engine.parkedWindowIDs.contains(managed.id))
        #expect(driver.currentFrame(1)?.origin == park)

        let removedWindowIDs = try await engine.deleteTab(b.id)
        #expect(removedWindowIDs == [1], "caller receives the AX resources to forget")
        #expect(engine.state.tabs.map(\.id) == [a.id])
        #expect(engine.parkedWindowIDs.isEmpty)
        // 画面隅に取り残さず、記録していた frame へ戻す
        #expect(driver.currentFrame(1) == frame)
    }

    @Test func deleteActiveTabActivatesNext() async throws {
        let (engine, driver) = makeEngine()
        let a = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(1, frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        driver.add(2, frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: content, into: a.id)
        let wb = try await engine.register(windowID: 2, pid: 200, identity: identity("b"), frame: content, into: b.id)
        #expect(engine.parkedWindowIDs.contains(wb.id))

        try await engine.deleteTab(a.id)
        #expect(engine.state.activeTabID == b.id)
        #expect(engine.parkedWindowIDs.isEmpty)
        #expect(driver.currentFrame(2) == content)
        // A のウィンドウは解放されて自由なまま(位置は触らない)
        #expect(driver.currentFrame(1) == content)
    }
}

@MainActor
struct RegistrationTests {
    @Test func registerIntoActiveTabAppliesAndAdoptsActualFrame() async throws {
        let (engine, driver) = makeEngine()
        let a = engine.createTab(name: "A")
        driver.add(1, frame: CGRect(x: 0, y: 0, width: 100, height: 100), minSize: CGSize(width: 940, height: 0))
        let requested = CGRect(x: 240, y: 30, width: 840, height: 1090)
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("docker"), frame: requested, into: a.id)
        // 最小幅 940 にクランプされた到達 frame が基準になる
        #expect(managed.frame == CGRect(x: 240, y: 30, width: 940, height: 1090))
        #expect(engine.state.tabs[0].windows.first?.frame == managed.frame)
        #expect(!engine.parkedWindowIDs.contains(managed.id))
    }

    @Test func duplicateRegistrationIsRejected() async throws {
        let (engine, driver) = makeEngine()
        let a = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(1, frame: content)
        try await engine.register(windowID: 1, pid: 100, identity: identity("x"), frame: content, into: a.id)
        await #expect(throws: TabEngine.EngineError.self) {
            try await engine.register(windowID: 1, pid: 100, identity: identity("x"), frame: content, into: b.id)
        }
    }

    @Test func unregisterParkedWindowRestoresIt() async throws {
        let (engine, driver) = makeEngine()
        _ = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(1, frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        let frame = CGRect(x: 400, y: 50, width: 700, height: 500)
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("x"), frame: frame, into: b.id)
        let removedWindowID = try await engine.unregister(managed.id)
        #expect(removedWindowID == 1, "caller receives the AX resource to forget")
        #expect(engine.state.allWindows.isEmpty)
        #expect(driver.currentFrame(1) == frame)
    }

    @Test func destroyedWindowIsRemovedAfterGraceWhenAppStaysAlive() async throws {
        let (engine, driver) = makeEngine()
        engine.vanishGracePeriod = .milliseconds(40)
        let a = engine.createTab(name: "A")
        driver.add(1, frame: content)
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("x"), frame: content, into: a.id)
        engine.noteWindowFocused(windowID: 1)
        #expect(engine.state.tabs[0].lastFocusedWindowID == managed.id)
        engine.noteWindowDestroyed(windowID: 1)
        // 即削除ではなく保留(アプリごと終了の途中かもしれないため)。紐付けだけ外れる。
        #expect(engine.state.managedWindow(id: managed.id)?.window.isBound == false)
        try await Task.sleep(for: .milliseconds(70))
        await engine.reconcile(liveWindowIDs: [99], livePIDs: [100])  // アプリは生きている → 本当に閉じられた
        #expect(engine.state.allWindows.isEmpty)
        #expect(engine.state.tabs[0].lastFocusedWindowID == nil)
    }
}

@MainActor
struct SwitchingTests {
    @Test func activateParksOthersAndRestoresMembers() async throws {
        let (engine, driver) = makeEngine()
        let a = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(1, frame: content)
        driver.add(2, frame: content)
        let left = CGRect(x: 240, y: 30, width: 840, height: 1090)
        let right = CGRect(x: 1080, y: 30, width: 840, height: 1090)
        let wa = try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: left, into: a.id)
        let wb = try await engine.register(windowID: 2, pid: 200, identity: identity("b"), frame: right, into: b.id)
        #expect(driver.currentFrame(2)?.origin == park)

        var focusedPID: pid_t?
        engine.activateApplication = { focusedPID = $0 }
        let report = try await engine.activate(b.id)
        #expect(report.operationCount == 2)
        #expect(report.failures.isEmpty)
        #expect(engine.state.activeTabID == b.id)
        #expect(engine.parkedWindowIDs == [wa.id])
        #expect(driver.currentFrame(1)?.origin == park)
        #expect(driver.currentFrame(2) == right)
        #expect(driver.callCount("raise:2") == 1)
        #expect(focusedPID == 200)

        try await engine.activate(a.id)
        #expect(engine.parkedWindowIDs == [wb.id])
        #expect(driver.currentFrame(1) == left)
    }

    @Test func failedOperationDoesNotAdvanceState() async throws {
        let (engine, driver) = makeEngine()
        let a = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(1, frame: content)
        driver.add(2, frame: content)
        let wa = try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: content, into: a.id)
        try await engine.register(windowID: 2, pid: 200, identity: identity("b"), frame: content, into: b.id)

        driver.kill(1)
        let report = try await engine.activate(b.id)
        #expect(report.failures.map(\.managedID) == [wa.id])
        // 退避に失敗したので「退避済み」にはしない → 次の切替で再試行される
        #expect(!engine.parkedWindowIDs.contains(wa.id))
        #expect(engine.state.activeTabID == b.id)

        await engine.reconcile(liveWindowIDs: [2])
        #expect(engine.state.allWindows.map(\.windowID) == [2])
    }

    @Test func operationsRunInParallelAcrossPIDs() async throws {
        let (engine, driver) = makeEngine()
        let a = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        // 3 つの別アプリがそれぞれ 150ms かかる。直列なら 450ms 以上、並列なら 300ms 未満で終わる。
        for id: CGWindowID in [1, 2, 3] {
            driver.add(id, frame: content, delay: 0.15)
        }
        driver.add(9, frame: content)
        for id: CGWindowID in [1, 2, 3] {
            try await engine.register(windowID: id, pid: pid_t(id * 100), identity: identity("app\(id)"), frame: content, into: a.id)
        }
        try await engine.register(windowID: 9, pid: 900, identity: identity("b"), frame: content, into: b.id)

        let report = try await engine.activate(b.id)
        #expect(report.operationCount == 4)
        #expect(report.durationMs < 300, "parallel switch took \(report.durationMs) ms")
        #expect(driver.maxConcurrent >= 2)
    }
}

@MainActor
struct SnapBackTests {
    @Test func restoresOnceAfterQuietPeriod() async throws {
        let (engine, driver) = makeEngine(debounceMs: 20)
        let a = engine.createTab(name: "A")
        driver.add(1, frame: content)
        let frame = CGRect(x: 240, y: 30, width: 840, height: 1090)
        try await engine.register(windowID: 1, pid: 100, identity: identity("x"), frame: frame, into: a.id)
        let setFramesBefore = driver.callCount("setFrame")

        // ドラッグ中の連続通知を模す
        for step in 1...5 {
            driver.moveExternally(1, to: CGRect(x: 240 + step * 20, y: 30, width: 840, height: 1090))
            engine.windowFrameDidChange(windowID: 1)
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(driver.callCount("setFrame") == setFramesBefore, "must not restore while still moving")

        try await Task.sleep(for: .milliseconds(80))
        #expect(driver.currentFrame(1) == frame)
        #expect(driver.callCount("setFrame") == setFramesBefore + 1)
    }

    @Test func adoptsActualFrameAfterRepeatedMismatch() async throws {
        let (engine, driver) = makeEngine(debounceMs: 10)
        let a = engine.createTab(name: "A")
        driver.add(1, frame: content)
        let frame = CGRect(x: 240, y: 30, width: 840, height: 1090)
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("x"), frame: frame, into: a.id)

        // 登録後にアプリ側の最小幅が 1000 に変わり、基準 frame に戻せなくなったとする
        driver.setMinSize(CGSize(width: 1000, height: 0), of: 1)
        driver.moveExternally(1, to: CGRect(x: 240, y: 30, width: 1000, height: 1090))
        let before = driver.callCount("setFrame")
        engine.windowFrameDidChange(windowID: 1)
        try await Task.sleep(for: .milliseconds(150))

        #expect(driver.callCount("setFrame") == before + 3, "3 attempts then adopt")
        let adopted = engine.state.managedWindow(id: managed.id)?.window.frame
        #expect(adopted == CGRect(x: 240, y: 30, width: 1000, height: 1090))
    }

    @Test func editModeRecordsInsteadOfRestoring() async throws {
        let (engine, driver) = makeEngine(debounceMs: 10)
        let a = engine.createTab(name: "A")
        driver.add(1, frame: content)
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("x"), frame: content, into: a.id)
        engine.editMode = true
        let moved = CGRect(x: 300, y: 100, width: 800, height: 600)
        driver.moveExternally(1, to: moved)
        engine.windowFrameDidChange(windowID: 1)
        try await Task.sleep(for: .milliseconds(60))
        #expect(engine.state.managedWindow(id: managed.id)?.window.frame == moved)
        #expect(driver.currentFrame(1) == moved)
    }

    @Test func ignoresParkedAndInactiveWindows() async throws {
        let (engine, driver) = makeEngine(debounceMs: 10)
        _ = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(2, frame: content)
        try await engine.register(windowID: 2, pid: 200, identity: identity("b"), frame: content, into: b.id)
        let before = driver.callCount("setFrame")
        engine.windowFrameDidChange(windowID: 2)  // 退避中(= 非アクティブタブ)
        try await Task.sleep(for: .milliseconds(50))
        #expect(driver.callCount("setFrame") == before)
    }
}

@MainActor
struct ReconcileTests {
    @Test func reparksDriftedParkedWindow() async throws {
        let (engine, driver) = makeEngine()
        _ = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(2, frame: content)
        try await engine.register(windowID: 2, pid: 200, identity: identity("b"), frame: content, into: b.id)
        #expect(driver.currentFrame(2)?.origin == park)

        // アプリが自分で画面内に出てきてしまった状況
        driver.moveExternally(2, to: CGRect(x: 500, y: 500, width: 800, height: 600))
        await engine.reconcile(liveWindowIDs: [2])
        #expect(driver.currentFrame(2)?.origin == park)
    }
}

struct ModelCodingTests {
    @Test func runtimeBindingIsNotPersisted() throws {
        let window = ManagedWindow(
            frame: CGRect(x: 1, y: 2, width: 3, height: 4), identity: identity("x"), windowID: 42, pid: 7)
        var state = WorkspaceState(tabs: [Tab(name: "A", windows: [window])])
        state.activeTabID = state.tabs[0].id

        let data = try JSONEncoder().encode(state)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("windowID"))
        #expect(!json.contains("\"pid\""))

        let decoded = try JSONDecoder().decode(WorkspaceState.self, from: data)
        #expect(decoded.version == WorkspaceState.currentVersion)
        #expect(decoded.tabs[0].windows[0].id == window.id)
        #expect(decoded.tabs[0].windows[0].frame == window.frame)
        #expect(decoded.tabs[0].windows[0].windowID == nil)
        #expect(decoded.tabs[0].windows[0].isBound == false)
        #expect(decoded.activeTabID == state.activeTabID)
    }
}

@MainActor
struct ConcurrencyTests {
    @Test func rapidActivationsAreSerialized() async throws {
        let (engine, driver) = makeEngine()
        let a = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        let c = engine.createTab(name: "C")
        for id: CGWindowID in [1, 2, 3] {
            driver.add(id, frame: content, delay: 0.03)
        }
        try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: content, into: a.id)
        let wb = try await engine.register(windowID: 2, pid: 200, identity: identity("b"), frame: content, into: b.id)
        let wc = try await engine.register(windowID: 3, pid: 300, identity: identity("c"), frame: content, into: c.id)

        // async let 同士の開始順は未規定。B が実際に serialized 区間へ入り、driver 操作を
        // 始めたことを handshake で確認してから C を投入し、ユーザー操作の B → C を再現する。
        let callsBeforeActivation = driver.totalCallCount()
        let first = Task { try await engine.activate(b.id) }
        try await withDeadline {
            while driver.totalCallCount() == callsBeforeActivation {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
        let second = Task { try await engine.activate(c.id) }
        _ = try await first.value
        _ = try await second.value

        #expect(engine.state.activeTabID == c.id)
        #expect(!engine.parkedWindowIDs.contains(wc.id))
        #expect(engine.parkedWindowIDs.contains(wb.id), "B must be parked again after C was activated")
        #expect(driver.currentFrame(2)?.origin == park)
        #expect(driver.currentFrame(3) == content)
    }

    @Test func concurrentDuplicateRegistrationIsRejected() async throws {
        let (engine, driver) = makeEngine()
        let a = engine.createTab(name: "A")
        driver.add(1, frame: content, delay: 0.02)
        async let r1: ManagedWindow? = try? engine.register(windowID: 1, pid: 100, identity: identity("x"), frame: content, into: a.id)
        async let r2: ManagedWindow? = try? engine.register(windowID: 1, pid: 100, identity: identity("x"), frame: content, into: a.id)
        let results = await [r1, r2]
        #expect(results.compactMap { $0 }.count == 1)
        #expect(engine.state.allWindows.count == 1)
    }

    @Test func windowDestroyedDuringActivationLeavesNoStaleFlag() async throws {
        let (engine, driver) = makeEngine()
        let a = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(1, frame: content, delay: 0.08)
        driver.add(2, frame: content)
        let wa = try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: content, into: a.id)
        try await engine.register(windowID: 2, pid: 200, identity: identity("b"), frame: content, into: b.id)

        let activation = Task { try await engine.activate(b.id) }
        try await Task.sleep(for: .milliseconds(20))
        engine.noteWindowDestroyed(windowID: 1)  // 退避中に閉じられた → 消滅保留(紐付けは外れる)
        _ = try await activation.value

        #expect(engine.state.managedWindow(id: wa.id)?.window.isBound == false, "kept as pending-vanished")
        #expect(!engine.parkedWindowIDs.contains(wa.id), "no parked flag on an unbound entry")
        #expect(engine.state.allWindows.compactMap(\.windowID) == [2])
    }

    @Test func parksBeforeRestoresWithinSamePID() async throws {
        let (engine, driver) = makeEngine()
        let a = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(1, frame: content)
        driver.add(2, frame: content)
        // 同じアプリ(pid 100)の 2 枚を別タブに
        try await engine.register(windowID: 1, pid: 100, identity: identity("app"), frame: content, into: a.id)
        try await engine.register(windowID: 2, pid: 100, identity: identity("app"), frame: content, into: b.id)
        try await engine.activate(b.id)
        let calls = driver.calls
        let parkIndex = calls.lastIndex(of: "setPosition:1")
        let restoreIndex = calls.lastIndex(of: "setFrame:2")
        #expect(parkIndex != nil && restoreIndex != nil && parkIndex! < restoreIndex!)
        _ = a
    }
}

@MainActor
struct ReconcileHeuristicTests {
    @Test func clampedParkedWindowIsNotReparked() async throws {
        let (engine, driver) = makeEngine()
        _ = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(2, frame: content)
        try await engine.register(windowID: 2, pid: 200, identity: identity("b"), frame: content, into: b.id)
        // 実機では OS が y をクランプする(要求 1199 → 実際 1067)。これは「隅にいる」とみなす。
        driver.moveExternally(2, to: CGRect(x: 1919, y: 1067, width: 1680, height: 1090))
        let before = driver.callCount("setPosition")
        await engine.reconcile(liveWindowIDs: [2])
        #expect(driver.callCount("setPosition") == before)
    }
}

/// デッドロックしたらテストが永久に止まるので、期限付きで待つ。
func withDeadline<T: Sendable>(_ ms: Int = 1000, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: .milliseconds(ms))
            throw DeadlineExceeded()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
struct DeadlineExceeded: Error {}

@MainActor
struct ReviewFollowUpTests {
    @Test func activatingActiveTabDoesNotTouchItsWindows() async throws {
        let (engine, driver) = makeEngine()
        let a = engine.createTab(name: "A")
        driver.add(1, frame: content)
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("x"), frame: content, into: a.id)
        // ユーザーがドラッグ中(一時的な位置)
        let transient = CGRect(x: 500, y: 300, width: 1680, height: 1090)
        driver.moveExternally(1, to: transient)
        let before = driver.callCount("setFrame")
        let report = try await engine.activate(a.id)
        #expect(report.operationCount == 0)
        #expect(driver.callCount("setFrame") == before)
        #expect(engine.state.managedWindow(id: managed.id)?.window.frame == content, "must not adopt transient frame")
    }

    @Test func registerIntoInactiveTabIsNormalizedOnFirstActivation() async throws {
        let (engine, driver) = makeEngine()
        _ = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(2, frame: content, minSize: CGSize(width: 940, height: 0))
        let requested = CGRect(x: 240, y: 30, width: 840, height: 1090)
        let managed = try await engine.register(windowID: 2, pid: 200, identity: identity("docker"), frame: requested, into: b.id)
        #expect(engine.state.managedWindow(id: managed.id)?.window.frame == requested, "recorded as requested until activated")
        try await engine.activate(b.id)
        #expect(engine.state.managedWindow(id: managed.id)?.window.frame == CGRect(x: 240, y: 30, width: 940, height: 1090))
    }

    @Test func ownRestoreNotificationDoesNotTriggerExtraSetFrame() async throws {
        let (engine, driver) = makeEngine(debounceMs: 10)
        let a = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(1, frame: content)
        driver.add(2, frame: content)
        try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: content, into: a.id)
        try await engine.register(windowID: 2, pid: 200, identity: identity("b"), frame: content, into: b.id)
        try await engine.activate(b.id)
        let before = driver.callCount("setFrame")
        // 復元操作が発火させた通知(既にあるべき位置にいる)
        engine.windowFrameDidChange(windowID: 2)
        try await Task.sleep(for: .milliseconds(50))
        #expect(driver.callCount("setFrame") == before)
    }

    @Test func lockIsReleasedAfterThrowingOperation() async throws {
        let (engine, driver) = makeEngine()
        let a = engine.createTab(name: "A")
        driver.add(1, frame: content)
        await #expect(throws: TabEngine.EngineError.self) {
            try await engine.register(windowID: 1, pid: 100, identity: identity("x"), frame: content, into: UUID())
        }
        // ロックが漏れていればここで永久に待つ
        let report = try await withDeadline { try await engine.activate(a.id) }
        #expect(report.tabID == a.id)
    }

    @Test func setFrameAppliesWhenVisibleAndRecordsWhenParked() async throws {
        let (engine, driver) = makeEngine()
        let a = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(1, frame: content, minSize: CGSize(width: 500, height: 0))
        driver.add(2, frame: content)
        let wa = try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: content, into: a.id)
        let wb = try await engine.register(windowID: 2, pid: 200, identity: identity("b"), frame: content, into: b.id)

        let narrow = CGRect(x: 240, y: 30, width: 300, height: 500)
        let actual = try await engine.setFrame(narrow, of: wa.id)
        #expect(actual.width == 500, "visible window: applied and clamped by the app")
        #expect(engine.state.managedWindow(id: wa.id)?.window.frame == actual)

        let before = driver.callCount("setFrame")
        let recorded = try await engine.setFrame(narrow, of: wb.id)
        #expect(recorded == narrow, "parked window: recorded only")
        #expect(driver.callCount("setFrame") == before)
        #expect(driver.currentFrame(2)?.origin == park)
    }

    @Test func moveTabDuringRegisterStillTargetsRequestedTab() async throws {
        let (engine, driver) = makeEngine()
        let a = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(1, frame: content, delay: 0.05)
        let registration = Task { try await engine.register(windowID: 1, pid: 100, identity: identity("x"), frame: content, into: a.id) }
        try await Task.sleep(for: .milliseconds(10))
        try engine.moveTab(fromIndex: 0, toIndex: 1)  // A を後ろへ
        let managed = try await registration.value
        #expect(engine.state.managedWindow(id: managed.id)?.tab.id == a.id)
        #expect(engine.state.tabs.map(\.id) == [b.id, a.id])
    }

    @Test func moveTabDuringDeleteStillDeletesRequestedTab() async throws {
        let (engine, driver) = makeEngine()
        let a = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        let c = engine.createTab(name: "C")
        driver.add(2, frame: content, delay: 0.05)
        try await engine.register(windowID: 2, pid: 200, identity: identity("b"), frame: content, into: b.id)
        let deletion = Task { try await engine.deleteTab(b.id) }
        try await Task.sleep(for: .milliseconds(10))
        try engine.moveTab(fromIndex: 2, toIndex: 0)  // C を先頭へ
        _ = try await deletion.value
        #expect(engine.state.tabs.map(\.id) == [c.id, a.id])
    }

    @Test func raiseFailureDoesNotCountAsRestoreFailure() async throws {
        let (engine, driver) = makeEngine()
        _ = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(2, frame: content)
        driver.setRaiseFails(2)
        let wb = try await engine.register(windowID: 2, pid: 200, identity: identity("b"), frame: content, into: b.id)
        let report = try await engine.activate(b.id)
        #expect(report.failures.isEmpty)
        #expect(!engine.parkedWindowIDs.contains(wb.id))
        #expect(driver.currentFrame(2) == content)
    }

    @Test func reconcileRestoresActiveWindowStillFlaggedParked() async throws {
        let (engine, driver) = makeEngine()
        let a = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(1, frame: content)
        driver.add(2, frame: content)
        let wa = try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: content, into: a.id)
        try await engine.register(windowID: 2, pid: 200, identity: identity("b"), frame: content, into: b.id)
        try await engine.activate(b.id)
        driver.kill(1)
        let report = try await engine.activate(a.id)  // A の復元が失敗 → フラグは退避のまま
        #expect(report.failures.count == 1)
        #expect(engine.parkedWindowIDs.contains(wa.id))

        driver.revive(1)
        await engine.reconcile(liveWindowIDs: [1, 2])
        #expect(!engine.parkedWindowIDs.contains(wa.id))
        #expect(driver.currentFrame(1) == content)
    }

    @Test func reconcileParksInactiveWindowWhoseParkFailed() async throws {
        let (engine, driver) = makeEngine()
        let a = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(1, frame: content)
        driver.add(2, frame: content)
        let wa = try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: content, into: a.id)
        try await engine.register(windowID: 2, pid: 200, identity: identity("b"), frame: content, into: b.id)
        driver.kill(1)
        try await engine.activate(b.id)  // A の退避が失敗
        #expect(!engine.parkedWindowIDs.contains(wa.id))
        driver.revive(1)
        await engine.reconcile(liveWindowIDs: [1, 2])
        #expect(engine.parkedWindowIDs.contains(wa.id))
        #expect(driver.currentFrame(1)?.origin == park)
    }

    @Test func reconcileWithEmptyLiveSetRemovesNothing() async throws {
        let (engine, driver) = makeEngine()
        let a = engine.createTab(name: "A")
        driver.add(1, frame: content)
        try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: content, into: a.id)
        await engine.reconcile(liveWindowIDs: [])
        #expect(engine.state.allWindows.count == 1)
    }

    @Test func reconcileDoesNotBlockActivationWhileReadingSlowApp() async throws {
        let (engine, driver) = makeEngine()
        let a = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        let slow = engine.createTab(name: "Slow")
        driver.add(1, frame: content)
        driver.add(2, frame: content)
        driver.add(3, frame: content, delay: 0.3)  // 退避中の遅いアプリ
        try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: content, into: a.id)
        try await engine.register(windowID: 2, pid: 200, identity: identity("b"), frame: content, into: b.id)
        try await engine.register(windowID: 3, pid: 300, identity: identity("slow"), frame: content, into: slow.id)

        let reconcile = Task { await engine.reconcile(liveWindowIDs: [1, 2, 3]) }
        try await Task.sleep(for: .milliseconds(20))
        let sw = Stopwatch()
        try await engine.activate(b.id)
        #expect(sw.elapsedMs < 150, "activate waited \(sw.elapsedMs) ms behind reconcile's IPC")
        await reconcile.value
    }

    @Test func releaseRestoresWindowParkedButMarkedFailed() async throws {
        let (engine, driver) = makeEngine()
        let a = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(1, frame: content)
        driver.add(2, frame: content)
        let wa = try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: content, into: a.id)
        try await engine.register(windowID: 2, pid: 200, identity: identity("b"), frame: content, into: b.id)
        driver.setThrowAfterApply(1)  // 退避は適用されるがタイムアウト扱い
        let report = try await engine.activate(b.id)
        // 読み戻しで隅への到達を確認できるので、失敗扱いにせずフラグを実位置に合わせる。
        #expect(report.failures.isEmpty)
        #expect(engine.parkedWindowIDs.contains(wa.id))
        #expect(driver.currentFrame(1)?.origin == park, "actually parked despite the error")

        driver.setThrowAfterApply(1, false)
        try await engine.unregister(wa.id)
        #expect(driver.currentFrame(1) == content, "must not be left in the corner")
    }
}

@MainActor
struct TerminationTests {
    @Test func releaseAllParkedWindowsRestoresFramesWithoutChangingState() async throws {
        let (engine, driver) = makeEngine()
        let a = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(1, frame: content)
        driver.add(2, frame: content)
        let left = CGRect(x: 240, y: 30, width: 840, height: 1090)
        try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: content, into: a.id)
        let wb = try await engine.register(windowID: 2, pid: 200, identity: identity("b"), frame: left, into: b.id)
        #expect(driver.currentFrame(2)?.origin == park)

        await engine.releaseAllParkedWindows()
        #expect(driver.currentFrame(2) == left, "parked window returned to its frame")
        #expect(driver.currentFrame(1) == content, "visible window untouched")
        #expect(engine.state.tabs.count == 2 && engine.state.activeTabID == a.id)
        #expect(engine.state.managedWindow(id: wb.id) != nil, "registration kept")
        #expect(!engine.parkedWindowIDs.contains(wb.id))
    }
}

@MainActor
struct ContentAreaClampTests {
    @Test func registerAndSetFrameStayOutOfSidebarArea() async throws {
        let (engine, driver) = makeEngine()
        let a = engine.createTab(name: "A")
        driver.add(1, frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let underSidebar = CGRect(x: 40, y: 10, width: 800, height: 600)
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("x"), frame: underSidebar, into: a.id)
        #expect(managed.frame.origin == content.origin, "pulled to the content area origin")
        #expect(driver.currentFrame(1)?.origin == content.origin)

        let actual = try await engine.setFrame(CGRect(x: 100, y: 500, width: 800, height: 600), of: managed.id)
        #expect(actual.minX == content.minX)
        #expect(actual.minY == 500)
    }

    @Test func editModeClampsRecordedFrameAndMovesWindow() async throws {
        let (engine, driver) = makeEngine(debounceMs: 10)
        let a = engine.createTab(name: "A")
        driver.add(1, frame: content)
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("x"), frame: content, into: a.id)
        engine.editMode = true
        driver.moveExternally(1, to: CGRect(x: 50, y: 100, width: 800, height: 600))
        engine.windowFrameDidChange(windowID: 1)
        try await Task.sleep(for: .milliseconds(60))
        let expected = CGRect(x: content.minX, y: 100, width: 800, height: 600)
        #expect(engine.state.managedWindow(id: managed.id)?.window.frame == expected)
        #expect(driver.currentFrame(1) == expected, "window nudged out of the sidebar area")
    }

    @Test func oversizedWindowAlignsToContentOrigin() async throws {
        let (engine, driver) = makeEngine()
        let a = engine.createTab(name: "A")
        driver.add(1, frame: CGRect(x: -500, y: -200, width: 2000, height: 1500))
        let managed = try await engine.register(
            windowID: 1, pid: 100, identity: identity("big"), frame: CGRect(x: -500, y: -200, width: 2000, height: 1500), into: a.id)
        #expect(managed.frame.origin == content.origin)
        #expect(managed.frame.size == CGSize(width: 2000, height: 1500), "size is not changed by clamping")
    }
}

@MainActor
struct FlushTests {
    @Test func flushRestoresImmediatelyWithoutWaitingForDebounce() async throws {
        let (engine, driver) = makeEngine(debounceMs: 2000)
        let a = engine.createTab(name: "A")
        driver.add(1, frame: content)
        try await engine.register(windowID: 1, pid: 100, identity: identity("x"), frame: content, into: a.id)
        driver.moveExternally(1, to: CGRect(x: 500, y: 300, width: 1680, height: 1090))
        engine.windowFrameDidChange(windowID: 1)
        engine.flushPendingRestores()  // マウスアップ相当
        try await Task.sleep(for: .milliseconds(50))
        #expect(driver.currentFrame(1) == content)
    }
}

@MainActor
struct PersistenceTests {
    @Test func stateStoreRoundTripAndBackup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tabdesk-test-\(UUID().uuidString)")
        let store = StateStore(fileURL: dir.appendingPathComponent("state.json"))
        #expect(try store.load() == nil)

        var state = WorkspaceState(tabs: [Tab(name: "A", windows: [
            ManagedWindow(frame: content, identity: identity("x"), windowID: 42, pid: 7),
        ])])
        state.activeTabID = state.tabs[0].id
        try store.save(state)
        let loaded = try store.load()
        #expect(loaded?.tabs[0].name == "A")
        #expect(loaded?.tabs[0].windows[0].isBound == false, "runtime binding is not persisted")
        #expect(loaded?.activeTabID == state.activeTabID)

        try store.backupCorruptFile()
        #expect(try store.load() == nil)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("state.bak.json").path))
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func bindAttachesWindowToUnboundEntry() async throws {
        let (engine, driver) = makeEngine()
        let a = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(1, frame: content)
        driver.add(2, frame: content)
        let wa = try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: content, into: a.id)
        let wb = try await engine.register(windowID: 2, pid: 200, identity: identity("b"), frame: content, into: b.id)

        // アプリ終了 → 未復元として保持
        engine.unbindWindows(pid: 100)
        engine.noteWindowDestroyed(windowID: 2, appTerminated: true)
        #expect(engine.state.allWindows.count == 2)
        #expect(engine.state.allWindows.allSatisfy { !$0.isBound })
        #expect(engine.parkedWindowIDs.isEmpty)

        // 再起動したアプリの新しい窓を紐付け
        driver.add(11, frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        driver.add(12, frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        try await engine.bind(wa.id, windowID: 11, pid: 110, title: "new title")
        try await engine.bind(wb.id, windowID: 12, pid: 120)
        #expect(driver.currentFrame(11) == content, "active tab: frame applied")
        #expect(driver.currentFrame(12)?.origin == park, "inactive tab: parked")
        #expect(engine.parkedWindowIDs == [wb.id])
        #expect(engine.state.managedWindow(id: wa.id)?.window.identity.title == "new title")
        #expect(engine.state.managedWindow(forWindowID: 12)?.window.id == wb.id)

        await #expect(throws: TabEngine.EngineError.self) {
            try await engine.bind(wa.id, windowID: 12, pid: 120)  // 他のエントリに紐付いている窓
        }
    }

    @Test func reconcileUnbindsWhenAppIsGoneButRemovesWhenWindowClosed() async throws {
        let (engine, driver) = makeEngine()
        engine.vanishGracePeriod = .milliseconds(40)
        let a = engine.createTab(name: "A")
        driver.add(1, frame: content)
        driver.add(2, frame: content)
        let w1 = try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: content, into: a.id)
        let w2 = try await engine.register(windowID: 2, pid: 200, identity: identity("b"), frame: content, into: a.id)
        await engine.reconcile(liveWindowIDs: [], livePIDs: [100])  // 空集合 = 列挙失敗 → 何もしない
        #expect(engine.state.allWindows.count == 2)
        await engine.reconcile(liveWindowIDs: [3], livePIDs: [100])  // 1 は閉じられた、2 のアプリは終了
        let pendingClose = engine.state.managedWindow(id: w1.id)?.window
        #expect(pendingClose != nil, "a missing window with a live pid must enter the grace period")
        #expect(pendingClose?.windowID == nil)
        #expect(pendingClose?.pid == 100, "pid is retained until close versus quit is decided")
        let quitWindow = engine.state.managedWindow(id: w2.id)?.window
        #expect(quitWindow?.isBound == false)
        #expect(quitWindow?.pid == nil, "a window whose process is gone is kept fully unbound")

        try await Task.sleep(for: .milliseconds(70))
        await engine.reconcile(liveWindowIDs: [3], livePIDs: [100])
        #expect(engine.state.managedWindow(id: w1.id) == nil, "a standalone close is removed after grace")
        #expect(engine.state.managedWindow(id: w2.id) != nil, "an app-quit entry remains restorable")
    }
}

struct WindowMatcherTests {
    private func entry(_ app: String, title: String, size: CGSize = CGSize(width: 800, height: 600)) -> ManagedWindow {
        ManagedWindow(
            frame: content,
            identity: WindowIdentity(bundleID: "test.\(app)", appName: app, title: title, registeredSize: size),
            windowID: nil, pid: nil)
    }

    private func cand(_ id: CGWindowID, _ app: String, title: String, size: CGSize = CGSize(width: 800, height: 600)) -> WindowMatcher.Candidate {
        WindowMatcher.Candidate(windowID: id, pid: pid_t(id), bundleID: "test.\(app)", title: title, size: size)
    }

    @Test func exactTitleWins() {
        let e1 = entry("safari", title: "GitHub")
        let e2 = entry("safari", title: "Docs")
        let matches = WindowMatcher.match(
            unbound: [e1, e2],
            candidates: [cand(1, "safari", title: "Docs"), cand(2, "safari", title: "GitHub")],
            strictness: .strict)
        #expect(matches.count == 2)
        #expect(matches.first { $0.managedID == e1.id }?.candidate.windowID == 2)
        #expect(matches.first { $0.managedID == e2.id }?.candidate.windowID == 1)
    }

    @Test func uniqueAppMatchesDespiteTitleChangeOnlyWhenLenient() {
        let e = entry("ghostty", title: "~", size: CGSize(width: 1080, height: 1890))
        let c = cand(5, "ghostty", title: "vim main.swift", size: CGSize(width: 1080, height: 1890))
        #expect(WindowMatcher.match(unbound: [e], candidates: [c], strictness: .lenient).count == 1)
        #expect(WindowMatcher.match(unbound: [e], candidates: [c], strictness: .strict).isEmpty)
    }

    @Test func differentBundleNeverMatches() {
        let e = entry("safari", title: "GitHub")
        #expect(WindowMatcher.match(unbound: [e], candidates: [cand(1, "chrome", title: "GitHub")], strictness: .lenient).isEmpty)
    }

    @Test func ambiguousCandidatesAreNotGuessed() {
        // 同じアプリの 2 窓がどちらもタイトル不一致・サイズ不一致 → どちらにも紐付けない
        let e = entry("safari", title: "GitHub")
        let matches = WindowMatcher.match(
            unbound: [e],
            candidates: [cand(1, "safari", title: "Mail", size: CGSize(width: 1, height: 1)), cand(2, "safari", title: "News", size: CGSize(width: 1, height: 1))],
            strictness: .lenient)
        #expect(matches.isEmpty)
    }

    @Test func partialTitleAndSizeReachLenientThreshold() {
        let e = entry("textedit", title: "memo.txt")
        let others = entry("textedit", title: "other.txt")
        let matches = WindowMatcher.match(
            unbound: [e, others],
            candidates: [cand(1, "textedit", title: "memo.txt — 編集済み"), cand(2, "textedit", title: "zzz", size: CGSize(width: 1, height: 1))],
            strictness: .lenient)
        #expect(matches.count == 1)
        #expect(matches[0].managedID == e.id && matches[0].candidate.windowID == 1)
    }
}

@MainActor
struct StrandedWindowInvariantTests {
    @Test func registerIntoInactiveTabDoesNotStrandWindowWhenParkThrowsAfterApply() async throws {
        let (engine, driver) = makeEngine()
        _ = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(1, frame: content)
        driver.setThrowAfterApply(1)
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("x"), frame: content, into: b.id)
        #expect(driver.currentFrame(1)?.origin == park, "park was applied despite the error")
        #expect(engine.state.managedWindow(id: managed.id) != nil, "kept under management so it can be recovered")
        #expect(engine.parkedWindowIDs.contains(managed.id))

        driver.setThrowAfterApply(1, false)
        try await engine.unregister(managed.id)
        #expect(driver.currentFrame(1) == content, "recoverable: unregister restores it")
    }

    @Test func registerIntoInactiveTabFailsCleanlyWhenParkDidNotApply() async throws {
        let (engine, driver) = makeEngine()
        _ = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(1, frame: content)
        driver.setFailWrites(1)
        await #expect(throws: FakeWindowDriver.SimulatedTimeout.self) {
            try await engine.register(windowID: 1, pid: 100, identity: identity("x"), frame: content, into: b.id)
        }
        #expect(driver.currentFrame(1) == content, "window untouched")
        #expect(engine.state.allWindows.isEmpty, "nothing committed")
    }

    @Test func registerIntoActiveTabAdoptsCurrentFrameWhenSetFrameThrowsAfterApply() async throws {
        let (engine, driver) = makeEngine()
        let a = engine.createTab(name: "A")
        driver.add(1, frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        driver.setThrowAfterApply(1)
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("x"), frame: content, into: a.id)
        #expect(managed.frame == content, "actual frame read back after the ambiguous error")
        #expect(!engine.parkedWindowIDs.contains(managed.id))
    }

    @Test func unregisterKeepsRegistrationWhenRestoreFails() async throws {
        let (engine, driver) = makeEngine()
        _ = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(1, frame: content)
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("x"), frame: content, into: b.id)
        driver.setFailWrites(1)  // 無応答アプリ
        await #expect(throws: TabEngine.EngineError.self) { try await engine.unregister(managed.id) }
        #expect(engine.state.managedWindow(id: managed.id) != nil, "registration kept")
        #expect(engine.parkedWindowIDs.contains(managed.id), "still known to be parked")
        #expect(driver.currentFrame(1)?.origin == park)

        driver.setFailWrites(1, false)  // アプリ復帰
        try await engine.unregister(managed.id)
        #expect(engine.state.allWindows.isEmpty)
        #expect(driver.currentFrame(1) == content)
    }

    @Test func unregisterSucceedsWhenRestoreThrowsAfterApply() async throws {
        let (engine, driver) = makeEngine()
        _ = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(1, frame: content)
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("x"), frame: content, into: b.id)
        driver.setThrowAfterApply(1)
        try await engine.unregister(managed.id)  // 読み戻しで到達を確認できるので成功
        #expect(engine.state.allWindows.isEmpty)
        #expect(driver.currentFrame(1) == content)
    }

    @Test func deleteTabIsAbortedWhenAnyWindowCannotBeReleased() async throws {
        let (engine, driver) = makeEngine()
        let a = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(1, frame: content)
        driver.add(2, frame: content)
        let w1 = try await engine.register(windowID: 1, pid: 100, identity: identity("ok"), frame: content, into: b.id)
        let w2 = try await engine.register(windowID: 2, pid: 200, identity: identity("hung"), frame: content, into: b.id)
        driver.setFailWrites(2)
        await #expect(throws: TabEngine.EngineError.self) { try await engine.deleteTab(b.id) }
        #expect(engine.state.tabs.map(\.id) == [a.id, b.id], "tab kept")
        #expect(engine.state.managedWindow(id: w1.id) != nil && engine.state.managedWindow(id: w2.id) != nil)
        #expect(engine.parkedWindowIDs.contains(w2.id), "unreleased window still flagged parked")

        driver.setFailWrites(2, false)
        try await engine.deleteTab(b.id)
        #expect(engine.state.tabs.map(\.id) == [a.id])
        #expect(driver.currentFrame(2) == content)
    }

    @Test func bindIntoInactiveTabCommitsWhenParkThrowsAfterApply() async throws {
        let (engine, driver) = makeEngine()
        _ = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(1, frame: content)
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("x"), frame: content, into: b.id)
        engine.unbindWindows(pid: 100)
        driver.add(5, frame: content)
        driver.setThrowAfterApply(5)
        try await engine.bind(managed.id, windowID: 5, pid: 500)
        #expect(engine.state.managedWindow(id: managed.id)?.window.windowID == 5)
        #expect(engine.parkedWindowIDs.contains(managed.id))
        #expect(driver.currentFrame(5)?.origin == park)
    }
}

@MainActor
struct ShutdownTests {
    private func expectShuttingDown<T>(_ operation: () async throws -> T) async {
        do {
            _ = try await operation()
            Issue.record("expected TabEngine.EngineError.shuttingDown")
        } catch TabEngine.EngineError.shuttingDown {
            // Expected.
        } catch {
            Issue.record("expected shuttingDown, got \(error)")
        }
    }

    @Test func beginShutdownCancelsPendingRestoreAndRejectsWindowMutations() async throws {
        let (engine, driver) = makeEngine(debounceMs: 40)
        let a = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(1, frame: content)
        driver.add(2, frame: content)
        driver.add(3, frame: content)
        driver.add(4, frame: content)
        let active = try await engine.register(windowID: 1, pid: 100, identity: identity("active"), frame: content, into: a.id)
        let unbound = try await engine.register(windowID: 2, pid: 200, identity: identity("unbound"), frame: content, into: b.id)
        engine.unbindWindows(pid: 200)

        let dragged = CGRect(x: 500, y: 300, width: content.width, height: content.height)
        driver.moveExternally(1, to: dragged)
        engine.windowFrameDidChange(windowID: 1)
        let stateBeforeShutdown = engine.state
        let callsBeforeShutdown = driver.calls

        engine.beginShutdown()

        #expect(engine.isReleasingForShutdown)
        await expectShuttingDown {
            try await engine.register(windowID: 3, pid: 300, identity: identity("new"), frame: content, into: a.id)
        }
        await expectShuttingDown { try await engine.bind(unbound.id, windowID: 4, pid: 400) }
        await expectShuttingDown { try await engine.activate(b.id) }
        await expectShuttingDown { try await engine.setFrame(content, of: active.id) }
        await expectShuttingDown { try await engine.unregister(active.id) }
        await expectShuttingDown { try await engine.deleteTab(b.id) }

        try await Task.sleep(for: .milliseconds(80))
        #expect(driver.currentFrame(1) == dragged, "the pending snap-back is cancelled at the shutdown barrier")
        #expect(driver.calls == callsBeforeShutdown, "rejected operations must not touch real windows")
        #expect(engine.state == stateBeforeShutdown, "rejected operations must not mutate workspace state")
    }

    @Test func releaseIsNotUndoneByInFlightReconcile() async throws {
        let (engine, driver) = makeEngine()
        let a = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(1, frame: content)
        driver.add(2, frame: content, delay: 0.1)  // 退避中の遅いアプリ: reconcile の frame 読み取りが IPC 中になる
        try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: content, into: a.id)
        let left = CGRect(x: 240, y: 30, width: 840, height: 1090)
        try await engine.register(windowID: 2, pid: 200, identity: identity("b"), frame: left, into: b.id)
        #expect(driver.currentFrame(2)?.origin == park)

        let reconcile = Task { await engine.reconcile(liveWindowIDs: [1, 2]) }
        try await Task.sleep(for: .milliseconds(20))  // 読み取り中に終了処理が割り込む
        await engine.releaseAllParkedWindows()
        await reconcile.value
        #expect(driver.currentFrame(2) == left, "reconcile must not re-park a window released for shutdown")
        #expect(engine.isReleasingForShutdown)

        await engine.reconcile(liveWindowIDs: [1, 2])  // 終了後の reconcile も何もしない
        #expect(driver.currentFrame(2) == left)
    }

    @Test func terminationRepliesOnceAtDeadlineWhenCleanupHangs() async throws {
        var replies: [String] = []
        let coordinator = TerminationCoordinator(
            deadline: .milliseconds(50),
            cleanup: { try? await Task.sleep(for: .milliseconds(400)) },
            reply: { replies.append($0) })
        coordinator.requestTermination()
        coordinator.requestTermination()  // 再要求は無視
        try await Task.sleep(for: .milliseconds(150))
        #expect(replies.count == 1)
        #expect(replies.first?.contains("deadline") == true)
        try await Task.sleep(for: .milliseconds(350))
        #expect(replies.count == 1, "cleanup finishing later must not reply again")
    }

    @Test func terminationRepliesImmediatelyWhenCleanupIsFast() async throws {
        var replies: [String] = []
        let coordinator = TerminationCoordinator(deadline: .seconds(5), cleanup: {}, reply: { replies.append($0) })
        coordinator.requestTermination()
        try await Task.sleep(for: .milliseconds(30))
        #expect(replies == ["cleanup finished"])
        #expect(coordinator.isTerminating)
    }
}

@MainActor
struct ReconcileDriftTests {
    @Test func reconcileRestoresActiveWindowMovedWithoutNotification() async throws {
        let (engine, driver) = makeEngine(debounceMs: 10)
        let a = engine.createTab(name: "A")
        driver.add(1, frame: content)
        try await engine.register(windowID: 1, pid: 100, identity: identity("x"), frame: content, into: a.id)
        driver.moveExternally(1, to: CGRect(x: 600, y: 300, width: 1680, height: 1090))  // 通知なしでずれた
        await engine.reconcile(liveWindowIDs: [1])
        try await Task.sleep(for: .milliseconds(60))  // デバウンス経路で戻る
        #expect(driver.currentFrame(1) == content)
    }

    @Test func activateTreatsThrowAfterApplyAsSuccessViaReadBack() async throws {
        let (engine, driver) = makeEngine()
        let a = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(1, frame: content)
        driver.add(2, frame: content)
        let wa = try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: content, into: a.id)
        let wb = try await engine.register(windowID: 2, pid: 200, identity: identity("b"), frame: content, into: b.id)
        driver.setThrowAfterApply(1)
        driver.setThrowAfterApply(2)
        let report = try await engine.activate(b.id)
        #expect(report.failures.isEmpty, "applied-but-threw is confirmed by read-back")
        #expect(engine.parkedWindowIDs == [wa.id])
        #expect(!engine.parkedWindowIDs.contains(wb.id))
        #expect(driver.currentFrame(2) == content)
    }
}

struct ObserverPolicyTests {
    @Test func optionalFailureKeepsObserverRequiredFailureRejects() {
        let ok = AppWindowObserver.RegistrationPolicy.evaluate(
            required: ["AXWindowMoved": .success, "AXWindowResized": .notificationAlreadyRegistered],
            optional: ["AXFocusedWindowChanged": .notificationUnsupported])
        if case .success(let unavailable) = ok {
            #expect(unavailable == ["AXFocusedWindowChanged"])
        } else {
            Issue.record("optional failure must not reject the observer")
        }

        let rejected = AppWindowObserver.RegistrationPolicy.evaluate(
            required: ["AXWindowMoved": .success, "AXWindowResized": .cannotComplete],
            optional: [:])
        if case .failure(let error) = rejected {
            #expect(error.code == .cannotComplete)
            #expect(error.operation.contains("AXWindowResized"))
        } else {
            Issue.record("required failure must reject the observer")
        }
    }
}

@MainActor
struct SnapBackGenerationTests {
    @Test func staleSnapBackDoesNotOverwriteExplicitSetFrame() async throws {
        let (engine, driver) = makeEngine(debounceMs: 10)
        let a = engine.createTab(name: "A")
        driver.add(1, frame: content, delay: 0.08)  // frame 読み取りに時間がかかるアプリ
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("x"), frame: content, into: a.id)
        engine.editMode = true

        let stale = CGRect(x: 300, y: 100, width: 800, height: 600)
        driver.moveExternally(1, to: stale)
        engine.windowFrameDidChange(windowID: 1)
        try await Task.sleep(for: .milliseconds(30))  // 古い Task はいま frame 読み取り(IPC)の最中

        let explicit = CGRect(x: 500, y: 200, width: 700, height: 500)
        let actual = try await engine.setFrame(explicit, of: managed.id)  // 明示操作が後から入る
        #expect(actual == explicit)
        try await Task.sleep(for: .milliseconds(200))  // 古い Task が戻ってくるのを待つ
        #expect(engine.state.managedWindow(id: managed.id)?.window.frame == explicit, "stale task must not record the old position")
        #expect(driver.currentFrame(1) == explicit)
    }

    @Test func staleRestoreDoesNotReplaceNewerReservation() async throws {
        let (engine, driver) = makeEngine(debounceMs: 10)
        let a = engine.createTab(name: "A")
        driver.add(1, frame: content, delay: 0.05)
        try await engine.register(windowID: 1, pid: 100, identity: identity("x"), frame: content, into: a.id)

        driver.moveExternally(1, to: CGRect(x: 300, y: 100, width: 1680, height: 1090))
        engine.windowFrameDidChange(windowID: 1)
        try await Task.sleep(for: .milliseconds(20))  // 1 つ目の Task が IPC 中
        driver.moveExternally(1, to: CGRect(x: 400, y: 150, width: 1680, height: 1090))
        engine.windowFrameDidChange(windowID: 1)  // 新しい予約(世代が進む)
        try await Task.sleep(for: .milliseconds(400))
        #expect(driver.currentFrame(1) == content, "newer reservation restores; stale task neither interferes nor leaves it moved")
    }
}

@MainActor
struct EditModeActualFrameTests {
    @Test func editModeAdoptsActualFrameAfterAppConstraint() async throws {
        let (engine, driver) = makeEngine(debounceMs: 10)
        let a = engine.createTab(name: "A")
        driver.add(1, frame: content, minSize: CGSize(width: 900, height: 0))
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("x"), frame: content, into: a.id)
        engine.editMode = true
        // サイドバー領域に置かれ、かつ幅 700 はアプリの最小幅 900 未満(寄せる setFrame で幅がクランプされる)
        driver.moveExternally(1, to: CGRect(x: 50, y: 100, width: 700, height: 600))
        engine.windowFrameDidChange(windowID: 1)
        try await Task.sleep(for: .milliseconds(60))
        let recorded = engine.state.managedWindow(id: managed.id)?.window.frame
        #expect(recorded == CGRect(x: content.minX, y: 100, width: 900, height: 600), "actual (clamped by app) frame is recorded, not the request")
        #expect(driver.currentFrame(1) == recorded)
    }

    @Test func editModeDoesNotCommitTargetWhenClampMoveFails() async throws {
        let (engine, driver) = makeEngine(debounceMs: 10)
        let a = engine.createTab(name: "A")
        driver.add(1, frame: content)
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("x"), frame: content, into: a.id)
        engine.editMode = true
        driver.moveExternally(1, to: CGRect(x: 50, y: 100, width: 800, height: 600))
        driver.setFailWrites(1)
        engine.windowFrameDidChange(windowID: 1)
        try await Task.sleep(for: .milliseconds(60))
        #expect(engine.state.managedWindow(id: managed.id)?.window.frame == content, "previous frame kept when the nudge fails")
    }
}

struct ParallelEnumerationTests {
    @MainActor
    @Test func enumerationRunsPerAppInParallelAndKeepsMainActorResponsive() async throws {
        let apps = (1...3).map { AppDescriptor(pid: pid_t($0 * 100), name: "app\($0)", bundleID: "test.app\($0)") }
        let heartbeat = Locked(0)
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                heartbeat.withValue { $0 += 1 }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        let sw = Stopwatch()
        let (records, stats) = await WindowEnumerator.enumerateInParallel(apps) { app in
            Thread.sleep(forTimeInterval: 0.15)  // 遅いアプリへの同期 IPC を模す
            var s = EnumerationStats()
            s.apps = 1
            s.appFailureDetails = ["\(app.name): simulated"]
            return AppEnumeration(records: [], stats: s)
        }
        ticker.cancel()
        #expect(sw.elapsedMs < 300, "3 apps x 150 ms must not run sequentially (took \(sw.elapsedMs) ms)")
        #expect(heartbeat.current >= 5, "MainActor must keep running while enumeration blocks background threads")
        #expect(records.isEmpty)
        #expect(stats.apps == 3)
        #expect(stats.appFailureDetails.count == 3)
    }
}

/// 値を差し替えられる layout(ディスプレイ構成の変更を模す)。
final class MutableScreenLayout: ScreenLayout, @unchecked Sendable {
    private let lock = NSLock()
    private var _displays: [DisplayLayout]

    init(parkPoint: CGPoint, contentArea: CGRect) {
        _displays = FixedScreenLayout(parkPoint: parkPoint, contentArea: contentArea).displays
    }

    init(displays: [DisplayLayout]) {
        _displays = displays
    }

    var displays: [DisplayLayout] { lock.withLock { _displays } }

    func change(parkPoint: CGPoint, contentArea: CGRect) {
        lock.withLock {
            _displays = FixedScreenLayout(parkPoint: parkPoint, contentArea: contentArea).displays
        }
    }

    func change(displays: [DisplayLayout]) {
        lock.withLock { _displays = displays }
    }
}

@MainActor
struct LayoutReapplyTests {
    @Test func reapplyLayoutMovesWindowsToNewContentAreaAndParkPoint() async throws {
        let driver = FakeWindowDriver()
        let layout = MutableScreenLayout(parkPoint: park, contentArea: content)
        let engine = TabEngine(driver: driver, layout: layout)
        let a = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(1, frame: content)
        driver.add(2, frame: content)
        let wa = try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: CGRect(x: 240, y: 30, width: 800, height: 600), into: a.id)
        let wb = try await engine.register(windowID: 2, pid: 200, identity: identity("b"), frame: content, into: b.id)
        #expect(driver.currentFrame(2)?.origin == park)

        // 外部ディスプレイを外して小さい画面になった、という状況
        let newPark = CGPoint(x: 1439, y: 899)
        let newArea = CGRect(x: 300, y: 30, width: 1140, height: 800)
        layout.change(parkPoint: newPark, contentArea: newArea)
        await engine.reapplyLayout()

        #expect(driver.currentFrame(1)?.origin.x == 300, "active window pulled into the new content area")
        #expect(engine.state.managedWindow(id: wa.id)?.window.frame.minX == 300)
        #expect(driver.currentFrame(2)?.origin == newPark, "parked window moved to the new park point")
        #expect(engine.parkedWindowIDs.contains(wb.id))
    }
}

struct PersistedToggleTests {
    @Test func defaultIsRegisteredBeforeFirstReadAndToggleIsPersisted() {
        let suite = "tabdesk-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let toggle = PersistedToggle(key: "SidebarAlwaysOnTop", defaultValue: true, defaults: defaults)
        #expect(toggle.value == true, "empty defaults must read as the default, not false")
        toggle.value = false
        #expect(defaults.bool(forKey: "SidebarAlwaysOnTop") == false)
        let again = PersistedToggle(key: "SidebarAlwaysOnTop", defaultValue: true, defaults: defaults)
        #expect(again.value == false, "persisted value wins over the default")
    }
}

@MainActor
struct FocusTargetTests {
    @Test func focusTargetIsChosenFromStateAfterOperations() async throws {
        let (engine, driver) = makeEngine()
        let a = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(1, frame: content)
        driver.add(2, frame: content, delay: 0.08)
        driver.add(3, frame: content)
        try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: content, into: a.id)
        try await engine.register(windowID: 2, pid: 200, identity: identity("b-focused"), frame: content, into: b.id)
        try await engine.register(windowID: 3, pid: 300, identity: identity("b-other"), frame: content, into: b.id)
        engine.noteWindowFocused(windowID: 2)
        try await engine.activate(b.id)
        engine.noteWindowFocused(windowID: 2)
        try await engine.activate(a.id)

        var activated: [pid_t] = []
        engine.activateApplication = { activated.append($0) }
        let activation = Task { try await engine.activate(b.id) }
        try await Task.sleep(for: .milliseconds(20))
        engine.noteWindowDestroyed(windowID: 2)  // 切替の IPC 中に最終フォーカス窓が閉じられた
        _ = try await activation.value
        #expect(activated == [300], "must not activate the pid of a window that no longer exists")
    }
}

@MainActor
struct BindGuardTests {
    @Test func bindClampsLoadedFrameToCurrentScreenAndReplacesManualIdentity() async throws {
        let driver = FakeWindowDriver()
        let saved = CGRect(x: 2_500, y: 900, width: 800, height: 600)
        let managed = ManagedWindow(
            frame: saved,
            identity: identity("old"),
            windowID: nil,
            pid: nil)
        let tab = Tab(name: "A", windows: [managed])
        let initialState = WorkspaceState(tabs: [tab], activeTabID: tab.id)
        let engine = TabEngine(
            driver: driver,
            layout: FixedScreenLayout(parkPoint: park, contentArea: content),
            initialState: initialState)
        driver.add(11, frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        let replacement = WindowIdentity(
            bundleID: "test.new",
            appName: "New App",
            title: "New Window",
            registeredSize: CGSize(width: 640, height: 480))

        try await engine.bind(managed.id, windowID: 11, pid: 110, title: "ignored", identity: replacement)

        let expected = CGRect(x: 1_120, y: 520, width: 800, height: 600)
        let rebound = engine.state.managedWindow(id: managed.id)?.window
        #expect(driver.currentFrame(11) == expected, "restoration uses the current screen's content area")
        #expect(rebound?.frame == expected)
        #expect(rebound?.identity == replacement, "manual reassignment replaces all persisted identity fields")
    }

    @Test func bindIntoInactiveTabStoresClampedFrameForLaterActivation() async throws {
        let driver = FakeWindowDriver()
        let a = Tab(name: "A")
        let saved = CGRect(x: 2_500, y: 900, width: 800, height: 600)
        let managed = ManagedWindow(frame: saved, identity: identity("old"), windowID: nil, pid: nil)
        let b = Tab(name: "B", windows: [managed])
        let state = WorkspaceState(tabs: [a, b], activeTabID: a.id)
        let engine = TabEngine(
            driver: driver,
            layout: FixedScreenLayout(parkPoint: park, contentArea: content),
            initialState: state)
        driver.add(11, frame: content)

        try await engine.bind(managed.id, windowID: 11, pid: 110)

        let expected = CGRect(x: 1_120, y: 520, width: 800, height: 600)
        #expect(driver.currentFrame(11)?.origin == park)
        #expect(engine.state.managedWindow(id: managed.id)?.window.frame == expected)
        try await engine.activate(b.id)
        #expect(driver.currentFrame(11) == expected)
    }

    @Test func unregisteringAnUnboundEntryReturnsNoWindowID() async throws {
        let (engine, driver) = makeEngine()
        let a = engine.createTab(name: "A")
        driver.add(1, frame: content)
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("x"), frame: content, into: a.id)
        engine.unbindWindows(pid: 100)

        let removedWindowID = try await engine.unregister(managed.id)

        #expect(removedWindowID == nil)
        #expect(engine.state.managedWindow(id: managed.id) == nil)
    }

    @Test func bindRejectsOverwritingABoundEntryAndKeepsTheOldWindowTracked() async throws {
        let (engine, driver) = makeEngine()
        _ = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(1, frame: content)
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("x"), frame: content, into: b.id)
        engine.unbindWindows(pid: 100)
        driver.add(11, frame: content)
        driver.add(12, frame: content)
        try await engine.bind(managed.id, windowID: 11, pid: 110)
        #expect(driver.currentFrame(11)?.origin == park)

        await #expect(throws: TabEngine.EngineError.self) {
            try await engine.bind(managed.id, windowID: 12, pid: 120)  // 上書きは拒否
        }
        #expect(engine.state.managedWindow(forWindowID: 11)?.window.id == managed.id, "old window stays tracked")
        try await engine.bind(managed.id, windowID: 11, pid: 110)  // 同じ窓への再 bind は冪等

        await engine.releaseAllParkedWindows()
        #expect(driver.currentFrame(11) == content, "still recoverable at shutdown")
    }

    @Test func bindKeepsSavedFrameWhenPlacementDoesNotReachIt() async throws {
        let (engine, driver) = makeEngine()
        let a = engine.createTab(name: "A")
        driver.add(1, frame: content)
        let saved = CGRect(x: 400, y: 100, width: 800, height: 600)
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("x"), frame: saved, into: a.id)
        engine.unbindWindows(pid: 100)

        driver.add(11, frame: CGRect(x: 900, y: 500, width: 640, height: 480))
        driver.setFailWrites(11)  // 復元先アプリが一時的に無応答(読みは通る)
        try await engine.bind(managed.id, windowID: 11, pid: 110)
        #expect(engine.state.managedWindow(id: managed.id)?.window.isBound == true)
        #expect(engine.state.managedWindow(id: managed.id)?.window.frame == saved, "saved layout must survive a failed placement")

        driver.setFailWrites(11, false)
        await engine.reconcile(liveWindowIDs: [11])  // ずれ検出 → デバウンス復元
        try await Task.sleep(for: .milliseconds(60))
        #expect(driver.currentFrame(11) == saved)
    }
}

@MainActor
struct VanishedWindowTests {
    @Test func pollingOnlyAppQuitKeepsTheEntryAfterTheWindowDisappearsFirst() async throws {
        let (engine, driver) = makeEngine()
        engine.vanishGracePeriod = .seconds(3)
        let a = engine.createTab(name: "A")
        driver.add(1, frame: content)
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("chrome"), frame: content, into: a.id)
        driver.kill(1)

        // destroyed通知を取りこぼし、ポーリングだけがChrome型終了を観測する。
        await engine.reconcile(liveWindowIDs: [99], livePIDs: [100, 999])
        #expect(engine.state.managedWindow(id: managed.id)?.window.pid == 100)
        await engine.reconcile(liveWindowIDs: [99], livePIDs: [999])

        let kept = engine.state.managedWindow(id: managed.id)?.window
        #expect(kept != nil)
        #expect(kept?.isBound == false)
        #expect(kept?.pid == nil)
    }

    @Test func windowClosedWhileAppAliveIsRemovedOnlyAfterGrace() async throws {
        let (engine, driver) = makeEngine()
        engine.vanishGracePeriod = .milliseconds(50)
        let a = engine.createTab(name: "A")
        driver.add(1, frame: content)
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("x"), frame: content, into: a.id)
        driver.kill(1)
        engine.noteWindowDestroyed(windowID: 1)
        #expect(engine.state.managedWindow(id: managed.id)?.window.isBound == false, "binding dropped immediately")

        await engine.reconcile(liveWindowIDs: [99], livePIDs: [100])  // 猶予内: アプリは生きている
        #expect(engine.state.managedWindow(id: managed.id) != nil, "kept during the grace period")

        try await Task.sleep(for: .milliseconds(80))
        await engine.reconcile(liveWindowIDs: [99], livePIDs: [100])  // 猶予経過 + アプリ生存 = 本当に閉じられた
        #expect(engine.state.managedWindow(id: managed.id) == nil, "removed: the window alone was closed")
    }

    @Test func windowsClosedDuringAppQuitAreKeptAsUnbound() async throws {
        let (engine, driver) = makeEngine()
        engine.vanishGracePeriod = .seconds(3)
        let a = engine.createTab(name: "A")
        driver.add(1, frame: content)
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("chrome"), frame: content, into: a.id)
        // Chrome 型の終了: 先に窓が閉じ、その時点ではプロセスがまだ生きている
        driver.kill(1)
        engine.noteWindowDestroyed(windowID: 1)
        await engine.reconcile(liveWindowIDs: [99], livePIDs: [100, 999])  // まだ生きている → 保留
        #expect(engine.state.managedWindow(id: managed.id) != nil)

        await engine.reconcile(liveWindowIDs: [99], livePIDs: [999])  // プロセスが消えた → 未復元として保持
        let kept = engine.state.managedWindow(id: managed.id)
        #expect(kept != nil)
        #expect(kept?.window.isBound == false)
        #expect(kept?.window.pid == nil, "fully unbound so the matcher can rebind it later")
    }

    @Test func rebindDuringGraceCancelsTheVanishDecision() async throws {
        let (engine, driver) = makeEngine()
        engine.vanishGracePeriod = .milliseconds(30)
        let a = engine.createTab(name: "A")
        driver.add(1, frame: content)
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("x"), frame: content, into: a.id)
        driver.kill(1)
        engine.noteWindowDestroyed(windowID: 1)
        driver.add(2, frame: content)
        try await engine.bind(managed.id, windowID: 2, pid: 100)  // 同じアプリの新しい窓に紐付け直した
        try await Task.sleep(for: .milliseconds(60))
        await engine.reconcile(liveWindowIDs: [2], livePIDs: [100])
        #expect(engine.state.managedWindow(id: managed.id)?.window.windowID == 2, "must not be removed after rebinding")
    }

    @Test func slowRebindClaimsTheEntryBeforeGraceResolutionCanRemoveIt() async throws {
        let (engine, driver) = makeEngine()
        engine.vanishGracePeriod = .milliseconds(30)
        let a = engine.createTab(name: "A")
        driver.add(1, frame: content)
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("x"), frame: content, into: a.id)
        driver.kill(1)
        engine.noteWindowDestroyed(windowID: 1)

        // bind は place の完了まで commit しない。遅いIPCの待機中にも、entryを猶予削除の対象へ戻してはいけない。
        driver.add(2, frame: content, delay: 0.1)
        let binding = Task { try await engine.bind(managed.id, windowID: 2, pid: 100) }
        try await Task.sleep(for: .milliseconds(50))  // grace経過、placeはまだ待機中
        let reconciliation = Task { await engine.reconcile(liveWindowIDs: [2], livePIDs: [100]) }

        try await binding.value
        await reconciliation.value
        let rebound = engine.state.managedWindow(id: managed.id)?.window
        #expect(rebound?.windowID == 2)
        #expect(rebound?.pid == 100)
        #expect(rebound?.isBound == true)
    }
}

struct HotkeyTests {
    @Test func parserAcceptsAliasesAndNormalizes() throws {
        let h = try HotkeyParser.parse("Control + Option + 1")
        #expect(h.keyCode == 18)
        #expect(h.modifiers == HotkeyParser.controlKey | HotkeyParser.optionKey)
        let same = try HotkeyParser.parse("ctrl+alt+1")
        #expect(h.keyCode == same.keyCode && h.modifiers == same.modifiers)
        #expect(try HotkeyParser.parse("cmd+shift+r").modifiers == HotkeyParser.cmdKey | HotkeyParser.shiftKey)
        // 数字の keyCode は連番ではない(5=23, 6=22 など)
        #expect(try HotkeyParser.parse("ctrl+5").keyCode == 23)
        #expect(try HotkeyParser.parse("ctrl+6").keyCode == 22)
    }

    @Test func parserRejectsInvalidSpecs() {
        #expect(throws: HotkeyParser.ParseError.unknownKey("§")) { try HotkeyParser.parse("ctrl+§") }
        #expect(throws: HotkeyParser.ParseError.unknownModifier("hyper")) { try HotkeyParser.parse("hyper+1") }
        #expect(throws: HotkeyParser.ParseError.missingModifier("r")) { try HotkeyParser.parse("r") }
    }

    @Test func defaultConfigResolvesCompletely() {
        let (bindings, errors) = HotkeyConfig.default.resolve()
        #expect(errors.isEmpty)
        #expect(bindings.count == 14)  // タブ 1..9 + 順送り/逆送り + 登録 + 編集モード + サイドバー折りたたみ
        #expect(bindings.contains { $0.1 == .activateTab(9) })
        #expect(bindings.contains { $0.1 == .registerFocusedWindow })
    }

    @Test func brokenEntriesAreReportedButOthersSurvive() throws {
        var config = HotkeyConfig.default
        config.activateTab[2] = "banana"
        config.toggleEditMode = "ctrl+alt+1"  // タブ 1 と重複
        let (bindings, errors) = config.resolve()
        #expect(errors.count == 2)
        #expect(bindings.count == 12)  // 14 - 壊れた 1 - 重複 1
        #expect(!bindings.contains { $0.1 == .activateTab(3) })
    }

    @Test func configRoundTripsThroughJSON() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tabdesk-hotkeys-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("hotkeys.json")
        #expect(try HotkeyConfig.load(from: url) == nil)
        try HotkeyConfig.default.save(to: url)
        #expect(try HotkeyConfig.load(from: url) == HotkeyConfig.default)
        try? FileManager.default.removeItem(at: dir)
    }
}


@MainActor
struct AdjacentActivationTests {
    @Test func rapidAdjacentPressesAdvanceOneTabEach() async throws {
        let (engine, driver) = makeEngine()
        let a = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        let c = engine.createTab(name: "C")
        driver.add(1, frame: content, delay: 0.05)  // 切替に時間がかかるアプリ
        try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: content, into: a.id)

        // 1 回目の切替が進行中に 2 回目の押下が来る(連打)
        async let first: TabEngine.SwitchReport? = engine.activateAdjacent(offset: 1)
        async let second: TabEngine.SwitchReport? = engine.activateAdjacent(offset: 1)
        _ = try await (first, second)
        #expect(engine.state.activeTabID == c.id, "two presses must land two tabs ahead, not collapse onto B")
        _ = b
    }

    @Test func adjacentWrapsAroundAndHandlesMissingActiveTab() async throws {
        let (engine, _) = makeEngine()
        let a = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        try await engine.activateAdjacent(offset: -1)  // A から前へ → 末尾 B
        #expect(engine.state.activeTabID == b.id)
        try await engine.activateAdjacent(offset: 1)  // B から次へ → 先頭 A
        #expect(engine.state.activeTabID == a.id)

        let (empty, _) = makeEngine()
        #expect(try await empty.activateAdjacent(offset: 1) == nil, "no tabs: no-op")
    }
}

/// 外部リファクタ精査(v3 段階 0)の修正を固定するテスト。
@MainActor
struct AuditFixTests {
    /// 復元世代表は登録解除で剪定される(放置すると窓の入れ替わりぶん無限に育ち、
    /// cancelAllRestores が画面変更のたびに全走査する)。
    @Test func restoreGenerationIsPrunedOnRemoval() async throws {
        let (engine, driver) = makeEngine()
        let tab = engine.createTab(name: "A")
        driver.add(1, frame: CGRect(x: 300, y: 100, width: 500, height: 400))
        let managed = try await engine.register(
            windowID: 1, pid: 100, identity: identity("a"),
            frame: CGRect(x: 300, y: 100, width: 500, height: 400), into: tab.id)
        driver.moveExternally(1, to: CGRect(x: 700, y: 300, width: 500, height: 400))
        engine.windowFrameDidChange(windowID: 1)
        try await Task.sleep(for: .milliseconds(120))  // デバウンス消化(世代表にエントリが載る)
        #expect(engine.restoreGenerationCountForTesting > 0)

        try await engine.unregister(managed.id)
        #expect(engine.restoreGenerationCountForTesting == 0)
    }

    /// endLayoutTransition はシャットダウン中でも無条件でフラグを下ろす(段階 0 の修正の固定)。
    /// begin と対称のガードを将来うっかり再導入すると、シャットダウンを中断する経路ができたときに
    /// reconcile / スナップバックが永久停止する — このテストがその回帰を検知する。
    @Test func endLayoutTransitionClearsFlagEvenDuringShutdown() {
        let (engine, _) = makeEngine()
        engine.beginLayoutTransition()  // beginShutdown より先(begin はシャットダウン中を拒否するため)
        #expect(engine.isLayoutTransitioningForTesting)
        engine.beginShutdown()
        engine.endLayoutTransition()
        #expect(!engine.isLayoutTransitioningForTesting, "クリアは無条件であること")
    }

    /// 終了時の解放(releaseAll)は apply と同じ許容誤差ゲートで到達 frame を採用する。
    /// ゲートが無いと、サブポイントのずれが終了のたびに記録へ蓄積する。
    @Test func releaseDoesNotAdoptSubToleranceDrift() async throws {
        let (engine, driver) = makeEngine()
        let a = engine.createTab(name: "A")
        let b = engine.createTab(name: "B")
        driver.add(1, frame: content)
        try await engine.register(windowID: 1, pid: 100, identity: identity("a"), frame: content, into: a.id)
        let recorded = CGRect(x: 300, y: 100, width: 500, height: 400)
        driver.add(2, frame: recorded, minSize: CGSize(width: 500.5, height: 0))  // 復元すると幅 500.5 に丸まる
        let managed = try await engine.register(windowID: 2, pid: 200, identity: identity("b"), frame: recorded, into: b.id)
        #expect(engine.parkedWindowIDs.contains(managed.id))

        await engine.releaseAllParkedWindows()
        let after = engine.state.managedWindow(id: managed.id)?.window.frame
        #expect(after?.width == recorded.width, "許容誤差内(0.5pt)の到達値は採用しない")
    }
}

/// v4 段階 0: 終了時解放のタブ横断 pid 並列化の検証。
@MainActor
struct ShutdownReleaseBatchTests {
    /// 別タブ・別 pid の退避窓が、終了時に 1 回の解放バッチとして pid 並列で復元される。
    /// (旧実装はタブごとに逐次呼び出しだったため、遅いアプリの待ちがタブ数ぶん直列に積み上がった)
    @Test func shutdownReleasesAcrossTabsInOneBatch() async throws {
        let (engine, driver) = makeEngine()
        _ = engine.createTab(name: "Active")
        let b = engine.createTab(name: "B")
        let c = engine.createTab(name: "C")
        let frameB = CGRect(x: 300, y: 100, width: 500, height: 400)
        let frameC = CGRect(x: 900, y: 200, width: 500, height: 400)
        driver.add(1, frame: frameB)
        driver.add(2, frame: frameC)
        try await engine.register(windowID: 1, pid: 100, identity: identity("b"), frame: frameB, into: b.id)
        try await engine.register(windowID: 2, pid: 200, identity: identity("c"), frame: frameC, into: c.id)
        // 解放の setFrame だけ遅くして、並列実行なら実行時間が重なるようにする。
        driver.setDelay(1, 0.08)
        driver.setDelay(2, 0.08)

        await engine.releaseAllParkedWindows()

        #expect(driver.currentFrame(1) == frameB)
        #expect(driver.currentFrame(2) == frameC)
        #expect(driver.maxConcurrent >= 2, "タブをまたいだ pid 並列で解放される")
        #expect(engine.parkedWindowIDs.isEmpty)
    }
}
