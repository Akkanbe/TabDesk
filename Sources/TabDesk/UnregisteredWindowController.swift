import AppKit
import TabDeskCore

/// 未登録窓同士の順序は維持し、登録窓に隠れたときだけ前後関係を補正する。
@MainActor
final class UnregisteredWindowController {
    struct Window {
        let id: WindowReferenceID
        let frame: CGRect
        let bringForward: @MainActor () async throws -> Void
        var isEligible: @MainActor () async -> Bool = { true }
    }

    struct VisibleWindow: Equatable, Sendable {
        let number: CGWindowID
        let pid: pid_t
        let frame: CGRect
    }

    struct Snapshot {
        let signature: [VisibleWindow]
        /// CGWindowListと同じ、手前から奥の順。
        let windows: [Window]
        var canCache = true
    }

    private let context: () -> Set<WindowReferenceID>?
    private let sample: ([VisibleWindow]?) async -> Snapshot?
    private let onError: (Error) -> Void
    private let onFronting: (Int) -> Void
    private var task: Task<Void, Never>?
    private var generation = 0
    private var signature: [VisibleWindow]?
    private var sampledAt: ContinuousClock.Instant?
    private var requestPending = false
    private static let cacheLifetime: Duration = .seconds(10)

    init(context: @escaping () -> Set<WindowReferenceID>?,
         sample: @escaping ([VisibleWindow]?) async -> Snapshot? = { await UnregisteredWindowController.sample(previous: $0) },
         onFronting: @escaping (Int) -> Void = { _ in },
         onError: @escaping (Error) -> Void) {
        self.context = context
        self.sample = sample
        self.onError = onError
        self.onFronting = onFronting
    }

    /// OFFや登録・切替の開始で古い列挙結果を無効化する。実行済みのAX呼び出しは取り消せない。
    func invalidate() {
        generation += 1
        requestPending = false
        signature = nil
        task?.cancel()
    }

    func request() {
        guard let registered = context(), !registered.isEmpty else { return }
        if let task {
            // 中断済みのAX読み取りを待つ間に、再ONや切替完了の通知が届くことがある。
            // 通常の重複要求は重ねず、中断後の要求だけ一度追走する。
            if task.isCancelled { requestPending = true }
            return
        }
        let generation = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                task = nil
                if requestPending {
                    requestPending = false
                    request()
                }
            }
            let cacheValid = sampledAt.map { $0.duration(to: .now) < Self.cacheLifetime } ?? false
            guard let snapshot = await sample(cacheValid ? signature : nil), !Task.isCancelled,
                  generation == self.generation, context() == registered else { return }
            sampledAt = .now
            signature = snapshot.canCache ? snapshot.signature : nil
            let targets = Self.targets(in: snapshot.windows, registered: registered)
            if !targets.isEmpty {
                signature = nil
                onFronting(targets.count)
            }
            for window in targets {
                guard !Task.isCancelled, generation == self.generation, context() == registered else { return }
                guard await window.isEligible() else { continue }
                guard !Task.isCancelled, generation == self.generation, context() == registered else { return }
                do { try await window.bringForward() }
                catch {
                    // 一時的なAX失敗は次のtickで再評価し、他の窓の前面化は続ける。
                    signature = nil
                    onError(error)
                }
            }
        }
    }

    func waitForPendingWork() async {
        while let task { await task.value }
    }

    static func targets(in windows: [Window], registered: Set<WindowReferenceID>) -> [Window] {
        var coveringFrames: [CGRect] = []
        var selected: Set<Int> = []
        for (index, window) in windows.enumerated() {
            if registered.contains(window.id) { coveringFrames.append(window.frame) }
            else if coveringFrames.contains(where: { !$0.intersection(window.frame).isEmpty }) { selected.insert(index) }
        }
        guard !selected.isEmpty else { return [] }
        // 上げる窓と重なる、さらに手前の未登録窓も最後に上げ直す。
        // 別画面など、重なっていない窓からは入力フォーカスを奪わない。
        for index in windows.indices.reversed() where selected.contains(index) {
            for front in 0..<index where !registered.contains(windows[front].id) &&
                !windows[front].frame.intersection(windows[index].frame).isEmpty {
                selected.insert(front)
            }
        }
        return windows.indices.reversed().filter { selected.contains($0) }.map { windows[$0] }
    }

    static func stableWindows(before: [VisibleWindow], after: [VisibleWindow]) -> [VisibleWindow] {
        // 別アプリのツールチップ等で全窓を捨てず、最新の順序で安全な窓だけを残す。
        // 移動・生成・PID変更のあった窓は次の監視で読み直す。
        let changed = before.filter { !after.contains($0) } + after.filter { !before.contains($0) }
        return after.filter { window in
            before.contains(window) && !changed.contains { !$0.frame.intersection(window.frame).isEmpty }
        }
    }

    nonisolated private static func visibleWindows() -> [VisibleWindow]? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), !frame.isEmpty else { return nil }
            return VisibleWindow(number: number, pid: pid, frame: frame)
        }
    }

    static func sample(previous: [VisibleWindow]?, apps testApps: [AppDescriptor]? = nil) async -> Snapshot? {
        let executor = BlockingExecutor()
        let screenFrames = NSScreen.screens.map { ScreenGeometry.axRect(fromCocoa: $0.frame) }
        guard let before = await executor.run({ visibleWindows() }), before != previous else { return nil }
        let pids = Set(before.map(\.pid))
        let apps = (testApps ?? WindowEnumerator.regularApps()).filter { pids.contains($0.pid) }
        let (records, _) = await WindowEnumerator.enumerateInParallel(apps)
        guard !Task.isCancelled else { return nil }
        let matched: [CGWindowID: AXWindow] = await executor.run {
            var result: [CGWindowID: AXWindow] = [:]
            for record in records {
                // 公開AX参照で登録済みかを判定する。CG番号は可視性・重なり順の補助に限定する。
                guard let number = WindowServerMatch.windowNumber(for: record.window, requireTitleMatch: false) else { continue }
                result[number] = record.window
            }
            return result
        }
        guard !Task.isCancelled, let after = await executor.run({ visibleWindows() }) else { return nil }
        let windows = stableWindows(before: before, after: after).compactMap { visible -> Window? in
            // 退避点の1pxだけが画面に残る管理窓を、他の窓を覆う窓として扱わない。
            guard screenFrames.contains(where: {
                let intersection = $0.intersection(visible.frame)
                return intersection.width > 1 && intersection.height > 1
            }), let window = matched[visible.number] else { return nil }
            return Window(id: window.windowID, frame: visible.frame, bringForward: {
                guard let app = NSRunningApplication(processIdentifier: window.pid), !app.isHidden else { return }
                app.activate()
                try await executor.run { try window.raise() }
            }, isEligible: {
                // 列挙後の最小化・Space移動を確認し、呼び手もawait後に設定と登録を再検証する。
                await executor.run {
                    visibleWindows()?.contains(visible) == true && window.isStandard &&
                    window.minimizationState == false && window.layoutSuspension == false
                }
            })
        }
        return Snapshot(signature: after, windows: windows, canCache: before == after)
    }
}
