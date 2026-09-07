import AppKit
import Testing
import TabDeskCore
@testable import TabDesk

@MainActor
struct TileHistoryTests {
    @MainActor private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manager: WindowManager
        let editor: TileEditorController

        init(withWindows: Bool = false) throws {
            _ = NSApplication.shared
            let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
            let tiles = TilePartition.columns([UUID(), UUID()])
            let windows = withWindows ? tiles.tileIDs.map { id in
                ManagedWindow(frame: .zero,
                              identity: WindowIdentity(bundleID: "test.app", appName: "Test", title: "Document", registeredSize: .zero),
                              windowID: nil, pid: nil, tileID: id)
            } : []
            let tab = Tab(name: "History", windows: windows, layout: .tiled, tiles: tiles)
            try store.save(WorkspaceState(tabs: [tab], activeTabID: tab.id))
            manager = WindowManager(logger: FileLogger(fileURL: directory.appendingPathComponent("test.log")),
                                    store: store, monitoringEnabled: false)
            editor = TileEditorController(manager: manager, tabID: tab.id)
        }

        func close() {
            editor.close()
            try? FileManager.default.removeItem(at: directory)
        }

        func control<T: NSControl>(_ type: T.Type, action: String) throws -> T {
            func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
            let content = try #require(editor.window?.contentView)
            return try #require(views(content).compactMap { $0 as? T }
                .first { $0.action == NSSelectorFromString(action) })
        }
    }

    @Test func splitMergeUndoRedoPreservesDraftAcrossNotificationsAndLanguageChanges() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let editor = fixture.editor
        let original = editor.partition
        let workspace = fixture.manager.engine.state
        editor.splitSelected(axis: .vertical)
        let split = editor.partition
        try fixture.control(NSButton.self, action: "mergeSelected").performClick(nil)
        #expect(editor.partition == original)
        editor.undoEdit()
        #expect(editor.partition == split)
        editor.undoEdit()
        #expect(editor.partition == original)
        #expect(!editor.hasChanges && !editor.canUndo && editor.canRedo)
        editor.refreshState()
        L10n.$languageOverride.withValue(.english) { editor.refreshLocalization() }
        #expect(editor.canRedo)
        editor.redoEdit()
        #expect(editor.partition == split)
        editor.redoEdit()
        #expect(editor.partition == original && !editor.canRedo)
        #expect(fixture.manager.engine.state == workspace)
        editor.undoEdit()
        editor.splitSelected(axis: .horizontal)
        #expect(!editor.canRedo)
    }

    @Test func assignmentSwapCanBeUndoneAndApplyOrReloadClearsHistory() async throws {
        let fixture = try Fixture(withWindows: true)
        defer { fixture.close() }
        let editor = fixture.editor
        let original = editor.assignments
        let workspace = fixture.manager.engine.state
        let windows = try #require(workspace.tab(withID: editor.tabID)?.windows)
        let picker = try fixture.control(NSPopUpButton.self, action: "assignWindow")
        #expect(picker.numberOfItems == windows.count + 1, "同名の窓も別々の選択肢として保持する")
        let item = try #require(picker.itemArray.first { $0.representedObject as? UUID == windows[1].id })
        picker.select(item)
        #expect(NSApp.sendAction(try #require(picker.action), to: picker.target, from: picker))
        let swapped = editor.assignments
        #expect(swapped[windows[0].id] == original[windows[1].id])
        #expect(swapped[windows[1].id] == original[windows[0].id])
        editor.undoEdit()
        #expect(editor.assignments == original)
        editor.refreshState()
        editor.redoEdit()
        #expect(editor.assignments == swapped)
        #expect(fixture.manager.engine.state == workspace)
        #expect(await editor.applyDraft())
        #expect(!editor.canUndo && !editor.canRedo)
        #expect(fixture.manager.engine.state.tab(withID: editor.tabID)?.tileAssignments == swapped)
        editor.splitSelected(axis: .vertical)
        editor.undoEdit()
        #expect(editor.canRedo)
        try fixture.control(NSButton.self, action: "reload").performClick(nil)
        #expect(!editor.canUndo && !editor.canRedo)
    }

    @Test func undoRedoCannotBypassExternalAssignmentConflict() async throws {
        let fixture = try Fixture(withWindows: true)
        defer { fixture.close() }
        let editor = fixture.editor
        let original = editor.partition
        let assignments = editor.assignments
        let windows = try #require(fixture.manager.engine.state.tab(withID: editor.tabID)?.windows)
        editor.splitSelected(axis: .vertical)
        let draft = editor.partition
        editor.undoEdit()
        try await fixture.manager.engine.updateTiles(editor.tabID, partition: original,
                                                     assignments: [windows[0].id: try #require(windows[1].tileID),
                                                                   windows[1].id: try #require(windows[0].tileID)],
                                                     expected: original, expectedAssignments: assignments)
        let current = fixture.manager.engine.state
        editor.refreshState()
        #expect(editor.canRedo)
        editor.redoEdit()
        #expect(editor.partition == draft)
        #expect(await editor.applyDraft() == false)
        #expect(editor.canUndo && editor.partition == draft)
        #expect(fixture.manager.engine.state == current)
    }
}
