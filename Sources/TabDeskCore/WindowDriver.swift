import CoreGraphics
import Foundation

/// ウィンドウ操作の抽象。エンジンはこのプロトコル越しにだけ実ウィンドウに触る。
///
/// 本番は AX 実装(`AXWindowDriver`)、テストは偽物を差し込む。これにより Accessibility 権限なしで
/// エンジンのロジックを検証できる。各メソッドは同期で、相手アプリへの IPC でブロックしうる
/// (呼び出し側が `BlockingExecutor` 経由でバックグラウンドに逃がす)。
public protocol WindowDriver: Sendable {
    /// 現在の frame(AX 座標)。ウィンドウが消えていれば throw。
    func frame(of windowID: CGWindowID) throws -> CGRect
    /// frame を適用し、適用後に読み戻した実際の frame を返す(最小サイズ制約などで要求と違いうる)。
    @discardableResult
    func setFrame(_ frame: CGRect, of windowID: CGWindowID) throws -> CGRect
    func setPosition(_ point: CGPoint, of windowID: CGWindowID) throws
    func raise(_ windowID: CGWindowID) throws
}

public enum WindowDriverError: Error, CustomStringConvertible, Sendable {
    case unknownWindow(CGWindowID)

    public var description: String {
        switch self {
        case .unknownWindow(let id): return "unknown window \(id)"
        }
    }
}

/// 本番用ドライバ。登録済みの AXWindow を CGWindowID で引いて操作する。
public final class AXWindowDriver: WindowDriver {
    private let windows = Locked<[CGWindowID: AXWindow]>([:])
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

    public func forget(_ windowID: CGWindowID) {
        windows.withValue { _ = $0.removeValue(forKey: windowID) }
    }

    public func knows(_ windowID: CGWindowID) -> Bool {
        windows.withValue { $0[windowID] != nil }
    }

    private func window(_ windowID: CGWindowID) throws -> AXWindow {
        guard let w = windows.withValue({ $0[windowID] }) else {
            throw WindowDriverError.unknownWindow(windowID)
        }
        return w
    }

    public func frame(of windowID: CGWindowID) throws -> CGRect {
        try window(windowID).frame()
    }

    @discardableResult
    public func setFrame(_ frame: CGRect, of windowID: CGWindowID) throws -> CGRect {
        try window(windowID).setFrame(frame)
    }

    public func setPosition(_ point: CGPoint, of windowID: CGWindowID) throws {
        try window(windowID).setPosition(point)
    }

    public func raise(_ windowID: CGWindowID) throws {
        try window(windowID).raise()
    }
}
