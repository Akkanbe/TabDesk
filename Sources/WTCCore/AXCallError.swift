import ApplicationServices

/// AX API 呼び出しの失敗。どの操作がどのコードで失敗したかを必ず残す。
public struct AXCallError: Error, CustomStringConvertible, Sendable {
    public let operation: String
    public let code: AXError

    public init(operation: String, code: AXError) {
        self.operation = operation
        self.code = code
    }

    public var description: String {
        "\(operation) failed: \(code.wtcDescription)"
    }
}

extension AXError {
    /// 人間が読めるエラー名。apiDisabled は「Accessibility 権限なし」を意味するので特に重要。
    public var wtcDescription: String {
        switch self {
        case .success: return "success"
        case .failure: return "failure"
        case .illegalArgument: return "illegalArgument"
        case .invalidUIElement: return "invalidUIElement (window closed?)"
        case .invalidUIElementObserver: return "invalidUIElementObserver"
        case .cannotComplete: return "cannotComplete (app not responding / timeout)"
        case .attributeUnsupported: return "attributeUnsupported"
        case .actionUnsupported: return "actionUnsupported"
        case .notificationUnsupported: return "notificationUnsupported"
        case .notImplemented: return "notImplemented"
        case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
        case .notificationNotRegistered: return "notificationNotRegistered"
        case .apiDisabled: return "apiDisabled (Accessibility permission not granted)"
        case .noValue: return "noValue"
        case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
        case .notEnoughPrecision: return "notEnoughPrecision"
        @unknown default: return "unknown(\(rawValue))"
        }
    }
}
