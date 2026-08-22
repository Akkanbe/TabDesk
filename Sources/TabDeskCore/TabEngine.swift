import CoreGraphics
import Foundation

/// タブ管理の中核。タブ CRUD・ウィンドウ登録/解除・タブ切替・スナップバック・整合性維持を担う。
///
/// - 実ウィンドウには `WindowDriver` 越しにしか触らない(AX 非依存 → 権限なしでテスト可能)
/// - ブロッキングする操作は `BlockingExecutor` で GCD に逃がす。`@MainActor` なのは UI と状態を共有するため
/// - 状態は `WorkspaceState`(値型)で持ち、変更のたびに `onStateChanged` で通知する
/// - 状態を変える非同期操作は `serialized {}` で直列化する。IPC(frame の読み取り)はできるだけロックの外で行い、
///   ロック取得後に前提を再検証してから状態を変える
@MainActor
public final class TabEngine {
    public struct Configuration: Sendable {
        /// スナップバックのデバウンス時間。ドラッグ中は ~100ms 間隔で通知が来るので、これより長くする。
        public var debounce: Duration = .milliseconds(250)
        /// 復元しても戻らないとき、相手アプリの制約とみなして到達 frame を採用するまでの試行回数。
        public var maxRestoreAttempts = 3
        /// frame 比較の許容誤差(pt)。
        public var frameTolerance: CGFloat = 1.0

        public init() {}
    }

    public struct OperationFailure: Sendable, Hashable {
        public let managedID: UUID
        public let message: String
    }

    public struct SwitchReport: Sendable {
        public let tabID: UUID
        public let operationCount: Int
        public let durationMs: Double
        public let failures: [OperationFailure]
    }

    public enum EngineError: Error, CustomStringConvertible, Sendable {
        case unknownTab(UUID)
        case unknownWindow(UUID)
        case windowAlreadyRegistered(windowID: CGWindowID, managedID: UUID)
        case invalidTabOrder

        public var description: String {
            switch self {
            case .unknownTab(let id): return "unknown tab \(id)"
            case .unknownWindow(let id): return "unknown managed window \(id)"
            case .windowAlreadyRegistered(let wid, let mid): return "window \(wid) already registered as \(mid)"
            case .invalidTabOrder: return "invalid tab order"
            }
        }
    }

    // MARK: - 公開状態

    public private(set) var state: WorkspaceState {
        didSet { onStateChanged?(state) }
    }

    /// ON の間、ユーザーの移動・リサイズは復元せず新しい固定 frame として記録する。
    public var editMode = false

    public var onStateChanged: (@MainActor (WorkspaceState) -> Void)?
    /// 切替後にフォーカスを移すためのフック(AppKit への依存をエンジンに持ち込まないため)。
    public var activateApplication: (@MainActor (pid_t) -> Void)?
    public var log: @Sendable (String) -> Void = { _ in }

    /// 退避操作が成功した(= 画面隅にいるはずの)ウィンドウ。実行時の状態なので `WorkspaceState` には含めない。
    /// 操作が失敗したウィンドウはフラグが進まないため実位置とずれうる。ずれは `reconcile` が収束させる。
    public private(set) var parkedWindowIDs: Set<UUID> = []

    private let driver: any WindowDriver
    private let layout: any ScreenLayout
    private let config: Configuration
    private let executor = BlockingExecutor()
    private var pendingRestores: [UUID: (task: Task<Void, Never>, attempt: Int)] = [:]
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(
        driver: any WindowDriver,
        layout: any ScreenLayout,
        configuration: Configuration = Configuration(),
        initialState: WorkspaceState = WorkspaceState()
    ) {
        self.driver = driver
        self.layout = layout
        self.config = configuration
        self.state = initialState
    }

    // MARK: - タブ CRUD

    @discardableResult
    public func createTab(name: String) -> Tab {
        let tab = Tab(name: name)
        state.tabs.append(tab)
        if state.activeTabID == nil {
            state.activeTabID = tab.id
        }
        return tab
    }

    public func renameTab(_ id: UUID, to name: String) throws {
        let index = try tabIndex(id)
        state.tabs[index].name = name
    }

    public func moveTab(fromIndex from: Int, toIndex to: Int) throws {
        guard state.tabs.indices.contains(from), state.tabs.indices.contains(to) else {
            throw EngineError.invalidTabOrder
        }
        let tab = state.tabs.remove(at: from)
        state.tabs.insert(tab, at: to)
    }

    /// タブを削除する。退避中だったウィンドウは固定 frame に戻してから解放する(画面隅に取り残さない)。
    /// アクティブタブを削除した場合は残りの先頭タブをアクティブにする。
    public func deleteTab(_ id: UUID) async throws {
        try await serialized {
            let tab = try self.tab(id)
            await releaseAll(tab.windows, from: tab)
            // await をまたいだので index は引き直す(同期の moveTab が割り込みうる)。
            state.tabs.remove(at: try tabIndex(id))
            if state.activeTabID == id {
                state.activeTabID = nil
                if let next = state.tabs.first {
                    try await activateUnlocked(next.id)
                }
            }
        }
    }

    // MARK: - ウィンドウ登録 / 解除

    /// ウィンドウをタブに登録する。
    ///
    /// - アクティブタブへの登録: `frame` を適用し、到達した frame を固定 frame として記録する
    /// - 非アクティブタブへの登録: `frame` を記録だけして即座に退避する(次の切替時に適用・正規化される)
    @discardableResult
    public func register(
        windowID: CGWindowID,
        pid: pid_t,
        identity: WindowIdentity,
        frame: CGRect,
        into tabID: UUID
    ) async throws -> ManagedWindow {
        try await serialized {
            _ = try tabIndex(tabID)
            if let existing = state.managedWindow(forWindowID: windowID) {
                throw EngineError.windowAlreadyRegistered(windowID: windowID, managedID: existing.window.id)
            }
            let frame = clamped(frame)
            var managed = ManagedWindow(frame: frame, identity: identity, windowID: windowID, pid: pid)
            let driver = self.driver
            let intoActive = tabID == state.activeTabID

            if intoActive {
                let actual = try await executor.run { try driver.setFrame(frame, of: windowID) }
                managed.frame = actual
                log("register: \(identity.appName) → \(actual) (requested \(frame))")
            } else {
                let point = layout.parkPoint
                try await executor.run { try driver.setPosition(point, of: windowID) }
                log("register: \(identity.appName) → parked (inactive tab)")
            }
            // await をまたいだので index は引き直す(タブが消えていれば unknownTab)。
            let index = try tabIndex(tabID)
            state.tabs[index].windows.append(managed)
            if !intoActive {
                parkedWindowIDs.insert(managed.id)
            }
            return managed
        }
    }

    /// 登録を解除する。退避中なら固定 frame に戻してから手放す。
    public func unregister(_ id: UUID) async throws {
        try await serialized {
            guard let found = state.managedWindow(id: id) else { throw EngineError.unknownWindow(id) }
            await releaseAll([found.window], from: found.tab)
            removeFromState(id)
        }
    }

    /// アプリ終了前に呼ぶ。退避中(および非アクティブタブ)の全ウィンドウを固定 frame に戻す。
    /// 状態(タブ・登録)は変えない。切替が進行中なら順番を待つ。
    public func releaseAllParkedWindows() async {
        await serialized {
            for tab in state.tabs {
                await releaseAll(tab.windows, from: tab)
            }
        }
    }

    /// AX の destroyed 通知から呼ぶ。実ウィンドウが消えたので登録を外す。
    public func noteWindowDestroyed(windowID: CGWindowID) {
        guard let found = state.managedWindow(forWindowID: windowID) else { return }
        log("window destroyed: \(found.window.identity.appName) / \(found.window.identity.title)")
        removeFromState(found.window.id)
    }

    /// フォーカスが移ったウィンドウを記録する(切替時に最前面へ戻すため)。
    public func noteWindowFocused(windowID: CGWindowID) {
        guard let found = state.managedWindow(forWindowID: windowID),
            let index = state.tabs.firstIndex(where: { $0.id == found.tab.id })
        else { return }
        state.tabs[index].lastFocusedWindowID = found.window.id
    }

    /// 固定 frame を明示的に変える(配置 UI や編集操作から)。
    /// 表示中なら適用して到達 frame を記録、退避中なら記録だけする。
    @discardableResult
    public func setFrame(_ frame: CGRect, of id: UUID) async throws -> CGRect {
        try await serialized {
            guard let found = state.managedWindow(id: id) else { throw EngineError.unknownWindow(id) }
            let frame = clamped(frame)
            cancelPendingRestore(id)
            guard let windowID = found.window.windowID, !parkedWindowIDs.contains(id),
                found.tab.id == state.activeTabID
            else {
                updateFrame(id, frame)
                return frame
            }
            let driver = self.driver
            let actual = try await executor.run { try driver.setFrame(frame, of: windowID) }
            updateFrame(id, actual)
            return actual
        }
    }

    // MARK: - タブ切替

    /// タブを切り替える。他タブのウィンドウを退避し、対象タブのウィンドウを固定 frame に復元する。
    /// pid ごとに並列実行するので、1 アプリが遅くても他アプリは待たされない。
    @discardableResult
    public func activate(_ tabID: UUID) async throws -> SwitchReport {
        try await serialized { try await activateUnlocked(tabID) }
    }

    @discardableResult
    private func activateUnlocked(_ tabID: UUID) async throws -> SwitchReport {
        let target = try tab(tabID)
        let alreadyActive = tabID == state.activeTabID
        let point = layout.parkPoint
        var parks: [WindowOp] = []
        var restores: [WindowOp] = []
        for tab in state.tabs {
            for window in tab.windows {
                guard let windowID = window.windowID, let pid = window.pid else { continue }  // 未復元は対象外
                if tab.id == tabID {
                    // 既にアクティブなタブの窓には触らない。ドラッグ中の一時 frame を読み戻して
                    // 「到達 frame」として採用してしまうのを避けるため(ずれはスナップバックが直す)。
                    if !alreadyActive {
                        restores.append(WindowOp(managedID: window.id, windowID: windowID, pid: pid, kind: .restore(window.frame, raise: true)))
                    }
                } else if !parkedWindowIDs.contains(window.id) {
                    parks.append(WindowOp(managedID: window.id, windowID: windowID, pid: pid, kind: .park(point)))
                }
            }
        }
        // 最後にフォーカスしていたウィンドウは最後に raise して最前面にする。
        if let focused = target.lastFocusedWindowID, let i = restores.firstIndex(where: { $0.managedID == focused }) {
            restores.append(restores.remove(at: i))
        }
        // 同じアプリ内では退避を先に出す(復元した窓の上に退避前の窓が一瞬残らないように)。
        let ops = parks + restores

        let stopwatch = Stopwatch()
        let results = await run(ops)
        let elapsed = stopwatch.elapsedMs
        let failures = apply(results)
        state.activeTabID = tabID

        if !alreadyActive, let pid = focusTargetPID(in: target) {
            activateApplication?(pid)
        }
        log("activate \(target.name): \(ops.count) ops in \(String(format: "%.1f", elapsed)) ms" +
            (failures.isEmpty ? "" : "; failures: \(failures.map(\.message))"))
        return SwitchReport(tabID: tabID, operationCount: ops.count, durationMs: elapsed, failures: failures)
    }

    // MARK: - スナップバック

    /// AX の moved / resized 通知を受けたら呼ぶ。
    ///
    /// ドラッグ中は通知が ~100ms 間隔で来続けるため、静止するまで待ってから復元する(デバウンス)。
    /// 掴まれている最中に復元すると一時状態を「制約」と誤認して基準を壊すので、即時復元はしない。
    public func windowFrameDidChange(windowID: CGWindowID) {
        guard let found = state.managedWindow(forWindowID: windowID) else { return }
        let managed = found.window
        // 退避操作そのものが通知を発火させる。退避中の通知は編集モードでも記録しない。
        guard !parkedWindowIDs.contains(managed.id), found.tab.id == state.activeTabID else { return }
        // 通常モードは静止後に復元、編集モードは静止後に記録(どちらもデバウンス。ドラッグ中は触らない)。
        scheduleRestore(managed.id, attempt: 1)
    }

    private func scheduleRestore(_ id: UUID, attempt: Int) {
        pendingRestores[id]?.task.cancel()
        let delay = config.debounce
        let task = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return  // キャンセル(= 新しい通知で延長された、または flush で即時実行された)
            }
            await self?.performRestore(id, attempt: attempt)
        }
        pendingRestores[id] = (task, attempt)
    }

    /// デバウンス待ちの復元/記録を待たずに今すぐ実行する。
    /// マウスボタンが離された瞬間に呼ぶと、ドラッグ終了と同時に窓が戻る(250 ms 待たない)。
    public func flushPendingRestores() {
        let pending = pendingRestores
        pendingRestores.removeAll()
        for (id, entry) in pending {
            entry.task.cancel()
            Task { [weak self] in await self?.performRestore(id, attempt: entry.attempt) }
        }
    }

    private func performRestore(_ id: UUID, attempt: Int) async {
        pendingRestores[id] = nil
        guard let found = state.managedWindow(id: id), let windowID = found.window.windowID,
            !parkedWindowIDs.contains(id), found.tab.id == state.activeTabID
        else { return }
        let driver = self.driver
        // 読み取り(IPC)はロックの外。相手アプリが遅くても他の操作を待たせない。
        guard let current = try? await executor.run({ try driver.frame(of: windowID) }) else { return }

        await serialized {
            // ロック待ちの間に切替・解除が走っていることがあるので前提を見直す。
            guard let found = state.managedWindow(id: id), !parkedWindowIDs.contains(id),
                found.tab.id == state.activeTabID
            else { return }
            if editMode {
                // 編集モード: 静止した位置を新しい固定 frame として記録する。
                // サイドバー領域に置かれた場合はコンテンツ領域へ寄せ、窓もそこへ動かす。
                let target = clamped(current)
                updateFrame(id, target)
                if !approximatelyEqual(target, current) {
                    _ = try? await executor.run { try driver.setFrame(target, of: windowID) }
                }
                log("edit: recorded \(target) for \(found.window.identity.appName)")
                return
            }
            let recorded = found.window.frame
            if approximatelyEqual(current, recorded) { return }
            do {
                let actual = try await executor.run { try driver.setFrame(recorded, of: windowID) }
                if approximatelyEqual(actual, recorded) {
                    log("snap-back: \(found.window.identity.appName) \(current) → \(actual) (attempt \(attempt))")
                    return
                }
                if attempt < config.maxRestoreAttempts {
                    // まだ掴まれている最中かもしれないので、もう一度静止を待ってから再試行する。
                    scheduleRestore(id, attempt: attempt + 1)
                } else {
                    // 静止後に複数回試しても戻らない = 相手アプリの制約。到達 frame を新しい基準にする。
                    updateFrame(id, actual)
                    log("snap-back: cannot satisfy \(recorded); adopting \(actual) after \(attempt) attempts")
                }
            } catch {
                log("snap-back failed for \(found.window.identity.appName): \(error)")
            }
        }
    }

    // MARK: - 整合性維持(リコンシリエーション)

    /// 低頻度ポーリング(2 秒間隔を想定)から呼び、実態を「あるべき状態」へ収束させる。
    ///
    /// - `liveWindowIDs` には **存在する全ウィンドウ**(最小化・別 Space・フルスクリーンを含む)を渡すこと
    ///   (`WindowEnumerator.existingWindowIDs()`)。画面上の窓だけを渡すと最小化中の窓が登録解除されてしまう。
    ///   空集合は列挙失敗とみなし、削除は行わない
    /// - 過去の操作が失敗して実位置とフラグがずれた窓(アクティブタブなのに退避フラグ、非アクティブなのに未退避)を
    ///   復元/退避し直す。退避中の窓が隅から外れていれば戻す
    /// - frame の読み取り(IPC)はロックの外で pid 並列に行い、状態変更だけロック内で再検証して行う
    public func reconcile(liveWindowIDs: Set<CGWindowID>) async {
        if !liveWindowIDs.isEmpty {
            for window in state.allWindows {
                guard let windowID = window.windowID, !liveWindowIDs.contains(windowID) else { continue }
                log("reconcile: window gone: \(window.identity.appName) / \(window.identity.title)")
                removeFromState(window.id)
            }
        }

        let point = layout.parkPoint
        let drifted = await driftedParkedWindows(parkPoint: point)

        await serialized {
            var ops: [WindowOp] = []
            for tab in state.tabs {
                let isActive = tab.id == state.activeTabID
                for window in tab.windows {
                    guard let windowID = window.windowID, let pid = window.pid else { continue }
                    let flagged = parkedWindowIDs.contains(window.id)
                    if isActive, flagged {
                        // 復元に失敗したまま = 隅に残っているはずなので、復元をやり直す。
                        ops.append(WindowOp(managedID: window.id, windowID: windowID, pid: pid, kind: .restore(window.frame, raise: false)))
                    } else if !isActive, !flagged || drifted.contains(window.id) {
                        ops.append(WindowOp(managedID: window.id, windowID: windowID, pid: pid, kind: .park(point)))
                    }
                }
            }
            guard !ops.isEmpty else { return }
            log("reconcile: \(ops.count) corrective ops")
            let failures = apply(await run(ops))
            for failure in failures {
                log("reconcile: op failed for \(failure.managedID): \(failure.message)")
            }
        }
    }

    /// 退避中のはずなのに隅にいない窓を探す。読み取りは pid ごとに並列(ロックの外で呼ぶこと)。
    private func driftedParkedWindows(parkPoint point: CGPoint) async -> Set<UUID> {
        let candidates = state.allWindows.filter { parkedWindowIDs.contains($0.id) && $0.isBound }
        guard !candidates.isEmpty else { return [] }
        let driver = self.driver
        let executor = self.executor
        let groups = Dictionary(grouping: candidates, by: { $0.pid ?? 0 })
        return await withTaskGroup(of: [UUID].self) { group in
            for (_, windows) in groups {
                group.addTask {
                    await executor.run {
                        windows.compactMap { window -> UUID? in
                            // 読めない(消えた / 無応答)窓は判断材料がないので触らない。
                            guard let wid = window.windowID, let current = try? driver.frame(of: wid) else { return nil }
                            // y は OS にクランプされて窓の高さごとに変わる(実測 1067〜1087)ので判定に使わない。
                            // x = 画面幅 − 1 は通常のウィンドウでは起こらないので、x だけで「隅にいる」とみなす。
                            return abs(current.minX - point.x) <= 1 ? nil : window.id
                        }
                    }
                }
            }
            var all = Set<UUID>()
            for await ids in group {
                all.formUnion(ids)
            }
            return all
        }
    }

    // MARK: - 直列化

    /// 状態を変える非同期操作を直列化する。
    ///
    /// 各操作は await をまたぐので、同時に走ると「古い状態から組み立てた操作」が後から適用されて
    /// 整合が崩れる(例: タブ連打で 2 タブが同時に表示される)。@MainActor なのでフラグ自体に競合はなく、
    /// 待機側は continuation で順番を待つ。内部から呼ぶときは *Unlocked 版を使い、再入しないこと。
    /// IPC はなるべくロックの外で済ませ、ロック内では前提を再検証してから状態を変える。
    private func serialized<T>(_ body: () async throws -> T) async rethrows -> T {
        while isBusy {
            await withCheckedContinuation { waiters.append($0) }
        }
        isBusy = true
        defer {
            isBusy = false
            if !waiters.isEmpty {
                waiters.removeFirst().resume()
            }
        }
        return try await body()
    }

    // MARK: - 操作の実行

    private struct WindowOp: Sendable {
        enum Kind: Sendable {
            case park(CGPoint)
            case restore(CGRect, raise: Bool)
        }
        let managedID: UUID
        let windowID: CGWindowID
        let pid: pid_t
        let kind: Kind
    }

    private struct OpResult: Sendable {
        let op: WindowOp
        let actual: CGRect?
        let error: String?
        let note: String?
    }

    /// pid ごとに直列、pid 間は並列で実行する。
    private func run(_ ops: [WindowOp]) async -> [OpResult] {
        let groups = Dictionary(grouping: ops, by: \.pid)
        let driver = self.driver
        let executor = self.executor
        return await withTaskGroup(of: [OpResult].self) { group in
            for (_, groupOps) in groups {
                group.addTask {
                    await executor.run { groupOps.map { Self.perform($0, driver: driver) } }
                }
            }
            var all: [OpResult] = []
            for await results in group {
                all.append(contentsOf: results)
            }
            return all
        }
    }

    private nonisolated static func perform(_ op: WindowOp, driver: any WindowDriver) -> OpResult {
        do {
            switch op.kind {
            case .park(let point):
                try driver.setPosition(point, of: op.windowID)
                return OpResult(op: op, actual: nil, error: nil, note: nil)
            case .restore(let frame, let raise):
                let actual = try driver.setFrame(frame, of: op.windowID)
                var note: String?
                if raise {
                    // frame 適用が済んでいれば窓は見えている。raise の失敗で「復元失敗」にするとフラグが
                    // 実位置とずれる(退避扱いのまま表示される)ので、成功として扱い記録だけ残す。
                    do { try driver.raise(op.windowID) } catch { note = "raise failed: \(error)" }
                }
                return OpResult(op: op, actual: actual, error: nil, note: note)
            }
        } catch {
            return OpResult(op: op, actual: nil, error: "\(error)", note: nil)
        }
    }

    /// 実行結果を状態に反映する。失敗した操作は実位置が不明なのでフラグを進めない。
    private func apply(_ results: [OpResult]) -> [OperationFailure] {
        var failures: [OperationFailure] = []
        for result in results {
            // 実行中に閉じられた(noteWindowDestroyed された)ウィンドウの結果は捨てる。
            guard state.managedWindow(id: result.op.managedID) != nil else { continue }
            if let note = result.note {
                log("\(result.op.managedID): \(note)")
            }
            if let error = result.error {
                failures.append(OperationFailure(managedID: result.op.managedID, message: error))
                continue
            }
            switch result.op.kind {
            case .park:
                parkedWindowIDs.insert(result.op.managedID)
                cancelPendingRestore(result.op.managedID)
            case .restore(let requested, _):
                parkedWindowIDs.remove(result.op.managedID)
                if let actual = result.actual, !approximatelyEqual(actual, requested) {
                    // 自分の操作なのでユーザー操作との競合はない。相手アプリの制約として到達 frame を採用する。
                    updateFrame(result.op.managedID, actual)
                    log("adopting \(actual) for \(result.op.managedID) (requested \(requested))")
                }
            }
        }
        return failures
    }

    /// 解除・タブ削除で手放す窓を固定 frame に戻す(画面隅に取り残さないため)。
    /// 退避フラグだけに頼らず、非アクティブタブの窓は実位置にかかわらず戻す(退避が「失敗扱いだが適用済み」でも拾う)。
    private func releaseAll(_ windows: [ManagedWindow], from tab: Tab) async {
        let isActive = tab.id == state.activeTabID
        var ops: [WindowOp] = []
        for window in windows {
            cancelPendingRestore(window.id)
            guard let windowID = window.windowID, let pid = window.pid else { continue }
            if !isActive || parkedWindowIDs.contains(window.id) {
                ops.append(WindowOp(managedID: window.id, windowID: windowID, pid: pid, kind: .restore(window.frame, raise: false)))
            }
        }
        guard !ops.isEmpty else { return }
        for result in await run(ops) {
            if let error = result.error {
                log("release: could not restore \(result.op.managedID): \(error)")
            }
            parkedWindowIDs.remove(result.op.managedID)
        }
    }

    // MARK: - 内部ヘルパー

    private func focusTargetPID(in tab: Tab) -> pid_t? {
        if let focused = tab.lastFocusedWindowID, let w = tab.windows.first(where: { $0.id == focused }), let pid = w.pid {
            return pid
        }
        return tab.windows.first(where: { $0.pid != nil })?.pid
    }

    private func removeFromState(_ id: UUID) {
        cancelPendingRestore(id)
        parkedWindowIDs.remove(id)
        for index in state.tabs.indices {
            state.tabs[index].windows.removeAll { $0.id == id }
            if state.tabs[index].lastFocusedWindowID == id {
                state.tabs[index].lastFocusedWindowID = nil
            }
        }
    }

    private func updateFrame(_ id: UUID, _ frame: CGRect) {
        for ti in state.tabs.indices {
            if let wi = state.tabs[ti].windows.firstIndex(where: { $0.id == id }) {
                state.tabs[ti].windows[wi].frame = frame
                return
            }
        }
    }

    private func cancelPendingRestore(_ id: UUID) {
        pendingRestores[id]?.task.cancel()
        pendingRestores[id] = nil
    }

    private func tabIndex(_ id: UUID) throws -> Int {
        guard let index = state.tabs.firstIndex(where: { $0.id == id }) else { throw EngineError.unknownTab(id) }
        return index
    }

    private func tab(_ id: UUID) throws -> Tab {
        state.tabs[try tabIndex(id)]
    }

    /// 固定 frame をコンテンツ領域(サイドバーを除いた範囲)に収める。サイズは変えず位置だけ寄せる。
    /// 領域より大きい窓は領域の原点に揃える(はみ出しは許容)。仕様 §3.2「サイドバー領域は配置領域から除外」。
    private func clamped(_ frame: CGRect) -> CGRect {
        let area = layout.contentArea
        guard area.width > 0, area.height > 0 else { return frame }
        var f = frame
        f.origin.x = min(max(f.minX, area.minX), max(area.minX, area.maxX - f.width))
        f.origin.y = min(max(f.minY, area.minY), max(area.minY, area.maxY - f.height))
        return f
    }

    private func approximatelyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        ScreenGeometry.approximatelyEqual(a, b, tolerance: config.frameTolerance)
    }
}
