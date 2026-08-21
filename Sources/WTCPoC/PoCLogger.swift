import Foundation

/// 画面のログ欄・標準出力・ファイル(~/Library/Logs/WTCPoC/poc.log)に同じ行を書く。
/// ファイルに残すのは、`open` で起動したアプリの stdout は誰にも見えないため。
final class PoCLogger: @unchecked Sendable {
    typealias Sink = @MainActor @Sendable (String) -> Void

    let fileURL: URL
    private let handle: FileHandle?
    private let lock = NSLock()
    private var sink: Sink?

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/WTCPoC", isDirectory: true)
        fileURL = dir.appendingPathComponent("poc.log")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            let h = try FileHandle(forWritingTo: fileURL)
            try h.seekToEnd()
            handle = h
        } catch {
            handle = nil
            print("log file unavailable: \(error)")
        }
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
        if let handle, let data = line.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
        lock.unlock()
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
