import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
import TabDeskCore
@testable import TabDesk

@MainActor
struct HotkeyCenterTests {
    @Test func suspensionRestoresAppliedBindingsAndStopPreventsResurrection() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hotkeys.json")
        let config = HotkeyConfig(
            activateTab: ["ctrl+alt+1"], nextTab: nil, previousTab: nil,
            registerFocusedWindow: nil, toggleEditMode: nil, toggleSidebar: nil)
        try config.save(to: url)
        let ref = try #require(EventHotKeyRef(bitPattern: 1))
        var registrations: [Hotkey] = []
        var removals = 0
        let center = HotkeyCenter(
            logger: FileLogger(fileURL: directory.appendingPathComponent("log")), fileURL: url,
            registerKey: { hotkey, _ in registrations.append(hotkey); return (noErr, ref) },
            unregisterKey: { _ in removals += 1; return noErr })
        defer { center.stop() }
        #expect(center.reload().isEmpty)
        #expect(registrations.count == 1)
        #expect(center.suspendForRecording().isEmpty)
        #expect(removals == 1)
        // キャンセル時は、記録前に適用されていた割り当てを復帰させる。
        try HotkeyConfig.default.save(to: url)
        #expect(center.resumeAfterRecording().isEmpty)
        #expect(registrations.count == 2 && registrations[0] == registrations[1])
        #expect(center.resumeAfterRecording().isEmpty)
        #expect(registrations.count == 2)
        #expect(center.suspendForRecording().isEmpty)
        center.stop()
        #expect(center.resumeAfterRecording().isEmpty)
        #expect(!center.reload().isEmpty)
        #expect(registrations.count == 2)
    }

    @Test func failedUnregisterIsRetainedAndBlocksDuplicateRegistration() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hotkeys.json")
        try HotkeyConfig(
            activateTab: ["ctrl+alt+1"], nextTab: nil, previousTab: nil,
            registerFocusedWindow: nil, toggleEditMode: nil, toggleSidebar: nil).save(to: url)
        let ref = try #require(EventHotKeyRef(bitPattern: 1))
        var registered = 0
        var failRemoval = false
        var failRegistration = false
        let center = HotkeyCenter(
            logger: FileLogger(fileURL: directory.appendingPathComponent("log")), fileURL: url,
            registerKey: { _, _ in
                registered += 1
                return failRegistration ? (OSStatus(-9878), nil) : (noErr, ref)
            },
            unregisterKey: { _ in failRemoval ? OSStatus(-50) : noErr })
        defer { center.stop() }
        #expect(center.reload().isEmpty)
        failRemoval = true
        #expect(!center.suspendForRecording().isEmpty)
        #expect(!center.resumeAfterRecording().isEmpty)
        #expect(registered == 1)
        failRemoval = false
        #expect(center.reload().isEmpty)
        #expect(registered == 2)
        #expect(center.suspendForRecording().isEmpty)
        failRegistration = true
        #expect(!center.resumeAfterRecording().isEmpty)
    }
}
