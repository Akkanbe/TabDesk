import ApplicationServices

/// 全画面の推測ではなく、公開APIが現在許可している位置変更を操作の条件にする。
public enum WindowLayoutAccess: Equatable, Sendable {
    case movable
    case fixed
    case unavailable(AXError)

    public static func read(_ element: AXUIElement) -> Self {
        var settable = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(element, kAXPositionAttribute as CFString, &settable)
        return evaluate(error: error, settable: settable.boolValue)
    }

    static func evaluate(error: AXError, settable: Bool) -> Self {
        guard error == .success else { return .unavailable(error) }
        return settable ? .movable : .fixed
    }

    /// 不明はfalseに変換しない。エンジンが最後に確認した保護状態を維持する。
    public var suspension: Bool? {
        switch self {
        case .movable: return false
        case .fixed: return true
        case .unavailable: return nil
        }
    }

    public func requireMovable() throws {
        switch self {
        case .movable: return
        case .fixed: throw AXCallError(operation: "position change is not permitted", code: .cannotComplete)
        case .unavailable(let error):
            throw AXCallError(operation: "check position change permission", code: error)
        }
    }
}
