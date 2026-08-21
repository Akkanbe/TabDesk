import ApplicationServices
import Foundation

/// AXUIElement の属性読み書きを型付きで行う薄いヘルパー。
enum AXAttributes {
    static func copy(_ element: AXUIElement, _ attribute: String) throws -> CFTypeRef {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success, let value else {
            throw AXCallError(operation: "get \(attribute)", code: err)
        }
        return value
    }

    static func string(_ element: AXUIElement, _ attribute: String) throws -> String {
        let value = try copy(element, attribute)
        guard let s = value as? String else {
            throw AXCallError(operation: "get \(attribute) as String", code: .failure)
        }
        return s
    }

    static func bool(_ element: AXUIElement, _ attribute: String) throws -> Bool {
        let value = try copy(element, attribute)
        guard let b = value as? Bool else {
            throw AXCallError(operation: "get \(attribute) as Bool", code: .failure)
        }
        return b
    }

    static func point(_ element: AXUIElement, _ attribute: String) throws -> CGPoint {
        let axValue = try axValue(element, attribute)
        var p = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &p) else {
            throw AXCallError(operation: "get \(attribute) as CGPoint", code: .failure)
        }
        return p
    }

    static func size(_ element: AXUIElement, _ attribute: String) throws -> CGSize {
        let axValue = try axValue(element, attribute)
        var s = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &s) else {
            throw AXCallError(operation: "get \(attribute) as CGSize", code: .failure)
        }
        return s
    }

    static func elements(_ element: AXUIElement, _ attribute: String) throws -> [AXUIElement] {
        let value = try copy(element, attribute)
        guard let array = value as? [AXUIElement] else {
            throw AXCallError(operation: "get \(attribute) as [AXUIElement]", code: .failure)
        }
        return array
    }

    static func set(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) throws {
        let err = AXUIElementSetAttributeValue(element, attribute as CFString, value)
        guard err == .success else {
            throw AXCallError(operation: "set \(attribute)", code: err)
        }
    }

    static func perform(_ element: AXUIElement, action: String) throws {
        let err = AXUIElementPerformAction(element, action as CFString)
        guard err == .success else {
            throw AXCallError(operation: "perform \(action)", code: err)
        }
    }

    static func wrap(_ p: CGPoint) -> AXValue {
        var p = p
        // 型を正しく渡している限り AXValueCreate は失敗しない。
        return AXValueCreate(.cgPoint, &p)!
    }

    static func wrap(_ s: CGSize) -> AXValue {
        var s = s
        return AXValueCreate(.cgSize, &s)!
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) throws -> AXValue {
        let value = try copy(element, attribute)
        guard CFGetTypeID(value) == AXValueGetTypeID() else {
            throw AXCallError(operation: "get \(attribute) as AXValue", code: .failure)
        }
        // 型 ID を確認済みなのでビットキャストは安全。
        return unsafeDowncast(value, to: AXValue.self)
    }
}
