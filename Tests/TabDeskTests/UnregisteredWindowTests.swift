import AppKit
import Testing
import TabDeskCore
@testable import TabDesk

@MainActor
struct UnregisteredWindowTests {
    typealias Controller = UnregisteredWindowController
    private final class Holder { weak var controller: Controller? }
    private let frame = CGRect(x: 0, y: 0, width: 500, height: 300)

    private func window(_ id: WindowReferenceID, frame: CGRect? = nil,
                        action: @escaping @MainActor () async throws -> Void = {}) -> Controller.Window {
        .init(id: id, frame: frame ?? self.frame, bringForward: action)
    }

    @Test func onlyCorrectsOcclusionByRegisteredWindows() {
        let registered = WindowReferenceID(), free = WindowReferenceID()
        #expect(Controller.targets(in: [window(free), window(registered)], registered: [registered]).isEmpty)
        #expect(Controller.targets(in: [window(registered), window(free)], registered: []).isEmpty)
        #expect(Controller.targets(in: [window(registered), window(free,
            frame: CGRect(x: 600, y: 0, width: 500, height: 300))], registered: [registered]).isEmpty)
        #expect(Controller.targets(in: [window(registered), window(free)], registered: [registered]).map(\.id) == [free])
    }

    @Test func preservesUnregisteredRelativeOrderAndNeverRaisesRegisteredWindows() {
        let managed = WindowReferenceID(), a = WindowReferenceID(), b = WindowReferenceID(), c = WindowReferenceID()
        let windows = [window(a), window(managed), window(b), window(c)]
        #expect(Controller.targets(in: windows, registered: [managed]).map(\.id) == [c, b, a])
    }

    @Test func unrelatedDisplayDoesNotBecomeTheInputTarget() {
        let managed = WindowReferenceID(), covered = WindowReferenceID(), otherDisplay = WindowReferenceID()
        let windows = [window(otherDisplay, frame: CGRect(x: -1920, y: 0, width: 500, height: 300)),
                       window(managed), window(covered)]
        #expect(Controller.targets(in: windows, registered: [managed]).map(\.id) == [covered])
    }

    @Test func preservesOrderAcrossChainOfOverlappingUnregisteredWindows() {
        let managed = WindowReferenceID(), a = WindowReferenceID(), b = WindowReferenceID(), c = WindowReferenceID()
        let windows = [window(a, frame: CGRect(x: 800, y: 0, width: 500, height: 300)),
                       window(b, frame: CGRect(x: 400, y: 0, width: 500, height: 300)),
                       window(managed), window(c)]
        #expect(Controller.targets(in: windows, registered: [managed]).map(\.id) == [c, b, a])
    }

    @Test func requestAfterInvalidationRunsWhenOldSampleFinishes() async {
        let managed = WindowReferenceID(), free = WindowReferenceID()
        let holder = Holder()
        var samples = 0, raises = 0
        let snapshot = Controller.Snapshot(signature: [], windows: [window(managed), window(free) { raises += 1 }])
        let controller = Controller(context: { [managed] }, sample: { _ in
            samples += 1
            if samples == 1 {
                holder.controller?.invalidate()
                holder.controller?.request()
                holder.controller?.request()
            }
            return snapshot
        }, onError: { _ in })
        holder.controller = controller
        controller.request()
        await controller.waitForPendingWork()
        #expect(samples == 2)
        #expect(raises == 1)
    }

    @Test func disableDropsQueuedRetry() async {
        let managed = WindowReferenceID(), free = WindowReferenceID()
        let holder = Holder()
        var enabled = true
        var samples = 0, raises = 0
        let snapshot = Controller.Snapshot(signature: [], windows: [window(managed), window(free) { raises += 1 }])
        let controller = Controller(context: { enabled ? [managed] : nil }, sample: { _ in
            samples += 1
            holder.controller?.invalidate()
            holder.controller?.request()
            enabled = false
            holder.controller?.invalidate()
            return snapshot
        }, onError: { _ in })
        holder.controller = controller
        controller.request()
        await controller.waitForPendingWork()
        #expect(samples == 1 && raises == 0)
    }

    @Test func unrelatedWindowChangesDoNotDiscardStableWindows() {
        let a = Controller.VisibleWindow(number: 1, pid: 100, frame: frame)
        let b = Controller.VisibleWindow(number: 2, pid: 200, frame: frame)
        let popup = Controller.VisibleWindow(number: 3, pid: 300, frame: frame.offsetBy(dx: 1000, dy: 0))
        #expect(Controller.stableWindows(before: [a, b], after: [popup, a, b]) == [a, b])
        #expect(Controller.stableWindows(before: [popup, a, b], after: [a, b]) == [a, b])
        #expect(Controller.stableWindows(before: [a, b], after: [b, a]) == [b, a])
    }

    @Test func movedOrReusedWindowIsExcludedButOthersRemain() {
        let a = Controller.VisibleWindow(number: 1, pid: 100, frame: frame)
        let b = Controller.VisibleWindow(number: 2, pid: 200, frame: frame.offsetBy(dx: 1000, dy: 0))
        let moved = Controller.VisibleWindow(number: 1, pid: 100, frame: frame.offsetBy(dx: 10, dy: 0))
        let reused = Controller.VisibleWindow(number: 1, pid: 300, frame: frame)
        #expect(Controller.stableWindows(before: [a, b], after: [moved, b]) == [b])
        #expect(Controller.stableWindows(before: [a, b], after: [reused, b]) == [b])
    }

    @Test func changedOverlappingWindowDefersAffectedWindowsOnly() {
        let a = Controller.VisibleWindow(number: 1, pid: 100, frame: frame)
        let b = Controller.VisibleWindow(number: 2, pid: 200, frame: frame.offsetBy(dx: 1000, dy: 0))
        let popup = Controller.VisibleWindow(number: 3, pid: 300, frame: frame)
        #expect(Controller.stableWindows(before: [a, b], after: [popup, a, b]) == [b])
        #expect(Controller.stableWindows(before: [popup, a, b], after: [a, b]) == [b])
    }

    @Test func incompleteSnapshotIsNotCachedForTenSeconds() async {
        let managed = WindowReferenceID(), free = WindowReferenceID()
        var samples = 0, raises = 0
        let signature = [Controller.VisibleWindow(number: 1, pid: 100, frame: frame)]
        let incomplete = Controller.Snapshot(signature: signature, windows: [], canCache: false)
        let complete = Controller.Snapshot(signature: signature, windows: [window(managed), window(free) { raises += 1 }])
        let controller = Controller(context: { [managed] }, sample: { previous in
            samples += 1
            #expect(previous == nil)
            return samples == 1 ? incomplete : complete
        }, onError: { _ in })
        controller.request()
        await controller.waitForPendingWork()
        controller.request()
        await controller.waitForPendingWork()
        #expect(samples == 2 && raises == 1)
    }

    @Test func disabledOrBusyDoesNotEnumerate() async {
        var samples = 0
        let controller = Controller(context: { nil }, sample: { _ in samples += 1; return nil }, onError: { _ in })
        controller.request()
        await controller.waitForPendingWork()
        #expect(samples == 0)
    }

    @Test func registrationDuringEnumerationDiscardsSnapshot() async {
        let managed = WindowReferenceID(), free = WindowReferenceID()
        var registered: Set<WindowReferenceID> = [managed]
        var raises = 0
        let snapshot = Controller.Snapshot(signature: [], windows: [window(managed), window(free) { raises += 1 }])
        let controller = Controller(context: { registered }, sample: { _ in
            registered.insert(free)
            return snapshot
        }, onError: { _ in })
        controller.request()
        await controller.waitForPendingWork()
        #expect(raises == 0)
    }

    @Test func disableOrTerminationDuringEnumerationStopsFronting() async {
        let managed = WindowReferenceID(), free = WindowReferenceID()
        var raises = 0
        let snapshot = Controller.Snapshot(signature: [], windows: [window(managed), window(free) { raises += 1 }])
        let holder = Holder()
        let controller = Controller(context: { [managed] }, sample: { _ in
            holder.controller?.invalidate()
            return snapshot
        }, onError: { _ in })
        holder.controller = controller
        controller.request()
        await controller.waitForPendingWork()
        #expect(raises == 0)
    }

    @Test func cancellationBetweenWindowsStopsRemainingRaises() async {
        let managed = WindowReferenceID(), a = WindowReferenceID(), b = WindowReferenceID()
        var raised: [WindowReferenceID] = []
        let holder = Holder()
        let snapshot = Controller.Snapshot(signature: [], windows: [window(managed),
            window(a) { raised.append(a) }, window(b) { raised.append(b); holder.controller?.invalidate() }])
        let controller = Controller(context: { [managed] }, sample: { _ in snapshot }, onError: { _ in })
        holder.controller = controller
        controller.request()
        await controller.waitForPendingWork()
        #expect(raised == [b])
    }

    @Test func disableDuringEligibilityReadStopsActivation() async {
        let managed = WindowReferenceID(), free = WindowReferenceID()
        var enabled = true, raised = false
        var candidate = window(free) { raised = true }
        candidate.isEligible = { enabled = false; return true }
        let snapshot = Controller.Snapshot(signature: [], windows: [window(managed), candidate])
        let controller = Controller(context: { enabled ? [managed] : nil }, sample: { _ in snapshot }, onError: { _ in })
        controller.request()
        await controller.waitForPendingWork()
        #expect(!raised)
    }

    @Test func windowMinimizedAfterEnumerationIsNotRaised() async {
        let managed = WindowReferenceID(), free = WindowReferenceID()
        var raised = false
        var candidate = window(free) { raised = true }
        candidate.isEligible = { false }
        let snapshot = Controller.Snapshot(signature: [], windows: [window(managed), candidate])
        let controller = Controller(context: { [managed] }, sample: { _ in snapshot }, onError: { _ in })
        controller.request()
        await controller.waitForPendingWork()
        #expect(!raised)
    }

    @Test func failureDoesNotPreventOtherWindowsFromBeingRaised() async {
        enum Failure: Error { case unavailable }
        let managed = WindowReferenceID(), a = WindowReferenceID(), b = WindowReferenceID()
        var raises = 0, errors = 0
        let snapshot = Controller.Snapshot(signature: [], windows: [window(managed),
            window(a) { raises += 1 }, window(b) { throw Failure.unavailable }])
        let controller = Controller(context: { [managed] }, sample: { _ in snapshot }, onError: { _ in errors += 1 })
        controller.request()
        controller.request()
        await controller.waitForPendingWork()
        #expect(raises == 1 && errors == 1)
    }
}


@MainActor
struct UnregisteredWindowLayoutIntegrationTests {
    @Test(arguments: [false, true])
    func completedLayoutDoesNotBlockFronting(screenChange: Bool) async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = WindowManager(logger: FileLogger(fileURL: directory.appendingPathComponent("test.log")),
            store: StateStore(fileURL: directory.appendingPathComponent("state.json")), monitoringEnabled: false)
        if screenChange {
            manager.layoutMayHaveChanged(Notification(name: NSApplication.didChangeScreenParametersNotification))
        } else { manager.applySidebarWidthChange() }
        #expect(manager.isReapplyingLayout)
        await manager.waitForLayoutReapply()
        #expect(!manager.isReapplyingLayout, "完了済みTaskが前面化を永久に止めてはいけない")
        manager.beginTermination()
    }

    @Test func replacedLayoutTaskCannotClearCurrentBarrier() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = WindowManager(logger: FileLogger(fileURL: directory.appendingPathComponent("test.log")),
            store: StateStore(fileURL: directory.appendingPathComponent("state.json")), monitoringEnabled: false)
        manager.applySidebarWidthChange()
        manager.layoutMayHaveChanged(Notification(name: NSApplication.didChangeScreenParametersNotification))
        for _ in 0..<10 { await Task.yield() }
        #expect(manager.isReapplyingLayout)
        await manager.waitForLayoutReapply()
        #expect(!manager.isReapplyingLayout)
        manager.beginTermination()
    }
}
