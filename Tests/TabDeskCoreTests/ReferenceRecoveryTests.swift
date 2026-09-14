import Foundation
import Testing
@testable import TabDeskCore

@MainActor
struct ReferenceRecoveryTests {
    @Test func lostReferenceKeepsRegistrationAndSavedFrame() async throws {
        let driver = FakeWindowDriver()
        let frame = CGRect(x: 160, y: 40, width: 700, height: 500)
        let engine = TabEngine(driver: driver, layout: FixedScreenLayout(parkPoint: CGPoint(x: 1919, y: 1199), contentArea: frame))
        _ = engine.createTab(name: "Active")
        let tab = engine.createTab(name: "Inactive")
        driver.add(1, frame: frame)
        let window = try await engine.register(windowID: 1, pid: 100,
            identity: WindowIdentity(bundleID: "test", appName: "Test", title: "Document", registeredSize: frame.size), frame: frame, into: tab.id)
        #expect(engine.parkedWindowIDs.contains(window.id))
        engine.noteWindowReferenceLost(windowID: 1)
        let unbound = try #require(engine.state.managedWindow(id: window.id)?.window)
        #expect(!unbound.isBound && unbound.pid == nil)
        #expect(unbound.frame == frame && unbound.identity == window.identity)
        #expect(!engine.parkedWindowIDs.contains(window.id))
        await engine.reconcile(liveWindowIDs: [], livePIDs: [100])
        #expect(engine.state.managedWindow(id: window.id) != nil)
        let data = try JSONEncoder().encode(engine.state)
        let decoded = try JSONDecoder().decode(WorkspaceState.self, from: data)
        #expect(decoded.managedWindow(id: window.id)?.window.frame == frame)
    }

    @Test func processExitUnbindsEvenWhenNoWindowsRemain() async throws {
        let driver = FakeWindowDriver()
        let frame = CGRect(x: 160, y: 40, width: 700, height: 500)
        let engine = TabEngine(driver: driver, layout: FixedScreenLayout(parkPoint: CGPoint(x: 1919, y: 1199), contentArea: frame))
        let tab = engine.createTab(name: "Active")
        driver.add(1, frame: frame)
        let window = try await engine.register(windowID: 1, pid: 100,
            identity: WindowIdentity(bundleID: "test", appName: "Test", title: "Document", registeredSize: frame.size), frame: frame, into: tab.id)
        await engine.reconcile(liveWindowIDs: [], livePIDs: [])
        let saved = try #require(engine.state.managedWindow(id: window.id)?.window)
        #expect(!saved.isBound && saved.frame == frame)
    }
    @Test(arguments: [false, true]) func ignoredTabRestoreNeverSavesParkedCoordinates(ignoresPosition: Bool) async throws {
        let driver = FakeWindowDriver()
        let frame = CGRect(x: 160, y: 40, width: 700, height: 500)
        let engine = TabEngine(driver: driver, layout: FixedScreenLayout(parkPoint: CGPoint(x: 1919, y: 1199), contentArea: frame))
        let active = engine.createTab(name: "Active")
        let inactive = engine.createTab(name: "Inactive")
        driver.add(1, frame: frame)
        let window = try await engine.register(windowID: 1, pid: 100,
            identity: WindowIdentity(bundleID: "test", appName: "Test", title: "Document", registeredSize: frame.size), frame: frame, into: inactive.id)
        driver.ignoreReleasePosition(1, alsoPositionWrites: ignoresPosition)
        let report = try await engine.activate(inactive.id)
        #expect(report.failures.count == (ignoresPosition ? 1 : 0))
        #expect(engine.state.managedWindow(id: window.id)?.window.frame == frame)
        #expect(engine.parkedWindowIDs.contains(window.id) == ignoresPosition)
        if !ignoresPosition { #expect(driver.currentFrame(1) == frame) }
        _ = try await engine.activate(active.id)
        #expect(engine.state.managedWindow(id: window.id)?.window.frame == frame)
    }
}
