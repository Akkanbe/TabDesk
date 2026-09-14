import CoreGraphics
import Foundation
import Testing
@testable import TabDeskCore

@MainActor
struct WindowRecoveryTests {
    @Test(arguments: [TabLayout.free, .tiled], [false, true])
    func failedShutdownCanRecoverThroughSavedRegistration(layout: TabLayout, ignoresPosition: Bool) async throws {
        let area = CGRect(x: 160, y: 34, width: 1000, height: 800)
        let screens = FixedScreenLayout(parkPoint: CGPoint(x: 1159, y: 899), contentArea: area)
        let driver = FakeWindowDriver()
        let original = TabEngine(driver: driver, layout: screens)
        _ = original.createTab(name: "Active")
        let tab = original.createTab(name: "Recovery", layout: layout)
        let identity = WindowIdentity(bundleID: "test.app", appName: "Test", title: "Document", registeredSize: area.size)
        driver.add(1, frame: area)
        let window = try await original.register(windowID: 1, pid: 100, identity: identity, frame: area, into: tab.id)
        let before = original.state
        if ignoresPosition {
            driver.ignoreReleasePosition(1, alsoPositionWrites: true)
        } else {
            driver.configureRelease(1, fails: true)
            driver.setFailWrites(1)
        }
        await original.releaseAllParkedWindows()
        #expect(original.state == before)
        #expect(original.parkedWindowIDs.contains(window.id))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
        try store.save(original.state)
        let saved = try #require(try store.load())
        #expect(saved.allWindows.allSatisfy { !$0.isBound })

        // 新しい参照で実窓を列挙できるようになった再起動を模す。古い ID に依存しない。
        let recoveredDriver = FakeWindowDriver()
        recoveredDriver.add(2, frame: try #require(driver.currentFrame(1)))
        let restarted = TabEngine(driver: recoveredDriver, layout: screens, initialState: saved)
        let candidate = WindowMatcher.Candidate(windowID: 2, pid: 100, bundleID: identity.bundleID,
                                                title: identity.title, size: area.size)
        let matches = WindowMatcher.match(unbound: saved.allWindows, candidates: [candidate], strictness: .strict)
        #expect(matches.count == 1)
        let match = try #require(matches.first)
        try await restarted.bind(match.managedID, windowID: candidate.windowID, pid: candidate.pid, identity: identity)
        #expect(restarted.parkedWindowIDs.contains(window.id))
        _ = try await restarted.activate(tab.id)
        #expect(recoveredDriver.currentFrame(2) == area)
        #expect(restarted.state.tab(withID: tab.id)?.tiles == saved.tab(withID: tab.id)?.tiles)

        #expect(try await restarted.unregister(window.id) == 2)
        #expect(restarted.state.allWindows.isEmpty)
        #expect(recoveredDriver.currentFrame(2) == area)
        await restarted.releaseAllParkedWindows()
        #expect(recoveredDriver.currentFrame(2) == area)
    }

    @Test func ambiguousSearchKeepsRegistrationForManualAssignment() async throws {
        let area = CGRect(x: 160, y: 34, width: 1000, height: 800)
        let identity = WindowIdentity(bundleID: "test.app", appName: "Test", title: "Document", registeredSize: area.size)
        let window = ManagedWindow(frame: area, identity: identity, windowID: nil, pid: nil)
        let candidates = [1, 2].map {
            WindowMatcher.Candidate(windowID: WindowReferenceID(integerLiteral: UInt32($0)), pid: 100, bundleID: identity.bundleID,
                                    title: identity.title, size: area.size)
        }
        #expect(WindowMatcher.match(unbound: [window], candidates: candidates, strictness: .strict).isEmpty)
        let driver = FakeWindowDriver()
        let tab = Tab(name: "Recovery", windows: [window])
        let engine = TabEngine(driver: driver, layout: FixedScreenLayout(parkPoint: CGPoint(x: 1159, y: 899), contentArea: area),
                               initialState: WorkspaceState(tabs: [tab], activeTabID: tab.id))
        let offscreen = CGRect(x: 1159, y: 899, width: 1000, height: 800)
        driver.add(1, frame: offscreen)
        driver.add(2, frame: offscreen)
        try await engine.bind(window.id, windowID: 2, pid: 100, identity: identity)
        #expect(engine.state.allWindows.count == 1)
        #expect(engine.state.managedWindow(id: window.id)?.window.windowID == 2)
        #expect(driver.currentFrame(2) == area)
        #expect(driver.currentFrame(1) == offscreen)
    }
}
