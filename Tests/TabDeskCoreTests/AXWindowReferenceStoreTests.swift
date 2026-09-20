import ApplicationServices
import Foundation
import Testing
@testable import TabDeskCore

@MainActor
struct AXWindowReferenceStoreTests {
    // AX参照の比較はアプリ要素でも検証でき、外部アプリの権限やGUIに依存しない。
    @Test func equalReferencesKeepIdentityAcrossEnumerations() throws {
        let store = AXWindowReferenceStore()
        let session = store.beginProcess(pid: getpid())
        let first = AXUIElementCreateApplication(getpid())
        let second = AXUIElementCreateApplication(getpid())
        #expect(CFEqual(first, second))
        let id = try store.referenceID(for: first, in: session)
        #expect(try store.referenceID(for: second, in: session) == id)
        #expect(store.existingID(for: second, in: session) == id)
    }

    @Test func retiredSessionCannotIdentifyNewProcess() throws {
        let store = AXWindowReferenceStore()
        let element = AXUIElementCreateApplication(getpid())
        let old = store.beginProcess(pid: getpid())
        let oldID = try store.referenceID(for: element, in: old)
        let current = store.beginProcess(pid: getpid())
        let currentID = try store.referenceID(for: element, in: current)
        #expect(oldID != currentID)
        #expect(store.existingID(for: element, in: old) == nil)
        #expect(store.element(for: oldID, in: current) == nil)
        #expect(throws: AXWindowReferenceStore.StoreError.staleSession) {
            try store.referenceID(for: element, in: old)
        }
        store.endProcess(old)
        store.forget(currentID, in: old)
        #expect(store.element(for: currentID, in: current) != nil)
    }

    @Test func rejectsReferenceFromAnotherProcess() {
        let store = AXWindowReferenceStore()
        let session = store.beginProcess(pid: getpid())
        #expect(throws: AXWindowReferenceStore.StoreError.processMismatch) {
            try store.referenceID(for: AXUIElementCreateApplication(getppid()), in: session)
        }
    }

    @Test func unknownNotificationDoesNotAllocateIdentity() {
        let store = AXWindowReferenceStore()
        let session = store.beginProcess(pid: getpid())
        #expect(store.existingID(for: AXUIElementCreateApplication(getpid()), in: session) == nil)
    }

    @Test func forgottenReferenceGetsNewIdentity() throws {
        let store = AXWindowReferenceStore()
        let session = store.beginProcess(pid: getpid())
        let element = AXUIElementCreateApplication(getpid())
        let original = try store.referenceID(for: element, in: session)
        store.forget(original, in: session)
        #expect(store.element(for: original, in: session) == nil)
        #expect(try store.referenceID(for: element, in: session) != original)
    }

    @Test func endingOneProcessDoesNotDiscardAnother() throws {
        let store = AXWindowReferenceStore()
        let first = store.beginProcess(pid: getpid())
        let second = store.beginProcess(pid: getppid())
        let element = AXUIElementCreateApplication(getppid())
        let id = try store.referenceID(for: element, in: second)
        store.endProcess(first)
        #expect(store.element(for: id, in: second) != nil)
        store.endProcess(second)
        #expect(store.element(for: id, in: second) == nil)
    }
    @Test func concurrentEnumerationAllocatesOneIdentity() async throws {
        let store = AXWindowReferenceStore()
        let session = store.beginProcess(pid: getpid())
        let ids = try await withThrowingTaskGroup(of: WindowReferenceID.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    try store.referenceID(for: AXUIElementCreateApplication(getpid()), in: session)
                }
            }
            var ids: Set<WindowReferenceID> = []
            for try await id in group { ids.insert(id) }
            return ids
        }
        #expect(ids.count == 1)
    }
    @Test func kernelStartDateIsStableWithoutLaunchServicesMetadata() throws {
        let date = try #require(AXWindowReferenceStore.readKernelStartDate(getpid()))
        #expect(date <= Date())
        #expect(AXWindowReferenceStore.readKernelStartDate(getpid()) == date)
        #expect(AXWindowReferenceStore.readKernelStartDate(-1) == nil)
        let store = AXWindowReferenceStore(processStartDate: AXWindowReferenceStore.readKernelStartDate)
        let session = try store.session(for: getpid())
        #expect(store.isCurrent(session))
    }

    @Test func processRestartInvalidatesReferencesAndIgnoresDelayedTermination() throws {
        let clock = ProcessDate(Date(timeIntervalSince1970: 100))
        let store = AXWindowReferenceStore(processStartDate: { _ in clock.read() })
        let old = try store.session(for: getpid())
        let id = try store.referenceID(for: AXUIElementCreateApplication(getpid()), in: old)
        #expect(try store.session(for: getpid()) == old)
        clock.set(Date(timeIntervalSince1970: 200))
        #expect(store.hasEnded(old))
        let current = try store.session(for: getpid())
        #expect(current != old)
        #expect(!store.isCurrent(old))
        #expect(store.element(for: id, in: old) == nil)
        store.endProcess(pid: getpid(), launchDate: Date(timeIntervalSince1970: 100))
        store.endProcess(pid: getpid(), launchDate: nil)
        #expect(store.isCurrent(current))
    }

    @Test func missingStartDateRefusesAccessWithoutDiscardingReferences() throws {
        let clock = ProcessDate(Date(timeIntervalSince1970: 100))
        let store = AXWindowReferenceStore(processStartDate: { _ in clock.read() })
        let session = try store.session(for: getpid())
        let id = try store.referenceID(for: AXUIElementCreateApplication(getpid()), in: session)
        clock.set(nil)
        #expect(throws: AXWindowReferenceStore.StoreError.processUnavailable) {
            try store.session(for: getpid())
        }
        #expect(!store.isCurrent(session))
        #expect(store.element(for: id, in: session) != nil)
        clock.set(Date(timeIntervalSince1970: 100))
        #expect(store.isCurrent(session))
    }

}


private final class ProcessDate: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date?
    init(_ date: Date?) { self.date = date }
    func read() -> Date? { lock.lock(); defer { lock.unlock() }; return date }
    func set(_ date: Date?) { lock.lock(); defer { lock.unlock() }; self.date = date }
}
