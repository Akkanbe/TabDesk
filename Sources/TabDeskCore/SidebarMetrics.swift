import CoreGraphics
import Foundation

/// サイドバーの幅と折りたたみ状態(v3 段階 3、v4 段階 5 で画面ごとに拡張)。
///
/// 実体は UserDefaults なので、struct のコピー間・モジュール間で常に同じ値を共有する
/// (PersistedToggle と同じ仕掛け)。`SystemScreenLayout` は幅プロバイダ closure 越しに
/// ここを毎回読むため、値を変えた直後から contentArea 計算に反映される。
///
/// v4: **幅は全画面で共有**(キーは従来どおり)、**折りたたみは画面ごと**
/// (`SidebarCollapsed.<displayID>`。初回は旧キー `SidebarCollapsed` の値をシードする)。
public struct SidebarMetrics: Sendable {
    public static let minWidth: CGFloat = 160
    public static let maxWidth: CGFloat = 400
    /// 折りたたみ中の細いバーの幅(クリックで展開するためのつまみ)。
    public static let collapsedWidth: CGFloat = 16
    public static let defaultWidth: CGFloat = 240

    private let width: PersistedNumber
    private let collapsed: PersistedToggle

    public init(displayID: DisplayID? = nil, defaults: UserDefaults = .standard) {
        width = PersistedNumber(
            key: "SidebarExpandedWidth", defaultValue: Double(Self.defaultWidth), defaults: defaults)
        let legacy = PersistedToggle(key: "SidebarCollapsed", defaultValue: false, defaults: defaults)
        if let displayID {
            // 画面ごとの折りたたみ。既定値に旧グローバルキーの値を使う = v3 からの引き継ぎ。
            collapsed = PersistedToggle(
                key: "SidebarCollapsed.\(displayID)", defaultValue: legacy.value, defaults: defaults)
        } else {
            collapsed = legacy
        }
    }

    /// 展開時の幅。読み書きの両方で [minWidth, maxWidth] に丸める(手書きの defaults にも耐える)。
    public var expandedWidth: CGFloat {
        get {
            let stored = CGFloat(width.value)
            guard stored.isFinite else {
                width.value = Double(Self.defaultWidth)  // 起動クラッシュが再発しないよう壊れた保存値も自己修復する
                return Self.defaultWidth
            }
            return min(max(stored, Self.minWidth), Self.maxWidth)
        }
        nonmutating set {
            let finite = newValue.isFinite ? newValue : Self.defaultWidth
            width.value = Double(min(max(finite, Self.minWidth), Self.maxWidth))
        }
    }

    public var isCollapsed: Bool {
        get { collapsed.value }
        nonmutating set { collapsed.value = newValue }
    }

    /// レイアウト計算(contentArea)に使う実効幅。折りたたみ中は細いバーの幅。
    public var effectiveWidth: CGFloat { isCollapsed ? Self.collapsedWidth : expandedWidth }
}
