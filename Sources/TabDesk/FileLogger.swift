import Foundation

/// 標準出力とファイル(~/Library/Logs/TabDesk/tabdesk.log)に同じ行を書く。
/// `open` で起動したアプリの stdout は誰にも見えないので、ファイルに残す。
final class FileLogger: @unchecked Sendable {
    let fileURL: URL
    private let handle: FileHandle?
    private let lock = NSLock()

    init(directoryName: String, fileName: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/\(directoryName)", isDirectory: true)
        fileURL = dir.appendingPathComponent(fileName)
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

    func log(_ message: String) {
        let line = "\(Self.timestamp()) \(message)\n"
        lock.lock()
        if let handle, let data = line.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
        lock.unlock()
        print(line, terminator: "")
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
