import CoreGraphics
import Foundation
import Testing
@testable import TabDeskCore

@MainActor
struct TileCopyTests {
    @Test(arguments: AppLanguage.allCases, [false, true]) func copiesOnlyGeometryAndPreservesSource(language: AppLanguage, remote: Bool) async throws {
        let area = CGRect(x: 240, y: 30, width: 1680, height: 1090)
        let driver = FakeWindowDriver()
        let engine = TabEngine(driver: driver, layout: FixedScreenLayout(parkPoint: CGPoint(x: 1919, y: 1199), contentArea: area))
        let tab = engine.createTab(on: remote ? "disconnected" : nil)
        let original = try #require(tab.tiles)
        let split = try original.splitting(original.tileIDs[0], axis: .horizontal)
        let nested = try split.splitting(split.tileIDs[1], axis: .vertical).resizing(split.id, ratio: 0.37)
        try await engine.updateTiles(tab.id, partition: nested, assignments: [:], expected: original, expectedAssignments: [:])
        if !remote {
            driver.add(1, frame: area)
            try await engine.register(windowID: 1, pid: 100,
                                      identity: WindowIdentity(bundleID: "test", appName: "Test", title: "Document", registeredSize: area.size),
                                      frame: area, into: tab.id)
        }
        let source = try #require(engine.state.tab(withID: tab.id))
        let active = engine.state.activeTabIDs
        let calls = driver.totalCallCount()
        let copy = try L10n.$languageOverride.withValue(language) { try engine.duplicateTileLayout(tab.id) }
        #expect(copy.id != source.id && copy.displayID == source.displayID && copy.layout == .tiled)
        #expect(copy.windows.isEmpty && copy.lastFocusedWindowID == nil)
        #expect(engine.state.tabs[1].id == copy.id)
        #expect(engine.state.tab(withID: tab.id) == source && engine.state.activeTabIDs == active)
        #expect(driver.totalCallCount() == calls)
        let copied = try #require(copy.tiles)
        let oldGeometry = nested.geometry(in: area), newGeometry = copied.geometry(in: area)
        let oldIDs = Set(nested.tileIDs + oldGeometry.dividers.map(\.id))
        let newIDs = Set(copied.tileIDs + newGeometry.dividers.map(\.id))
        #expect(oldIDs.isDisjoint(with: newIDs))
        #expect(nested.tileIDs.compactMap { oldGeometry.tiles[$0] } == copied.tileIDs.compactMap { newGeometry.tiles[$0] })
        let modified = try copied.resizing(copied.id, ratio: 0.6)
        try await engine.updateTiles(copy.id, partition: modified, assignments: [:], expected: copied, expectedAssignments: [:])
        #expect(engine.state.tab(withID: source.id) == source)
        let store = StateStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("state.json"))
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.save(engine.state)
        let loaded = try #require(try store.load())
        #expect(loaded.tab(withID: copy.id)?.tiles == modified && loaded.tab(withID: copy.id)?.windows.isEmpty == true)
        #expect(loaded.tab(withID: source.id)?.tiles == nested)
        let again = try L10n.$languageOverride.withValue(language) { try engine.duplicateTileLayout(tab.id) }
        #expect(again.name == copy.name + " (2)")
    }

    @Test func rejectsFreeAndShutdownWithoutChangingState() throws {
        let engine = TabEngine(driver: FakeWindowDriver(), layout: FixedScreenLayout(parkPoint: .zero, contentArea: CGRect(x: 0, y: 0, width: 1000, height: 800)))
        let free = engine.createTab(name: "Free")
        let tiled = engine.createTab()
        let original = engine.state
        #expect(throws: TileEditError.self) { try engine.duplicateTileLayout(free.id) }
        engine.beginShutdown()
        #expect(throws: TabEngine.EngineError.self) { try engine.duplicateTileLayout(tiled.id) }
        #expect(engine.state == original)
    }
}
