import Foundation

/// 追記と世代更新を同じロックで保護する。失敗は呼び手へ返し、次の追記で再試行できる。
public final class RotatingLogFile: @unchecked Sendable {
    public enum LogError: Error {
        case notRegularFile(URL)
    }
    public let fileURL: URL
    private let maxBytes: Int
    private let backupCount: Int
    private let lock = NSLock()

    public init(fileURL: URL, maxBytes: Int = 5 * 1024 * 1024, backupCount: Int = 3) {
        precondition(maxBytes > 0 && backupCount > 0)
        self.fileURL = fileURL
        self.maxBytes = maxBytes
        self.backupCount = backupCount
    }

    public func append(_ text: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let data = boundedData(text)
        let fm = FileManager.default
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: fileURL.path) {
            let attributes = try fm.attributesOfItem(atPath: fileURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw LogError.notRegularFile(fileURL)
            }
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            if size > UInt64(maxBytes - data.count) {
                try rotate()
            }
        }
        if !fm.fileExists(atPath: fileURL.path) {
            try data.write(to: fileURL, options: .atomic)
            return
        }
        // 世代更新後に開き直すことで、退避済みファイルへの追記を防ぐ。
        let handle = try FileHandle(forWritingTo: fileURL)
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            try? handle.close()
            throw error
        }
        try handle.close()
    }

    private func backup(_ index: Int) -> URL {
        fileURL.appendingPathExtension(String(index))
    }

    private func rotate() throws {
        let fm = FileManager.default
        // ログ名と同名のディレクトリ等があっても削除しない。更新前に全世代を確認する。
        for index in 1...backupCount {
            let url = backup(index)
            if fm.fileExists(atPath: url.path) {
                let attributes = try fm.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else {
                    throw LogError.notRegularFile(url)
                }
            }
        }
        let oldest = backup(backupCount)
        if fm.fileExists(atPath: oldest.path) {
            try fm.removeItem(at: oldest)
        }
        if backupCount > 1 {
            for index in stride(from: backupCount - 1, through: 1, by: -1) {
                let source = backup(index)
                if fm.fileExists(atPath: source.path) {
                    try fm.moveItem(at: source, to: backup(index + 1))
                }
            }
        }
        try fm.moveItem(at: fileURL, to: backup(1))
    }

    private func boundedData(_ text: String) -> Data {
        let data = Data(text.utf8)
        guard data.count > maxBytes else { return data }
        let marker = Data("\n[log entry truncated]\n".utf8.prefix(maxBytes))
        var prefix = Data(data.prefix(maxBytes - marker.count))
        // UTF-8 の途中で切らず、巨大な1行でも容量上限を守る。
        while String(data: prefix, encoding: .utf8) == nil { prefix.removeLast() }
        prefix.append(marker)
        return prefix
    }
}
