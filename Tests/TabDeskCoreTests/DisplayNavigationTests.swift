import CoreGraphics
import Foundation
import Testing
@testable import TabDeskCore

private func display(_ id: String, x: CGFloat, y: CGFloat = 0) -> DisplayLayout {
    let frame = CGRect(x: x, y: y, width: 1000, height: 800)
    return DisplayLayout(id: id, frame: frame, contentArea: frame, parkPoint: CGPoint(x: 4000, y: 900))
}

struct DisplayNavigationTests {
    private let screens = [display("right", x: 1000), display("bottom", x: 0, y: 800), display("top", x: 0)]

    @Test func spatialOrderWrapsAndDisconnectedScreensAreExcluded() {
        #expect(DisplayNavigation.adjacent(to: "top", offset: 1, displays: screens) == "bottom")
        #expect(DisplayNavigation.adjacent(to: "bottom", offset: 1, displays: screens) == "right")
        #expect(DisplayNavigation.adjacent(to: "top", offset: -1, displays: screens) == "right")
        #expect(DisplayNavigation.adjacent(to: "right", offset: 1, displays: screens) == "top")
        #expect(DisplayNavigation.adjacent(to: "top", offset: 1, displays: [screens[2]]) == nil)
        #expect(DisplayNavigation.adjacent(to: nil, offset: 1, displays: []) == nil)
    }

    @Test func selectionSurvivesOldFocusAndMouseButFollowsRealWindowChanges() {
        var selection = DisplayNavigation()
        let old = DisplayNavigation.Focus(pid: 10, displayID: "top")
        let target = DisplayNavigation.Focus(pid: 10, displayID: "right")
        selection.select("right", focus: old)
        #expect(selection.resolve(fallback: "top", focus: old, displays: screens, busy: false) == "right")
        #expect(selection.resolve(fallback: "top", focus: target, displays: screens, busy: true) == "right")
        selection.completed(focus: target)
        #expect(selection.resolve(fallback: "top", focus: target, displays: screens, busy: false) == "right")
        #expect(selection.resolve(fallback: "top", focus: old, displays: screens, busy: false) == "top")
        let firstWindow = DisplayNavigation.Focus(pid: 10, displayID: "top", windowID: 1)
        let anotherWindow = DisplayNavigation.Focus(pid: 10, displayID: "top", windowID: 2)
        selection.select("right", focus: firstWindow)
        #expect(selection.resolve(fallback: "top", focus: anotherWindow, displays: screens, busy: false) == "top")
        selection.select("right", focus: old)
        #expect(selection.resolve(fallback: "top", focus: old, displays: [screens[2]], busy: true) == "top")
    }

    @Test func oldSettingsGetNewDefaultsAndNullStaysDisabled() throws {
        let old = try JSONDecoder().decode(HotkeyConfig.self, from: Data("{}".utf8))
        #expect(old.nextDisplay == "ctrl+alt+right")
        #expect(old.previousDisplay == "ctrl+alt+left")
        var disabled = old
        disabled.nextDisplay = nil
        disabled.previousDisplay = nil
        #expect(try JSONDecoder().decode(HotkeyConfig.self, from: JSONEncoder().encode(disabled)) == disabled)
        var duplicate = old
        duplicate.nextDisplay = old.nextTab
        #expect(duplicate.resolve().errors.count == 1)
    }
}

@MainActor
struct DisplayWindowFocusTests {
    @Test(arguments: [false, true])
    func failedRestorationDoesNotFocusAParkedWindow(hasVisibleAlternative: Bool) async throws {
        let driver = FakeWindowDriver()
        let engine = TabEngine(driver: driver, layout: FixedScreenLayout(displays: [display("main", x: 0)]))
        let target = engine.createTab(name: "Target", on: "main")
        let other = engine.createTab(name: "Other", on: "main")
        let frame = CGRect(x: 100, y: 100, width: 300, height: 200)
        driver.add(1, frame: frame)
        let managed = try await engine.register(windowID: 1, pid: 100, identity: WindowIdentity(
            bundleID: "test", appName: "Test", title: "Test", registeredSize: frame.size), frame: frame, into: target.id)
        if hasVisibleAlternative {
            driver.add(2, frame: frame)
            _ = try await engine.register(windowID: 2, pid: 200, identity: WindowIdentity(
                bundleID: "test.other", appName: "Other", title: "Other", registeredSize: frame.size), frame: frame, into: target.id)
        }
        engine.noteWindowFocused(windowID: 1)
        try await engine.activate(other.id)
        driver.setFailWrites(1)
        var activatedPIDs: [pid_t] = []
        engine.activateApplication = { pid, _ in activatedPIDs.append(pid) }
        let report = try await engine.activate(target.id)
        #expect(!report.failures.isEmpty)
        #expect(engine.parkedWindowIDs.contains(managed.id))
        #expect(activatedPIDs == (hasVisibleAlternative ? [200] : []))
        driver.setFailWrites(1, false)
        activatedPIDs.removeAll()
        let before = driver.callLog().count
        #expect(try await engine.focusActiveWindow(on: "main") == hasVisibleAlternative)
        #expect(activatedPIDs == (hasVisibleAlternative ? [200] : []))
        #expect(!driver.callLog().dropFirst(before).contains("raise:1"))
    }

    @Test func focusPreservesLayoutAndSkipsUnavailableWindows() async throws {
        let driver = FakeWindowDriver()
        let engine = TabEngine(driver: driver, layout: FixedScreenLayout(displays: [display("left", x: 0), display("right", x: 1000)]))
        let tab = engine.createTab(name: "Work", on: "right")
        for id: WindowReferenceID in [1, 2] {
            let frame = CGRect(x: 1100, y: 100, width: 300, height: 200)
            driver.add(id, frame: frame)
            _ = try await engine.register(windowID: id, pid: 100, identity: WindowIdentity(
                bundleID: "test", appName: "Test", title: "\(id)", registeredSize: frame.size), frame: frame, into: tab.id)
        }
        engine.noteWindowFocused(windowID: 2)
        let state = engine.state
        let before = driver.calls.count
        var activated: [DisplayID?] = []
        engine.activateApplication = { _, screen in activated.append(screen) }
        #expect(try await engine.focusActiveWindow(on: "right"))
        #expect(driver.calls.last == "raise:2")
        #expect(engine.state == state)
        #expect(!driver.calls.dropFirst(before).contains { $0.hasPrefix("set") })
        #expect(activated == ["right"])
        driver.setRaiseFails(2)
        #expect(try await engine.focusActiveWindow(on: "right"))
        #expect(driver.calls.last == "raise:1")
        driver.setRaiseFails(2, false)
        driver.setMinimized(2)
        #expect(try await engine.focusActiveWindow(on: "right"))
        #expect(driver.calls.last == "raise:1")
        driver.setFullscreenReadFails(1)
        #expect(try await !engine.focusActiveWindow(on: "right"))
        driver.setFullscreenReadFails(1, false)
        driver.setFullscreen(1)
        #expect(try await !engine.focusActiveWindow(on: "right"))
        #expect(try await !engine.focusActiveWindow(on: "disconnected"))
        let empty = engine.createTab(name: "Empty", on: "left")
        #expect(engine.activeTabID(on: "left") == empty.id)
        #expect(try await !engine.focusActiveWindow(on: "left"))
    }
}
