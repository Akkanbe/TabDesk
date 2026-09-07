import AppKit
import Testing
import TabDeskCore
@testable import TabDesk

@MainActor
struct TilePlacementIssuesTests {
    @Test func issuesFollowWindowIDsAndCurrentDraftAssignments() throws {
        let a = UUID(), b = UUID()
        let partition = TilePartition.columns([a, b])
        let identity = WindowIdentity(bundleID: "test.app", appName: "Test", title: "Same Title", registeredSize: .zero)
        let first = ManagedWindow(frame: .zero, identity: identity, windowID: nil, pid: nil, tileID: a)
        let second = ManagedWindow(frame: .zero, identity: identity, windowID: nil, pid: nil, tileID: b)
        let tab = Tab(name: "Issues", windows: [first, second], layout: .tiled, tiles: partition)
        let assignments = [first.id: b, second.id: a]
        let issues = TilePlacementIssue.items(tab: tab, failedWindowIDs: [first.id, UUID()],
                                              partition: partition, assignments: assignments)
        #expect(issues.count == 1)
        #expect(issues.first?.windowID == first.id)
        #expect(issues.first?.tileID == b && issues.first?.tileNumber == 2)
        #expect(issues.first?.windowName == "Test — Same Title")
        let afterRemoval = TilePlacementIssue.items(tab: Tab(name: "Issues", windows: [second]), failedWindowIDs: [first.id],
                                                    partition: partition, assignments: assignments)
        #expect(afterRemoval.isEmpty)
    }

    @Test func issueSelectionSurvivesTranslationAndRecoveryRemovesRows() throws {
        _ = NSApplication.shared
        let issues = [TilePlacementIssue(windowID: UUID(), tileID: UUID(), tileNumber: 1, windowName: "App — Document"),
                      TilePlacementIssue(windowID: UUID(), tileID: UUID(), tileNumber: 2, windowName: "App — Document")]
        let view = TilePlacementIssuesView()
        var selected: UUID?
        view.onSelectWindow = { selected = $0 }
        L10n.$languageOverride.withValue(.japanese) { view.update(issues, canSelect: true) }
        #expect(!view.isHidden && view.picker.numberOfItems == 2)
        view.picker.selectItem(at: 1)
        L10n.$languageOverride.withValue(.english) { view.update(issues, canSelect: true) }
        #expect(view.picker.selectedItem?.title == "Tile 2 — App — Document")
        view.selectButton.performClick(nil)
        #expect(selected == issues[1].windowID)
        view.update([issues[0]], canSelect: false)
        #expect(!view.selectButton.isEnabled)
        view.selectButton.performClick(nil)
        #expect(selected == issues[1].windowID)
        view.update([issues[0]], canSelect: true)
        view.selectButton.performClick(nil)
        #expect(selected == issues[0].windowID)
        view.update([], canSelect: true)
        #expect(view.isHidden && view.picker.numberOfItems == 0 && !view.selectButton.isEnabled)
    }

    @Test(arguments: AppLanguage.allCases, [false, true]) func issueControlsFitMinimumEditorSize(language: AppLanguage, dark: Bool) throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StateStore(fileURL: directory.appendingPathComponent("state.json"))
        let partition = TilePartition.columns([UUID(), UUID()])
        let windows = partition.tileIDs.map { tileID in
            ManagedWindow(frame: .zero,
                          identity: WindowIdentity(bundleID: "test.app", appName: "Example App", title: String(repeating: "Long Document ", count: 30), registeredSize: .zero),
                          windowID: nil, pid: nil, tileID: tileID)
        }
        let tab = Tab(name: "Layout", windows: windows, layout: .tiled, tiles: partition)
        try store.save(WorkspaceState(tabs: [tab], activeTabID: tab.id))
        let manager = WindowManager(logger: FileLogger(fileURL: directory.appendingPathComponent("test.log")), store: store, monitoringEnabled: false)
        let editor = TileEditorController(manager: manager, tabID: tab.id)
        defer { editor.close() }
        let window = try #require(editor.window)
        window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let issues = TilePlacementIssue.items(tab: tab, failedWindowIDs: windows.map(\.id), partition: partition, assignments: tab.tileAssignments)
        L10n.$languageOverride.withValue(language) {
            editor.refreshLocalization()
            editor.placementIssues.update(issues, canSelect: true)
        }
        let content = try #require(window.contentView)
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(white: dark ? 0.13 : 0.95, alpha: 1).cgColor
        content.layoutSubtreeIfNeeded()
        func check(_ view: NSView) {
            for child in view.subviews where !child.isHidden {
                if child is NSButton || child is NSPopUpButton { #expect(content.bounds.contains(child.convert(child.bounds, to: content))) }
                check(child)
            }
        }
        check(content)
        #expect(editor.canvas.bounds.height >= 240)
        #expect(!editor.placementIssues.picker.frame.intersects(editor.placementIssues.selectButton.frame))
        if let base = ProcessInfo.processInfo.environment["TABDESK_TILE_PREVIEW_PATH"] {
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "\(base)-issues-\(language.rawValue)-\(dark ? "dark" : "light").png"))
        }
        let original = manager.engine.state
        editor.placementIssues.picker.selectItem(at: 1)
        editor.placementIssues.selectButton.performClick(nil)
        #expect(editor.canvas.selected == windows[1].tileID)
        #expect(manager.engine.state == original && !editor.canUndo)
    }
}
