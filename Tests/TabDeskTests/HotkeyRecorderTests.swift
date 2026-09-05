import AppKit
import Foundation
import Testing
import TabDeskCore
@testable import TabDesk

@MainActor
struct HotkeyRecorderTests {
    private func event(
        _ code: UInt16, flags: NSEvent.ModifierFlags = [], window: NSWindow, repeatKey: Bool = false
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "日本語", charactersIgnoringModifiers: "日本語", isARepeat: repeatKey, keyCode: code))
    }

    @Test func recordsPhysicalCombinationAndPersistsExistingFormat() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hotkeys.json")
        var suspended = 0
        var resumed = 0
        var applied = 0
        let controller = HotkeySettingsController(
            configURL: url,
            suspendHotkeys: { suspended += 1; return [] },
            resumeHotkeys: { resumed += 1; return [] }
        ) { applied += 1; return [] }
        controller.loadConfiguration()
        let window = try #require(controller.window)
        controller.beginRecording(at: 0)
        #expect(suspended == 1 && resumed == 0)
        #expect(controller.fields[0].isRecording)
        let key = try event(20, flags: [.control, .option, .shift, .command, .capsLock], window: window)
        #expect(controller.handleRecording(key) == nil)
        #expect(controller.fields[0].specification == "ctrl+alt+shift+cmd+3")
        #expect(controller.fields[0].title == "⌃⌥⇧⌘3")
        #expect(controller.recordingIndex == nil)
        #expect(resumed == 1 && applied == 0)
        controller.save()
        #expect(applied == 1)
        let config = try #require(try HotkeyConfig.load(from: url))
        #expect(config.activateTab[0] == "ctrl+alt+shift+cmd+3")
    }

    @Test func tabAndEscapeWithModifiersAreRecordedInsteadOfNavigating() throws {
        _ = NSApplication.shared
        let controller = HotkeySettingsController(configURL: URL(fileURLWithPath: "/unused/hotkeys.json")) { [] }
        controller.loadConfiguration()
        let window = try #require(controller.window)
        controller.beginRecording(at: 9)
        #expect(controller.handleRecording(try event(48, flags: [.control], window: window)) == nil)
        #expect(controller.fields[9].specification == "ctrl+tab")
        controller.beginRecording(at: 10)
        #expect(controller.handleRecording(try event(53, flags: [.command], window: window)) == nil)
        #expect(controller.fields[10].specification == "cmd+escape")
    }

    @Test func cancellationClearFocusLossAndCloseResumeExactlyOnce() throws {
        _ = NSApplication.shared
        var suspended = 0
        var resumed = 0
        let controller = HotkeySettingsController(
            configURL: URL(fileURLWithPath: "/unused/hotkeys.json"),
            suspendHotkeys: { suspended += 1; return [] },
            resumeHotkeys: { resumed += 1; return [] }
        ) { [] }
        controller.loadConfiguration()
        let window = try #require(controller.window)
        let original = controller.fields[0].specification
        controller.beginRecording(at: 0)
        #expect(controller.handleRecording(try event(53, window: window)) == nil)
        #expect(controller.fields[0].specification == original)
        controller.beginRecording(at: 0)
        #expect(controller.handleRecording(try event(51, window: window)) == nil)
        #expect(controller.fields[0].specification.isEmpty)
        controller.beginRecording(at: 1)
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
        controller.beginRecording(at: 2)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
        #expect(suspended == 4 && resumed == 4)
        #expect(controller.recordingIndex == nil)
    }

    @Test func bareUnknownAndRepeatedKeysDoNotOverwriteBinding() throws {
        _ = NSApplication.shared
        let controller = HotkeySettingsController(configURL: URL(fileURLWithPath: "/unused/hotkeys.json")) { [] }
        controller.loadConfiguration()
        let window = try #require(controller.window)
        let original = controller.fields[0].specification
        controller.beginRecording(at: 0)
        #expect(controller.handleRecording(try event(0, window: window)) == nil)
        #expect(controller.handleRecording(try event(0, flags: .command, window: window, repeatKey: true)) == nil)
        #expect(controller.handleRecording(try event(255, flags: .command, window: window)) == nil)
        #expect(controller.fields[0].specification == original)
        #expect(controller.recordingIndex == 0)
        let tab = try event(48, window: window)
        #expect(controller.handleRecording(tab) === tab)
        #expect(controller.recordingIndex == nil)
    }

    @Test func failureToSuspendDoesNotStartRecordingAndAttemptsRecovery() {
        _ = NSApplication.shared
        var resumed = 0
        let controller = HotkeySettingsController(
            configURL: URL(fileURLWithPath: "/unused/hotkeys.json"),
            suspendHotkeys: { ["simulated suspension failure"] },
            resumeHotkeys: { resumed += 1; return [] }
        ) { [] }
        controller.loadConfiguration()
        controller.beginRecording(at: 0)
        #expect(controller.recordingIndex == nil)
        #expect(resumed == 1)
        #expect(controller.messageView.string.contains("simulated suspension failure"))
    }
}
