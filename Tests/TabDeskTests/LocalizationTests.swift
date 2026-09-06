import AppKit
import Foundation
import Testing
import TabDeskCore
@testable import TabDesk

@MainActor
struct LocalizationUITests {
    @Test func languageSwitchPreservesUnsavedShortcutsAndRecording() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hotkeys.json")
        try HotkeyConfig.default.save(to: url)
        let original = try Data(contentsOf: url)
        var applied = 0
        var resumed = 0
        let controller = L10n.$languageOverride.withValue(.japanese) {
            HotkeySettingsController(configURL: url, resumeHotkeys: { resumed += 1; return [] }) {
                applied += 1; return []
            }
        }
        controller.loadConfiguration()
        controller.fields[0].specification = "ctrl+cmd+f12"
        controller.fields[1].specification = ""
        controller.beginRecording(at: 2)
        let values = controller.fields.map(\.specification)
        L10n.$languageOverride.withValue(.english) {
            controller.refreshLocalization()
            #expect(controller.window?.title == "Hotkey Settings")
            #expect(controller.fields[1].title == "Click to Record")
            #expect(controller.fields[2].title == "Press a shortcut…")
            #expect(controller.messageView.string.hasPrefix("Press a shortcut."))
        }
        #expect(controller.recordingIndex == 2)
        #expect(controller.fields.map(\.specification) == values)
        #expect(applied == 0 && resumed == 0)
        #expect(try Data(contentsOf: url) == original)
        L10n.$languageOverride.withValue(.japanese) {
            controller.refreshLocalization()
            #expect(controller.window?.title == "ホットキー設定")
            #expect(controller.fields[1].title == "クリックして設定")
        }
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        #expect(resumed == 1)
    }

    @Test func validationWarningChangesLanguageWithoutSaving() throws {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let controller = HotkeySettingsController(configURL: url) { Issue.record("Unexpected apply"); return [] }
        controller.loadConfiguration()
        controller.fields[1].specification = controller.fields[0].specification
        L10n.$languageOverride.withValue(.japanese) { controller.save() }
        #expect(controller.messageView.string.contains("重複"))
        L10n.$languageOverride.withValue(.english) { controller.refreshLocalization() }
        #expect(controller.messageView.string.contains("already assigned"))
        #expect(controller.messageView.textColor == .systemRed)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func sidebarRefreshPreservesWorkspaceAndPanel() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = FileLogger(fileURL: directory.appendingPathComponent("test.log"))
        let manager = WindowManager(logger: logger, store: StateStore(fileURL: directory.appendingPathComponent("state.json")), monitoringEnabled: false)
        let display = try #require(manager.layout.primaryDisplay)
        manager.engine.createTab(name: "仕事 / Work", on: display.id)
        let state = manager.engine.state
        let panel = SidebarPanel(manager: manager, logger: logger, displayID: display.id)
        defer { panel.close() }
        let content = try #require(panel.contentView)
        let frame = panel.frame
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let controls = views(content)
        L10n.$languageOverride.withValue(.english) { panel.refreshLocalization() }
        #expect(panel.contentView === content)
        #expect(panel.frame == frame)
        #expect(manager.engine.state == state)
        let englishButtons = controls.compactMap { ($0 as? NSButton)?.title }
        #expect(englishButtons.contains("＋ Add Window"))
        let labels = views(content).compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(labels.contains("仕事 / Work"))
        L10n.$languageOverride.withValue(.japanese) { panel.refreshLocalization() }
        let japaneseButtons = controls.compactMap { ($0 as? NSButton)?.title }
        #expect(japaneseButtons.contains("＋ ウィンドウを追加"))
        #expect(manager.engine.state == state)
    }
}
