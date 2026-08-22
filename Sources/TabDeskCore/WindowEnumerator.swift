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
}

/// 列挙の内訳。「0 件」のときに権限なし・ウィンドウなし・私有関数の不調のどれかを切り分けるために残す。
public struct EnumerationStats: Sendable, CustomStringConvertible {
    public var apps = 0
    /// kAXWindows が読めなかったアプリ(ウィンドウなし・無応答・権限なし)と AXError の内訳。
    public var appFailures: [String: Int] = [:]
    public var elements = 0
    public var nonStandard = 0
    /// _AXUIElementGetWindow が失敗した要素数と AXError の内訳。
    public var windowIDFailures: [String: Int] = [:]
    public var standard = 0
    /// 「どのアプリで」失敗したか(原因調査用)。
    public var appFailureDetails: [String] = []
    public var windowIDFailureDetails: [String] = []

    public var description: String {
        func fmt(_ d: [String: Int]) -> String {
            d.isEmpty ? "0" : d.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",")
        }
        var s = "apps=\(apps) appFailures=[\(fmt(appFailures))] elements=\(elements) " +
            "nonStandard=\(nonStandard) windowIDFailures=[\(fmt(windowIDFailures))] standard=\(standard)"
        if !appFailureDetails.isEmpty { s += " appFailureDetails=\(appFailureDetails)" }
        if !windowIDFailureDetails.isEmpty { s += " windowIDFailureDetails=\(windowIDFailureDetails)" }
        return s
    }
}

public enum WindowEnumerator {
    /// 列挙時の AX タイムアウト。応答しないアプリで UI が固まらないよう短くする。
    public static let messagingTimeout: Float = 0.5

    /// 通常アプリ(Dock に出るアプリ)の標準ウィンドウを列挙する。
    /// ダイアログ・シート・パネルは kAXStandardWindowSubrole でないので除外される。
    @MainActor
    public static func standardWindows(excludingPID excluded: pid_t = getpid())
        -> (records: [WindowRecord], stats: EnumerationStats)
    {
        var result: [WindowRecord] = []
        var stats = EnumerationStats()
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular, app.processIdentifier != excluded else { continue }
            stats.apps += 1
            let pid = app.processIdentifier
            let appName = app.localizedName ?? "pid \(pid)"
            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appElement, messagingTimeout)

            let elements: [AXUIElement]
            do {
                elements = try AXAttributes.elements(appElement, kAXWindowsAttribute)
            } catch let error as AXCallError {
                stats.appFailures[error.code.readableDescription, default: 0] += 1
                stats.appFailureDetails.append("\(appName): \(error.code.readableDescription)")
                continue
            } catch {
                stats.appFailures["\(error)", default: 0] += 1
                stats.appFailureDetails.append("\(appName): \(error)")
                continue
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
                stats.standard += 1
                result.append(
                    WindowRecord(
                        window: window,
                        appName: appName,
                        bundleID: app.bundleIdentifier ?? "",
                        title: window.title,
                        frame: try? window.frame(),
                        isMinimized: window.isMinimized
                    )
                )
            }
        }
        return (result, stats)
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
