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
        /// 退避中の窓を固定 frame に戻せなかった(登録は保持される。相手アプリが応答したら再試行できる)。
        case releaseFailed(managedIDs: Set<UUID>)
        /// エントリは既に別の実ウィンドウに紐付いている(上書きすると前の窓が追跡不能になる)。
        case entryAlreadyBound(managedID: UUID, boundWindowID: CGWindowID)

        public var description: String {
            switch self {
            case .unknownTab(let id): return "unknown tab \(id)"
            case .unknownWindow(let id): return "unknown managed window \(id)"
            case .windowAlreadyRegistered(let wid, let mid): return "window \(wid) already registered as \(mid)"
            case .invalidTabOrder: return "invalid tab order"
            case .releaseFailed(let ids): return "could not restore \(ids.count) parked window(s); registration kept"
            case .entryAlreadyBound(let mid, let wid): return "entry \(mid) is already bound to window \(wid)"
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

    /// 終了処理(`releaseAllParkedWindows`)が始まったら true。以降の reconcile は戻した窓を再び隅へ送らない。
    public private(set) var isReleasingForShutdown = false

    /// 退避操作が成功した(= 画面隅にいるはずの)ウィンドウ。実行時の状態なので `WorkspaceState` には含めない。
    /// 操作が失敗したウィンドウはフラグが進まないため実位置とずれうる。ずれは `reconcile` が収束させる。
    public private(set) var parkedWindowIDs: Set<UUID> = []

    private let driver: any WindowDriver
    private let layout: any ScreenLayout
    private let config: Configuration
    private let executor = BlockingExecutor()
    private var pendingRestores: [UUID: (task: Task<Void, Never>, attempt: Int, generation: UInt64)] = [:]
    /// 窓ごとの復元予約の世代。Task.cancel は IPC 中の Task を止められないので、
    /// 戻ってきた古い Task が「自分はまだ最新か」を世代で確かめてから状態を触る。
    private var restoreGeneration: [UUID: UInt64] = [:]
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
            let unreleased = await releaseAll(tab.windows, from: tab)
            // 1 枚でも戻せなければタブごと残す(隅に取り残した窓を追跡不能にしない)。
            // 戻せた窓は非アクティブタブの未退避窓として reconcile が再び退避する。
            guard unreleased.isEmpty else { throw EngineError.releaseFailed(managedIDs: unreleased) }
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
            let intoActive = tabID == state.activeTabID

            let outcome = try await place(windowID: windowID, frame: frame, intoActive: intoActive)
            switch outcome {
            case .placed(let actual):
                managed.frame = actual
            case .unreached(let current):
                // 新規登録は「今ある位置」を基準にしてよい(ユーザーがまだレイアウトを決めていない)。
                managed.frame = clamped(current)
            case .parked:
                break
            }
            log("register: \(identity.appName) → \(outcome.description) (requested \(frame))")
            // await をまたいだので index は引き直す(タブが消えていれば unknownTab)。
            let index = try tabIndex(tabID)
            state.tabs[index].windows.append(managed)
            if case .parked = outcome {
                parkedWindowIDs.insert(managed.id)
            }
            return managed
        }
    }

    /// 登録を解除する。退避中なら固定 frame に戻してから手放す。
    public func unregister(_ id: UUID) async throws {
        try await serialized {
            guard let found = state.managedWindow(id: id) else { throw EngineError.unknownWindow(id) }
            let unreleased = await releaseAll([found.window], from: found.tab)
            // 固定 frame に戻せたことを確認できるまで登録は手放さない(隅に取り残さない)。
            guard unreleased.isEmpty else { throw EngineError.releaseFailed(managedIDs: unreleased) }
            removeFromState(id)
        }
    }

    /// 保存済み(未復元)エントリに実ウィンドウを紐付ける(再起動後の復元、手動割り当て)。
    /// アクティブタブなら固定 frame を適用して到達 frame を採用、非アクティブタブなら即座に退避する。
    public func bind(_ id: UUID, windowID: CGWindowID, pid: pid_t, title: String? = nil) async throws {
        try await serialized {
            guard let found = state.managedWindow(id: id) else { throw EngineError.unknownWindow(id) }
            if let existing = state.managedWindow(forWindowID: windowID), existing.window.id != id {
                throw EngineError.windowAlreadyRegistered(windowID: windowID, managedID: existing.window.id)
            }
            // 既に別の窓に紐付いているエントリは上書きしない(前の窓が state から消えて追跡不能になる)。
            // 同じ窓への再 bind は冪等に成功させる(緩め照合と厳しめ照合が同じ窓を選んだ場合など)。
            if let bound = found.window.windowID {
                guard bound == windowID else {
                    throw EngineError.entryAlreadyBound(managedID: id, boundWindowID: bound)
                }
                return
            }
            let intoActive = found.tab.id == state.activeTabID
            let recorded = found.window.frame
            let outcome = try await place(windowID: windowID, frame: recorded, intoActive: intoActive)
            let frame: CGRect
            switch outcome {
            case .placed(let actual):
                frame = actual
            case .unreached:
                // 復元では保存済みレイアウトこそ守るべき値。実窓は後の reconcile / スナップバックが寄せる。
                frame = recorded
            case .parked:
                frame = recorded
            }
            // await をまたいだので引き直す(解除されていれば unknownWindow)。
            guard let again = state.managedWindow(id: id),
                let ti = state.tabs.firstIndex(where: { $0.id == again.tab.id }),
                let wi = state.tabs[ti].windows.firstIndex(where: { $0.id == id })
            else { throw EngineError.unknownWindow(id) }
            state.tabs[ti].windows[wi].windowID = windowID
            state.tabs[ti].windows[wi].pid = pid
            state.tabs[ti].windows[wi].frame = frame
            if let title { state.tabs[ti].windows[wi].identity.title = title }
            if intoActive {
                parkedWindowIDs.remove(id)
            } else {
                parkedWindowIDs.insert(id)
            }
            log("bind: \(again.window.identity.appName) / \(title ?? again.window.identity.title) → \(intoActive ? "\(frame)" : "parked")")
        }
    }

    /// アプリが終了したとき、その pid の窓を「未復元」に戻す(登録は保持し、再起動後の自動紐付けに備える)。
    public func unbindWindows(pid: pid_t) {
        var count = 0
        for ti in state.tabs.indices {
            for wi in state.tabs[ti].windows.indices where state.tabs[ti].windows[wi].pid == pid {
                let id = state.tabs[ti].windows[wi].id
                cancelPendingRestore(id)
                parkedWindowIDs.remove(id)
                state.tabs[ti].windows[wi].windowID = nil
                state.tabs[ti].windows[wi].pid = nil
                vanished.removeValue(forKey: id)
                count += 1
            }
        }
        if count > 0 {
            log("unbind: pid \(pid) terminated, \(count) window(s) kept as unbound")
        }
    }

    /// アプリ終了前に呼ぶ。退避中(および非アクティブタブ)の全ウィンドウを固定 frame に戻す。
    /// 状態(タブ・登録)は変えない。切替が進行中なら順番を待つ。
    public func releaseAllParkedWindows() async {
        // ロック取得前に立てる: ロック待ち中の reconcile にも、これから始まる reconcile にも効かせる。
        isReleasingForShutdown = true
        await serialized {
            var unreleased = Set<UUID>()
            for tab in state.tabs {
                unreleased.formUnion(await releaseAll(tab.windows, from: tab))
            }
            if !unreleased.isEmpty {
                log("shutdown: \(unreleased.count) window(s) could not be restored and may remain parked")
            }
        }
    }

    /// destroyed の瞬間は「窓だけ閉じた」のか「終了シーケンス中の窓クローズ」なのか区別できない
    /// (Chrome 等は全窓を閉じてからプロセスを終えるため、その時点の isTerminated は false になりやすい)。
    /// 猶予時間。この間に pid が消えたら「アプリごと終了」として未復元で保持、生きていれば除去する。
    public var vanishGracePeriod: Duration = .seconds(3)
    private var vanished: [UUID: (pid: pid_t, at: ContinuousClock.Instant)] = [:]

    /// AX の destroyed 通知から呼ぶ。窓だけが閉じられたなら登録を外し、
    /// アプリごと終了したなら「未復元」として保持する(`appTerminated`)。
    /// どちらか確定できない場合は紐付けだけ外して保留し、判定は reconcile が行う。
    public func noteWindowDestroyed(windowID: CGWindowID, appTerminated: Bool = false) {
        guard let found = state.managedWindow(forWindowID: windowID) else { return }
        if appTerminated, let pid = found.window.pid {
            unbindWindows(pid: pid)
            return
        }
        let id = found.window.id
        cancelPendingRestore(id)
        parkedWindowIDs.remove(id)
        guard let pid = found.window.pid else {
            removeFromState(id)
            return
        }
        // 実窓との紐付けだけ外す(以後の操作対象から外れる)。pid は生存判定に使うので残す。
        setBinding(id, windowID: nil, pid: pid)
        vanished[id] = (pid, ContinuousClock.now)
        log("window vanished: \(found.window.identity.appName) / \(found.window.identity.title); deciding after grace")
    }

    /// 消滅保留の決着。アプリごと消えていれば未復元として保持、猶予を過ぎてもアプリが生きていれば
    /// 「本当に閉じられた」として除去する。`livePIDs` が nil のときは猶予経過でのみ除去する。
    private func resolveVanished(livePIDs: Set<pid_t>?) {
        guard !vanished.isEmpty else { return }
        let now = ContinuousClock.now
        for (id, info) in vanished {
            guard let found = state.managedWindow(id: id) else {
                vanished.removeValue(forKey: id)
                continue
            }
            if found.window.isBound {
                // 保留中に(同じアプリの新しい窓へ)再紐付けされた。
                vanished.removeValue(forKey: id)
                continue
            }
            if let livePIDs, !livePIDs.contains(info.pid) {
                setBinding(id, windowID: nil, pid: nil)
                vanished.removeValue(forKey: id)
                log("vanished: app of \(found.window.identity.appName) quit; kept as unbound")
            } else if now - info.at >= vanishGracePeriod {
                vanished.removeValue(forKey: id)
                log("vanished: \(found.window.identity.appName) / \(found.window.identity.title) was closed; removing")
                removeFromState(id)
            }
        }
    }

    private func setBinding(_ id: UUID, windowID: CGWindowID?, pid: pid_t?) {
        for ti in state.tabs.indices {
            if let wi = state.tabs[ti].windows.firstIndex(where: { $0.id == id }) {
                state.tabs[ti].windows[wi].windowID = windowID
                state.tabs[ti].windows[wi].pid = pid
                return
            }
        }
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
        let failures = await apply(results)
        state.activeTabID = tabID

        // IPC 中に最終フォーカス窓が閉じられていることがあるので、切替開始時の snapshot ではなく今の状態から選ぶ。
        if !alreadyActive, let refreshed = state.tab(withID: tabID), let pid = focusTargetPID(in: refreshed) {
            activateApplication?(pid)
        }
        log("activate \(target.name): \(ops.count) ops in \(String(format: "%.1f", elapsed)) ms" +
            (failures.isEmpty ? "" : "; failures: \(failures.map(\.message))"))
        return SwitchReport(tabID: tabID, operationCount: ops.count, durationMs: elapsed, failures: failures)
    }

    // MARK: - レイアウトの再適用

    /// ディスプレイ構成の変更・スリープ/ロック解除のあとに呼ぶ。
    /// アクティブタブの窓を新しいコンテンツ領域に収め直し、非アクティブタブの窓を新しい退避点へ移す。
    /// ユーザー操作との競合は想定しない(イベント起点)ので、デバウンスせず直接適用する。
    public func reapplyLayout() async {
        await serialized {
            guard !isReleasingForShutdown else { return }
            let point = layout.parkPoint
            var ops: [WindowOp] = []
            for tab in state.tabs {
                let isActive = tab.id == state.activeTabID
                for window in tab.windows {
                    guard let windowID = window.windowID, let pid = window.pid else { continue }
                    if isActive {
                        let target = clamped(window.frame)
                        if target != window.frame { updateFrame(window.id, target) }
                        cancelPendingRestore(window.id)
                        ops.append(WindowOp(managedID: window.id, windowID: windowID, pid: pid, kind: .restore(target, raise: false)))
                    } else {
                        ops.append(WindowOp(managedID: window.id, windowID: windowID, pid: pid, kind: .park(point)))
                    }
                }
            }
            guard !ops.isEmpty else { return }
            let failures = await apply(await run(ops))
            log("reapplyLayout: \(ops.count) ops" + (failures.isEmpty ? "" : "; failures: \(failures.map(\.message))"))
        }
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

    private func nextGeneration(for id: UUID) -> UInt64 {
        let next = (restoreGeneration[id] ?? 0) + 1
        restoreGeneration[id] = next
        return next
    }

    private func isLatest(_ id: UUID, _ generation: UInt64) -> Bool {
        restoreGeneration[id] == generation
    }

    private func scheduleRestore(_ id: UUID, attempt: Int) {
        pendingRestores[id]?.task.cancel()
        let generation = nextGeneration(for: id)
        let delay = config.debounce
        let task = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return  // キャンセル(= 新しい通知で延長された、または flush で即時実行された)
            }
            await self?.performRestore(id, attempt: attempt, generation: generation)
        }
        pendingRestores[id] = (task, attempt, generation)
    }

    /// デバウンス待ちの復元/記録を待たずに今すぐ実行する。
    /// マウスボタンが離された瞬間に呼ぶと、ドラッグ終了と同時に窓が戻る(250 ms 待たない)。
    public func flushPendingRestores() {
        let pending = pendingRestores
        pendingRestores.removeAll()
        for (id, entry) in pending {
            entry.task.cancel()
            // 世代はそのまま(予約を前倒しするだけ)。
            Task { [weak self] in await self?.performRestore(id, attempt: entry.attempt, generation: entry.generation) }
        }
    }

    private func performRestore(_ id: UUID, attempt: Int, generation: UInt64) async {
        // 自分より新しい予約・明示操作があれば何もしない(古い値を書き戻さない)。
        guard isLatest(id, generation) else { return }
        if pendingRestores[id]?.generation == generation {
            pendingRestores[id] = nil
        }
        guard let found = state.managedWindow(id: id), let windowID = found.window.windowID,
            !parkedWindowIDs.contains(id), found.tab.id == state.activeTabID
        else { return }
        let driver = self.driver
        // 読み取り(IPC)はロックの外。相手アプリが遅くても他の操作を待たせない。
        guard let current = try? await executor.run({ try driver.frame(of: windowID) }) else { return }
        guard isLatest(id, generation) else { return }  // IPC 中に新しい通知や setFrame が入った

        await serialized {
            // ロック待ちの間に切替・解除・新しい予約が走っていることがあるので前提を見直す。
            guard isLatest(id, generation), let found = state.managedWindow(id: id), !parkedWindowIDs.contains(id),
                found.tab.id == state.activeTabID
            else { return }
            if editMode {
                await recordEditedFrame(id: id, windowID: windowID, current: current, attempt: attempt, generation: generation,
                    appName: found.window.identity.appName)
                return
            }
            let recorded = found.window.frame
            if approximatelyEqual(current, recorded) { return }
            do {
                let actual = try await executor.run { try driver.setFrame(recorded, of: windowID) }
                guard isLatest(id, generation) else { return }
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

    /// 編集モード: 静止した位置を新しい固定 frame として記録する。
    /// サイドバー領域に置かれていればコンテンツ領域へ寄せてから、**到達した frame** を記録する(要求値は保存しない)。
    /// 寄せる操作が失敗したら以前の固定 frame を維持し、再試行に回す。
    private func recordEditedFrame(
        id: UUID, windowID: CGWindowID, current: CGRect, attempt: Int, generation: UInt64, appName: String
    ) async {
        let target = clamped(current)
        if approximatelyEqual(target, current) {
            updateFrame(id, current)
            log("edit: recorded \(current) for \(appName)")
            return
        }
        let driver = self.driver
        do {
            let actual = try await executor.run { try driver.setFrame(target, of: windowID) }
            guard isLatest(id, generation) else { return }
            updateFrame(id, actual)
            log("edit: nudged into content area and recorded \(actual) for \(appName)")
        } catch {
            guard isLatest(id, generation) else { return }
            log("edit: could not nudge \(appName) (\(error)); keeping previous frame")
            if attempt < config.maxRestoreAttempts {
                scheduleRestore(id, attempt: attempt + 1)
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
    /// - Parameter livePIDs: 実行中のアプリの pid。消えた窓の pid がここに無ければアプリごと終了したとみなし、
    ///   除去ではなく「未復元」に戻す。nil なら常に除去する。
    public func reconcile(liveWindowIDs: Set<CGWindowID>, livePIDs: Set<pid_t>? = nil) async {
        guard !isReleasingForShutdown else { return }
        resolveVanished(livePIDs: livePIDs)
        if !liveWindowIDs.isEmpty {
            for window in state.allWindows {
                guard let windowID = window.windowID, !liveWindowIDs.contains(windowID) else { continue }
                if let livePIDs, let pid = window.pid, !livePIDs.contains(pid) {
                    unbindWindows(pid: pid)
                    continue
                }
                log("reconcile: window gone: \(window.identity.appName) / \(window.identity.title)")
                removeFromState(window.id)
            }
        }

        let point = layout.parkPoint
        let frames = await observedFrames()

        await serialized {
            // ロック待ちの間に終了処理が走っていれば、戻された窓を隅へ送り返さない。
            guard !isReleasingForShutdown else { return }
            var ops: [WindowOp] = []
            for tab in state.tabs {
                let isActive = tab.id == state.activeTabID
                for window in tab.windows {
                    guard let windowID = window.windowID, let pid = window.pid else { continue }
                    let flagged = parkedWindowIDs.contains(window.id)
                    let current = frames[window.id]
                    if isActive, flagged {
                        // 復元に失敗したまま = 隅に残っているはずなので、復元をやり直す。
                        ops.append(WindowOp(managedID: window.id, windowID: windowID, pid: pid, kind: .restore(window.frame, raise: false)))
                    } else if isActive, let current, !approximatelyEqual(current, window.frame), pendingRestores[window.id] == nil {
                        // 通知を取りこぼして固定 frame からずれている。ドラッグ中かもしれないので
                        // 即時には動かさず、通常のデバウンス復元(編集モードなら記録)に流す。
                        log("reconcile: \(window.identity.appName) drifted to \(current); scheduling restore")
                        scheduleRestore(window.id, attempt: 1)
                    } else if !isActive, !flagged || (current.map { abs($0.minX - point.x) > 1 } ?? false) {
                        // y は OS にクランプされて窓の高さごとに変わる(実測 1067〜1087)ので判定に使わない。
                        // x = 画面幅 − 1 は通常のウィンドウでは起こらないので、x だけで「隅にいる」とみなす。
                        ops.append(WindowOp(managedID: window.id, windowID: windowID, pid: pid, kind: .park(point)))
                    }
                }
            }
            guard !ops.isEmpty else { return }
            log("reconcile: \(ops.count) corrective ops")
            let failures = await apply(await run(ops))
            for failure in failures {
                log("reconcile: op failed for \(failure.managedID): \(failure.message)")
            }
        }
    }

    /// 紐付いている全窓の現在 frame を読む。読み取りは pid ごとに並列(ロックの外で呼ぶこと)。
    /// 読めない(消えた / 無応答)窓は含めない = 判断材料がないので触らない。
    private func observedFrames() async -> [UUID: CGRect] {
        let candidates = state.allWindows.filter(\.isBound)
        guard !candidates.isEmpty else { return [:] }
        let driver = self.driver
        let executor = self.executor
        let groups = Dictionary(grouping: candidates, by: { $0.pid ?? 0 })
        return await withTaskGroup(of: [(UUID, CGRect)].self) { group in
            for (_, windows) in groups {
                group.addTask {
                    await executor.run {
                        windows.compactMap { window -> (UUID, CGRect)? in
                            guard let wid = window.windowID, let current = try? driver.frame(of: wid) else { return nil }
                            return (window.id, current)
                        }
                    }
                }
            }
            var all: [UUID: CGRect] = [:]
            for await pairs in group {
                for (id, frame) in pairs { all[id] = frame }
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
    /// ただし AX は「適用したあとで throw」することがあるので、失敗した op は読み戻して到達していれば成功扱いにする。
    private func apply(_ results: [OpResult]) async -> [OperationFailure] {
        var failures: [OperationFailure] = []
        let driver = self.driver
        for var result in results {
            // 実行中に閉じられた・紐付けが外れた/変わったウィンドウの結果は捨てる
            // (unbound になったエントリに退避フラグを立てない)。
            guard state.managedWindow(id: result.op.managedID)?.window.windowID == result.op.windowID else { continue }
            if let note = result.note {
                log("\(result.op.managedID): \(note)")
            }
            if let error = result.error {
                let windowID = result.op.windowID
                let current = try? await executor.run { try driver.frame(of: windowID) }
                let reached: Bool
                switch result.op.kind {
                case .park(let point): reached = current.map { abs($0.minX - point.x) <= 1 } ?? false
                case .restore(let frame, _): reached = current.map { approximatelyEqual($0, frame) } ?? false
                }
                guard reached, let current else {
                    failures.append(OperationFailure(managedID: result.op.managedID, message: error))
                    continue
                }
                log("\(result.op.managedID): reported \(error) but reached the target; treating as success")
                result = OpResult(op: result.op, actual: current, error: nil, note: nil)
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
    ///
    /// 戻り値は復元を確認できなかった窓(退避フラグは維持する)。呼び出し側はこれが空のときだけ登録を手放す。
    private func releaseAll(_ windows: [ManagedWindow], from tab: Tab) async -> Set<UUID> {
        let isActive = tab.id == state.activeTabID
        var ops: [WindowOp] = []
        for window in windows {
            cancelPendingRestore(window.id)
            guard let windowID = window.windowID, let pid = window.pid else { continue }
            if !isActive || parkedWindowIDs.contains(window.id) {
                ops.append(WindowOp(managedID: window.id, windowID: windowID, pid: pid, kind: .restore(window.frame, raise: false)))
            }
        }
        guard !ops.isEmpty else { return [] }
        let driver = self.driver
        var unreleased = Set<UUID>()
        for result in await run(ops) {
            if let error = result.error {
                // 適用後に throw した可能性があるので読み戻して確認する。到達していれば成功扱い。
                let recorded: CGRect? = { if case .restore(let f, _) = result.op.kind { return f } else { return nil } }()
                let windowID = result.op.windowID
                if let recorded, let current = try? await executor.run({ try driver.frame(of: windowID) }),
                    approximatelyEqual(current, recorded)
                {
                    log("release: \(result.op.managedID) reported \(error) but reached its frame")
                } else {
                    log("release: could not restore \(result.op.managedID): \(error)")
                    unreleased.insert(result.op.managedID)
                    continue
                }
            }
            parkedWindowIDs.remove(result.op.managedID)
        }
        return unreleased
    }

    private enum PlacementOutcome: CustomStringConvertible {
        /// 要求 frame に到達した(制約によるサイズ差は含む)。
        case placed(CGRect)
        /// setFrame が失敗し、読み戻した現在 frame は要求に到達していない(未適用または部分適用)。
        case unreached(CGRect)
        case parked

        var description: String {
            switch self {
            case .placed(let f): return "\(f)"
            case .unreached(let f): return "unreached (at \(f))"
            case .parked: return "parked (inactive tab)"
            }
        }
    }

    /// 登録・紐付け時の配置。失敗しても窓の実状態を読み戻し、管理下に置けるなら結果を返す。
    ///
    /// AX は操作を適用したあとでタイムアウト等を返すことがある。そのとき未登録のまま捨てると
    /// 隅へ動かした窓を誰も追跡できなくなるので、「動いていれば commit、動いていなければ throw」にする。
    private func place(windowID: CGWindowID, frame: CGRect, intoActive: Bool) async throws -> PlacementOutcome {
        let driver = self.driver
        if intoActive {
            do {
                return .placed(try await executor.run { try driver.setFrame(frame, of: windowID) })
            } catch {
                // 読み戻せれば(未適用・部分適用でも)管理下に置く。読めない = 窓が消えた/無応答なので失敗させる。
                if let current = try? await executor.run({ try driver.frame(of: windowID) }) {
                    if approximatelyEqual(current, frame) {
                        log("place: setFrame reported \(error) but reached the frame")
                        return .placed(current)
                    }
                    log("place: setFrame reported \(error); window is at \(current), not at the request")
                    return .unreached(current)
                }
                throw error
            }
        }
        let point = layout.parkPoint
        do {
            try await executor.run { try driver.setPosition(point, of: windowID) }
            return .parked
        } catch {
            if await isProbablyParked(windowID, parkPoint: point) {
                log("place: park reported \(error) but the window is at the corner; committing as parked")
                return .parked
            }
            throw error
        }
    }

    /// 退避の IPC が失敗したあと、実際に隅へ動いたかを読み戻して判定する。
    /// 読めない場合は「動いたかもしれない」として true(見失うより管理下に置く方が安全。消えた窓は reconcile が外す)。
    private func isProbablyParked(_ windowID: CGWindowID, parkPoint: CGPoint) async -> Bool {
        let driver = self.driver
        guard let current = try? await executor.run({ try driver.frame(of: windowID) }) else { return true }
        return abs(current.minX - parkPoint.x) <= 1
    }

    // MARK: - 内部ヘルパー

    private func focusTargetPID(in tab: Tab) -> pid_t? {
        // 未復元(実窓なし)のエントリは前面化の対象にしない(消滅保留中は pid だけ残っていることがある)。
        if let focused = tab.lastFocusedWindowID, let w = tab.windows.first(where: { $0.id == focused }),
            w.isBound, let pid = w.pid
        {
            return pid
        }
        return tab.windows.first(where: \.isBound)?.pid
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
        // IPC 中で止められない Task が戻ってきても古い値を書かないよう、世代を進めて無効化する。
        _ = nextGeneration(for: id)
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
