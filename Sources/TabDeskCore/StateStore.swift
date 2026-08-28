import Foundation

/// WorkspaceState の JSON 保存/読込。書き込みはアトミック(一時ファイル → rename)。
public struct StateStore: Sendable {
    public enum StoreError: Error, CustomStringConvertible {
        case unsupportedVersion(found: Int, expected: Int)

        public var description: String {
            switch self {
            case .unsupportedVersion(let found, let expected):
                return "unsupported state version \(found) (expected \(expected))"
            }
        }
    }

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// 既定の保存先: ~/Library/Application Support/<appName>/state.json
    public static func defaultURL(appName: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(appName, isDirectory: true).appendingPathComponent("state.json")
    }

    /// ファイルが無ければ nil。バージョン不一致は throw(呼び出し側でバックアップして初期化する)。
    public func load() throws -> WorkspaceState? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let state = try JSONDecoder().decode(WorkspaceState.self, from: data)
        guard state.version == WorkspaceState.currentVersion else {
            throw StoreError.unsupportedVersion(found: state.version, expected: WorkspaceState.currentVersion)
        }
        return state
    }

    public func save(_ state: WorkspaceState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 途中でクラッシュしても壊れたファイルが残らないよう、一時ファイルに書いてから置き換える。
        try data.write(to: fileURL, options: .atomic)
    }

    /// 読めなかったファイルを退避する(上書きして履歴を失わないため)。
    public func backupCorruptFile() throws {
        let backup = fileURL.deletingPathExtension().appendingPathExtension("bak.json")
        // 既存 backup を先に削除してから move すると、move 失敗時に新旧どちらの backup も失う。
        // atomic write で置換を完了してから原本を消し、途中失敗でも少なくとも片方を残す。
        let data = try Data(contentsOf: fileURL)
        try data.write(to: backup, options: .atomic)
        try FileManager.default.removeItem(at: fileURL)
    }
}
