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
    /// 所属ディスプレイ(v4)。nil =「そのときの主ディスプレイ」(v1〜v3 データと空タブ。
    /// 主画面の役割が移っても凍結しないための意味論)。具体 ID は物理画面に固定される。
    /// 不変量(v4 段階 3 以降): タブ内の全窓の displayID はタブの displayID と一致する。
    public var displayID: DisplayID?

    public init(
        id: UUID = UUID(), name: String, windows: [ManagedWindow] = [],
        lastFocusedWindowID: UUID? = nil, layout: TabLayout = .free, displayID: DisplayID? = nil
    ) {
        self.id = id
        self.name = name
        self.windows = windows
        self.lastFocusedWindowID = lastFocusedWindowID
        self.layout = layout
        self.displayID = displayID
    }

    enum CodingKeys: String, CodingKey {
        case id, name, windows, lastFocusedWindowID, layout, displayID
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
        displayID = try c.decodeIfPresent(DisplayID.self, forKey: .displayID)  // キー無し(v3 以前)= nil = 主
    }
}

/// エンジンの全状態。永続化の単位でもある。
public struct WorkspaceState: Codable, Sendable, Hashable {
    public static let currentVersion = 1

    public var version: Int
    public var tabs: [Tab]
    /// v3 まで唯一のアクティブタブ。v4 以降は「主ディスプレイのアクティブ」のミラーとして
    /// 書き続ける(旧バイナリで開いても v3 モードで動くダウングレード耐性のため。docs/06_v4_design.md)。
    public var activeTabID: UUID?
    /// ディスプレイごとのアクティブタブ(v4)。キーは接続時の具体 DisplayID
    /// (nil タブ = 主の意味のタブも、そのときの主ディスプレイの具体 ID で載る)。
    public var activeTabIDs: [DisplayID: UUID]

    public init(tabs: [Tab] = [], activeTabID: UUID? = nil, activeTabIDs: [DisplayID: UUID] = [:]) {
        self.version = Self.currentVersion
        self.tabs = tabs
        self.activeTabID = activeTabID
        self.activeTabIDs = activeTabIDs
    }

    enum CodingKeys: String, CodingKey {
        case version, tabs, activeTabID, activeTabIDs
    }

    /// activeTabIDs はキーが無い v3 以前のファイルでも読めるよう寛容にデコードする(version は 1 のまま)。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        tabs = try c.decode([Tab].self, forKey: .tabs)
        activeTabID = try c.decodeIfPresent(UUID.self, forKey: .activeTabID)
        activeTabIDs = (try? c.decode([DisplayID: UUID].self, forKey: .activeTabIDs)) ?? [:]
    }

    public func tab(withID id: UUID) -> Tab? {
        tabs.first { $0.id == id }
    }

    public var activeTab: Tab? {
        activeTabID.flatMap(tab(withID:))
    }

    /// 指定ディスプレイに属するタブ(並び順維持)。nil タブは主ディスプレイ扱い。
    public func tabs(on displayID: DisplayID, primaryID: DisplayID?) -> [Tab] {
        tabs.filter { ($0.displayID ?? primaryID) == displayID }
    }

    /// 指定ディスプレイのアクティブタブ。
    public func activeTab(on displayID: DisplayID) -> Tab? {
        activeTabIDs[displayID].flatMap(tab(withID:))
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
