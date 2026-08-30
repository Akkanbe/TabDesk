import Foundation

/// UserDefaults に保存する数値の設定(PersistedToggle の数値版)。
/// 既定値の登録と読み書きを 1 箇所にまとめ、「登録前に読んで 0 を表示する」種の事故を防ぐ。
// UserDefaults はスレッドセーフ(Apple ドキュメント)だが Sendable 注釈が無いので unchecked にする。
public struct PersistedNumber: @unchecked Sendable {
    public let key: String
    public let defaultValue: Double
    private let defaults: UserDefaults

    public init(key: String, defaultValue: Double, defaults: UserDefaults = .standard) {
        self.key = key
        self.defaultValue = defaultValue
        self.defaults = defaults
        defaults.register(defaults: [key: defaultValue])
    }

    public var value: Double {
        get { defaults.double(forKey: key) }
        nonmutating set { defaults.set(newValue, forKey: key) }
    }
}
