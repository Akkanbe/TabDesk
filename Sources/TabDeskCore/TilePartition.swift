import CoreGraphics
import Foundation

public enum TileAxis: String, Codable, Sendable {
    case horizontal // 左右に分割
    case vertical   // 上下に分割
}

public enum TileEditError: Error, CustomStringConvertible, Sendable {
    case invalidPartition, noEmptyTile, occupiedMerge, cannotMerge, tooSmall

    public var description: String {
        switch self {
        case .invalidPartition: return L10n.text(.invalidTiles)
        case .noEmptyTile: return L10n.text(.noEmptyTile)
        case .occupiedMerge: return L10n.text(.occupiedMerge)
        case .cannotMerge: return L10n.text(.cannotMerge)
        case .tooSmall: return L10n.text(.tilesTooSmall)
        }
    }
}

/// 領域を二分する木。矩形を独立に移動させず、共有境界だけを変えることで隙間と重複を防ぐ。
public indirect enum TilePartition: Codable, Hashable, Sendable {
    case tile(UUID)
    case split(id: UUID, axis: TileAxis, ratio: Double, first: TilePartition, second: TilePartition)

    public var id: UUID {
        switch self {
        case .tile(let id), .split(let id, _, _, _, _): return id
        }
    }

    public var tileIDs: [UUID] {
        switch self {
        case .tile(let id): return [id]
        case .split(_, _, _, let first, let second): return first.tileIDs + second.tileIDs
        }
    }

    /// タブ間で区画の識別子を共有しない。分割軸・比率だけを引き継ぐ。
    public func copyWithNewIDs() -> TilePartition {
        switch self {
        case .tile: return .tile(UUID())
        case .split(_, let axis, let ratio, let first, let second):
            return .split(id: UUID(), axis: axis, ratio: ratio,
                          first: first.copyWithNewIDs(), second: second.copyWithNewIDs())
        }
    }

    public func validate() throws {
        var seen = Set<UUID>()
        func visit(_ node: TilePartition, depth: Int) throws {
            guard depth <= 16, seen.insert(node.id).inserted, seen.count <= 127 else {
                throw TileEditError.invalidPartition
            }
            if case .split(_, _, let ratio, let first, let second) = node {
                guard ratio.isFinite, (0.05...0.95).contains(ratio) else { throw TileEditError.invalidPartition }
                try visit(first, depth: depth + 1)
                try visit(second, depth: depth + 1)
            }
        }
        try visit(self, depth: 0)
    }

    public struct Divider: Sendable {
        public let id: UUID
        public let axis: TileAxis
        public let area: CGRect
        public let position: CGFloat
    }

    public func geometry(in area: CGRect) -> (tiles: [UUID: CGRect], dividers: [Divider]) {
        var tiles: [UUID: CGRect] = [:]
        var dividers: [Divider] = []
        func visit(_ node: TilePartition, _ rect: CGRect) {
            switch node {
            case .tile(let id): tiles[id] = rect
            case .split(let id, let axis, let ratio, let first, let second):
                var a = rect
                var b = rect
                let position: CGFloat
                if axis == .horizontal {
                    position = min(rect.maxX, max(rect.minX, (rect.minX + rect.width * ratio).rounded()))
                    a.size.width = position - rect.minX
                    b.origin.x = position
                    b.size.width = rect.maxX - position
                } else {
                    position = min(rect.maxY, max(rect.minY, (rect.minY + rect.height * ratio).rounded()))
                    a.size.height = position - rect.minY
                    b.origin.y = position
                    b.size.height = rect.maxY - position
                }
                dividers.append(Divider(id: id, axis: axis, area: rect, position: position))
                visit(first, a)
                visit(second, b)
            }
        }
        visit(self, area)
        return (tiles, dividers)
    }

    public func splitting(_ tileID: UUID, axis: TileAxis) throws -> TilePartition {
        guard tileIDs.contains(tileID) else { throw TileEditError.invalidPartition }
        let updated = replacing(tileID, with: .split(id: UUID(), axis: axis, ratio: 0.5,
                                                    first: .tile(tileID), second: .tile(UUID())))
        try updated.validate()
        return updated
    }

    public func resizing(_ dividerID: UUID, ratio: Double) throws -> TilePartition {
        guard ratio.isFinite else { throw TileEditError.invalidPartition }
        switch self {
        case .tile: throw TileEditError.invalidPartition
        case .split(let id, let axis, let oldRatio, let first, let second):
            if id == dividerID {
                return .split(id: id, axis: axis, ratio: min(0.95, max(0.05, ratio)), first: first, second: second)
            }
            if first.contains(dividerID) {
                return .split(id: id, axis: axis, ratio: oldRatio, first: try first.resizing(dividerID, ratio: ratio), second: second)
            }
            return .split(id: id, axis: axis, ratio: oldRatio, first: first, second: try second.resizing(dividerID, ratio: ratio))
        }
    }

    /// 同じ分割から生まれた隣接タイル同士を結合する。占有済みならその ID を残す。
    public func merging(_ tileID: UUID, occupied: Set<UUID>) throws -> (partition: TilePartition, selected: UUID) {
        switch self {
        case .tile: throw TileEditError.cannotMerge
        case .split(let id, let axis, let ratio, let first, let second):
            if case .tile(let a) = first, case .tile(let b) = second, a == tileID || b == tileID {
                guard !occupied.contains(a) || !occupied.contains(b) else { throw TileEditError.occupiedMerge }
                let keep = occupied.contains(a) ? a : occupied.contains(b) ? b : tileID
                return (.tile(keep), keep)
            }
            if first.tileIDs.contains(tileID) {
                let result = try first.merging(tileID, occupied: occupied)
                return (.split(id: id, axis: axis, ratio: ratio, first: result.partition, second: second), result.selected)
            }
            let result = try second.merging(tileID, occupied: occupied)
            return (.split(id: id, axis: axis, ratio: ratio, first: first, second: result.partition), result.selected)
        }
    }

    private func contains(_ target: UUID) -> Bool {
        if id == target { return true }
        if case .split(_, _, _, let a, let b) = self { return a.contains(target) || b.contains(target) }
        return false
    }

    private func replacing(_ target: UUID, with replacement: TilePartition) -> TilePartition {
        if id == target { return replacement }
        switch self {
        case .tile: return self
        case .split(let id, let axis, let ratio, let first, let second):
            return .split(id: id, axis: axis, ratio: ratio,
                          first: first.replacing(target, with: replacement), second: second.replacing(target, with: replacement))
        }
    }

    /// 初回のモード切替用。既存窓には等幅のタイルを割り当てる。
    public static func columns(_ ids: [UUID]) -> TilePartition {
        guard ids.count > 1 else { return .tile(ids.first ?? UUID()) }
        let middle = ids.count / 2
        return .split(id: UUID(), axis: .horizontal, ratio: Double(middle) / Double(ids.count),
                      first: columns(Array(ids.prefix(middle))), second: columns(Array(ids.dropFirst(middle))))
    }
}
