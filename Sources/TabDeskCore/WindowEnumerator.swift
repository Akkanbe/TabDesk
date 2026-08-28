import AppKit
import ApplicationServices

/// 列挙時点のウィンドウ情報のスナップショット。
public struct WindowRecord: Sendable {
    public let window: AXWindow
    public let appName: String
    public let bundleID: String
    public let title: String
    public let frame: CGRect?
    public let isMinimized: Bool
    /// 列挙時点の "AXFullScreen" 生値(nil = 属性なし)。判定には isFullscreen を使う。
    public let fullscreenRaw: Bool?

    public init(
        window: AXWindow, appName: String, bundleID: String, title: String,
        frame: CGRect?, isMinimized: Bool, fullscreenRaw: Bool? = nil
    ) {
        self.window = window
        self.appName = appName
        self.bundleID = bundleID
        self.title = title
        self.frame = frame
        self.isMinimized = isMinimized
        self.fullscreenRaw = fullscreenRaw
    }

    public var isFullscreen: Bool { fullscreenRaw ?? false }
}

/// 列挙の内訳。「0 件」のときに権限なし・ウィンドウなし・私有関数の不調のどれかを切り分けるために残す。
public struct EnumerationStats: Sendable, CustomStringConvertible {
    public var apps = 0
    /// kAXWindows が読めなかったアプリ(ウィンドウなし・無応答・権限なし)と AXError の内訳。
    public var appFailures: [String: Int] = [:]
    public var elements = 0
    public var nonStandard = 0
    /// ネイティブフルスクリーン中のため除外した標準ウィンドウ数(v2 段階 A)。
    public var fullscreen = 0
    /// 最小化中のため除外した標準ウィンドウ数(v2 段階 A)。
    public var minimized = 0
    /// _AXUIElementGetWindow が失敗した要素数と AXError の内訳。
    public var windowIDFailures: [String: Int] = [:]
    public var standard = 0
    /// 「どのアプリで」失敗したか(原因調査用)。
    public var appFailureDetails: [String] = []
    public var windowIDFailureDetails: [String] = []
    /// フルスクリーン/最小化で除外した窓の内訳(実測とフィルタ誤検知の確認用。docs/04_v2_design.md)。
    public var exclusionDetails: [String] = []

    public var description: String {
        func fmt(_ d: [String: Int]) -> String {
            d.isEmpty ? "0" : d.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",")
        }
        var s = "apps=\(apps) appFailures=[\(fmt(appFailures))] elements=\(elements) " +
            "nonStandard=\(nonStandard) fullscreen=\(fullscreen) minimized=\(minimized) " +
            "windowIDFailures=[\(fmt(windowIDFailures))] standard=\(standard)"
        if !appFailureDetails.isEmpty { s += " appFailureDetails=\(appFailureDetails)" }
        if !windowIDFailureDetails.isEmpty { s += " windowIDFailureDetails=\(windowIDFailureDetails)" }
        if !exclusionDetails.isEmpty { s += " exclusionDetails=\(exclusionDetails)" }
        return s
    }
}

/// 列挙対象アプリの軽量な記述(NSWorkspace から MainActor 上で取る)。AX には触れない。
public struct AppDescriptor: Sendable, Hashable {
    public let pid: pid_t
    public let name: String
    public let bundleID: String

    public init(pid: pid_t, name: String, bundleID: String) {
        self.pid = pid
        self.name = name
        self.bundleID = bundleID
    }
}

/// 1 アプリ分の列挙結果。
public struct AppEnumeration: Sendable {
    public var records: [WindowRecord]
    public var stats: EnumerationStats

    public init(records: [WindowRecord], stats: EnumerationStats) {
        self.records = records
        self.stats = stats
    }
}

extension EnumerationStats {
    mutating func merge(_ other: EnumerationStats) {
        apps += other.apps
        for (k, v) in other.appFailures { appFailures[k, default: 0] += v }
        elements += other.elements
        nonStandard += other.nonStandard
        fullscreen += other.fullscreen
        minimized += other.minimized
        for (k, v) in other.windowIDFailures { windowIDFailures[k, default: 0] += v }
        standard += other.standard
        appFailureDetails += other.appFailureDetails
        windowIDFailureDetails += other.windowIDFailureDetails
        exclusionDetails += other.exclusionDetails
    }
}

public enum WindowEnumerator {
    /// 列挙時の AX タイムアウト。応答しないアプリで UI が固まらないよう短くする。
    public static let messagingTimeout: Float = 0.5

    /// 通常アプリ(Dock に出るアプリ)の一覧。NSWorkspace なので MainActor、AX IPC は無い。
    @MainActor
    public static func regularApps(excludingPID excluded: pid_t = getpid()) -> [AppDescriptor] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, app.processIdentifier != excluded else { return nil }
            return AppDescriptor(
                pid: app.processIdentifier,
                name: app.localizedName ?? "pid \(app.processIdentifier)",
                bundleID: app.bundleIdentifier ?? "")
        }
    }

    /// 1 アプリの標準ウィンドウを列挙する(相手アプリへの同期 IPC。バックグラウンドで呼ぶこと)。
    /// ダイアログ・シート・パネルは kAXStandardWindowSubrole でないので除外される。
    public static func enumerateWindows(of app: AppDescriptor) -> AppEnumeration {
        var result: [WindowRecord] = []
        var stats = EnumerationStats()
        stats.apps = 1
        let pid = app.pid
        let appName = app.name
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)

        let elements: [AXUIElement]
        do {
            elements = try AXAttributes.elements(appElement, kAXWindowsAttribute)
        } catch let error as AXCallError {
            stats.appFailures[error.code.readableDescription, default: 0] += 1
            stats.appFailureDetails.append("\(appName): \(error.code.readableDescription)")
            return AppEnumeration(records: [], stats: stats)
        } catch {
            stats.appFailures["\(error)", default: 0] += 1
            stats.appFailureDetails.append("\(appName): \(error)")
            return AppEnumeration(records: [], stats: stats)
        }
        for element in elements {
            stats.elements += 1
            AXUIElementSetMessagingTimeout(element, messagingTimeout)
            let window: AXWindow
            do {
                window = try AXWindow(element: element, pid: pid)
            } catch let error as AXCallError {
                stats.windowIDFailures[error.code.readableDescription, default: 0] += 1
                let role = (try? AXAttributes.string(element, kAXRoleAttribute)) ?? "?"
                let subrole = (try? AXAttributes.string(element, kAXSubroleAttribute)) ?? "?"
                stats.windowIDFailureDetails.append("\(appName) [\(role)/\(subrole)]: \(error.code.readableDescription)")
                continue
            } catch {
                stats.windowIDFailures["\(error)", default: 0] += 1
                stats.windowIDFailureDetails.append("\(appName): \(error)")
                continue
            }
            guard window.isStandard else {
                stats.nonStandard += 1
                continue
            }
            // フルスクリーン中は登録対象外(仕様 §3.3)。最小化中も除外する:
            // frame は書けても raise で復帰せず、登録しても切替時に現れない死にエントリになるため。
            guard !window.isFullscreen else {
                stats.fullscreen += 1
                stats.exclusionDetails.append("\(appName) [fullscreen]: \(window.title)")
                continue
            }
            guard !window.isMinimized else {
                stats.minimized += 1
                stats.exclusionDetails.append("\(appName) [minimized]: \(window.title)")
                continue
            }
            stats.standard += 1
            result.append(
                WindowRecord(
                    window: window,
                    appName: appName,
                    bundleID: app.bundleID,
                    title: window.title,
                    frame: try? window.frame(),
                    isMinimized: window.isMinimized,
                    fullscreenRaw: window.fullscreenRaw
                )
            )
        }
        return AppEnumeration(records: result, stats: stats)
    }

    /// 複数アプリを pid ごとに並列で列挙し、結果を結合する(MainActor を塞がない)。
    /// `enumerate` は差し替え可能(テストで遅延バックエンドを注入する)。
    public static func enumerateInParallel(
        _ apps: [AppDescriptor],
        enumerate: @escaping @Sendable (AppDescriptor) -> AppEnumeration = enumerateWindows(of:)
    ) async -> (records: [WindowRecord], stats: EnumerationStats) {
        let executor = BlockingExecutor()
        let results: [AppEnumeration] = await withTaskGroup(of: AppEnumeration.self) { group in
            for app in apps {
                group.addTask { await executor.run { enumerate(app) } }
            }
            var all: [AppEnumeration] = []
            for await r in group { all.append(r) }
            return all
        }
        var records: [WindowRecord] = []
        var stats = EnumerationStats()
        // 結果順を安定させる(pid 昇順)。TaskGroup の完了順は不定のため。
        for r in results.sorted(by: { ($0.records.first?.window.pid ?? 0) < ($1.records.first?.window.pid ?? 0) }) {
            records += r.records
            stats.merge(r.stats)
        }
        return (records, stats)
    }

    /// 通常アプリの標準ウィンドウを pid 並列で列挙する(MainActor を塞がない版)。
    @MainActor
    public static func standardWindowsAsync(excludingPID excluded: pid_t = getpid())
        async -> (records: [WindowRecord], stats: EnumerationStats)
    {
        await enumerateInParallel(regularApps(excludingPID: excluded))
    }

    /// 同期版(PoC 用)。MainActor 上で全アプリへ逐次 IPC するので本体では使わない。
    @MainActor
    public static func standardWindows(excludingPID excluded: pid_t = getpid())
        -> (records: [WindowRecord], stats: EnumerationStats)
    {
        var records: [WindowRecord] = []
        var stats = EnumerationStats()
        for app in regularApps(excludingPID: excluded) {
            let r = enumerateWindows(of: app)
            records += r.records
            stats.merge(r.stats)
        }
        return (records, stats)
    }

    /// CGWindowList 側から見た画面上のウィンドウ ID(_AXUIElementGetWindow の答え合わせ用)。
    /// 最小化・別 Space・フルスクリーン中の窓は含まないので、`TabEngine.reconcile` には渡さないこと。
    public static func onScreenWindowIDs() -> Set<CGWindowID> {
        windowIDs(options: [.optionOnScreenOnly, .excludeDesktopElements])
    }

    /// 存在する全ウィンドウの ID(最小化・別 Space・フルスクリーン中も含む)。`TabEngine.reconcile` に渡す用。
    /// 列挙に失敗したときは空集合(reconcile 側は空集合なら削除しない)。
    public static func existingWindowIDs() -> Set<CGWindowID> {
        windowIDs(options: [.optionAll, .excludeDesktopElements])
    }

    private static func windowIDs(options: CGWindowListOption) -> Set<CGWindowID> {
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        var ids = Set<CGWindowID>()
        for info in list {
            // layer 0 が通常ウィンドウ。メニューバー等のオーバーレイは除外。
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                let number = info[kCGWindowNumber as String] as? CGWindowID
            else { continue }
            ids.insert(number)
        }
        return ids
    }
}
