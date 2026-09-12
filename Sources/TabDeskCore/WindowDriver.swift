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
    func frame(of windowID: CGWindowID) throws -> CGRect
    /// frame を適用し、適用後に読み戻した実際の frame を返す(最小サイズ制約などで要求と違いうる)。
    @discardableResult
    func setFrame(_ frame: CGRect, of windowID: CGWindowID) throws -> CGRect
    func setPosition(_ point: CGPoint, of windowID: CGWindowID) throws
    func isMinimized(of windowID: CGWindowID) throws -> Bool
    func raise(_ windowID: CGWindowID) throws
    /// ネイティブフルスクリーン中か(v3 段階 2)。ウィンドウが消えていれば throw。
    /// **nil = 判定不能**(属性が読めない・タイムアウト)。呼び手は nil を「前回の判定を維持」と
    /// 扱うこと — false に潰すと、忙しいアプリの一時的な読み取り失敗でフルスクリーン集合から
    /// 誤って外れ、復元リトライがフルスクリーン寸法を採用する破壊が再発する(v3 レビュー指摘)。
    func isFullscreen(of windowID: CGWindowID) throws -> Bool?
    /// 終了時だけ参照を更新する。closed は存在しないと確認できた場合に限る。
    func prepareForRelease(of windowID: CGWindowID) throws -> WindowReleaseStatus
}

public enum WindowReleaseStatus: Sendable { case ready, closed }

extension WindowDriver {
    public func isMinimized(of windowID: CGWindowID) throws -> Bool { false }
    public func prepareForRelease(of windowID: CGWindowID) throws -> WindowReleaseStatus { .ready }
}

public enum WindowDriverError: Error, CustomStringConvertible, Sendable {
    case unknownWindow(CGWindowID)
    case releaseReferenceUnavailable(CGWindowID)

    public var description: String {
        switch self {
        case .unknownWindow(let id): return "unknown window \(id)"
        case .releaseReferenceUnavailable(let id): return "window \(id) has no usable AX reference; closure could not be confirmed"
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

    public func isMinimized(of windowID: CGWindowID) throws -> Bool {
        try AXAttributes.bool(window(windowID).element, kAXMinimizedAttribute)
    }

    public func raise(_ windowID: CGWindowID) throws {
        try window(windowID).raise()
    }

    public func isFullscreen(of windowID: CGWindowID) throws -> Bool? {
        try window(windowID).fullscreenRaw  // nil = 属性が読めない(呼び手が前回判定を維持する)
    }

    public func prepareForRelease(of windowID: CGWindowID) throws -> WindowReleaseStatus {
        let previous = try window(windowID)
        let app = AXUIElementCreateApplication(previous.pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        // 登録候補の列挙は最小化・fullscreen を除くため使わない。ここでは ID の一致だけで探す。
        let elements = try AXAttributes.elements(app, kAXWindowsAttribute)
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
        let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        guard Self.confirmedClosed(windowID: windowID, pid: previous.pid, windowInfo: info) else {
            throw WindowDriverError.releaseReferenceUnavailable(windowID)
        }
        return .closed
    }

    /// AX の一覧にないだけでは閉じたと判断しない。WindowServer の一覧取得失敗も「不明」。
    static func confirmedClosed(windowID: CGWindowID, pid: pid_t, windowInfo: [[String: Any]]?) -> Bool {
        guard let windowInfo else { return false }
        return windowInfo.allSatisfy { info in
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { return false }
            return id != windowID || owner != pid
        }
    }
}
