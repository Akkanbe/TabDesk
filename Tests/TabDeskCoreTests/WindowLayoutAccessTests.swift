import ApplicationServices
import Testing
@testable import TabDeskCore

struct WindowLayoutAccessTests {
    @Test func fixedWindowSuspendsAndRejectsWrites() {
        let access = WindowLayoutAccess.evaluate(error: .success, settable: false)
        #expect(access.suspension == true)
        #expect(throws: AXCallError.self) { try access.requireMovable() }
    }

    @Test func movableWindowResumesAndAllowsWrites() throws {
        let access = WindowLayoutAccess.evaluate(error: .success, settable: true)
        #expect(access.suspension == false)
        try access.requireMovable()
    }

    @Test(arguments: [AXError.cannotComplete, .invalidUIElement, .attributeUnsupported, .apiDisabled], [false, true])
    func failedQueryNeverTrustsOutputFlag(error: AXError, settable: Bool) {
        let access = WindowLayoutAccess.evaluate(error: error, settable: settable)
        #expect(access == .unavailable(error))
        #expect(access.suspension == nil)
        #expect(throws: AXCallError.self) { try access.requireMovable() }
    }
}
