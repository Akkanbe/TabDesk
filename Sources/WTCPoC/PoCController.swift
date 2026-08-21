import AppKit
import ApplicationServices
import AXShim
import WTCCore

/// v0 検証項目を実行するコントローラ。UI と URL スキームの両方から同じメソッドを叩く。
@MainActor
final class PoCController {
    enum SetName: String, CaseIterable {
        case a = "A"
        case b = "B"
    }

    struct Entry {
        var window: AXWindow
        var set: SetName
        /// 「あるべき位置」。スナップバックと復元の基準。
        var recordedFrame: CGRect
        var appName: String
        var title: String
        var isParked = false
    }

    enum Placement: String {
        case left, right, full
    }

    /// サイドバー幅の想定値(モックアップ比率から)。コンテンツ領域はこの右側。
    static let sidebarWidth: CGFloat = 240

    let logger: PoCLogger
    private(set) var records: [WindowRecord] = []
    private(set) var entries: [CGWindowID: Entry] = [:]
    private(set) var activeSet: SetName?
    private(set) var watching = false
    var parallel = false
    var editMode = false
    var onChanged: (() -> Void)?

    /// スナップバックの方式。
    /// - immediate: 通知が来るたびに即座に戻す(ドラッグ中も引き戻す = 掴んでも動かせない体感)
    /// - debounced: 通知が一定時間止んでから戻す(ドラッグ終了後に戻る体感。掴んでいる最中の
    ///   一時状態を制約と誤認して基準 frame を書き換えてしまう事故も防げる)
    enum SnapMode: String {
        case immediate, debounced
    }
    var snapMode: SnapMode = .debounced
    var debounceMs = 250
    private static let maxRestoreAttempts = 3

    private var observers: [pid_t: AppWindowObserver] = [:]
    private var pendingRestores: [CGWindowID: DispatchWorkItem] = [:]

    init(logger: PoCLogger) {
        self.logger = logger
    }

    // MARK: - 状態確認

    var isTrusted: Bool { AXIsProcessTrusted() }

    func status() {
        let screen = ScreenGeometry.primaryScreen
        logger.log("status: accessibility=\(isTrusted ? "granted" : "NOT granted") " +
            "_AXUIElementGetWindow=\(AXShimIsAvailable() ? "available" : "MISSING") " +
            "primaryScreen=\(screen.map { "\(ScreenGeometry.fullFrameAX(of: $0))" } ?? "none") " +
            "visible=\(screen.map { "\(ScreenGeometry.visibleFrameAX(of: $0))" } ?? "none") " +
            "contentArea=\(contentArea.map { "\($0)" } ?? "none")")
    }

    func requestPermission() {
        // プロンプト付きで問い合わせると、未許可ならシステム設定へ誘導するダイアログが出る。
        // kAXTrustedCheckOptionPrompt はグローバル var として import され Swift 6 では参照できないため、
        // その実体である文字列キーを直接使う。
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        logger.log("requestPermission: trusted=\(trusted)")
    }

    // MARK: - 列挙

    func refresh() {
        let sw = Stopwatch()
        let (found, stats) = WindowEnumerator.standardWindows()
        records = found
        let axIDs = Set(records.map(\.window.windowID))
        let cgIDs = WindowEnumerator.onScreenWindowIDs()
        let onScreenNotInAX = cgIDs.subtracting(axIDs).count
        logger.log("refresh: \(records.count) standard windows in \(fmt(sw.elapsedMs)) ms; " +
            "AX∩CG=\(axIDs.intersection(cgIDs).count) AX-only(minimized等)=\(axIDs.subtracting(cgIDs).count) " +
            "CG-only(非標準/他アプリ)=\(onScreenNotInAX)")
        logger.log("refresh: \(stats)")
        if !stats.windowIDFailures.isEmpty {
            logger.log("refresh: ⚠ _AXUIElementGetWindow failed for some elements — 検証項目 2 要確認")
        }
        // 閉じられたウィンドウをセットから外す。
        for (wid, entry) in entries where (try? entry.window.frame()) == nil {
            logger.log("refresh: drop closed window \(wid) (\(entry.appName) / \(entry.title))")
            entries.removeValue(forKey: wid)
        }
        refreshObserversIfWatching()
        onChanged?()
    }

    func list() {
        for r in records {
            let set = entries[r.window.windowID]?.set.rawValue ?? "-"
            logger.log("  [\(set)] wid=\(r.window.windowID) pid=\(r.window.pid) \(r.appName) | \(r.title) | " +
                "\(r.frame.map { fmt($0) } ?? "?")\(r.isMinimized ? " (minimized)" : "")")
        }
    }

    // MARK: - セット管理

    func add(_ wids: [CGWindowID], to set: SetName) {
        for wid in wids {
            guard let r = records.first(where: { $0.window.windowID == wid }) else {
                logger.log("add: wid \(wid) not in list (refresh first?)")
                continue
            }
            guard let frame = try? r.window.frame() else {
                logger.log("add: wid \(wid) frame unavailable")
                continue
            }
            entries[wid] = Entry(window: r.window, set: set, recordedFrame: frame, appName: r.appName, title: r.title)
            logger.log("add: wid \(wid) \(r.appName) → set \(set.rawValue), recorded \(fmt(frame))")
        }
        refreshObserversIfWatching()
        onChanged?()
    }

    func remove(_ wids: [CGWindowID]) {
        for wid in wids where entries.removeValue(forKey: wid) != nil {
            logger.log("remove: wid \(wid)")
        }
        refreshObserversIfWatching()
        onChanged?()
    }

    // MARK: - 配置・退避・復元

    var contentArea: CGRect? {
        guard let screen = ScreenGeometry.primaryScreen else { return nil }
        let visible = ScreenGeometry.visibleFrameAX(of: screen)
        return CGRect(
            x: visible.minX + Self.sidebarWidth, y: visible.minY,
            width: visible.width - Self.sidebarWidth, height: visible.height)
    }

    func place(_ wids: [CGWindowID], _ placement: Placement) {
        guard let area = contentArea else { return }
        let target: CGRect
        switch placement {
        case .left: target = CGRect(x: area.minX, y: area.minY, width: area.width / 2, height: area.height)
        case .right: target = CGRect(x: area.midX, y: area.minY, width: area.width / 2, height: area.height)
        case .full: target = area
        }
        for wid in wids {
            guard var entry = entries[wid] else {
                logger.log("place: wid \(wid) is not in a set")
                continue
            }
            let sw = Stopwatch()
            do {
                let actual = try entry.window.setFrame(target)
                // 要求値ではなく到達した frame を基準にする。最小サイズ制約などで要求どおりにならない
                // アプリでも、以後のスナップバック判定(現在 frame と基準の比較)が成立するようにするため。
                entry.recordedFrame = actual
                entry.isParked = false
                entries[wid] = entry
                logger.log("place \(placement.rawValue): wid \(wid) \(entry.appName) in \(fmt(sw.elapsedMs)) ms; " +
                    "requested \(fmt(target)) actual \(fmt(actual))" +
                    (ScreenGeometry.approximatelyEqual(target, actual) ? "" : "  ⚠ MISMATCH"))
            } catch {
                logger.log("place: wid \(wid) \(entry.appName) FAILED: \(error)")
            }
        }
        onChanged?()
    }

    func park(_ wids: [CGWindowID]) {
        guard let screen = ScreenGeometry.primaryScreen else { return }
        let point = ScreenGeometry.parkPoint(on: screen)
        for wid in wids {
            guard var entry = entries[wid] else { continue }
            let sw = Stopwatch()
            do {
                try entry.window.setPosition(point)
                let actual = try entry.window.frame()
                entry.isParked = true
                entries[wid] = entry
                logger.log("park: wid \(wid) \(entry.appName) in \(fmt(sw.elapsedMs)) ms; " +
                    "requested \(fmt(point)) actual origin \(fmt(actual.origin)) size \(fmt(actual.size))")
            } catch {
                logger.log("park: wid \(wid) \(entry.appName) FAILED: \(error)")
            }
        }
        onChanged?()
    }

    func restore(_ wids: [CGWindowID]) {
        for wid in wids {
            guard var entry = entries[wid] else { continue }
            let sw = Stopwatch()
            do {
                let actual = try entry.window.setFrame(entry.recordedFrame)
                try entry.window.raise()
                entry.isParked = false
                entries[wid] = entry
                logger.log("restore: wid \(wid) \(entry.appName) in \(fmt(sw.elapsedMs)) ms; actual \(fmt(actual))" +
                    (ScreenGeometry.approximatelyEqual(entry.recordedFrame, actual) ? "" : "  ⚠ MISMATCH"))
            } catch {
                logger.log("restore: wid \(wid) \(entry.appName) FAILED: \(error)")
            }
        }
        onChanged?()
    }

    /// 任意の frame へ移動する。セット未登録のウィンドウも対象(検証で動かした窓を元へ戻す用途)。
    func move(_ wid: CGWindowID, to frame: CGRect) {
        let window: AXWindow
        let name: String
        if let e = entries[wid] {
            window = e.window
            name = e.appName
        } else if let r = records.first(where: { $0.window.windowID == wid }) {
            window = r.window
            name = r.appName
        } else {
            logger.log("move: wid \(wid) not found (refresh first?)")
            return
        }
        let sw = Stopwatch()
        do {
            let actual = try window.setFrame(frame)
            if var e = entries[wid] {
                e.recordedFrame = actual
                e.isParked = false
                entries[wid] = e
            }
            logger.log("move: wid \(wid) \(name) in \(fmt(sw.elapsedMs)) ms; requested \(fmt(frame)) actual \(fmt(actual))" +
                (ScreenGeometry.approximatelyEqual(frame, actual) ? "" : "  ⚠ MISMATCH"))
        } catch {
            logger.log("move: wid \(wid) \(name) FAILED: \(error)")
        }
        onChanged?()
    }

    // MARK: - セット切替(タブ切替の中核)

    private struct Op: Sendable {
        enum Kind: Sendable {
            case park(CGPoint)
            case restore(CGRect)
        }
        let wid: CGWindowID
        let window: AXWindow
        let kind: Kind
    }

    /// セットを切り替え、所要時間(ms)を返す。
    @discardableResult
    func show(_ set: SetName) -> Double {
        guard let screen = ScreenGeometry.primaryScreen else { return 0 }
        let point = ScreenGeometry.parkPoint(on: screen)
        var ops: [Op] = []
        for (wid, e) in entries {
            if e.set == set {
                ops.append(Op(wid: wid, window: e.window, kind: .restore(e.recordedFrame)))
            } else if !e.isParked {
                ops.append(Op(wid: wid, window: e.window, kind: .park(point)))
            }
        }
        // 退避を先に出すと、復元されたウィンドウの上に退避中ウィンドウが一瞬残らない。
        ops.sort { lhs, _ in if case .park = lhs.kind { return true } else { return false } }

        let sw = Stopwatch()
        let failures: [(CGWindowID, String)]
        if parallel {
            failures = Self.runParallel(ops, logger: logger)
        } else {
            failures = Self.runSequential(ops)
        }
        let elapsed = sw.elapsedMs

        // 失敗(タイムアウト含む)した op は実際の位置が不明なので状態を進めない。
        // 退避は次回の show() で再試行され、復元は毎回必ず発行されるので取りこぼしが残らない。
        let failedWIDs = Set(failures.map(\.0))
        for op in ops where !failedWIDs.contains(op.wid) {
            guard var e = entries[op.wid] else { continue }
            if case .park = op.kind { e.isParked = true } else { e.isParked = false }
            entries[op.wid] = e
        }
        activeSet = set
        // フォーカスもセット側へ移す(アプリ単位の activate で十分)。
        if let first = entries.values.first(where: { $0.set == set }),
            let app = NSRunningApplication(processIdentifier: first.window.pid)
        {
            app.activate()
        }
        logger.log("show \(set.rawValue): \(ops.count) ops (\(parallel ? "parallel" : "sequential")) in \(fmt(elapsed)) ms" +
            (failures.isEmpty ? "" : "; FAILURES: \(failures.map { "\($0.0): \($0.1)" }.joined(separator: ", "))"))
        onChanged?()
        return elapsed
    }

    private nonisolated static func run(_ op: Op) throws {
        switch op.kind {
        case .park(let p):
            try op.window.setPosition(p)
        case .restore(let r):
            try op.window.setFrame(r)
            try op.window.raise()
        }
    }

    private nonisolated static func runSequential(_ ops: [Op]) -> [(CGWindowID, String)] {
        var failures: [(CGWindowID, String)] = []
        for op in ops {
            do { try run(op) } catch { failures.append((op.wid, "\(error)")) }
        }
        return failures
    }

    /// pid ごとに別スレッドで実行する。AX 呼び出しは相手アプリへの同期 IPC なので、
    /// 1 アプリが遅くても他アプリの移動はブロックされない。
    private nonisolated static func runParallel(_ ops: [Op], logger: PoCLogger) -> [(CGWindowID, String)] {
        let groups = Dictionary(grouping: ops, by: \.window.pid)
        let failures = Locked<[(CGWindowID, String)]>([])
        let timings = Locked<[String]>([])
        let finishedPIDs = Locked<Set<pid_t>>([])
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInteractive)
        for (pid, groupOps) in groups {
            queue.async(group: group) {
                let sw = Stopwatch()
                for op in groupOps {
                    do { try run(op) } catch { failures.withValue { $0.append((op.wid, "\(error)")) } }
                }
                timings.withValue { $0.append("pid \(pid): \(groupOps.count) ops \(String(format: "%.1f", sw.elapsedMs)) ms") }
                finishedPIDs.withValue { _ = $0.insert(pid) }
            }
        }
        if group.wait(timeout: .now() + 3) == .timedOut {
            // 間に合わなかった pid の op は結果不明なので、wid ごとに失敗として返す(状態を進めないため)。
            let done = finishedPIDs.current
            for (pid, groupOps) in groups where !done.contains(pid) {
                for op in groupOps {
                    failures.withValue { $0.append((op.wid, "timeout: pid \(pid) did not respond within 3 s")) }
                }
            }
        }
        logger.log("  per-pid: " + timings.current.joined(separator: " | "))
        return failures.current
    }

    func bench(rounds: Int) {
        guard rounds > 0, !entries.isEmpty else {
            logger.log("bench: add windows to set A and B first")
            return
        }
        var durations: [Double] = []
        var next: SetName = activeSet == .a ? .b : .a
        for _ in 0..<rounds {
            durations.append(show(next))
            next = next == .a ? .b : .a
        }
        let mean = durations.reduce(0, +) / Double(durations.count)
        logger.log("bench: \(rounds) switches (\(parallel ? "parallel" : "sequential")) " +
            "mean \(fmt(mean)) ms, min \(fmt(durations.min() ?? 0)) ms, max \(fmt(durations.max() ?? 0)) ms")
    }

    // MARK: - スナップバック監視

    func setWatch(_ on: Bool) {
        watching = on
        observers.values.forEach { $0.invalidate() }
        observers.removeAll()
        pendingRestores.values.forEach { $0.cancel() }
        pendingRestores.removeAll()
        guard on else {
            logger.log("watch: off")
            return
        }
        refreshObserversIfWatching()
        logger.log("watch: on (\(snapMode.rawValue), \(debounceMs) ms) for pids \(observers.keys.sorted())")
    }

    private func refreshObserversIfWatching() {
        guard watching else { return }
        let pids = Set(entries.values.map(\.window.pid))
        for (pid, observer) in observers where !pids.contains(pid) {
            observer.invalidate()
            observers.removeValue(forKey: pid)
        }
        for pid in pids where observers[pid] == nil {
            do {
                observers[pid] = try AppWindowObserver(
                    pid: pid,
                    notifications: [kAXWindowMovedNotification, kAXWindowResizedNotification]
                ) { [weak self] notification, element in
                    self?.handleWindowChange(notification, element)
                }
            } catch {
                logger.log("watch: observer for pid \(pid) FAILED: \(error)")
            }
        }
    }

    private func handleWindowChange(_ notification: String, _ element: AXUIElement) {
        var wid: CGWindowID = 0
        guard AXShimGetWindowID(element, &wid) == .success, var entry = entries[wid] else { return }
        // 退避操作そのものが kAXWindowMoved を発火させる(show()/park() の復帰後にランループで届く)。
        // 退避中ウィンドウの通知を編集モードで「新しい固定位置」として記録すると右下隅が基準になって
        // しまうので、編集モード判定より先に弾く。
        guard !entry.isParked else { return }
        guard let current = try? entry.window.frame() else { return }

        if editMode {
            entry.recordedFrame = current
            entries[wid] = entry
            logger.log("edit: \(notification) wid \(wid) → recorded \(fmt(current))")
            onChanged?()
            return
        }
        // 非アクティブセットのウィンドウは「動いて当然」なので触らない。
        guard entry.set == activeSet else { return }
        // 自分の復元操作で届いた通知(= 既にあるべき位置)は無視してループを防ぐ。
        guard !ScreenGeometry.approximatelyEqual(current, entry.recordedFrame) else { return }

        switch snapMode {
        case .immediate:
            let sw = Stopwatch()
            do {
                let actual = try entry.window.setFrame(entry.recordedFrame)
                logger.log("snap-back(immediate): \(notification) wid \(wid) \(entry.appName) moved to \(fmt(current)) → " +
                    "restored \(fmt(actual)) in \(fmt(sw.elapsedMs)) ms" +
                    (ScreenGeometry.approximatelyEqual(actual, entry.recordedFrame) ? "" : "  ⚠ MISMATCH"))
            } catch {
                logger.log("snap-back: wid \(wid) FAILED: \(error)")
            }
        case .debounced:
            // 通知が止むまで待つ。ドラッグ中は ~100ms 間隔で通知が来続けるので、都度リセットされる。
            scheduleRestore(wid: wid, attempt: 1, reason: "\(notification) → \(fmt(current))")
        }
    }

    private func scheduleRestore(wid: CGWindowID, attempt: Int, reason: String) {
        pendingRestores[wid]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.performDebouncedRestore(wid: wid, attempt: attempt, reason: reason)
        }
        pendingRestores[wid] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(debounceMs), execute: item)
    }

    private func performDebouncedRestore(wid: CGWindowID, attempt: Int, reason: String) {
        pendingRestores[wid] = nil
        guard var entry = entries[wid], !entry.isParked, entry.set == activeSet, !editMode else { return }
        guard let current = try? entry.window.frame() else { return }
        guard !ScreenGeometry.approximatelyEqual(current, entry.recordedFrame) else {
            logger.log("snap-back(debounced): wid \(wid) already at recorded frame, nothing to do")
            return
        }
        let sw = Stopwatch()
        do {
            let actual = try entry.window.setFrame(entry.recordedFrame)
            let ok = ScreenGeometry.approximatelyEqual(actual, entry.recordedFrame)
            logger.log("snap-back(debounced, attempt \(attempt)): wid \(wid) \(entry.appName) was at \(fmt(current)) " +
                "[last: \(reason)] → restored \(fmt(actual)) in \(fmt(sw.elapsedMs)) ms" + (ok ? "" : "  ⚠ MISMATCH"))
            if !ok {
                if attempt < Self.maxRestoreAttempts {
                    // まだ掴まれている最中かもしれないので、もう一度静止を待ってから再試行する。
                    scheduleRestore(wid: wid, attempt: attempt + 1, reason: "retry")
                } else {
                    // 静止後に複数回試しても戻らないなら、相手アプリの制約(最小サイズ等)とみなして採用する。
                    entry.recordedFrame = actual
                    entries[wid] = entry
                    logger.log("snap-back: ⚠ wid \(wid) cannot satisfy recorded frame after \(attempt) attempts; adopting \(fmt(actual))")
                    onChanged?()
                }
            }
        } catch {
            logger.log("snap-back: wid \(wid) FAILED: \(error)")
        }
    }

    // MARK: - URL スキーム(wtcpoc://command?key=value)

    func handle(url: URL) {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let command = comps.host ?? ""
        var q: [String: String] = [:]
        for item in comps.queryItems ?? [] { q[item.name] = item.value ?? "" }
        let wids = (q["wid"] ?? "").split(separator: ",").compactMap { CGWindowID($0.trimmingCharacters(in: .whitespaces)) }
        let on = (q["on"] ?? "1") != "0"
        logger.log("url: \(url.absoluteString)")

        switch command {
        case "status": status()
        case "permission": requestPermission()
        case "refresh": refresh()
        case "list": refresh(); list()
        case "add":
            guard let set = SetName(rawValue: (q["set"] ?? "").uppercased()) else {
                logger.log("url: add needs set=A|B")
                return
            }
            add(wids, to: set)
        case "remove": remove(wids)
        case "place":
            guard let placement = Placement(rawValue: q["where"] ?? "") else {
                logger.log("url: place needs where=left|right|full")
                return
            }
            place(wids, placement)
        case "park": park(wids)
        case "restore": restore(wids)
        case "show":
            guard let set = SetName(rawValue: (q["set"] ?? "").uppercased()) else {
                logger.log("url: show needs set=A|B")
                return
            }
            show(set)
        case "bench":
            if let p = q["parallel"] { parallel = p != "0" }
            bench(rounds: Int(q["rounds"] ?? "") ?? 10)
            onChanged?()
        case "parallel": parallel = on; logger.log("parallel=\(parallel)"); onChanged?()
        case "watch":
            if let m = q["mode"], let mode = SnapMode(rawValue: m) { snapMode = mode }
            if let ms = Int(q["ms"] ?? ""), ms > 0 { debounceMs = ms }
            setWatch(on)
            onChanged?()
        case "move":
            guard wids.count == 1, let x = Double(q["x"] ?? ""), let y = Double(q["y"] ?? ""),
                let w = Double(q["w"] ?? ""), let h = Double(q["h"] ?? "")
            else {
                logger.log("url: move needs wid=<one>&x=&y=&w=&h=")
                return
            }
            move(wids[0], to: CGRect(x: x, y: y, width: w, height: h))
        case "edit": editMode = on; logger.log("editMode=\(editMode)"); onChanged?()
        default: logger.log("url: unknown command '\(command)'")
        }
    }

    // MARK: - 整形

    private func fmt(_ ms: Double) -> String { String(format: "%.1f", ms) }
    private func fmt(_ r: CGRect) -> String {
        String(format: "(%.0f,%.0f %.0fx%.0f)", r.minX, r.minY, r.width, r.height)
    }
    private func fmt(_ p: CGPoint) -> String { String(format: "(%.0f,%.0f)", p.x, p.y) }
    private func fmt(_ s: CGSize) -> String { String(format: "%.0fx%.0f", s.width, s.height) }
}
