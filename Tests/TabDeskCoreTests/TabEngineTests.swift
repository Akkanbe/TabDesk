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

        try await engine.deleteTab(b.id)
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
        try await engine.unregister(managed.id)
        #expect(engine.state.allWindows.isEmpty)
        #expect(driver.currentFrame(1) == frame)
    }

    @Test func destroyedWindowIsRemoved() async throws {
        let (engine, driver) = makeEngine()
        let a = engine.createTab(name: "A")
        driver.add(1, frame: content)
        let managed = try await engine.register(windowID: 1, pid: 100, identity: identity("x"), frame: content, into: a.id)
        engine.noteWindowFocused(windowID: 1)
        #expect(engine.state.tabs[0].lastFocusedWindowID == managed.id)
        engine.noteWindowDestroyed(windowID: 1)
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

        // タブ連打: B → C をほぼ同時に
        async let first = engine.activate(b.id)
        async let second = engine.activate(c.id)
        _ = try await (first, second)

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
        engine.noteWindowDestroyed(windowID: 1)  // 退避中に閉じられた
        _ = try await activation.value

        #expect(engine.state.allWindows.map(\.windowID) == [2])
        #expect(!engine.parkedWindowIDs.contains(wa.id))
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
private func withDeadline<T: Sendable>(_ ms: Int = 1000, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
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
private struct DeadlineExceeded: Error {}

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
        try await deletion.value
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
        try await engine.activate(b.id)
        #expect(!engine.parkedWindowIDs.contains(wa.id))
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
