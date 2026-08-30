import CoreGraphics
import Foundation
import Testing
@testable import TabDeskCore

/// Tiler(段階 C)の純関数と、Tab.layout の後方互換デコードの検証。
struct TileLayoutTests {
    private func window(_ id: UUID = UUID(), bound: Bool = true) -> ManagedWindow {
        ManagedWindow(
            id: id,
            frame: CGRect(x: 300, y: 100, width: 400, height: 300),
            identity: WindowIdentity(bundleID: "test.app", appName: "App", title: "T", registeredSize: CGSize(width: 400, height: 300)),
            windowID: bound ? CGWindowID.random(in: 1...99999) : nil,
            pid: bound ? 100 : nil)
    }

    private let area = CGRect(x: 240, y: 30, width: 1680, height: 1090)

    @Test func columnsSplitEquallyInWindowOrder() {
        let windows = [window(), window(), window()]
        let frames = Tiler.columnFrames(for: windows, in: area)
        #expect(frames.count == 3)
        let ordered = windows.compactMap { frames[$0.id] }
        // 左から並び順どおり、全高、境界が連続していて合計が area とぴったり一致する。
        #expect(ordered[0].minX == area.minX)
        for f in ordered {
            #expect(f.minY == area.minY)
            #expect(f.height == area.height)
        }
        for (left, right) in zip(ordered, ordered.dropFirst()) {
            #expect(left.maxX == right.minX)
        }
        #expect(ordered.last?.maxX == area.maxX)
        #expect(ordered.map(\.width).reduce(0, +) == area.width)
    }

    @Test(arguments: [1, 2, 5]) func columnWidthsCoverAreaExactly(count: Int) {
        let windows = (0..<count).map { _ in window() }
        let frames = Tiler.columnFrames(for: windows, in: area)
        let ordered = windows.compactMap { frames[$0.id] }
        #expect(ordered.count == count)
        #expect(ordered.first?.minX == area.minX)
        #expect(ordered.last?.maxX == area.maxX)
        #expect(ordered.map(\.width).reduce(0, +) == area.width)
        // 端数の出る幅(1680/5=336 は割り切れるので 3 窓ケースが端数を踏む)でも各列は整数境界。
        for f in ordered {
            #expect(f.minX == f.minX.rounded())
            #expect(f.maxX == f.maxX.rounded())
        }
    }

    @Test func unboundWindowsAreSkipped() {
        let bound1 = window()
        let unbound = window(bound: false)
        let bound2 = window()
        let frames = Tiler.columnFrames(for: [bound1, unbound, bound2], in: area)
        #expect(frames.count == 2)
        #expect(frames[unbound.id] == nil)
        // 未復元の窓は列数に入らない = bound の 2 枚で等分する。
        #expect(frames[bound1.id]?.width == area.width / 2)
    }

    @Test func emptyInputsProduceNoFrames() {
        #expect(Tiler.columnFrames(for: [], in: area).isEmpty)
        #expect(Tiler.columnFrames(for: [window(bound: false)], in: area).isEmpty)
        #expect(Tiler.columnFrames(for: [window()], in: .zero).isEmpty)
    }

    // MARK: - Tab.layout の後方互換デコード

    /// v1 の state.json には layout キーが無い。`.free` として読めること(バージョンは 1 のまま)。
    @Test func decodingV1TabWithoutLayoutKeyDefaultsToFree() throws {
        let json = """
            {"id": "\(UUID().uuidString)", "name": "Work", "windows": []}
            """
        let tab = try JSONDecoder().decode(Tab.self, from: Data(json.utf8))
        #expect(tab.layout == .free)
    }

    /// 将来のバイナリが書いた未知のレイアウト値は `.free` に落とし、ファイル全体を壊さない。
    @Test func decodingUnknownLayoutValueDegradesToFree() throws {
        let json = """
            {"id": "\(UUID().uuidString)", "name": "Work", "windows": [], "layout": "future-mode"}
            """
        let tab = try JSONDecoder().decode(Tab.self, from: Data(json.utf8))
        #expect(tab.layout == .free)
    }

    // MARK: - Tab.representativeWindow(サムネイル対象。v3 段階 5)

    @Test func representativeWindowPrefersLastFocusedBoundWindow() {
        let first = window()
        let focused = window()
        let tab = Tab(name: "A", windows: [first, focused], lastFocusedWindowID: focused.id)
        #expect(tab.representativeWindow?.id == focused.id)
    }

    @Test func representativeWindowFallsBackToFirstBound() {
        let unbound = window(bound: false)
        let bound = window()
        // lastFocused が未復元(unbound)なら先頭の bound な窓へ。
        let tab = Tab(name: "A", windows: [unbound, bound], lastFocusedWindowID: unbound.id)
        #expect(tab.representativeWindow?.id == bound.id)
    }

    @Test func representativeWindowIsNilWhenAllUnbound() {
        let tab = Tab(name: "A", windows: [window(bound: false), window(bound: false)])
        #expect(tab.representativeWindow == nil)
    }

    @Test func layoutRoundTripsThroughCoding() throws {
        let tab = Tab(name: "Tiled", windows: [window()], layout: .columns)
        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(Tab.self, from: data)
        #expect(decoded.layout == .columns)
        #expect(decoded.id == tab.id)
        // windowID / pid は実行時専用なので落ちる(v1 からの既存仕様)。
        #expect(decoded.windows.first?.isBound == false)
    }
}
