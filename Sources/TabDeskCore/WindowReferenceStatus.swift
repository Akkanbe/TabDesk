import ApplicationServices

public enum WindowReferenceStatus: Equatable, Sendable {
    case usable, invalidated, unknown

    static func evaluate(roleError: AXError, presentInCompleteList: Bool?) -> Self {
        guard roleError == .invalidUIElement, presentInCompleteList == false else { return .unknown }
        return .invalidated
    }
}
