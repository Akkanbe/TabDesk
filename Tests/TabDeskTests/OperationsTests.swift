import AppKit
import Foundation
import Testing
import TabDeskCore
@testable import TabDesk

@MainActor
struct PersistenceStatusTests {
    @Test func failedSaveNotifiesAndSuccessfulRetryClearsWarning() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        let manager = WindowManager(
            logger: FileLogger(fileURL: directory.appendingPathComponent("tests.log")),
            store: StateStore(fileURL: url), monitoringEnabled: false)
        var notifications: [String?] = []
        manager.onSaveStatusChanged = { notifications.append(manager.saveFailure) }
        defer { manager.onSaveStatusChanged = nil }
        // 書き込み先をディレクトリにして、権限やディスク容量に依存せず失敗させる。
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #expect(!manager.saveNow(scheduleRetry: false))
        #expect(manager.saveFailure != nil)
        #expect(manager.canRetrySave)
        try FileManager.default.removeItem(at: url)
        #expect(manager.saveNow(scheduleRetry: false))
        #expect(manager.saveFailure == nil)
        #expect(notifications.count == 2)
        #expect(try StateStore(fileURL: url).load() == manager.engine.state)
    }

    @Test func failedBackupBlocksWritesAndOffersNoRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        let original = Data("invalid JSON".utf8)
        try original.write(to: url)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("state.bak.json"), withIntermediateDirectories: true)
        let manager = WindowManager(
            logger: FileLogger(fileURL: directory.appendingPathComponent("tests.log")),
            store: StateStore(fileURL: url), monitoringEnabled: false)
        #expect(manager.saveFailure != nil)
        #expect(!manager.canRetrySave)
        #expect(!manager.saveNow(scheduleRetry: false))
        #expect(try Data(contentsOf: url) == original)
    }
}

@MainActor
struct HotkeySettingsTests {
    @Test func settingsControlsFitInsideWindow() throws {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let controller = HotkeySettingsController(configURL: url) { [] }
        controller.loadConfiguration()
        let content = try #require(controller.window?.contentView)
        controller.window?.appearance = NSAppearance(named: .aqua)
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(white: 0.95, alpha: 1).cgColor
        content.layoutSubtreeIfNeeded()
        for field in controller.fields {
            let rect = field.convert(field.bounds, to: content)
            #expect(rect.width >= 300 && rect.height >= 20)
            #expect(content.bounds.contains(rect))
        }
        func checkButtons(_ view: NSView) {
            for child in view.subviews {
                if child is NSButton { #expect(content.bounds.contains(child.convert(child.bounds, to: content))) }
                checkButtons(child)
            }
        }
        checkButtons(content)
        if let path = ProcessInfo.processInfo.environment["TABDESK_TEST_PREVIEW_PATH"] {
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path))
        }
    }

    @Test func invalidInputDoesNotSaveOrApplyAndDisabledFieldsRoundTrip() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("hotkeys.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try HotkeyConfig.default.save(to: url)
        let original = try Data(contentsOf: url)
        var applyCount = 0
        let controller = HotkeySettingsController(configURL: url) { applyCount += 1; return [] }
        controller.loadConfiguration()
        controller.fields[1].specification = controller.fields[0].specification
        controller.save()
        #expect(applyCount == 0)
        #expect(try Data(contentsOf: url) == original)
        #expect(controller.messageView.string.contains("重複"))
        controller.fields[1].specification = "invalid"
        controller.save()
        #expect(applyCount == 0)
        #expect(try Data(contentsOf: url) == original)
        controller.fields.forEach { $0.specification = "" }
        controller.fields[2].specification = " ctrl+alt+3 "
        controller.save()
        #expect(applyCount == 1)
        let config = try #require(try HotkeyConfig.load(from: url))
        #expect(config.resolve().bindings.map(\.1) == [.activateTab(3)])
        #expect(config.nextTab == nil && config.previousTab == nil)
        controller.loadConfiguration()
        #expect(controller.fields[2].specification == "ctrl+alt+3")
        #expect(controller.fields[9].specification.isEmpty)
    }

    @Test func unreadableConfigAndWriteFailureDoNotApply() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hotkeys.json")
        let original = Data("invalid JSON".utf8)
        try original.write(to: url)
        var applyCount = 0
        let controller = HotkeySettingsController(configURL: url) { applyCount += 1; return [] }
        controller.loadConfiguration()
        controller.save()
        #expect(applyCount == 0)
        #expect(try Data(contentsOf: url) == original)
        try FileManager.default.removeItem(at: url)
        controller.loadConfiguration()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        controller.save()
        #expect(applyCount == 0)
        #expect(controller.messageView.string.contains("保存できません"))
    }

    @Test func registrationWarningsAreVisibleAfterSaving() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hotkeys.json")
        let controller = HotkeySettingsController(configURL: url) { ["ctrl+tab：他アプリが使用中"] }
        controller.loadConfiguration()
        controller.save()
        #expect(try HotkeyConfig.load(from: url) == .default)
        #expect(controller.messageView.string.contains("一部を適用できません"))
        #expect(controller.messageView.string.contains("他アプリが使用中"))
    }
}
