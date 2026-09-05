import Foundation
import TabDeskCore

/// 標準出力とファイル(~/Library/Logs/TabDesk/tabdesk.log)に同じ行を書く。
/// `open` で起動したアプリの stdout は誰にも見えないので、ファイルに残す。
final class FileLogger: @unchecked Sendable {
    let fileURL: URL
    private let file: RotatingLogFile

    convenience init(directoryName: String, fileName: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/\(directoryName)", isDirectory: true)
        self.init(fileURL: dir.appendingPathComponent(fileName))
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        file = RotatingLogFile(fileURL: fileURL)
    }

    func log(_ message: String) {
        let line = "\(Self.timestamp()) \(message)\n"
        do {
            try file.append(line)
        } catch {
            print("log file unavailable: \(error)")
        }
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
