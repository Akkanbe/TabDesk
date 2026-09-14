import AppKit
import Foundation

/// 検証専用アプリ。外部窓・TabDesk設定には触れず、自分の2枚の窓だけを操作する。
@main
@MainActor
struct PublicAXFixture {
    static func main() {
        guard (2...3).contains(CommandLine.arguments.count) else {
            FileHandle.standardError.write(Data("Usage: PublicAXFixture <new or empty control directory>\n".utf8))
            exit(1)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = Delegate(directory: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true), navigation: CommandLine.arguments.last == "--navigation")
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    @MainActor
    final class Delegate: NSObject, NSApplicationDelegate {
        let directory: URL
        let navigation: Bool
        var navigationWindows: [NSWindow] = []
        let previousApp = NSWorkspace.shared.frontmostApplication
        var first: NSWindow?
        var second: NSWindow?
        var timer: Timer?
        var lastCommand = ""
        var lastSnapshot = ""

        init(directory: URL, navigation: Bool) { self.directory = directory; self.navigation = navigation }

        func applicationDidFinishLaunching(_ notification: Notification) {
            do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
            catch { fail(error) }
            if navigation {
                for (display, screen) in NSScreen.screens.enumerated() {
                    for tab in 1...2 {
                        let window = makeWindow()
                        window.title = "TabDesk Navigation \(display + 1)-\(tab)"
                        window.setFrameOrigin(CGPoint(x: screen.visibleFrame.minX + 280, y: screen.visibleFrame.minY + 180))
                        let input = NSTextField(frame: CGRect(x: 30, y: 40, width: 430, height: 30))
                        input.placeholderString = "ホットキー切替後の入力先確認"
                        window.contentView?.addSubview(input)
                        window.initialFirstResponder = input
                        window.makeFirstResponder(input)
                        navigationWindows.append(window)
                    }
                }
                first = navigationWindows.first
                second = navigationWindows.dropFirst().first
            } else {
                first = makeWindow()
                second = makeWindow()
            }
            first?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            tick()
        }

        func makeWindow() -> NSWindow {
            let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 800)
            let window = NSWindow(contentRect: CGRect(x: visible.midX - 250, y: visible.midY - 150, width: 500, height: 300),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "TabDesk Public API Test"
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.fullScreenPrimary]
            let label = NSTextField(labelWithString: "公開API検証専用の窓です。\n書類や設定は保存しません。")
            label.frame = CGRect(x: 30, y: 100, width: 430, height: 60)
            window.contentView?.addSubview(label)
            window.orderFront(nil)
            return window
        }

        func tick() {
            let url = directory.appendingPathComponent("command.txt")
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    let command = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !command.isEmpty, command != lastCommand {
                        lastCommand = command
                        execute(command.split(separator: ":", maxSplits: 1).last.map(String.init) ?? "")
                    }
                }
                let sources: [(String, NSWindow?)] = navigation
                    ? navigationWindows.enumerated().map { ("n\($0.offset)", Optional($0.element)) }
                    : [("a", first), ("b", second)]
                let windows = sources.compactMap { label, window -> [String: Any]? in
                    guard let window else { return nil }
                    return ["label": label, "title": window.title, "number": window.windowNumber,
                            "input": (window.contentView?.subviews.compactMap { $0 as? NSTextField }.first { $0.isEditable })?.stringValue ?? "",
                            "frame": NSStringFromRect(window.frame), "fullscreen": window.styleMask.contains(.fullScreen),
                            "minimized": window.isMiniaturized, "key": window.isKeyWindow]
                }
                let object: [String: Any] = ["pid": getpid(), "command": lastCommand, "windows": windows]
                let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                let text = String(decoding: data, as: UTF8.self)
                if text != lastSnapshot {
                    try data.write(to: directory.appendingPathComponent("state.json"), options: .atomic)
                    FileHandle.standardOutput.write(data + Data([10]))
                    lastSnapshot = text
                }
            } catch { fail(error) }
        }

        func execute(_ command: String) {
            switch command {
            case "focus-a": first?.makeKeyAndOrderFront(nil)
            case "focus-b": second?.makeKeyAndOrderFront(nil)
            case "minimize": first?.miniaturize(nil)
            case "restore": first?.deminiaturize(nil)
            case "fullscreen":
                if let first, !first.styleMask.contains(.fullScreen) { first.toggleFullScreen(nil) }
            case "normal":
                if let first, first.styleMask.contains(.fullScreen) { first.toggleFullScreen(nil) }
            case "maximize":
                if let first, let screen = first.screen { first.setFrame(screen.frame, display: true) }
            case "overlap":
                if let first, let second { first.setFrame(second.frame, display: true) }
            case "rename": first?.title = "TabDesk Public API Test Renamed"
            case "close-a": first?.close(); first = nil
            case "create-a": if first == nil { first = makeWindow() }
            case "quit": NSApp.terminate(nil)
            default:
                FileHandle.standardError.write(Data("Unknown fixture command: \(command)\n".utf8))
            }
        }

        func applicationWillTerminate(_ notification: Notification) {
            timer?.invalidate()
            previousApp?.activate(options: [])
        }

        func fail(_ error: Error) -> Never {
            FileHandle.standardError.write(Data("Fixture failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
