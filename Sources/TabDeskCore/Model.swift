import CoreGraphics
import Foundation

/// 再起動をまたいでウィンドウを再同定するための情報。
/// CGWindowID はセッション内でしか安定しないので、これをヒューリスティックの材料にする(復元は段階 4)。
public struct WindowIdentity: Codable, Sendable, Hashable {
    public var bundleID: String
    public var appName: String
    public var title: String
    public var registeredSize: CGSize

    public init(bundleID: String, appName: String, title: String, registeredSize: CGSize) {
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.registeredSize = registeredSize
    }
}

/// タブに登録されたウィンドウ 1 枚。
public struct ManagedWindow: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    /// 固定 frame(AX 座標)。「要求値」ではなく「適用後に到達した frame」を持つ。
    public var frame: CGRect
    public var identity: WindowIdentity
    /// 所属ディスプレイ(v2 段階 D)。nil = 主ディスプレイ(v1 データもここに落ちる)。
    /// optional なので合成デコーダが decodeIfPresent になり、キーの無い v1 ファイルもそのまま読める。
    public var displayID: DisplayID?
    /// 実行時にだけ意味を持つ実ウィンドウへの紐付け。永続化しない(nil = 未復元)。
    public var windowID: CGWindowID?
    public var pid: pid_t?

    // windowID / pid は CodingKeys から外すことで JSON に出さない。
    enum CodingKeys: String, CodingKey {
        case id, frame, identity, displayID
    }

    public init(
        id: UUID = UUID(), frame: CGRect, identity: WindowIdentity,
        windowID: CGWindowID?, pid: pid_t?, displayID: DisplayID? = nil
    ) {
        self.id = id
        self.frame = frame
        self.identity = identity
        self.windowID = windowID
        self.pid = pid
        self.displayID = displayID
    }

    public var isBound: Bool {
        windowID != nil && pid != nil
    }
}

public struct Tab: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var name: String
    public var windows: [ManagedWindow]
    /// このタブで最後にフォーカスされていたウィンドウ。切替時に最前面へ持ってくる。
    public var lastFocusedWindowID: UUID?
    /// 配置方式(v2 段階 C)。
    public var layout: TabLayout

    public init(
        id: UUID = UUID(), name: String, windows: [ManagedWindow] = [],
        lastFocusedWindowID: UUID? = nil, layout: TabLayout = .free
    ) {
        self.id = id
        self.name = name
        self.windows = windows
        self.lastFocusedWindowID = lastFocusedWindowID
        self.layout = layout
    }

    enum CodingKeys: String, CodingKey {
        case id, name, windows, lastFocusedWindowID, layout
    }

    /// タブを代表する実ウィンドウ(サムネイル撮影の対象。v3 段階 5)。
    /// 最後にフォーカスされていた bound な窓 → 無ければ先頭の bound な窓。全滅なら nil。
    public var representativeWindow: ManagedWindow? {
        if let id = lastFocusedWindowID, let window = windows.first(where: { $0.id == id }), window.isBound {
            return window
        }
        return windows.first(where: \.isBound)
    }

    /// layout はキーが無い v1 の state.json も、将来の未知の値も `.free` として読む。
    /// version を上げる移行(不一致で .bak 退避+初期化)を避けるための後方互換デコード(docs/04_v2_design.md)。
    /// encode は合成のまま(layout も常に書く)。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        windows = try c.decode([ManagedWindow].self, forKey: .windows)
        lastFocusedWindowID = try c.decodeIfPresent(UUID.self, forKey: .lastFocusedWindowID)
        layout = (try? c.decode(TabLayout.self, forKey: .layout)) ?? .free
    }
}

/// エンジンの全状態。永続化の単位でもある。
public struct WorkspaceState: Codable, Sendable, Hashable {
    public static let currentVersion = 1

    public var version: Int
    public var tabs: [Tab]
    public var activeTabID: UUID?

    public init(tabs: [Tab] = [], activeTabID: UUID? = nil) {
        self.version = Self.currentVersion
        self.tabs = tabs
        self.activeTabID = activeTabID
    }

    public func tab(withID id: UUID) -> Tab? {
        tabs.first { $0.id == id }
    }

    public var activeTab: Tab? {
        activeTabID.flatMap(tab(withID:))
    }

    /// 実ウィンドウ ID から登録情報を引く。
    public func managedWindow(forWindowID windowID: CGWindowID) -> (tab: Tab, window: ManagedWindow)? {
        for tab in tabs {
            if let w = tab.windows.first(where: { $0.windowID == windowID }) {
                return (tab, w)
            }
        }
        return nil
    }

    public func managedWindow(id: UUID) -> (tab: Tab, window: ManagedWindow)? {
        for tab in tabs {
            if let w = tab.windows.first(where: { $0.id == id }) {
                return (tab, w)
            }
        }
        return nil
    }

    public var allWindows: [ManagedWindow] {
        tabs.flatMap(\.windows)
    }
}
