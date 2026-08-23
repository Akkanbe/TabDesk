import Foundation

/// UserDefaults に保存する真偽値の設定。既定値の登録と読み書きを 1 箇所にまとめ、
/// 「既定値を登録する前に読んで逆の状態を表示する」種の事故を防ぐ。
// UserDefaults はスレッドセーフ(Apple ドキュメント)だが Sendable 注釈が無いので unchecked にする。
public struct PersistedToggle: @unchecked Sendable {
    public let key: String
    public let defaultValue: Bool
    private let defaults: UserDefaults

    public init(key: String, defaultValue: Bool, defaults: UserDefaults = .standard) {
        self.key = key
        self.defaultValue = defaultValue
        self.defaults = defaults
        defaults.register(defaults: [key: defaultValue])
    }

    public var value: Bool {
        get { defaults.bool(forKey: key) }
        nonmutating set { defaults.set(newValue, forKey: key) }
    }
}
