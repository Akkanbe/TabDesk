import AppKit
import Foundation
import Testing
import TabDeskCore
@testable import TabDesk

@MainActor
struct TileEditorTests {
    @Test(arguments: AppLanguage.allCases, [false, true]) func editorFitsAndDraftDoesNotMoveWindowsUntilApply(language: AppLanguage, dark: Bool) async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = FileLogger(fileURL: directory.appendingPathComponent("test.log"))
        let manager = WindowManager(logger: logger, store: StateStore(fileURL: directory.appendingPathComponent("state.json")), monitoringEnabled: false)
        let tab = manager.engine.createTab()
        let original = manager.engine.state
        let editor = L10n.$languageOverride.withValue(language) { TileEditorController(manager: manager, tabID: tab.id) }
        defer { editor.close() }
        L10n.$languageOverride.withValue(language) {
            editor.splitSelected(axis: .horizontal)
            editor.splitSelected(axis: .vertical)
            editor.refreshLocalization()
        }
        #expect(editor.partition.tileIDs.count == 3)
        #expect(editor.hasChanges)
        #expect(manager.engine.state == original)
        let content = try #require(editor.window?.contentView)
        editor.window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(white: dark ? 0.13 : 0.95, alpha: 1).cgColor
        content.layoutSubtreeIfNeeded()
        func check(_ view: NSView) {
            for child in view.subviews {
                if child is NSButton || child is NSPopUpButton {
                    #expect(content.bounds.contains(child.convert(child.bounds, to: content)))
                }
                check(child)
            }
        }
        check(content)
        #expect(editor.canvas.bounds.height >= 240)
        if let base = ProcessInfo.processInfo.environment["TABDESK_TILE_PREVIEW_PATH"] {
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "\(base)-\(language.rawValue)-\(dark ? "dark" : "light").png"))
        }
        let applied = await L10n.$languageOverride.withValue(language) { await editor.applyDraft() }
        #expect(applied)
        #expect(!editor.hasChanges)
        #expect(manager.engine.state.tab(withID: tab.id)?.tiles == editor.partition)
        #expect(manager.engine.state.tab(withID: tab.id)?.windows.isEmpty == true)
    }

    @Test func dividerDragChangesOnlyRatioAndLanguageSwitchKeepsDraft() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = WindowManager(logger: FileLogger(fileURL: directory.appendingPathComponent("test.log")),
                                    store: StateStore(fileURL: directory.appendingPathComponent("state.json")), monitoringEnabled: false)
        let tab = manager.engine.createTab()
        let editor = TileEditorController(manager: manager, tabID: tab.id)
        defer { editor.close() }
        editor.splitSelected(axis: .horizontal)
        let window = try #require(editor.window)
        window.contentView?.layoutSubtreeIfNeeded()
        let canvas = editor.canvas
        let divider = try #require(canvas.partition.geometry(in: canvas.drawingArea).dividers.first)
        let start = canvas.convert(NSPoint(x: divider.position, y: divider.area.midY), to: nil)
        let end = canvas.convert(NSPoint(x: divider.area.minX + divider.area.width * 0.7, y: divider.area.midY), to: nil)
        func event(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let ids = editor.partition.tileIDs
        canvas.mouseDown(with: try event(.leftMouseDown, start))
        canvas.mouseDragged(with: try event(.leftMouseDragged, end))
        canvas.mouseUp(with: try event(.leftMouseUp, end))
        if case .split(_, _, let ratio, _, _) = editor.partition { #expect(abs(ratio - 0.7) < 0.01) }
        else { Issue.record("Expected split") }
        let draft = editor.partition
        L10n.$languageOverride.withValue(.english) { editor.refreshLocalization() }
        #expect(editor.partition == draft)
        #expect(editor.partition.tileIDs == ids)
        #expect(manager.engine.state.tab(withID: tab.id)?.tiles == tab.tiles)
    }
}
