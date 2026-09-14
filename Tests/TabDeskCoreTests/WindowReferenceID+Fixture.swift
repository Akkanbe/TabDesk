import Foundation
@testable import TabDeskCore

// 既存シナリオの「窓1/窓2」を読みやすく保つ。製品コードではUUIDを発行する。
extension WindowReferenceID: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: UInt32) {
        self = WindowReferenceID(uuidString: String(format: "00000000-0000-0000-0000-%012llx", UInt64(value)))!
    }
}

extension WindowReferenceID {
    var fixtureNumber: UInt32 { UInt32(description.suffix(12), radix: 16)! }
    var fixtureLabel: String {
        UInt32(description.suffix(12), radix: 16).map(String.init) ?? description
    }
}
