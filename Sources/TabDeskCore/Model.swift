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
    /// 実行時にだけ意味を持つ実ウィンドウへの紐付け。永続化しない(nil = 未復元)。
    public var windowID: CGWindowID?
    public var pid: pid_t?

    // windowID / pid は CodingKeys から外すことで JSON に出さない。
    enum CodingKeys: String, CodingKey {
        case id, frame, identity
    }

    public init(id: UUID = UUID(), frame: CGRect, identity: WindowIdentity, windowID: CGWindowID?, pid: pid_t?) {
        self.id = id
        self.frame = frame
        self.identity = identity
        self.windowID = windowID
        self.pid = pid
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

    public init(id: UUID = UUID(), name: String, windows: [ManagedWindow] = [], lastFocusedWindowID: UUID? = nil) {
        self.id = id
        self.name = name
        self.windows = windows
        self.lastFocusedWindowID = lastFocusedWindowID
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
