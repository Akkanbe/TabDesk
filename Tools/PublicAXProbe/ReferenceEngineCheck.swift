import AppKit
import ApplicationServices
@testable import TabDeskCore

/// 稼働中のTabDeskや保存設定を使わず、Fixtureの2枚だけを製品Coreで操作する。
@main
@MainActor
struct ReferenceEngineCheck {
    enum CheckError: Error { case failed(String) }
    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw CheckError.failed(message) }
    }
    static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }
    static func main() async {
        var originals: [(AXWindow, CGRect)] = []
        do {
            try require(CommandLine.arguments.count == 2, "Usage: ReferenceEngineCheck <fixture control directory>")
            let directory = URL(fileURLWithPath: CommandLine.arguments[1])
            let state = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("state.json"))) as? [String: Any]
            guard let pid = state?["pid"] as? Int32,
                  let app = NSRunningApplication(processIdentifier: pid),
                  app.bundleIdentifier == "io.github.akkanbe.tabdesk.axfixture", !app.isTerminated else {
                throw CheckError.failed("Expected the dedicated fixture")
            }
            let descriptor = AppDescriptor(pid: pid, name: "Fixture", bundleID: app.bundleIdentifier!)
            let records = WindowEnumerator.enumerateWindows(of: descriptor).records
            try require(records.count == 2, "Expected two movable fixture windows")
            let windows = records.map(\.window)
            originals = try windows.map { ($0, try $0.frame()) }
            try require(windows[0].windowID != windows[1].windowID, "Overlapping windows share an ID")
            try require(windows[0].title == windows[1].title && close(originals[0].1, originals[1].1), "Fixture must start with identical titles and frames")
            let refreshed = WindowEnumerator.enumerateWindows(of: descriptor).records
            try require(Set(refreshed.map(\.window.windowID)) == Set(windows.map(\.windowID)), "IDs changed across enumeration")
            try require(WindowServerMatch.windowNumber(for: windows[0]) == nil, "Ambiguous screenshot match must be omitted")
            print("PASS: identical overlapping windows have distinct, stable public AX IDs; ambiguous CG match omitted")

            let root = AXUIElementCreateApplication(pid)
            let focusedValue = try AXAttributes.copy(root, kAXFocusedWindowAttribute)
            try require(CFGetTypeID(focusedValue) == AXUIElementGetTypeID(), "No focused fixture window")
            let focused = try AXWindow(element: unsafeDowncast(focusedValue, to: AXUIElement.self), pid: pid)
            try require(windows.contains(focused), "Focus did not resolve to an enumerated reference")
            let driver = AXWindowDriver(messagingTimeout: 0.5)
            windows.forEach { driver.adopt($0) }
            let frames = NSScreen.screens.map { ScreenGeometry.fullFrameAX(of: $0) }
            guard let parkPoint = ScreenGeometry.parkPoints(forDisplayFrames: frames).first else {
                throw CheckError.failed("No display available")
            }
            let engine = TabEngine(driver: driver,
                layout: FixedScreenLayout(parkPoint: parkPoint, contentArea: originals[0].1))
            engine.log = { print("engine: \($0)") }
            print("fixture: originals=\(originals.map { $0.1 }) screens=\(frames) park=\(parkPoint)")
            let first = engine.createTab(name: "Fixture A", layout: .free)
            let second = engine.createTab(name: "Fixture B", layout: .free)
            for (index, record) in records.enumerated() {
                _ = try await engine.register(windowID: record.window.windowID, pid: pid,
                    identity: WindowIdentity(bundleID: descriptor.bundleID, appName: "Fixture", title: record.title,
                        registeredSize: originals[index].1.size), frame: originals[index].1, into: index == 0 ? first.id : second.id)
            }
            try require(try close(windows[0].frame(), originals[0].1), "Registering B moved A")
            try require(!engine.parkedWindowIDs.isEmpty, "Inactive window not parked")
            _ = try await engine.activate(second.id)
            try require(try close(windows[1].frame(), originals[1].1), "Switch did not restore B: actual=\(try windows[1].frame()) expected=\(originals[1].1)")
            _ = try await engine.activateAdjacent(offset: -1, on: "fixed")
            try require(try close(windows[0].frame(), originals[0].1), "Adjacent switch did not restore A")
            let data = try JSONEncoder().encode(engine.state)
            let json = String(decoding: data, as: UTF8.self)
            try require(!json.contains("windowID") && !json.contains("\"pid\""), "Runtime identity leaked into saved state")
            let decoded = try JSONDecoder().decode(WorkspaceState.self, from: data)
            try require(decoded.allWindows.allSatisfy { !$0.isBound }, "Decoded bindings should be empty")
            await engine.releaseAllParkedWindows()
            for (window, frame) in originals { try require(try close(window.frame(), frame), "Shutdown failed to restore fixture") }
            try require(engine.parkedWindowIDs.isEmpty, "Shutdown left parked registrations")
            print("PASS: register, park, switch, adjacent switch, state round-trip and shutdown restore using production Core")

            // 終了済みエンジンは変更を拒否するため、稼働中の追跡は別のメモリ内エンジンで調べる。
            let trackingEngine = TabEngine(driver: driver,
                layout: FixedScreenLayout(parkPoint: parkPoint, contentArea: originals[0].1), initialState: engine.state)
            // 消滅通知を使わず、失効した参照だけが検出されることを調べる。
            try "engine-check:close-a\n".write(to: directory.appendingPathComponent("command.txt"), atomically: true, encoding: .utf8)
            var invalidated: Set<WindowReferenceID> = []
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(100))
                invalidated = await driver.invalidatedWindowIDs()
                if !invalidated.isEmpty { break }
            }
            try require(invalidated == [focused.windowID], "Closed A was not distinguished from live B")
            for id in invalidated { trackingEngine.noteWindowReferenceLost(windowID: id) }
            try require(trackingEngine.state.allWindows.count == 2 && trackingEngine.state.allWindows.filter { !$0.isBound }.count == 1,
                "Lost reference should retain the saved registration")
            print("PASS: missing destroyed notification handled as reference loss; surviving window untouched, registration retained")
        } catch {
            // 検証が途中で失敗しても、自分が動かしたFixtureの窓を可能な範囲で戻す。
            for (window, frame) in originals where window.referenceStatus() != .invalidated {
                do { _ = try window.setFrame(frame) }
                catch { FileHandle.standardError.write(Data("fixture restore: \(error)\n".utf8)) }
            }
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
