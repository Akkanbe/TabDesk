import CoreGraphics
import Foundation
import Testing
@testable import TabDeskCore

struct TilePartitionTests {
    @Test(arguments: [false, true]) func preparingTilesPreservesExistingAssignmentsAfterEarlierUnassignedWindow(hasEmptyTile: Bool) throws {
        let occupiedID = UUID()
        let partition = hasEmptyTile
            ? try TilePartition.tile(occupiedID).splitting(occupiedID, axis: .horizontal)
            : .tile(occupiedID)
        let identity = WindowIdentity(bundleID: "test.app", appName: "Test", title: "Document", registeredSize: .zero)
        let added = ManagedWindow(frame: .zero, identity: identity, windowID: nil, pid: nil)
        let existing = ManagedWindow(frame: .zero, identity: identity, windowID: nil, pid: nil, tileID: occupiedID)
        var tab = Tab(name: "Saved", windows: [added, existing], layout: .tiled, tiles: partition)
        try tab.prepareTiles()
        #expect(tab.windows[1].tileID == occupiedID)
        #expect(tab.windows[0].tileID != occupiedID)
        #expect(tab.tiles?.tileIDs.count == 2)
        if hasEmptyTile { #expect(tab.tiles == partition) }
        let prepared = tab
        try tab.prepareTiles()
        #expect(tab == prepared)

        let saved = Tab(name: "Saved", windows: [added, existing], layout: .tiled, tiles: partition)
        let restored = try JSONDecoder().decode(Tab.self, from: JSONEncoder().encode(saved))
        #expect(restored.windows[1].tileID == occupiedID)
        #expect(restored.windows[0].tileID != occupiedID)
    }

    @Test func nestedPartitionsCoverAreaWithoutOverlapAfterResizing() throws {
        let a = UUID()
        var partition = try TilePartition.tile(a).splitting(a, axis: .horizontal)
        let b = try #require(partition.tileIDs.last)
        partition = try partition.splitting(b, axis: .vertical)
        partition = try partition.resizing(partition.id, ratio: 0.37)
        for area in [CGRect(x: 240, y: 30, width: 1681, height: 1091),
                     CGRect(x: 16, y: 30, width: 1905, height: 1091),
                     CGRect(x: -1900, y: -750, width: 1537, height: 981)] {
            let frames = Array(partition.geometry(in: area).tiles.values)
            #expect(frames.count == 3)
            #expect(frames.allSatisfy { area.contains($0) && $0.width > 0 && $0.height > 0 })
            #expect(abs(frames.reduce(0) { $0 + $1.width * $1.height } - area.width * area.height) < 0.01)
            for i in frames.indices {
                for j in frames.indices where i < j { #expect(frames[i].intersection(frames[j]).isEmpty) }
            }
        }
    }

    @Test func mergePreservesOccupiedIdentityAndRejectsTwoOccupiedTiles() throws {
        let a = UUID()
        let partition = try TilePartition.tile(a).splitting(a, axis: .horizontal)
        let b = try #require(partition.tileIDs.last)
        let merged = try partition.merging(b, occupied: [a])
        #expect(merged.partition == .tile(a))
        #expect(merged.selected == a)
        #expect(throws: TileEditError.self) { try partition.merging(a, occupied: [a, b]) }
        let nested = try partition.splitting(b, axis: .vertical)
        #expect(throws: TileEditError.self) { try nested.merging(a, occupied: []) }
    }

    @Test func rejectsInvalidGeometryAndLimitsPartitionComplexity() throws {
        let id = UUID()
        let duplicate = TilePartition.split(id: UUID(), axis: .horizontal, ratio: 0.5, first: .tile(id), second: .tile(id))
        #expect(throws: TileEditError.self) { try duplicate.validate() }
        let invalid = TilePartition.split(id: UUID(), axis: .vertical, ratio: .nan, first: .tile(UUID()), second: .tile(UUID()))
        #expect(throws: TileEditError.self) { try invalid.validate() }
        let full = TilePartition.columns((0..<64).map { _ in UUID() })
        try full.validate()
        #expect(throws: TileEditError.self) { try full.splitting(full.tileIDs[0], axis: .vertical) }
    }

    @Test func savedTilesAndUnboundAssignmentsSurviveRestartAndMigration() throws {
        let tileID = UUID()
        let partition = try TilePartition.tile(tileID).splitting(tileID, axis: .vertical)
        let window = ManagedWindow(frame: CGRect(x: 240, y: 30, width: 800, height: 450),
                                   identity: WindowIdentity(bundleID: "test.app", appName: "Test", title: "Document", registeredSize: .zero),
                                   windowID: 1, pid: 100, tileID: tileID)
        let tab = Tab(name: "Saved", windows: [window], layout: .tiled, tiles: partition)
        let original = WorkspaceState(tabs: [tab], activeTabID: tab.id)
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(WorkspaceState.self, from: data).migratedForPerDisplayTabs(primaryID: "fixed")
        #expect(restored.tabs[0].tiles == partition)
        #expect(restored.tabs[0].windows[0].tileID == tileID)
        #expect(!restored.tabs[0].windows[0].isBound)
        #expect(restored.tabs[0].tiles?.tileIDs.count == 2)
    }
}

@MainActor
struct ManualTileEngineTests {
    private let area = CGRect(x: 240, y: 30, width: 1680, height: 1000)
    private func makeEngine() -> (TabEngine, FakeWindowDriver) {
        let driver = FakeWindowDriver()
        let engine = TabEngine(driver: driver, layout: FixedScreenLayout(parkPoint: CGPoint(x: 1919, y: 1199), contentArea: area))
        return (engine, driver)
    }
    private func identity(_ n: Int) -> WindowIdentity {
        WindowIdentity(bundleID: "test.app", appName: "App", title: "Window \(n)", registeredSize: CGSize(width: 500, height: 400))
    }
    private func register(_ number: UInt32, engine: TabEngine, driver: FakeWindowDriver, tab: UUID, tile: UUID? = nil) async throws -> ManagedWindow {
        let frame = CGRect(x: 400, y: 100, width: 500, height: 400)
        driver.add(number, frame: frame)
        return try await engine.register(windowID: number, pid: 100, identity: identity(Int(number)), frame: frame, into: tab, tileID: tile)
    }

    @Test func newTabIsTiledAndFullTileRejectsAdditionalWindowBeforeMovingIt() async throws {
        let (engine, driver) = makeEngine()
        let tab = engine.createTab()
        #expect(tab.layout == .tiled)
        let first = try await register(1, engine: engine, driver: driver, tab: tab.id)
        #expect(first.frame == area)
        #expect(first.tileID == tab.tiles?.tileIDs.first)
        let frame = CGRect(x: 700, y: 200, width: 400, height: 300)
        driver.add(2, frame: frame)
        await #expect(throws: TileEditError.self) {
            try await engine.register(windowID: 2, pid: 100, identity: identity(2), frame: frame, into: tab.id)
        }
        #expect(driver.currentFrame(2) == frame)
        #expect(engine.state.tabs[0].windows.count == 1)
    }

    @Test func splitAssignSwapAndRemovalKeepEmptyTiles() async throws {
        let (engine, driver) = makeEngine()
        let tab = engine.createTab()
        let original = try #require(tab.tiles)
        let a = original.tileIDs[0]
        let split = try original.splitting(a, axis: .horizontal)
        let b = split.tileIDs[1]
        try await engine.updateTiles(tab.id, partition: split, assignments: [:], expected: original,
                                     expectedAssignments: engine.state.tab(withID: tab.id)?.tileAssignments ?? [:])
        let first = try await register(1, engine: engine, driver: driver, tab: tab.id, tile: b)
        let second = try await register(2, engine: engine, driver: driver, tab: tab.id, tile: a)
        let frames = split.geometry(in: area).tiles
        #expect(driver.currentFrame(1) == frames[b])
        #expect(driver.currentFrame(2) == frames[a])
        try await engine.updateTiles(tab.id, partition: split, assignments: [first.id: a, second.id: b], expected: split,
                                     expectedAssignments: engine.state.tab(withID: tab.id)?.tileAssignments ?? [:])
        #expect(driver.currentFrame(1) == frames[a])
        #expect(driver.currentFrame(2) == frames[b])
        _ = try await engine.unregister(first.id)
        #expect(engine.state.tabs[0].tiles == split)
        #expect(driver.currentFrame(2) == frames[b])
        let third = try await register(3, engine: engine, driver: driver, tab: tab.id)
        #expect(third.tileID == a)
    }

    @Test func rejectsStaleOrDuplicateAssignmentsWithoutChangingState() async throws {
        let (engine, driver) = makeEngine()
        let tab = engine.createTab()
        let original = try #require(tab.tiles)
        let a = original.tileIDs[0]
        let split = try original.splitting(a, axis: .horizontal)
        try await engine.updateTiles(tab.id, partition: split, assignments: [:], expected: original,
                                     expectedAssignments: engine.state.tab(withID: tab.id)?.tileAssignments ?? [:])
        let first = try await register(1, engine: engine, driver: driver, tab: tab.id)
        let second = try await register(2, engine: engine, driver: driver, tab: tab.id)
        let state = engine.state
        await #expect(throws: TileEditError.self) {
            try await engine.updateTiles(tab.id, partition: split, assignments: [first.id: a, second.id: a], expected: split,
                                     expectedAssignments: engine.state.tab(withID: tab.id)?.tileAssignments ?? [:])
        }
        await #expect(throws: TileEditError.self) {
            try await engine.updateTiles(tab.id, partition: split, assignments: [first.id: a, second.id: split.tileIDs[1]], expected: original,
                                     expectedAssignments: engine.state.tab(withID: tab.id)?.tileAssignments ?? [:])
        }
        #expect(engine.state == state)
    }

    @Test func modeSwitchPreservesPartitionAndUnboundSlot() async throws {
        let (engine, driver) = makeEngine()
        let tab = engine.createTab(name: "Existing Free")
        #expect(tab.layout == .free)
        let first = try await register(1, engine: engine, driver: driver, tab: tab.id)
        _ = try await register(2, engine: engine, driver: driver, tab: tab.id)
        try await engine.setTabLayout(tab.id, .tiled)
        let partition = try #require(engine.state.tabs[0].tiles)
        engine.noteWindowDestroyed(windowID: 1, appTerminated: true)
        #expect(engine.state.tabs[0].tiles == partition)
        #expect(engine.state.managedWindow(id: first.id)?.window.tileID == partition.tileIDs[0])
        try await engine.setTabLayout(tab.id, .free)
        try await engine.setTabLayout(tab.id, .tiled)
        #expect(engine.state.tabs[0].tiles == partition)
    }

    @Test func sidebarWidthChangeReflowsActiveAndInactiveTiles() async throws {
        let driver = FakeWindowDriver()
        let layout = MutableScreenLayout(parkPoint: CGPoint(x: 1919, y: 1199), contentArea: area)
        let engine = TabEngine(driver: driver, layout: layout)
        let tab = engine.createTab()
        let original = try #require(tab.tiles)
        let split = try original.splitting(original.tileIDs[0], axis: .horizontal)
        try await engine.updateTiles(tab.id, partition: split, assignments: [:], expected: original,
                                     expectedAssignments: engine.state.tab(withID: tab.id)?.tileAssignments ?? [:])
        let first = try await register(1, engine: engine, driver: driver, tab: tab.id)
        let second = try await register(2, engine: engine, driver: driver, tab: tab.id)
        let wider = CGRect(x: 16, y: 30, width: 1904, height: 1000)
        layout.change(parkPoint: CGPoint(x: 1919, y: 1199), contentArea: wider)
        await engine.reapplyLayout()
        let frames = split.geometry(in: wider).tiles
        #expect(driver.currentFrame(1) == frames[first.tileID!])
        #expect(driver.currentFrame(2) == frames[second.tileID!])
        let other = engine.createTab(name: "Other")
        _ = try await engine.activate(other.id)
        layout.change(parkPoint: CGPoint(x: 1919, y: 1199), contentArea: area)
        await engine.reapplyLayout()
        #expect(engine.state.managedWindow(id: first.id)?.window.frame == split.geometry(in: area).tiles[first.tileID!])
        _ = try await engine.activate(tab.id)
        #expect(driver.currentFrame(1) == split.geometry(in: area).tiles[first.tileID!])
        #expect(engine.state.tab(withID: tab.id)?.tiles == split)
    }

    @Test func tileEditsPreserveFullscreenAndDisconnectedWindows() async throws {
        let driver = FakeWindowDriver()
        let layout = MutableScreenLayout(parkPoint: CGPoint(x: 1919, y: 1199), contentArea: area)
        let displays = layout.displays
        let engine = TabEngine(driver: driver, layout: layout)
        let tab = engine.createTab(on: displays[0].id)
        let window = try await register(1, engine: engine, driver: driver, tab: tab.id)
        let original = try #require(tab.tiles)
        let split = try original.splitting(original.tileIDs[0], axis: .horizontal)
        driver.setFullscreen(1)
        await engine.reconcile(liveWindowIDs: [1], livePIDs: [100])
        let fullscreenFrame = driver.currentFrame(1)
        try await engine.updateTiles(tab.id, partition: split, assignments: [window.id: original.tileIDs[0]], expected: original,
                                     expectedAssignments: engine.state.tab(withID: tab.id)?.tileAssignments ?? [:])
        #expect(driver.currentFrame(1) == fullscreenFrame)
        #expect(engine.tilePlacementFailures(in: tab.id).isEmpty)
        let recorded = engine.state.managedWindow(id: window.id)?.window.frame
        layout.change(displays: [])
        await engine.reapplyLayout()
        #expect(engine.state.managedWindow(id: window.id)?.window.frame == recorded)
        #expect(driver.currentFrame(1) == fullscreenFrame)
        driver.setFullscreen(1, false)
        layout.change(displays: displays)
        await engine.reconcile(liveWindowIDs: [1], livePIDs: [100])
        await engine.reapplyLayout()
        #expect(driver.currentFrame(1) == split.geometry(in: area).tiles[original.tileIDs[0]])
        #expect(engine.state.tab(withID: tab.id)?.tiles == split)
    }

    @Test func failedPlacementIsVisibleAndSuccessfulRetryClearsWarning() async throws {
        let (engine, driver) = makeEngine()
        let tab = engine.createTab()
        let window = try await register(1, engine: engine, driver: driver, tab: tab.id)
        let original = try #require(tab.tiles)
        let split = try original.splitting(original.tileIDs[0], axis: .horizontal)
        driver.setFailWrites(1)
        try await engine.updateTiles(tab.id, partition: split, assignments: [window.id: original.tileIDs[0]], expected: original,
                                     expectedAssignments: engine.state.tab(withID: tab.id)?.tileAssignments ?? [:])
        #expect(engine.tilePlacementFailures(in: tab.id) == [window.id])
        driver.setFailWrites(1, false)
        try await engine.updateTiles(tab.id, partition: split, assignments: [window.id: original.tileIDs[0]], expected: split,
                                     expectedAssignments: engine.state.tab(withID: tab.id)?.tileAssignments ?? [:])
        #expect(engine.tilePlacementFailures(in: tab.id).isEmpty)
    }

    @Test func minimumSizeWarningDoesNotRetryImpossibleSizeForever() async throws {
        let (engine, driver) = makeEngine()
        let tab = engine.createTab()
        let original = try #require(tab.tiles)
        let split = try original.splitting(original.tileIDs[0], axis: .horizontal)
        try await engine.updateTiles(tab.id, partition: split, assignments: [:], expected: original,
                                     expectedAssignments: engine.state.tab(withID: tab.id)?.tileAssignments ?? [:])
        let frame = CGRect(x: 400, y: 100, width: 1000, height: 400)
        driver.add(1, frame: frame, minSize: CGSize(width: 1000, height: 100))
        let window = try await engine.register(windowID: 1, pid: 100, identity: identity(1), frame: frame, into: tab.id)
        #expect(engine.tilePlacementFailures(in: tab.id) == [window.id])
        let actual = driver.currentFrame(1)
        await engine.reconcile(liveWindowIDs: [1], livePIDs: [100])
        await engine.reconcile(liveWindowIDs: [1], livePIDs: [100])
        #expect(driver.currentFrame(1) == actual)
        #expect(engine.state.tabs[0].tiles == split)
    }

    @Test func successfulSnapBackClearsPlacementFailureWithoutWorkspaceChange() async throws {
        let driver = FakeWindowDriver()
        var configuration = TabEngine.Configuration()
        configuration.debounce = .milliseconds(10)
        let engine = TabEngine(driver: driver,
                               layout: FixedScreenLayout(parkPoint: CGPoint(x: 1919, y: 1199), contentArea: area),
                               configuration: configuration)
        let tab = engine.createTab()
        let window = try await register(1, engine: engine, driver: driver, tab: tab.id)
        let original = try #require(tab.tiles)
        let split = try original.splitting(original.tileIDs[0], axis: .horizontal)
        driver.setFailWrites(1)
        try await engine.updateTiles(tab.id, partition: split, assignments: [window.id: original.tileIDs[0]],
                                     expected: original, expectedAssignments: [window.id: original.tileIDs[0]])
        #expect(engine.tilePlacementFailures(in: tab.id) == [window.id])
        let recorded = engine.state
        var notifiedRecovery = false
        engine.onStateChanged = { state in
            if state == recorded && engine.tilePlacementFailures(in: tab.id).isEmpty { notifiedRecovery = true }
        }
        defer { engine.onStateChanged = nil }
        driver.setFailWrites(1, false)
        engine.windowFrameDidChange(windowID: 1)
        try await Task.sleep(for: .milliseconds(150))
        #expect(driver.currentFrame(1) == recorded.managedWindow(id: window.id)?.window.frame)
        #expect(engine.state == recorded)
        #expect(engine.tilePlacementFailures(in: tab.id).isEmpty)
        #expect(notifiedRecovery)
    }
}
