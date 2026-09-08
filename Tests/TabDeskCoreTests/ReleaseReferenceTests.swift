import CoreGraphics
import Foundation
import Testing
@testable import TabDeskCore

@MainActor
struct ReleaseReferenceTests {
    @Test(arguments: [false, true]) func shutdownDoesNotSaveParkedPositionAsSuccessfulRestore(ignoresPosition: Bool) async throws {
        let driver = FakeWindowDriver()
        let frame = CGRect(x: 240, y: 40, width: 600, height: 400)
        let engine = TabEngine(driver: driver, layout: FixedScreenLayout(parkPoint: CGPoint(x: 1919, y: 1199),
                                                                        contentArea: CGRect(x: 240, y: 30, width: 1680, height: 1090)))
        _ = engine.createTab(name: "Active")
        let tab = engine.createTab(name: "Inactive")
        driver.add(1, frame: frame)
        let window = try await engine.register(windowID: 1, pid: 100,
                                               identity: WindowIdentity(bundleID: "test", appName: "Test", title: "Test", registeredSize: frame.size),
                                               frame: frame, into: tab.id)
        driver.ignoreReleasePosition(1, alsoPositionWrites: ignoresPosition)
        await engine.releaseAllParkedWindows()
        #expect(engine.state.managedWindow(id: window.id)?.window.frame == frame)
        #expect(engine.parkedWindowIDs.contains(window.id) == ignoresPosition)
        if !ignoresPosition { #expect(driver.currentFrame(1) == frame) }
    }

    @Test(arguments: [false, true]) func refreshedReferenceRestoresParkedWindow(preparationFails: Bool) async throws {
        let driver = FakeWindowDriver()
        let frame = CGRect(x: 240, y: 40, width: 600, height: 400)
        let engine = TabEngine(driver: driver, layout: FixedScreenLayout(parkPoint: CGPoint(x: 1919, y: 1199),
                                                                        contentArea: CGRect(x: 240, y: 30, width: 1680, height: 1090)))
        _ = engine.createTab(name: "Active")
        let tab = engine.createTab(name: "Inactive")
        driver.add(1, frame: frame)
        let window = try await engine.register(windowID: 1, pid: 100,
                                               identity: WindowIdentity(bundleID: "test", appName: "Test", title: "Test", registeredSize: frame.size),
                                               frame: frame, into: tab.id)
        driver.configureRelease(1, fails: preparationFails, repairsWrites: !preparationFails)
        driver.setFailWrites(1, !preparationFails)
        let original = engine.state
        await engine.releaseAllParkedWindows()
        #expect(driver.currentFrame(1) == frame)
        #expect(!engine.parkedWindowIDs.contains(window.id))
        #expect(engine.state == original)
        #expect(driver.callCount("prepareForRelease") == 1)
    }

    @Test(arguments: [false, true]) func onlyConfirmedClosureRemovesRuntimeBinding(closed: Bool) async throws {
        let driver = FakeWindowDriver()
        let frame = CGRect(x: 240, y: 40, width: 600, height: 400)
        let engine = TabEngine(driver: driver, layout: FixedScreenLayout(parkPoint: CGPoint(x: 1919, y: 1199),
                                                                        contentArea: CGRect(x: 240, y: 30, width: 1680, height: 1090)))
        _ = engine.createTab(name: "Active")
        let tab = engine.createTab(name: "Inactive")
        driver.add(1, frame: frame)
        let window = try await engine.register(windowID: 1, pid: 100,
                                               identity: WindowIdentity(bundleID: "test", appName: "Test", title: "Test", registeredSize: frame.size),
                                               frame: frame, into: tab.id)
        driver.configureRelease(1, status: closed ? .closed : .ready, fails: !closed)
        driver.setFailWrites(1)
        let writes = driver.callCount("setFrame")
        await engine.releaseAllParkedWindows()
        let saved = try #require(engine.state.managedWindow(id: window.id)?.window)
        #expect(saved.id == window.id && saved.frame == frame && saved.identity == window.identity)
        #expect(saved.isBound == !closed)
        #expect(engine.parkedWindowIDs.contains(window.id) == !closed)
        if closed { #expect(driver.callCount("setFrame") == writes) }
    }

    @Test func missingAXReferenceRequiresWindowServerConfirmation() {
        #expect(!AXWindowDriver.confirmedClosed(windowID: 1, pid: 100, windowInfo: nil))
        #expect(!AXWindowDriver.confirmedClosed(windowID: 1, pid: 100, windowInfo: [[kCGWindowNumber as String: NSNumber(value: 1)]]))
        #expect(!AXWindowDriver.confirmedClosed(windowID: 1, pid: 100, windowInfo: [
            [kCGWindowNumber as String: NSNumber(value: 1), kCGWindowOwnerPID as String: NSNumber(value: 100)]]))
        #expect(AXWindowDriver.confirmedClosed(windowID: 1, pid: 100, windowInfo: []))
        #expect(AXWindowDriver.confirmedClosed(windowID: 1, pid: 100, windowInfo: [
            [kCGWindowNumber as String: NSNumber(value: 1), kCGWindowOwnerPID as String: NSNumber(value: 200)]]))
    }
}
