import Foundation
import TabDeskCore

/// 画面のログ欄・標準出力・ファイル(~/Library/Logs/TabDeskPoC/poc.log)に同じ行を書く。
/// ファイルに残すのは、`open` で起動したアプリの stdout は誰にも見えないため。
final class PoCLogger: @unchecked Sendable {
    typealias Sink = @MainActor @Sendable (String) -> Void

    let fileURL: URL
    private let file: RotatingLogFile
    private let lock = NSLock()
    private var sink: Sink?

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/TabDeskPoC", isDirectory: true)
        fileURL = dir.appendingPathComponent("poc.log")
        file = RotatingLogFile(fileURL: fileURL)
    }

    func setSink(_ sink: @escaping Sink) {
        lock.lock()
        defer { lock.unlock() }
        self.sink = sink
    }

    func log(_ message: String) {
        let line = "\(Self.timestamp()) \(message)\n"
        lock.lock()
        let currentSink = sink
        lock.unlock()
        do {
            try file.append(line)
        } catch {
            print("log file unavailable: \(error)")
        }
        print(line, terminator: "")
        if let currentSink {
            Task { @MainActor in currentSink(line) }
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static func timestamp() -> String {
        formatter.string(from: Date())
    }
}
