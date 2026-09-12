import Foundation

/// 明示選択はマウス位置では解除せず、前面窓の変化で通常の追従へ戻す。
public struct DisplayNavigation {
    public struct Focus: Equatable {
        public let pid: pid_t?
        public let displayID: DisplayID?
        public let windowID: UInt32?
        public init(pid: pid_t?, displayID: DisplayID?, windowID: UInt32? = nil) {
            self.windowID = windowID
            self.pid = pid
            self.displayID = displayID
        }
    }

    public private(set) var selectedID: DisplayID?
    private var baseline: Focus?
    public init() {}

    public mutating func resolve(fallback: DisplayID?, focus: Focus, displays: [DisplayLayout], busy: Bool) -> DisplayID? {
        if let selectedID, !displays.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
        if !busy, let baseline, baseline != focus {
            selectedID = nil
            self.baseline = nil
        }
        return selectedID ?? fallback
    }

    public mutating func select(_ id: DisplayID, focus: Focus) {
        selectedID = id
        baseline = focus
    }

    public mutating func completed(focus: Focus) { baseline = focus }

    public static func adjacent(to current: DisplayID?, offset: Int, displays: [DisplayLayout]) -> DisplayID? {
        guard displays.count > 1 else { return nil }
        let ordered = displays.sorted {
            if $0.frame.minX != $1.frame.minX { return $0.frame.minX < $1.frame.minX }
            if $0.frame.minY != $1.frame.minY { return $0.frame.minY < $1.frame.minY }
            return $0.id < $1.id
        }
        guard let index = ordered.firstIndex(where: { $0.id == current }) else { return ordered.first?.id }
        let next = (index + offset % ordered.count + ordered.count) % ordered.count
        return ordered[next].id
    }
}
