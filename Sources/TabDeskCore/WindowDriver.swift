import CoreGraphics
import Foundation
import ApplicationServices

/// ウィンドウ操作の抽象。エンジンはこのプロトコル越しにだけ実ウィンドウに触る。
///
/// 本番は AX 実装(`AXWindowDriver`)、テストは偽物を差し込む。これにより Accessibility 権限なしで
/// エンジンのロジックを検証できる。各メソッドは同期で、相手アプリへの IPC でブロックしうる
/// (呼び出し側が `BlockingExecutor` 経由でバックグラウンドに逃がす)。
public protocol WindowDriver: Sendable {
    /// 現在の frame(AX 座標)。ウィンドウが消えていれば throw。
    func frame(of windowID: WindowReferenceID) throws -> CGRect
    /// frame を適用し、適用後に読み戻した実際の frame を返す(最小サイズ制約などで要求と違いうる)。
    @discardableResult
    func setFrame(_ frame: CGRect, of windowID: WindowReferenceID) throws -> CGRect
    func setPosition(_ point: CGPoint, of windowID: WindowReferenceID) throws
    func isMinimized(of windowID: WindowReferenceID) throws -> Bool
    func raise(_ windowID: WindowReferenceID) throws
    /// 公開API上で位置変更が不許可となり、配置操作を保留する必要があるか。
    /// **nil = 判定不能**(属性が読めない・タイムアウト)。呼び手は nil を「前回の判定を維持」と
    /// 扱うこと。実際の書き込み直前にもドライバが可否を再確認し、不明なら書き込まない。
    func isLayoutSuspended(of windowID: WindowReferenceID) throws -> Bool?
    /// 終了時だけ参照を更新する。invalidated は参照の失効を確認できた場合に限る。登録自体は保持する。
    func prepareForRelease(of windowID: WindowReferenceID) throws -> WindowReleaseStatus
}

public enum WindowReleaseStatus: Sendable { case ready, invalidated }

extension WindowDriver {
    public func isMinimized(of windowID: WindowReferenceID) throws -> Bool { false }
    public func prepareForRelease(of windowID: WindowReferenceID) throws -> WindowReleaseStatus { .ready }
}

public enum WindowDriverError: Error, CustomStringConvertible, Sendable {
    case unknownWindow(WindowReferenceID)
    case releaseReferenceUnavailable(WindowReferenceID)

    public var description: String {
        switch self {
        case .unknownWindow(let id): return "unknown window \(id)"
        case .releaseReferenceUnavailable(let id): return "window \(id) has no usable AX reference; closure could not be confirmed"
        }
    }
}

/// 本番用ドライバ。登録済みの AXWindow を WindowReferenceID で引いて操作する。
public final class AXWindowDriver: WindowDriver {
    private let windows = Locked<[WindowReferenceID: AXWindow]>([:])
    /// 1 要素あたりの AX タイムアウト(秒)。無応答アプリが切替全体を巻き込まないよう短めにする。
    public let messagingTimeout: Float

    public init(messagingTimeout: Float = 1.0) {
        self.messagingTimeout = messagingTimeout
    }

    /// エンジンから操作できるようにウィンドウを預ける(登録時に呼ぶ)。
    public func adopt(_ window: AXWindow) {
        window.setMessagingTimeout(messagingTimeout)
        windows.withValue { $0[window.windowID] = window }
    }

    public func forget(_ windowID: WindowReferenceID) {
        windows.withValue { _ = $0.removeValue(forKey: windowID) }
    }

    public func retireReference(_ windowID: WindowReferenceID) {
        windows.withValue { $0[windowID] }?.retireReference()
    }

    private func window(_ windowID: WindowReferenceID) throws -> AXWindow {
        guard let w = windows.withValue({ $0[windowID] }) else {
            throw WindowDriverError.unknownWindow(windowID)
        }
        return w
    }

    public func frame(of windowID: WindowReferenceID) throws -> CGRect {
        try window(windowID).frame()
    }

    @discardableResult
    public func setFrame(_ frame: CGRect, of windowID: WindowReferenceID) throws -> CGRect {
        try window(windowID).setFrame(frame)
    }

    public func setPosition(_ point: CGPoint, of windowID: WindowReferenceID) throws {
        try window(windowID).setPosition(point)
    }

    public func isMinimized(of windowID: WindowReferenceID) throws -> Bool {
        try AXAttributes.bool(window(windowID).element, kAXMinimizedAttribute)
    }

    public func raise(_ windowID: WindowReferenceID) throws {
        try window(windowID).raise()
    }

    public func isLayoutSuspended(of windowID: WindowReferenceID) throws -> Bool? {
        try window(windowID).layoutSuspension  // nil = 属性が読めない(呼び手が前回判定を維持する)
    }

    public func prepareForRelease(of windowID: WindowReferenceID) throws -> WindowReleaseStatus {
        let previous = try window(windowID)
        let app = AXUIElementCreateApplication(previous.pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        // 登録候補の列挙は最小化・fullscreen を除くため使わない。ここでは ID の一致だけで探す。
        let elements = (try? AXAttributes.elements(app, kAXWindowsAttribute)) ?? []
        for element in elements {
            guard let fresh = try? AXWindow(element: element, pid: previous.pid), fresh.windowID == windowID else { continue }
            fresh.setMessagingTimeout(messagingTimeout)
            return try windows.withValue { cached in
                guard let current = cached[windowID], current.pid == previous.pid,
                      CFEqual(current.element, previous.element) else { throw WindowDriverError.unknownWindow(windowID) }
                cached[windowID] = fresh
                return .ready
            }
        }
        // 参照が一覧に現れなくても有効なら、その参照で復旧を試みる。
        if (try? previous.frame()) != nil { return .ready }
        if previous.referenceStatus() == .invalidated { return .invalidated }
        throw WindowDriverError.releaseReferenceUnavailable(windowID)
    }

    /// 各アプリを並列に調べる。一時エラーは「失効」に変換しない。
    public func invalidatedWindowIDs() async -> Set<WindowReferenceID> {
        let snapshot = windows.withValue { Array($0.values) }
        let groups = Dictionary(grouping: snapshot, by: \.pid)
        let executor = BlockingExecutor()
        return await withTaskGroup(of: Set<WindowReferenceID>.self) { group in
            for entries in groups.values {
                group.addTask {
                    await executor.run {
                        Set(entries.filter { $0.referenceStatus() == .invalidated }.map(\.windowID))
                    }
                }
            }
            var result: Set<WindowReferenceID> = []
            for await ids in group { result.formUnion(ids) }
            return result
        }
    }

    public func cgWindowID(for id: WindowReferenceID) -> CGWindowID? {
        guard let window = try? window(id) else { return nil }
        return WindowServerMatch.windowNumber(for: window)
    }
}
