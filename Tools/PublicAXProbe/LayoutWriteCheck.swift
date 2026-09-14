@testable import TabDeskCore
import AppKit
import ApplicationServices
import Foundation

/// 本体と同じAXWindow実装の書き込み保護を、専用Fixtureだけで検証する。
@main
struct LayoutWriteCheck {
    static func main() {
        do {
            guard CommandLine.arguments.count == 3,
                  ["movable", "fixed"].contains(CommandLine.arguments[2]) else {
                throw CheckError.failed("Usage: LayoutWriteCheck <fixture control directory> <movable|fixed>")
            }
            let file = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("state.json")
            let state = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
            guard let pid = state?["pid"] as? Int32,
                  let app = NSRunningApplication(processIdentifier: pid),
                  app.bundleIdentifier == "io.github.akkanbe.tabdesk.axfixture", !app.isTerminated,
                  let rows = state?["windows"] as? [[String: Any]],
                  rows.contains(where: { $0["label"] as? String == "a" }) else {
                throw CheckError.failed("Expected the dedicated fixture's window A")
            }
            let root = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(root, 0.5)
            // 先にFixtureのrenameコマンドでAだけ固有名へ変える。前面状態やOS窓番号に依存しない。
            let candidates = try AXAttributes.elements(root, kAXWindowsAttribute)
                .compactMap { try? AXWindow(element: $0, pid: pid) }
                .filter { $0.title == "TabDesk Public API Test Renamed" }
            guard candidates.count == 1, let window = candidates.first else { throw CheckError.failed("Fixture window cannot be identified") }
            window.setMessagingTimeout(0.5)
            let before = try window.frame()
            let expectedFixed = CommandLine.arguments[2] == "fixed"
            guard window.layoutSuspension == expectedFixed else {
                throw CheckError.failed("Unexpected access state: \(String(describing: window.layoutSuspension))")
            }
            let requested = CGRect(x: before.minX + 10, y: before.minY + 10, width: before.width, height: before.height)
            if expectedFixed {
                let writes: [() throws -> Void] = [
                    { try window.setPosition(requested.origin) },
                    { try window.setSize(requested.size) },
                    { _ = try window.setFrame(requested) },
                    { try window.raise() }
                ]
                var rejected = 0
                for write in writes {
                    do { try write() } catch is AXCallError { rejected += 1 }
                }
                guard rejected == writes.count, try window.frame() == before else {
                    throw CheckError.failed("Suspended window was not protected")
                }
                print("PASS: position, size, frame and raise rejected; fixture frame unchanged")
            } else {
                try window.setPosition(requested.origin)
                let moved = try window.frame()
                // 通常状態へ復帰した後も、読み取りだけでなく実際の移動が可能なことを確認。
                guard abs(moved.minX - requested.minX) <= 2, abs(moved.minY - requested.minY) <= 2 else {
                    throw CheckError.failed("Movable fixture did not reach requested position")
                }
                try window.setPosition(before.origin)
                print("PASS: fixture moved and returned using production AXWindow")
            }
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
    enum CheckError: Error { case failed(String) }
}
