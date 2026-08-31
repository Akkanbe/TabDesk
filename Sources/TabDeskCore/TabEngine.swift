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
        /// 切替前にアクティブだったタブ(直列区間内で確定した値。サムネイル撮影の対象決定に使う)。
        public let previousActiveTabID: UUID?
        public let operationCount: Int
        public let durationMs: Double
        public let failures: [OperationFailure]
    }

    public enum EngineError: Error, CustomStringConvertible, Sendable {
        case unknownTab(UUID)
        case unknownWindow(UUID)
        case windowAlreadyRegistered(windowID: CGWindowID, managedID: UUID)
        case invalidTabOrder
        case invalidWindowOrder
        /// columns では列計算が frame の唯一の正なので、個別 frame は直接変更できない。
        case frameManagedByLayout(tabID: UUID)
        /// 退避中の窓を固定 frame に戻せなかった(登録は保持される。相手アプリが応答したら再試行できる)。
        case releaseFailed(managedIDs: Set<UUID>)
        /// エントリは既に別の実ウィンドウに紐付いている(上書きすると前の窓が追跡不能になる)。
        case entryAlreadyBound(managedID: UUID, boundWindowID: CGWindowID)
        /// 終了時の全窓解放が始まっている。これ以降に実窓を動かす操作は受け付けない。
        case shuttingDown

        public var description: String {
            switch self {
            case .unknownTab(let id): return "unknown tab \(id)"
            case .unknownWindow(let id): return "unknown managed window \(id)"
            case .windowAlreadyRegistered(let wid, let mid): return "window \(wid) already registered as \(mid)"
            case .invalidTabOrder: return "invalid tab order"
            case .invalidWindowOrder: return "invalid window order"
            case .frameManagedByLayout(let id): return "window frame is managed by tab layout \(id)"
            case .releaseFailed(let ids): return "could not restore \(ids.count) parked window(s); registration kept"
            case .entryAlreadyBound(let mid, let wid): return "entry \(mid) is already bound to window \(wid)"
            case .shuttingDown: return "TabDesk is shutting down"
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

    /// ネイティブフルスクリーン中の窓(v3 段階 2。実行時のみ、tabdesk://status の診断にも使う)。
    /// reconcile の一括読み取りで毎 tick 更新し、スナップバック経路では通知時に読み直す。
    /// メンバーの窓には op を発行しない(setFrame/setPosition が黙って無視され、復元リトライが
    /// 最終的にフルスクリーン寸法を「到達 frame」として採用してしまうため)。
    /// 切断退避(D3)との意図的な差: ディスプレイは接続中なので、記録 frame の更新(clamp / 列計算)は
    /// 続ける — 論理配置は正しく保ち、解除後にそこへ戻す。op だけを止める。
    public private(set) var fullscreenWindowIDs: Set<UUID> = []

    private let driver: any WindowDriver
    private let layout: any ScreenLayout
    private let config: Configuration
    private let executor = BlockingExecutor()
    private var pendingRestores: [UUID: (task: Task<Void, Never>, attempt: Int, generation: UInt64)] = [:]
    /// 窓ごとの復元予約の世代。Task.cancel は IPC 中の Task を止められないので、
    /// 戻ってきた古い Task が「自分はまだ最新か」を世代で確かめてから状態を触る。
    private var restoreGeneration: [UUID: UInt64] = [:]
    /// テスト用: 復元世代表のエントリ数(登録解除で剪定されることの検証)。
    var restoreGenerationCountForTesting: Int { restoreGeneration.count }
    /// テスト用: レイアウト遷移バリアの状態(endLayoutTransition の無条件クリアを固定する)。
    var isLayoutTransitioningForTesting: Bool { isLayoutTransitioning }
    /// 画面構成変更から再適用完了まで、OS 由来の moved/resized をユーザー編集として扱わない。
    private var isLayoutTransitioning = false
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// 同期削除経路(destroyed / vanish)から立てる列再計算の予約。直近の reconcile が 1 回だけ消化する。
    /// タイルの再計算を構造イベント時に限定するための仕組み(毎 reconcile で理想値を書き直すと、
    /// 最小サイズ制約のあるアプリと「理想値→失敗→到達値採用→また理想値」の発振になる)。
    private var pendingRetileTabIDs: Set<UUID> = []

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

    /// タブ内でウィンドウを 1 つ前/後ろへ並べ替える(columns の列順 = 一覧の並び順)。
    /// columns のタブなら新しい順序で列を組み直す。範囲外は invalidWindowOrder。
    public func moveWindow(_ id: UUID, offset: Int) async throws {
        try await serialized {
            try rejectIfShuttingDown()
            guard let location = windowLocation(of: id) else { throw EngineError.unknownWindow(id) }
            let destination = location.windowIndex + offset
            guard state.tabs[location.tabIndex].windows.indices.contains(destination) else {
                throw EngineError.invalidWindowOrder
            }
            let window = state.tabs[location.tabIndex].windows.remove(at: location.windowIndex)
            state.tabs[location.tabIndex].windows.insert(window, at: destination)
            if state.tabs[location.tabIndex].layout == .columns {
                await retileUnlocked(state.tabs[location.tabIndex].id)
            }
        }
    }

    /// タブのレイアウトを変更する。columns にした場合はその場で列を適用する。
    /// free に戻した場合は現在のタイル rect がそのまま自由配置の固定 frame になる(旧配置は保存しない)。
    public func setTabLayout(_ tabID: UUID, _ newLayout: TabLayout) async throws {
        try await serialized {
            try rejectIfShuttingDown()
            let index = try tabIndex(tabID)
            guard state.tabs[index].layout != newLayout else { return }
            state.tabs[index].layout = newLayout
            log("layout: \(state.tabs[index].name) → \(newLayout.rawValue)")
            if newLayout == .columns {
                await retileUnlocked(tabID)
            }
        }
    }

    /// タブを削除する。退避中だったウィンドウは固定 frame に戻してから解放する(画面隅に取り残さない)。
    /// アクティブタブを削除した場合は残りの先頭タブをアクティブにする。
    @discardableResult
    public func deleteTab(_ id: UUID) async throws -> [CGWindowID] {
        try await serialized {
            try rejectIfShuttingDown()
            let tab = try self.tab(id)
            let unreleased = await releaseAll(tab.windows, from: tab)
            // 1 枚でも戻せなければタブごと残す(隅に取り残した窓を追跡不能にしない)。
            // 戻せた窓は非アクティブタブの未退避窓として reconcile が再び退避する。
            guard unreleased.isEmpty else { throw EngineError.releaseFailed(managedIDs: unreleased) }
            let removedWindowIDs = tab.windows.compactMap(\.windowID)
            for window in tab.windows {
                clearRuntimeTracking(for: window.id)
            }
            pendingRetileTabIDs.remove(id)
            // await をまたいだので index は引き直す(同期の moveTab が割り込みうる)。
            state.tabs.remove(at: try tabIndex(id))
            if state.activeTabID == id {
                state.activeTabID = nil
                if let next = state.tabs.first {
                    try await activateUnlocked(next.id)
                }
            }
            return removedWindowIDs
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
            try rejectIfShuttingDown()
            _ = try tabIndex(tabID)
            if let existing = state.managedWindow(forWindowID: windowID) {
                throw EngineError.windowAlreadyRegistered(windowID: windowID, managedID: existing.window.id)
            }
            // 窓がいたディスプレイに留める(主ディスプレイへの引き込みは段階 D で廃止)。
            let display = layout.display(containing: frame) ?? layout.primaryDisplay
            let frame = clamped(frame, in: display?.contentArea ?? layout.contentArea)
            var managed = ManagedWindow(
                frame: frame, identity: identity, windowID: windowID, pid: pid, displayID: display?.id)
            let intoActive = tabID == state.activeTabID

            let outcome = try await place(
                windowID: windowID, frame: frame, intoActive: intoActive,
                parkPoint: display?.parkPoint ?? layout.parkPoint)
            // 登録直前のUI判定後、place の IPC 中にも fullscreen へ入り得る。binding がまだ
            // state に無いので、windowID を直接読み直してから保存値とruntime状態を確定する。
            let fullscreenAfterPlacement = await probeFullscreen(windowID: windowID)
            // place の IPC 中に所属ディスプレイが切断された場合、OS が生きている画面へ
            // 丸めた実位置を保存しない。登録開始時の座標を再接続用に残す。
            let disconnectedAfterPlacement = isDisplayDisconnected(managed)
            if !disconnectedAfterPlacement, fullscreenAfterPlacement != true {
                switch outcome {
                case .placed(let actual):
                    managed.frame = actual
                case .unreached(let current):
                    // 新規登録は「今ある位置」を基準にしてよい(ユーザーがまだレイアウトを決めていない)。
                    managed.frame = clamped(current, in: display?.contentArea ?? layout.contentArea)
                case .parked:
                    break
                }
            }
            log("register: \(identity.appName) → \(outcome.description) (requested \(frame))")
            // await をまたいだので index は引き直す(タブが消えていれば unknownTab)。
            let index = try tabIndex(tabID)
            state.tabs[index].windows.append(managed)
            if fullscreenAfterPlacement == true {
                fullscreenWindowIDs.insert(managed.id)
                log("fullscreen: \(identity.appName) entered during registration; suspending ops")
            } else if case .parked = outcome, !disconnectedAfterPlacement {
                parkedWindowIDs.insert(managed.id)
            }
            if state.tabs[index].layout == .columns {
                await retileUnlocked(tabID)
            }
            // columns では直前の retile で frame が変わるため、登録前のローカル snapshot を返さない。
            guard let committed = state.managedWindow(id: managed.id)?.window else {
                throw EngineError.unknownWindow(managed.id)
            }
            return committed
        }
    }

    /// 登録を解除する。退避中なら固定 frame に戻してから手放す。
    @discardableResult
    public func unregister(_ id: UUID) async throws -> CGWindowID? {
        try await serialized {
            try rejectIfShuttingDown()
            guard let found = state.managedWindow(id: id) else { throw EngineError.unknownWindow(id) }
            let unreleased = await releaseAll([found.window], from: found.tab)
            // 固定 frame に戻せたことを確認できるまで登録は手放さない(隅に取り残さない)。
            guard unreleased.isEmpty else { throw EngineError.releaseFailed(managedIDs: unreleased) }
            removeFromState(id)
            await retileUnlocked(found.tab.id)  // columns なら残りで列を組み直す(free なら何もしない)
            return found.window.windowID
        }
    }

    /// 保存済み(未復元)エントリに実ウィンドウを紐付ける(再起動後の復元、手動割り当て)。
    /// アクティブタブなら固定 frame を適用して到達 frame を採用、非アクティブタブなら即座に退避する。
    public func bind(
        _ id: UUID,
        windowID: CGWindowID,
        pid: pid_t,
        title: String? = nil,
        identity: WindowIdentity? = nil
    ) async throws {
        try await serialized {
            try rejectIfShuttingDown()
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
            // fullscreen / park は実ウィンドウとの binding 固有の状態。前の binding の残骸を
            // 新しい窓へ持ち越さない。
            clearRuntimeTracking(for: id)
            // 消滅判定の猶予中に新しい窓への紐付けを開始した場合、place の IPC 待ち中に
            // resolveVanished が entry を削除しないよう、この時点で古い消滅保留を取り消す。
            vanished.removeValue(forKey: id)
            let intoActive = found.tab.id == state.activeTabID
            let requestedFrame: CGRect
            let frame: CGRect
            let fullscreenAfterPlacement: Bool?
            if isDisplayDisconnected(found.window) {
                // 切断退避中は配置(place)を丸ごと省略する: 記録 frame を凍結し、実窓は今の場所のまま
                // 紐付けだけ行う(段階 D3)。再接続後の reapplyLayout が記録 frame へ復元する。
                requestedFrame = found.window.frame
                frame = requestedFrame
                fullscreenAfterPlacement = nil
                log("bind (display disconnected): kept frame, window left as-is")
            } else {
                // 保存時と画面構成が違っていても、最初の復元から現在のコンテンツ領域内へ収める。
                // 退避先も窓のディスプレイの隅。
                let recorded = clamped(found.window.frame, for: found.window)
                requestedFrame = recorded
                let outcome = try await place(
                    windowID: windowID, frame: recorded, intoActive: intoActive,
                    parkPoint: parkPoint(for: found.window))
                switch outcome {
                case .placed(let actual):
                    frame = actual
                case .unreached:
                    // 復元では保存済みレイアウトこそ守るべき値。実窓は後の reconcile / スナップバックが寄せる。
                    frame = recorded
                case .parked:
                    frame = recorded
                }
                // place 中のfullscreen進入を、保存frameを確定する前に拾う。bind完了前なので
                // managed ID 用のmembership helperではなく実windowIDを直接読む。
                fullscreenAfterPlacement = await probeFullscreen(windowID: windowID)
            }
            // await をまたいだので引き直す(解除されていれば unknownWindow)。
            guard let location = windowLocation(of: id) else { throw EngineError.unknownWindow(id) }
            let currentTab = state.tabs[location.tabIndex]
            let currentWindow = currentTab.windows[location.windowIndex]
            let previousIdentity = currentWindow.identity
            // 接続中として place を始めても、その IPC 中に切断されうる。そこで読み戻した
            // 主画面側の座標ではなく、entry が元から持っていた座標を凍結する。
            let disconnectedAfterPlacement = isDisplayDisconnected(currentWindow)
            let committedFrame: CGRect
            if disconnectedAfterPlacement {
                committedFrame = currentWindow.frame
            } else if fullscreenAfterPlacement == true {
                // fullscreen 中も論理配置の更新は続ける。解除後に安全な現在領域へ戻せるよう、
                // 実際のfullscreen寸法ではなくplaceへ渡したclamp済みframeを保持する。
                committedFrame = requestedFrame
            } else {
                committedFrame = frame
            }
            state.tabs[location.tabIndex].windows[location.windowIndex].windowID = windowID
            state.tabs[location.tabIndex].windows[location.windowIndex].pid = pid
            state.tabs[location.tabIndex].windows[location.windowIndex].frame = committedFrame
            if let identity {
                state.tabs[location.tabIndex].windows[location.windowIndex].identity = identity
            } else if let title {
                state.tabs[location.tabIndex].windows[location.windowIndex].identity.title = title
            }
            if fullscreenAfterPlacement == true {
                fullscreenWindowIDs.insert(id)
                parkedWindowIDs.remove(id)
                log("fullscreen: \(previousIdentity.appName) entered during binding; suspending ops")
            } else if intoActive || disconnectedAfterPlacement {
                // 切断退避中は park していない(op を出していない)ので、非アクティブでもフラグは立てない。
                parkedWindowIDs.remove(id)
            } else {
                parkedWindowIDs.insert(id)
            }
            let placementDescription: String
            if disconnectedAfterPlacement {
                placementDescription = "display disconnected; kept \(committedFrame)"
            } else if fullscreenAfterPlacement == true {
                placementDescription = "fullscreen; kept logical frame \(committedFrame)"
            } else {
                placementDescription = intoActive ? "\(committedFrame)" : "parked"
            }
            log("bind: \(previousIdentity.appName) / \(title ?? previousIdentity.title) → \(placementDescription)")
            if state.tabs[location.tabIndex].layout == .columns {
                await retileUnlocked(state.tabs[location.tabIndex].id)
            }
        }
    }

    /// アプリが終了したとき、その pid の窓を「未復元」に戻す(登録は保持し、再起動後の自動紐付けに備える)。
    public func unbindWindows(pid: pid_t) {
        var count = 0
        for ti in state.tabs.indices {
            for wi in state.tabs[ti].windows.indices where state.tabs[ti].windows[wi].pid == pid {
                let id = state.tabs[ti].windows[wi].id
                clearRuntimeTracking(for: id)
                state.tabs[ti].windows[wi].windowID = nil
                state.tabs[ti].windows[wi].pid = nil
                vanished.removeValue(forKey: id)
                count += 1
                // unbound は列数に入らないので、columns では bound 数の減少も構造イベント
                // (removeFromState と同じく同期経路なので予約だけ立て、reconcile が消化する)。
                if state.tabs[ti].layout == .columns {
                    pendingRetileTabIDs.insert(state.tabs[ti].id)
                }
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
        beginShutdown()
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

    /// 終了barrierを同期的に立てる。WindowManagerは終了要求を受けたその場で呼び、
    /// cleanup Taskが実行されるまでの短い隙間にも新しいpark/bindを許さない。
    public func beginShutdown() {
        guard !isReleasingForShutdown else { return }
        isReleasingForShutdown = true
        cancelAllRestores()
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
        markVanished(found)
    }

    /// 通知・ポーリング共通の「窓は消えたが、アプリ終了か単独closeか未確定」状態へ移す。
    private func markVanished(_ found: (tab: Tab, window: ManagedWindow)) {
        let id = found.window.id
        guard let pid = found.window.pid else {
            removeFromState(id)
            return
        }
        // park / fullscreen / restore世代は、消えた実ウィンドウとの binding 固有の状態。
        // entry 自体は復元用に残しても、次の実ウィンドウへ持ち越してはいけない。
        clearRuntimeTracking(for: id)
        // 実窓との紐付けだけ外す(以後の操作対象から外れる)。pid は生存判定に使うので残す。
        setBinding(id, windowID: nil, pid: pid)
        if found.tab.layout == .columns {
            // 猶予中もこの窓は操作対象外なので、残った bound 窓だけで列を組み直す。
            pendingRetileTabIDs.insert(found.tab.id)
        }
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
                clearRuntimeTracking(for: id)
                setBinding(id, windowID: nil, pid: nil)
                log("vanished: app of \(found.window.identity.appName) quit; kept as unbound")
            } else if now - info.at >= vanishGracePeriod {
                vanished.removeValue(forKey: id)
                log("vanished: \(found.window.identity.appName) / \(found.window.identity.title) was closed; removing")
                removeFromState(id)
            }
        }
    }

    private func setBinding(_ id: UUID, windowID: CGWindowID?, pid: pid_t?) {
        updateManagedWindow(id) { window in
            window.windowID = windowID
            window.pid = pid
        }
    }

    /// フォーカスが移ったウィンドウを記録する(切替時に最前面へ戻すため)。
    public func noteWindowFocused(windowID: CGWindowID) {
        guard let found = state.managedWindow(forWindowID: windowID),
            let index = state.tabs.firstIndex(where: { $0.id == found.tab.id })
        else { return }
        guard state.tabs[index].lastFocusedWindowID != found.window.id else { return }
        state.tabs[index].lastFocusedWindowID = found.window.id
    }

    /// 固定 frame を明示的に変える(free の配置 UI や編集操作から)。
    /// 表示中なら適用して到達 frame を記録、退避中なら記録だけする。
    @discardableResult
    public func setFrame(_ frame: CGRect, of id: UUID) async throws -> CGRect {
        try await serialized {
            try rejectIfShuttingDown()
            guard let found = state.managedWindow(id: id) else { throw EngineError.unknownWindow(id) }
            guard found.tab.layout == .free else {
                throw EngineError.frameManagedByLayout(tabID: found.tab.id)
            }
            // 切断退避中は要求値をそのまま記録して IPC しない(clamp すると主の座標に化ける)。
            let frame = isDisplayDisconnected(found.window) ? frame : clamped(frame, for: found.window)
            cancelPendingRestore(id)
            // フルスクリーン中も記録のみ(段階 2 の他経路と同じ: 論理配置は更新し、IPC は出さない。
            // 出すと書き込みが飲み込まれ、読み戻したフルスクリーン寸法を記録してしまう)。
            guard let windowID = found.window.windowID, !parkedWindowIDs.contains(id),
                found.tab.id == state.activeTabID, !opsSuppressed(for: found.window)
            else {
                updateFrame(id, frame)
                return frame
            }
            let driver = self.driver
            let actual = try await executor.run { try driver.setFrame(frame, of: windowID) }
            guard let rebound = state.managedWindow(id: id), rebound.window.windowID == windowID else {
                throw EngineError.unknownWindow(id)
            }
            // 呼出し直前には通常窓でも、IPC 中に fullscreen / ディスプレイ切断へ遷移しうる。
            // fullscreen ならユーザーの論理要求だけを残し、切断なら従来値を凍結する。
            if !approximatelyEqual(actual, frame),
                await refreshFullscreenMembership(managedID: id, windowID: windowID) == true
            {
                updateFrame(id, frame)
                return frame
            }
            guard let current = state.managedWindow(id: id), current.window.windowID == windowID else {
                throw EngineError.unknownWindow(id)
            }
            if isDisplayDisconnected(current.window) {
                return current.window.frame
            }
            updateFrame(id, actual)
            return actual
        }
    }

    // MARK: - タブ切替

    /// タブを切り替える。他タブのウィンドウを退避し、対象タブのウィンドウを固定 frame に復元する。
    /// pid ごとに並列実行するので、1 アプリが遅くても他アプリは待たされない。
    @discardableResult
    public func activate(_ tabID: UUID) async throws -> SwitchReport {
        try await serialized {
            try rejectIfShuttingDown()
            return try await activateUnlocked(tabID)
        }
    }

    /// 隣のタブへ切り替える(offset +1 = 次、-1 = 前。端で循環)。
    /// 相対ターゲットの解決を直列区間の**中**で行う。連打時、切替が確定する前の古い activeTabID から
    /// 同じタブを選んでしまい「1 押下 = 1 タブ」にならない問題を防ぐ(押した回数ぶん確実に進む)。
    @discardableResult
    public func activateAdjacent(offset: Int) async throws -> SwitchReport? {
        try await serialized {
            try rejectIfShuttingDown()
            let count = state.tabs.count
            guard count > 0 else { return nil }
            let index: Int
            if let current = state.tabs.firstIndex(where: { $0.id == state.activeTabID }) {
                index = ((current + offset) % count + count) % count
            } else {
                // アクティブタブが無い/消えている場合は方向によらず先頭へ。
                index = 0
            }
            return try await activateUnlocked(state.tabs[index].id)
        }
    }

    @discardableResult
    private func activateUnlocked(_ tabID: UUID) async throws -> SwitchReport {
        let target = try tab(tabID)
        let previousActive = state.activeTabID
        let alreadyActive = tabID == state.activeTabID
        let desired = desiredFrames(for: target)
        var parks: [WindowOp] = []
        var restores: [WindowOp] = []
        for tab in state.tabs {
            for window in tab.windows {
                guard let windowID = window.windowID, let pid = window.pid else { continue }  // 未復元は対象外
                guard !isDisplayDisconnected(window) else { continue }  // 切断退避(frame 凍結・op なし)
                if tab.id == tabID {
                    // 既にアクティブなタブの窓には触らない。ドラッグ中の一時 frame を読み戻して
                    // 「到達 frame」として採用してしまうのを避けるため(ずれはスナップバックが直す)。
                    if !alreadyActive {
                        let targetFrame = desired[window.id] ?? clamped(window.frame, for: window)
                        if targetFrame != window.frame { updateFrame(window.id, targetFrame) }
                        // フルスクリーン中は論理 frame だけ更新して op は出さない(解除後にここへ戻す)。
                        guard !fullscreenWindowIDs.contains(window.id) else { continue }
                        restores.append(WindowOp(managedID: window.id, windowID: windowID, pid: pid, kind: .restore(targetFrame, raise: true)))
                    }
                } else if !parkedWindowIDs.contains(window.id), !fullscreenWindowIDs.contains(window.id) {
                    // 原則は同じ画面の隅。内側の画面では露出を防ぐため配置外縁へ fallback する。
                    parks.append(WindowOp(managedID: window.id, windowID: windowID, pid: pid, kind: .park(parkPoint(for: window))))
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
        return SwitchReport(
            tabID: tabID, previousActiveTabID: previousActive,
            operationCount: ops.count, durationMs: elapsed, failures: failures)
    }

    // MARK: - レイアウトの再適用

    /// ディスプレイ構成の変更・スリープ/ロック解除のあとに呼ぶ。
    /// アクティブタブの窓を新しいコンテンツ領域に収め直し、非アクティブタブの窓を新しい退避点へ移す。
    /// ユーザー操作との競合は想定しない(イベント起点)ので、デバウンスせず直接適用する。
    public func reapplyLayout() async {
        await serialized {
            guard !isReleasingForShutdown else { return }
            // columns はコンテンツ領域の変化に追従して列を計算し直す(free は従来どおり位置 clamp のみ)。
            // 窓のディスプレイが切断されていれば主ディスプレイへ clamp される(段階 D の消失ポリシー)。
            var ops: [WindowOp] = []
            for tab in state.tabs {
                let isActive = tab.id == state.activeTabID
                let desired = desiredFrames(for: tab)
                for window in tab.windows {
                    // 切断退避中は論理 frame を凍結し op も出さない(段階 D3)。ここで clamp すると
                    // 主ディスプレイの座標で保存され、再接続後に元の位置へ戻れなくなる(精査 High)。
                    guard !isDisplayDisconnected(window) else { continue }
                    // 接続中の窓は、非アクティブでも論理 frame を現在の画面構成へ更新する。更新しないと、
                    // 画面リサイズ後にそのタブを表示せず解除・削除・終了した際、旧座標へ復元してしまう。
                    let target = desired[window.id] ?? clamped(window.frame, for: window)
                    if target != window.frame { updateFrame(window.id, target) }
                    guard let windowID = window.windowID, let pid = window.pid else { continue }
                    // フルスクリーン中は論理 frame の更新だけ行い、op は出さない(段階 2)。
                    guard !fullscreenWindowIDs.contains(window.id) else { continue }
                    if isActive {
                        cancelPendingRestore(window.id)
                        ops.append(WindowOp(managedID: window.id, windowID: windowID, pid: pid, kind: .restore(target, raise: false)))
                    } else {
                        ops.append(WindowOp(managedID: window.id, windowID: windowID, pid: pid, kind: .park(parkPoint(for: window))))
                    }
                }
            }
            guard !ops.isEmpty else { return }
            let failures = await apply(await run(ops))
            log("reapplyLayout: \(ops.count) ops" + (failures.isEmpty ? "" : "; failures: \(failures.map(\.message))"))
        }
    }

    /// 画面変更通知を受けた同期地点で立てる barrier。OS が先に動かした窓を編集モードで記録しない。
    public func beginLayoutTransition() {
        guard !isReleasingForShutdown else { return }
        isLayoutTransitioning = true
        cancelAllRestores()
    }

    /// 最新の画面構成で reapplyLayout が完了したあとに通知受付を戻す。
    /// begin と違い無条件でクリアする(フラグを下ろす操作を条件付きにすると、将来
    /// シャットダウンを中断する経路ができたときに reconcile が永久停止する罠になる)。
    public func endLayoutTransition() {
        isLayoutTransitioning = false
    }

    // MARK: - スナップバック

    /// AX の moved / resized 通知を受けたら呼ぶ。
    ///
    /// ドラッグ中は通知が ~100ms 間隔で来続けるため、静止するまで待ってから復元する(デバウンス)。
    /// 掴まれている最中に復元すると一時状態を「制約」と誤認して基準を壊すので、即時復元はしない。
    public func windowFrameDidChange(windowID: CGWindowID) {
        guard !isReleasingForShutdown, !isLayoutTransitioning else { return }
        guard let found = state.managedWindow(forWindowID: windowID) else { return }
        let managed = found.window
        // 退避操作そのものが通知を発火させる。退避中の通知は編集モードでも記録しない。
        guard !parkedWindowIDs.contains(managed.id), found.tab.id == state.activeTabID else { return }
        // 切断退避中はスナップバックも記録もしない(段階 D3)。編集モードの例外は設けない:
        // OS による移動(切断時の退避)とユーザーのドラッグは通知からは区別できず、遅延して届いた
        // OS 移動の通知 1 発で凍結 frame が上書きされてしまう。位置を変えたい場合は解除→再登録。
        guard !isDisplayDisconnected(managed) else { return }
        // フルスクリーン既知の窓も予約しない(進入直後で集合が未更新の場合は performRestore が
        // 同じバッチの読み直しで検出する。段階 2)。
        guard !fullscreenWindowIDs.contains(managed.id) else { return }
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
        guard !isReleasingForShutdown, !isLayoutTransitioning else { return }
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
        guard isLatest(id, generation), !isReleasingForShutdown, !isLayoutTransitioning else { return }
        if pendingRestores[id]?.generation == generation {
            pendingRestores[id] = nil
        }
        guard let found = state.managedWindow(id: id), let windowID = found.window.windowID,
            !parkedWindowIDs.contains(id), found.tab.id == state.activeTabID
        else { return }
        let driver = self.driver
        // 読み取り(IPC)はロックの外。相手アプリが遅くても他の操作を待たせない。
        // フルスクリーンも同じバッチで読む: 進入の resize 通知は次の reconcile より先に届くため、
        // ここで検出しないと「3 回試行 → フルスクリーン寸法を採用」の破壊が起きる(段階 2)。
        guard let probed = try? await executor.run({
            (frame: try driver.frame(of: windowID),
                fullscreen: (try? driver.isFullscreen(of: windowID)) ?? nil)  // nil = 判定不能
        }) else { return }
        let current = probed.frame
        guard isLatest(id, generation) else { return }  // IPC 中に新しい通知や setFrame が入った

        await serialized {
            // ロック待ちの間に切替・解除・新しい予約が走っていることがあるので前提を見直す。
            guard isLatest(id, generation), !isReleasingForShutdown, !isLayoutTransitioning,
                let found = state.managedWindow(id: id), found.window.windowID == windowID,
                !parkedWindowIDs.contains(id),
                found.tab.id == state.activeTabID
            else { return }
            if probed.fullscreen == true {
                if fullscreenWindowIDs.insert(id).inserted {
                    log("fullscreen: \(found.window.identity.appName) entered; suspending ops")
                }
                return  // 復元しない・採用しない(解除は reconcile が検出して自動復帰)
            }
            // 判定不能(nil)でメンバー中なら手を出さない(誤復元 → フルスクリーン寸法採用の破壊を防ぐ)。
            if probed.fullscreen == nil, fullscreenWindowIDs.contains(id) { return }
            let recorded = found.window.frame
            // 自分の reapply 等で既に記録値へ到達した通知は、編集モードでも所属変更として扱わない。
            if approximatelyEqual(current, recorded) { return }
            // 切断退避中は復元も記録もしない(段階 D3、windowFrameDidChange と同じ理由。
            // 予約後に切断された場合もここで止まる)。
            guard !isDisplayDisconnected(found.window) else { return }
            // 編集モードで記録するのは free のタブだけ。columns では列が唯一の正なので、
            // ドラッグは編集モードでも常にスナップバックさせる(記録すると列と記録がずれたまま残る)。
            if editMode, found.tab.layout == .free {
                await recordEditedFrame(id: id, windowID: windowID, current: current, attempt: attempt, generation: generation,
                    appName: found.window.identity.appName)
                return
            }
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
                    // 最終試行の IPC 中に fullscreen 化・画面切断・rebind が起きても、そこで
                    // 読み戻した座標を固定 frame として採用しない。
                    if await refreshFullscreenMembership(managedID: id, windowID: windowID) == true {
                        return
                    }
                    guard isLatest(id, generation), !isReleasingForShutdown, !isLayoutTransitioning,
                        let rebound = state.managedWindow(id: id), rebound.window.windowID == windowID,
                        rebound.tab.id == state.activeTabID, !parkedWindowIDs.contains(id),
                        !opsSuppressed(for: rebound.window)
                    else { return }
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
    /// 別ディスプレイに置かれた場合は所属もそのディスプレイへ更新する(段階 D)。
    private func recordEditedFrame(
        id: UUID, windowID: CGWindowID, current: CGRect, attempt: Int, generation: UInt64, appName: String
    ) async {
        let display = layout.display(containing: current) ?? layout.primaryDisplay
        let target = clamped(current, in: display?.contentArea ?? layout.contentArea)
        if approximatelyEqual(target, current) {
            updateFrame(id, current)
            updateDisplayID(id, display?.id)
            log("edit: recorded \(current) for \(appName)")
            return
        }
        let driver = self.driver
        do {
            let actual = try await executor.run { try driver.setFrame(target, of: windowID) }
            // clamp IPC 中に fullscreen 化・画面切断・rebind が起きた場合、その到達値と
            // 所属ディスプレイをユーザー編集として記録しない。
            if await refreshFullscreenMembership(managedID: id, windowID: windowID) == true {
                return
            }
            guard isLatest(id, generation), !isReleasingForShutdown, !isLayoutTransitioning,
                let rebound = state.managedWindow(id: id), rebound.window.windowID == windowID,
                rebound.tab.id == state.activeTabID, !parkedWindowIDs.contains(id),
                !opsSuppressed(for: rebound.window),
                display.map({ layout.display(id: $0.id) != nil }) ?? true
            else { return }
            updateFrame(id, actual)
            updateDisplayID(id, display?.id)
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
        guard !isReleasingForShutdown, !isLayoutTransitioning else { return }
        resolveVanished(livePIDs: livePIDs)
        if !liveWindowIDs.isEmpty {
            for window in state.allWindows {
                guard let windowID = window.windowID, !liveWindowIDs.contains(windowID) else { continue }
                if let livePIDs, let pid = window.pid {
                    if !livePIDs.contains(pid) {
                        unbindWindows(pid: pid)
                    } else if let found = state.managedWindow(id: window.id) {
                        // destroyed通知を取りこぼしても、通知経路と同じ猶予を通す。
                        // Chrome型の「窓を閉じてからprocess終了」で登録を誤削除しない。
                        markVanished(found)
                    }
                } else {
                    log("reconcile: window gone: \(window.identity.appName) / \(window.identity.title)")
                    removeFromState(window.id)
                }
            }
        }

        let observed = await observedStates()

        await serialized {
            // ロック待ちの間に終了処理が走っていれば、戻された窓を隅へ送り返さない。
            guard !isReleasingForShutdown, !isLayoutTransitioning else { return }
            // 同期削除経路(destroyed / vanish)で予約された列の再計算をここで 1 回だけ消化する。
            // 予約を先に空にしてから実行する(失敗しても次の構造イベントまで繰り返さない = 発振させない)。
            // 再タイルした窓は、ロック外で読んだ frames(再タイル前のスナップショット)との比較から外す
            // (外さないと動かした直後の窓すべてに無用の復元予約を出してしまう)。
            // フルスクリーン集合を一括読み取りの結果で更新する(op ループより先に。段階 2)。
            // 読めなかった窓は前回の判定を維持する(判断材料が無いのに解除すると op を出してしまう)。
            for (id, obs) in observed {
                // IPC 中に entry が unbind / rebind されていたら、旧実窓の結果を新しい binding へ
                // 適用しない。managed UUID だけでは実窓の世代を識別できない。
                guard state.managedWindow(id: id)?.window.windowID == obs.windowID else { continue }
                switch obs.isFullscreen {
                case true?:
                    if fullscreenWindowIDs.insert(id).inserted {
                        log("fullscreen: \(id) entered; suspending ops")
                    }
                case false?:
                    if fullscreenWindowIDs.remove(id) != nil {
                        log("fullscreen: \(id) exited; resuming management")
                    }
                case nil:
                    break  // 判定不能: 前回のメンバーシップを維持(誤って外すと復元リトライが破壊する)
                }
            }
            var retiledWindowIDs: Set<UUID> = []
            if !pendingRetileTabIDs.isEmpty {
                let tabIDs = pendingRetileTabIDs
                pendingRetileTabIDs.removeAll()
                for tabID in tabIDs {
                    if let tab = state.tabs.first(where: { $0.id == tabID }) {
                        retiledWindowIDs.formUnion(tab.windows.map(\.id))
                    }
                    await retileUnlocked(tabID)
                }
            }
            var ops: [WindowOp] = []
            for tab in state.tabs {
                let isActive = tab.id == state.activeTabID
                for window in tab.windows {
                    guard let windowID = window.windowID, let pid = window.pid else { continue }
                    // 切断退避(D3)・フルスクリーン(段階 2)は補正しない
                    // (park 再試行・ずれ検知・フラグ修復すべて対象外)。
                    guard !opsSuppressed(for: window) else { continue }
                    let flagged = parkedWindowIDs.contains(window.id)
                    let current = observed[window.id].flatMap { observation in
                        observation.windowID == windowID ? observation.frame : nil
                    }
                    if isActive, flagged {
                        // 復元に失敗したまま = 隅に残っているはずなので、復元をやり直す。
                        ops.append(WindowOp(managedID: window.id, windowID: windowID, pid: pid, kind: .restore(window.frame, raise: false)))
                    } else if isActive, let current, !approximatelyEqual(current, window.frame),
                        pendingRestores[window.id] == nil, !retiledWindowIDs.contains(window.id)
                    {
                        // 通知を取りこぼして固定 frame からずれている。ドラッグ中かもしれないので
                        // 即時には動かさず、通常のデバウンス復元(編集モードなら記録)に流す。
                        log("reconcile: \(window.identity.appName) drifted to \(current); scheduling restore")
                        scheduleRestore(window.id, attempt: 1)
                    } else if !isActive {
                        // y は OS にクランプされて窓の高さごとに変わる(実測 1067〜1087)ので判定に使わない。
                        // x = 計算済み退避点は通常のウィンドウ位置ではないので、x だけで「隅にいる」とみなす。
                        // 比較は必ずその窓のディスプレイの隅と行う(他画面の隅 x と比べると誤検知する。段階 D)。
                        let point = parkPoint(for: window)
                        if !flagged || (current.map { abs($0.minX - point.x) > 1 } ?? false) {
                            ops.append(WindowOp(managedID: window.id, windowID: windowID, pid: pid, kind: .park(point)))
                        }
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

    struct ObservedWindowState: Sendable {
        /// 観測した実ウィンドウ。managed ID が同じでも rebind 後なら結果を破棄するために保持する。
        let windowID: CGWindowID
        /// frame だけ読めない場合も fullscreen=true は利用し、危険な op を止める。
        let frame: CGRect?
        /// nil = 判定不能(前回のフルスクリーン判定を維持する)。
        let isFullscreen: Bool?
    }

    /// 紐付いている全窓の現在 frame とフルスクリーン状態を読む。読み取りは pid ごとに並列(ロックの外で呼ぶこと)。
    /// 読めない(消えた / 無応答)窓は含めない = 判断材料がないので触らない。
    /// フルスクリーンは同じバッチで読むので追加の往復は増えない(属性読み 1 回ぶんだけ)。
    private func observedStates() async -> [UUID: ObservedWindowState] {
        let candidates = state.allWindows.filter(\.isBound)
        guard !candidates.isEmpty else { return [:] }
        let driver = self.driver
        let executor = self.executor
        let groups = Dictionary(grouping: candidates, by: { $0.pid ?? 0 })
        return await withTaskGroup(of: [(UUID, ObservedWindowState)].self) { group in
            for (_, windows) in groups {
                group.addTask {
                    await executor.run {
                        windows.compactMap { window -> (UUID, ObservedWindowState)? in
                            guard let wid = window.windowID else { return nil }
                            let current = try? driver.frame(of: wid)
                            // nil(読めない)は nil のまま運ぶ(false に潰さない — 呼び手が前回判定を維持する)。
                            let fullscreen = (try? driver.isFullscreen(of: wid)) ?? nil
                            // 両方とも読めない窓は判断材料が無いので含めない。
                            guard current != nil || fullscreen != nil else { return nil }
                            return (window.id, ObservedWindowState(
                                windowID: wid, frame: current, isFullscreen: fullscreen))
                        }
                    }
                }
            }
            var all: [UUID: ObservedWindowState] = [:]
            for await pairs in group {
                for (id, observed) in pairs { all[id] = observed }
            }
            return all
        }
    }

    /// 観測結果が現在の binding のものなら集合へ反映し、反映後の既知状態を返す。
    /// nil は観測中に rebind されて結果を捨てた場合だけ。属性の読取り不能は前回状態を返す。
    @discardableResult
    private func applyFullscreenObservation(
        _ value: Bool?, managedID id: UUID, windowID: CGWindowID
    ) -> Bool? {
        guard let found = state.managedWindow(id: id), found.window.windowID == windowID else { return nil }
        switch value {
        case true?:
            if fullscreenWindowIDs.insert(id).inserted {
                log("fullscreen: \(found.window.identity.appName) entered; suspending ops")
            }
        case false?:
            if fullscreenWindowIDs.remove(id) != nil {
                log("fullscreen: \(found.window.identity.appName) exited; resuming management")
            }
        case nil:
            break
        }
        return fullscreenWindowIDs.contains(id)
    }

    private func refreshFullscreenMembership(managedID id: UUID, windowID: CGWindowID) async -> Bool? {
        let value = await probeFullscreen(windowID: windowID)
        return applyFullscreenObservation(value, managedID: id, windowID: windowID)
    }

    private func probeFullscreen(windowID: CGWindowID) async -> Bool? {
        let driver = self.driver
        do {
            return try await executor.run { try driver.isFullscreen(of: windowID) }
        } catch {
            return nil
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

    private struct ReleaseResult: Sendable {
        let result: OpResult
        let didPerform: Bool
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

    /// 終了期限内のbest-effort復元を守るため、同じpidでは窓ごとに
    /// fullscreen確認→MainActor上のbinding/D3再検証→restoreを続けて行う。
    /// 候補全件の確認完了を待ってから復元を始めず、pid間の並列性も維持する。
    private func runRelease(_ ops: [WindowOp]) async -> [ReleaseResult] {
        let groups = Dictionary(grouping: ops, by: \.pid)
        return await withTaskGroup(of: [ReleaseResult].self) { group in
            for (_, groupOps) in groups {
                group.addTask {
                    await self.performReleaseGroup(groupOps)
                }
            }
            var all: [ReleaseResult] = []
            for await results in group {
                all.append(contentsOf: results)
            }
            return all
        }
    }

    private func performReleaseGroup(_ ops: [WindowOp]) async -> [ReleaseResult] {
        var results: [ReleaseResult] = []
        for op in ops {
            let fullscreen = await probeFullscreen(windowID: op.windowID)
            guard let bound = state.managedWindow(id: op.managedID),
                bound.window.windowID == op.windowID
            else {
                results.append(skippedReleaseResult(for: op))
                continue
            }
            let isFullscreen = applyFullscreenObservation(
                fullscreen, managedID: op.managedID, windowID: op.windowID)
            // probeの待機中に切断された窓へ、新しいrestoreを発行しない(D3)。nil観測時は
            // applyFullscreenObservationが前回membershipを維持するため、既知fullscreenも触らない。
            guard !isDisplayDisconnected(bound.window), isFullscreen != true else {
                results.append(skippedReleaseResult(for: op))
                continue
            }
            let driver = self.driver
            let result = await executor.run { Self.perform(op, driver: driver) }
            results.append(ReleaseResult(result: result, didPerform: true))
        }
        return results
    }

    private func skippedReleaseResult(for op: WindowOp) -> ReleaseResult {
        ReleaseResult(
            result: OpResult(op: op, actual: nil, error: nil, note: nil),
            didPerform: false)
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
                // 読み戻し中にも destroyed / rebind は起こりうる。旧窓の到達判定を新しい
                // binding のフラグへ反映しない。
                guard let currentBinding = state.managedWindow(id: result.op.managedID),
                    currentBinding.window.windowID == windowID
                else { continue }
                if isDisplayDisconnected(currentBinding.window) {
                    parkedWindowIDs.remove(result.op.managedID)
                    continue
                }
                if await refreshFullscreenMembership(
                    managedID: result.op.managedID, windowID: windowID) == true
                {
                    parkedWindowIDs.remove(result.op.managedID)
                    continue
                }
                guard let rebound = state.managedWindow(id: result.op.managedID),
                    rebound.window.windowID == windowID
                else { continue }
                if isDisplayDisconnected(rebound.window) {
                    parkedWindowIDs.remove(result.op.managedID)
                    continue
                }
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
            guard let currentBinding = state.managedWindow(id: result.op.managedID),
                currentBinding.window.windowID == result.op.windowID
            else { continue }
            // IPC 中にディスプレイが切断された場合は D3 の凍結を優先し、park フラグも残さない。
            if isDisplayDisconnected(currentBinding.window) {
                parkedWindowIDs.remove(result.op.managedID)
                continue
            }
            // 既知の fullscreen へは結果を反映しない。restore の actual 差分は下で再確認する。
            if fullscreenWindowIDs.contains(result.op.managedID) {
                parkedWindowIDs.remove(result.op.managedID)
                continue
            }
            switch result.op.kind {
            case .park:
                parkedWindowIDs.insert(result.op.managedID)
                cancelPendingRestore(result.op.managedID)
            case .restore(let requested, _):
                parkedWindowIDs.remove(result.op.managedID)
                if let actual = result.actual, !approximatelyEqual(actual, requested),
                    let found = state.managedWindow(id: result.op.managedID),
                    !opsSuppressed(for: found.window)
                {
                    // reconcile の次回 tick 前に fullscreen へ入ると、setFrame は成功扱いのまま
                    // 飲み込まれて fullscreen 寸法を返す。差分採用の直前だけ再確認して保存値を守る。
                    if await refreshFullscreenMembership(
                        managedID: result.op.managedID, windowID: result.op.windowID) == true
                    {
                        continue
                    }
                    guard let rebound = state.managedWindow(id: result.op.managedID),
                        rebound.window.windowID == result.op.windowID,
                        !isDisplayDisconnected(rebound.window)
                    else { continue }
                    // 自分の操作なのでユーザー操作との競合はない。相手アプリの制約として到達 frame を採用する。
                    // op の IPC 中に切断/フルスクリーン化した場合だけは採用しない(凍結・論理配置の保険)。
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
        let currentTab = state.tab(withID: tab.id) ?? tab
        let isActive = currentTab.id == state.activeTabID
        let desired = desiredFrames(for: currentTab)
        var candidates: [(window: ManagedWindow, target: CGRect)] = []
        for snapshot in windows {
            cancelPendingRestore(snapshot.id)
            guard let found = state.managedWindow(id: snapshot.id) else { continue }
            let window = found.window
            // 切断退避中は frame を凍結して op も出さず、退避フラグだけ畳んで手放す(段階 D3)。
            // 実窓は macOS が置いた場所のまま。次回起動・再接続時の復元材料として記録座標を残す。
            if isDisplayDisconnected(window) {
                parkedWindowIDs.remove(window.id)
                continue
            }
            // 画面変更通知の 1 秒デバウンスより先に解除・終了されても、切断済み画面へ戻さない。
            let target = desired[window.id] ?? clamped(window.frame, for: window)
            let frameChanged = target != window.frame
            if frameChanged { updateFrame(window.id, target) }
            guard window.isBound, !isActive || parkedWindowIDs.contains(window.id) || frameChanged else { continue }
            candidates.append((window, target))
        }

        var ops: [WindowOp] = []
        for candidate in candidates {
            guard let found = state.managedWindow(id: candidate.window.id),
                found.window.windowID == candidate.window.windowID,
                let windowID = found.window.windowID, let pid = found.window.pid
            else { continue }
            if isDisplayDisconnected(found.window) {
                parkedWindowIDs.remove(found.window.id)
                continue
            }
            ops.append(WindowOp(
                managedID: found.window.id, windowID: windowID, pid: pid,
                kind: .restore(candidate.target, raise: false)))
        }
        guard !ops.isEmpty else { return [] }
        let driver = self.driver
        var unreleased = Set<UUID>()
        for releaseResult in await runRelease(ops) {
            let result = releaseResult.result
            // release 専用経路も通常の apply と同じく、実行中の destroyed / rebind を検証する。
            guard let bound = state.managedWindow(id: result.op.managedID),
                bound.window.windowID == result.op.windowID
            else { continue }
            // IPC 中に切断された場合は開始済み操作を取り消せなくても、到達値は保存しない。
            if isDisplayDisconnected(bound.window) {
                parkedWindowIDs.remove(result.op.managedID)
                continue
            }
            if !releaseResult.didPerform || fullscreenWindowIDs.contains(result.op.managedID) {
                parkedWindowIDs.remove(result.op.managedID)
                continue
            }
            if let error = result.error {
                // 適用後に throw した可能性があるので読み戻して確認する。到達していれば成功扱い。
                let recorded: CGRect? = { if case .restore(let f, _) = result.op.kind { return f } else { return nil } }()
                let windowID = result.op.windowID
                let current = try? await executor.run { try driver.frame(of: windowID) }
                guard let rebound = state.managedWindow(id: result.op.managedID),
                    rebound.window.windowID == windowID
                else { continue }
                if isDisplayDisconnected(rebound.window) {
                    parkedWindowIDs.remove(result.op.managedID)
                    continue
                }
                // 書込み失敗が実は fullscreen 進入だった場合も、解除失敗にはせず記録を維持する。
                if await refreshFullscreenMembership(
                    managedID: result.op.managedID, windowID: windowID) == true
                {
                    parkedWindowIDs.remove(result.op.managedID)
                    continue
                }
                guard let currentBound = state.managedWindow(id: result.op.managedID),
                    currentBound.window.windowID == windowID
                else { continue }
                if isDisplayDisconnected(currentBound.window) {
                    parkedWindowIDs.remove(result.op.managedID)
                    continue
                }
                if let recorded, let current, approximatelyEqual(current, recorded) {
                    log("release: \(result.op.managedID) reported \(error) but reached its frame")
                } else {
                    log("release: could not restore \(result.op.managedID): \(error)")
                    unreleased.insert(result.op.managedID)
                    continue
                }
            }
            // apply と同じ許容誤差ゲート: 誤差内の読み戻し値まで採用すると、終了のたびに
            // サブポイントのずれが記録に蓄積する。
            if let actual = result.actual, case .restore(let requested, _) = result.op.kind,
                !approximatelyEqual(actual, requested)
            {
                if await refreshFullscreenMembership(
                    managedID: result.op.managedID, windowID: result.op.windowID) == true
                {
                    parkedWindowIDs.remove(result.op.managedID)
                    continue
                }
                guard let rebound = state.managedWindow(id: result.op.managedID),
                    rebound.window.windowID == result.op.windowID,
                    !isDisplayDisconnected(rebound.window)
                else {
                    parkedWindowIDs.remove(result.op.managedID)
                    continue
                }
                updateFrame(result.op.managedID, actual)
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
    /// - Parameter parkPoint: 非アクティブタブへの登録時の退避先(その窓のディスプレイの隅)。
    private func place(windowID: CGWindowID, frame: CGRect, intoActive: Bool, parkPoint point: CGPoint) async throws -> PlacementOutcome {
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

    // MARK: - ディスプレイ(段階 D)

    /// 窓が属するディスプレイ。未記録(nil = v1 データ)や切断中は主ディスプレイに fallback する。
    /// 注意: 呼び手は先に isDisplayDisconnected を確認すること。ここでの主 fallback が正当なのは
    /// nil(= 主の意味)の場合だけで、切断中の窓に使うと「主の領域へ clamp」してしまう。
    private func display(for window: ManagedWindow) -> DisplayLayout? {
        layout.display(id: window.displayID) ?? layout.primaryDisplay
    }

    /// 窓のディスプレイが「記録されているのに現在接続されていない」か(v3 段階 D3 = 切断退避)。
    /// nil(v1 データ = 主ディスプレイの意味)は切断扱いにしない。
    ///
    /// 切断中の窓は記録 frame / displayID を**凍結**し、**op を一切発行しない**(park / restore /
    /// retile / snapback すべて)。op を出すと macOS が生きている画面へ clamp した結果を
    /// 採用経路(apply / releaseAll / performRestore)が記録へ書き戻してしまうため、
    /// clamp の抑止だけでは足りない。実窓は macOS が置いた場所に放置し、bind・生存管理・focus 追跡は
    /// 続ける。再接続後は displays が毎回再計算されるため、次の reapplyLayout の通常経路が
    /// 記録 frame へ復元する(ディスプレイ集合の差分検知は不要)。
    /// 編集モードでも例外は設けない(OS 移動とユーザードラッグを通知から区別できないため)。
    /// 切断中の窓を別の場所で管理し直したい場合は、解除して登録し直す。
    private func isDisplayDisconnected(_ window: ManagedWindow) -> Bool {
        guard let id = window.displayID else { return false }
        return layout.display(id: id) == nil
    }

    /// この窓への op 発行(park / restore / retile)を止めるべきか。
    /// 切断退避(D3)とフルスクリーン(段階 2)の共通ゲート。記録 frame の凍結有無は別
    /// (切断中は凍結、フルスクリーン中は更新を続ける)なので、呼び手が使い分ける。
    private func opsSuppressed(for window: ManagedWindow) -> Bool {
        isDisplayDisconnected(window) || fullscreenWindowIDs.contains(window.id)
    }

    /// 窓の所属ディスプレイ用に計算済みの安全な退避先。通常は同じ画面の右下隅だが、
    /// その隅が配置の内側なら外縁ディスプレイへ fallback する。
    private func parkPoint(for window: ManagedWindow) -> CGPoint {
        display(for: window)?.parkPoint ?? layout.parkPoint
    }

    private func updateDisplayID(_ id: UUID, _ displayID: DisplayID?) {
        updateManagedWindow(id) { $0.displayID = displayID }
    }

    // MARK: - タイルレイアウト(段階 C)

    /// アクティブ化・再適用時の「あるべき frame」。free は clamped(記録 frame)、columns は等幅カラム。
    /// columns はディスプレイごとにグループ化して、それぞれのコンテンツ領域内で等分する(段階 D)。
    /// columns では未復元(unbound)の窓は列数に入らず、エントリも返らない(呼び手が記録 frame に fallback)。
    private func desiredFrames(for tab: Tab) -> [UUID: CGRect] {
        // 切断退避中の窓は対象外(frame 凍結、columns では列数にも入れない)。エントリを返さないだけでなく、
        // 呼び手側も fallback の clamp を踏まないよう isDisplayDisconnected でスキップすること。
        let windows = tab.windows.filter { !isDisplayDisconnected($0) }
        switch tab.layout {
        case .free:
            // 壊れた state.json で UUID が重複していてもクラッシュさせない(先勝ち)。
            return Dictionary(
                windows.map { ($0.id, clamped($0.frame, for: $0)) },
                uniquingKeysWith: { first, _ in first })
        case .columns:
            var frames: [UUID: CGRect] = [:]
            // Dictionary(grouping:) はグループ内の順序を保つので、列順 = 一覧順が画面ごとに維持される。
            let groups = Dictionary(grouping: windows) { display(for: $0)?.id ?? "" }
            for (_, windows) in groups {
                guard let area = windows.first.flatMap({ display(for: $0)?.contentArea }) else { continue }
                frames.merge(Tiler.columnFrames(for: windows, in: area)) { current, _ in current }
            }
            return frames
        }
    }

    /// columns タブの列を計算し直して記録し、アクティブタブなら実窓にも適用する。冪等。
    /// 登録・解除・bind・レイアウト変更などの構造イベントからだけ呼ぶ(定常の reconcile からは呼ばない。
    /// 呼ぶと最小サイズ制約のあるアプリで発振する — pendingRetileTabIDs のコメント参照)。
    private func retileUnlocked(_ tabID: UUID) async {
        pendingRetileTabIDs.remove(tabID)  // 直接消化した予約は reconcile に残さない
        guard let index = state.tabs.firstIndex(where: { $0.id == tabID }),
            state.tabs[index].layout == .columns
        else { return }
        let tab = state.tabs[index]
        let desired = desiredFrames(for: tab)
        guard !desired.isEmpty else { return }
        let isActive = tab.id == state.activeTabID
        var ops: [WindowOp] = []
        for window in tab.windows {
            guard let target = desired[window.id] else { continue }  // unbound / 切断退避は列に入らない
            if target != window.frame { updateFrame(window.id, target) }
            guard isActive, let windowID = window.windowID, let pid = window.pid,
                !parkedWindowIDs.contains(window.id),
                !fullscreenWindowIDs.contains(window.id)  // 列 slot は保持、op だけ出さない(段階 2)
            else { continue }
            cancelPendingRestore(window.id)
            ops.append(WindowOp(managedID: window.id, windowID: windowID, pid: pid, kind: .restore(target, raise: false)))
        }
        guard !ops.isEmpty else { return }
        let failures = await apply(await run(ops))
        log("retile: \(tab.name): \(ops.count) op(s)" +
            (failures.isEmpty ? "" : "; failures: \(failures.map(\.message))"))
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
        clearRuntimeTracking(for: id)
        for index in state.tabs.indices {
            let before = state.tabs[index].windows.count
            state.tabs[index].windows.removeAll { $0.id == id }
            // 同期経路(destroyed / vanish)からは retile の IPC を挟めないので予約だけ立てる。
            // unregister のような直列区間内の呼び手は、この直後に直接 retileUnlocked して予約を消化する。
            if state.tabs[index].windows.count != before, state.tabs[index].layout == .columns {
                pendingRetileTabIDs.insert(state.tabs[index].id)
            }
            if state.tabs[index].lastFocusedWindowID == id {
                state.tabs[index].lastFocusedWindowID = nil
            }
        }
    }

    /// 実ウィンドウとの binding にだけ属する状態をまとめて破棄する。
    /// cancel で飛行中 Task の世代を無効化してからキー自体も剪定する。
    private func clearRuntimeTracking(for id: UUID) {
        cancelPendingRestore(id)
        restoreGeneration.removeValue(forKey: id)  // キー欠損なら飛行中 Task の isLatest は false
        parkedWindowIDs.remove(id)
        fullscreenWindowIDs.remove(id)
        vanished.removeValue(forKey: id)
    }

    private func updateFrame(_ id: UUID, _ frame: CGRect) {
        updateManagedWindow(id) { $0.frame = frame }
    }

    /// `WorkspaceState` は値型なので、管理ウィンドウの検索と in-place 更新をここに集約する。
    /// 同じ二重ループを各更新経路に持たせず、常に最初に見つかったエントリを更新する。
    private struct WindowLocation {
        let tabIndex: Int
        let windowIndex: Int
    }

    private func windowLocation(of id: UUID) -> WindowLocation? {
        for tabIndex in state.tabs.indices {
            if let windowIndex = state.tabs[tabIndex].windows.firstIndex(where: { $0.id == id }) {
                return WindowLocation(tabIndex: tabIndex, windowIndex: windowIndex)
            }
        }
        return nil
    }

    @discardableResult
    private func updateManagedWindow(_ id: UUID, _ update: (inout ManagedWindow) -> Void) -> Bool {
        guard let location = windowLocation(of: id) else { return false }
        update(&state.tabs[location.tabIndex].windows[location.windowIndex])
        return true
    }

    private func cancelPendingRestore(_ id: UUID) {
        pendingRestores[id]?.task.cancel()
        pendingRestores[id] = nil
        // IPC 中で止められない Task が戻ってきても古い値を書かないよう、世代を進めて無効化する。
        _ = nextGeneration(for: id)
    }

    /// sleep 中だけでなく既に IPC 中の restore も世代で無効化する。
    private func cancelAllRestores() {
        let ids = Set(pendingRestores.keys).union(restoreGeneration.keys)
        for id in ids { cancelPendingRestore(id) }
    }

    private func rejectIfShuttingDown() throws {
        if isReleasingForShutdown { throw EngineError.shuttingDown }
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
    /// 主ディスプレイの領域に収める v1 互換版。窓ごとの判定は clamped(_:for:) を使う。
    private func clamped(_ frame: CGRect) -> CGRect {
        clamped(frame, in: layout.contentArea)
    }

    /// 窓が属するディスプレイのコンテンツ領域に収める(段階 D)。ディスプレイ切断中は主ディスプレイへ。
    private func clamped(_ frame: CGRect, for window: ManagedWindow) -> CGRect {
        clamped(frame, in: display(for: window)?.contentArea ?? layout.contentArea)
    }

    private func clamped(_ frame: CGRect, in area: CGRect) -> CGRect {
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
