import AppKit
import ApplicationServices
import AXShim
import TabDeskCore

/// エンジンと macOS(AX 通知・NSWorkspace・ポーリング)をつなぐアプリ層のサービス。
///
/// エンジンは AX を知らないので、ここで AXWindow を預け、通知をエンジンのメソッド呼び出しに翻訳する。
@MainActor
final class WindowManager {
    static let sidebarWidth: CGFloat = 240
    static let reconcileInterval: TimeInterval = 2

    let engine: TabEngine
    let layout = SystemScreenLayout(sidebarWidth: WindowManager.sidebarWidth)
    let store: StateStore
    /// Cmd-Tab 等で非アクティブタブの窓にフォーカスが移ったら、そのタブへ自動で切り替える(§3.6)。
    let focusFollows = PersistedToggle(key: "FocusFollowsWindow", defaultValue: true)
    /// true を返す間は切替後のアプリ前面化を行わない(サイドバーで改名中など)。
    var suppressAppActivation: (@MainActor () -> Bool)?
    /// UI 向けの状態変更通知(エンジンの onStateChanged はここが占有し、保存とあわせて配る)。
    var onStateChanged: (@MainActor (WorkspaceState) -> Void)?
    private let driver = AXWindowDriver()
    private let logger: FileLogger
    private var saveTask: Task<Void, Never>?
    private var saveRetryAttempt = 0
    private var stateIsDirty = false
    private var stateWritesEnabled = true
    private var restoreTask: Task<Void, Never>?
    /// 復元Task中に現れた窓の一度きりの appeared イベントを、Task完了後まで保持する。
    private var strictRestorePending = false
    private var reconcileTask: Task<Void, Never>?
    private var layoutReapplyTask: Task<Void, Never>?
    private(set) var isTerminating = false
    private var initialRestoreDone = false
    private var lastExistingIDs: Set<CGWindowID> = []
    private var observers: [pid_t: AppWindowObserver] = [:]
    /// destroyed 通知は壊れた要素で届くので ID を引けない。登録時の要素を覚えておき CFEqual で突き合わせる。
    private var elements: [CGWindowID: (pid: pid_t, element: AXUIElement)] = [:]
    private var reconcileTimer: Timer?
    private var mouseUpMonitor: Any?
    private let executor = BlockingExecutor()
    /// フォーカス通知は最後に届いたものだけを処理する。切替中の通知も捨てず、完了後に再検証する。
    private var focusFollowTask: Task<Void, Never>?
    private var pendingFocusedWindowID: CGWindowID?
    private var focusGeneration: UInt64 = 0
    private var focusSwitchDepth = 0
    /// focused-window 通知を購読できないアプリは、前面にいる間だけ reconcile で補完する。
    private var focusPollingPIDs: Set<pid_t> = []
    /// engine.register / engine.bind の await 中の窓(windowID → pid)。二重登録を入口で弾くのに加え、
    /// elements は commit 後にしか入らないため、その pid の observer を途中で捨てないための印でもある。
    private var inFlight: [CGWindowID: pid_t] = [:]

    private func observerIsUnused(pid: pid_t) -> Bool {
        !elements.values.contains(where: { $0.pid == pid }) && !inFlight.values.contains(pid)
    }

    enum RegistrationError: Error, CustomStringConvertible {
        case alreadyInProgress(CGWindowID)
        /// 移動・リサイズ通知(位置固定の要)を購読できないアプリ。登録は行わない(半端な登録を残さない)。
        case observerUnavailable(pid: pid_t, underlying: String)
        /// フルスクリーン/最小化中の窓(列挙後にメニューが古くなっていた場合の直前再チェック)。
        case notRegistrable(reason: String)

        var description: String {
            switch self {
            case .alreadyInProgress(let id): return "window \(id) is already being registered"
            case .observerUnavailable(let pid, let underlying): return "cannot observe pid \(pid): \(underlying)"
            case .notRegistrable(let reason): return "window is not registrable: \(reason)"
            }
        }
    }

    init(logger: FileLogger, store: StateStore = StateStore(fileURL: StateStore.defaultURL(appName: "TabDesk"))) {
        self.logger = logger
        self.store = store
        var initial = WorkspaceState()
        do {
            if let loaded = try store.load() {
                initial = loaded
                logger.log("state loaded: \(loaded.tabs.count) tab(s), \(loaded.allWindows.count) window(s) from \(store.fileURL.path)")
            }
        } catch {
            // 読めないファイルは退避して初期状態から始める(履歴は .bak.json に残る)。
            logger.log("state load failed: \(error); backing up and starting fresh")
            do {
                try store.backupCorruptFile()
            } catch {
                // 壊れた原本を退避できないまま上書きすると、復旧材料まで失う。
                stateWritesEnabled = false
                logger.log("state backup failed: \(error); automatic writes disabled to preserve the original file")
            }
        }
        engine = TabEngine(driver: driver, layout: layout, initialState: initial)
        engine.log = { logger.log($0) }
        engine.onStateChanged = { [weak self] state in
            self?.scheduleSave()
            self?.onStateChanged?(state)
        }
        engine.activateApplication = { [weak self] pid in
            if self?.suppressAppActivation?() == true { return }
            NSRunningApplication(processIdentifier: pid)?.activate()
        }

        reconcileTimer = Timer.scheduledTimer(withTimeInterval: Self.reconcileInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileTick() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        // ドラッグ終了(マウスアップ)を全アプリで拾い、デバウンスを待たずに復元する。
        // グローバル監視は Accessibility 権限があれば使える。
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.flushPendingRestores() }
        }
        // ディスプレイ構成の変更・スリープ/ロック解除では窓が OS に動かされることがあるので配置を再適用する。
        NotificationCenter.default.addObserver(
            self, selector: #selector(layoutMayHaveChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(layoutMayHaveChanged(_:)),
            name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(layoutMayHaveChanged(_:)),
            name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(layoutMayHaveChanged(_:)),
            name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        lastExistingIDs = WindowEnumerator.existingWindowIDs()
        if isTrusted {
            startInitialRestoreIfNeeded()
        }
    }

    // MARK: - 永続化

    /// 変更が連続しても 0.5 秒にまとめて書く。
    private func scheduleSave() {
        stateIsDirty = true
        saveRetryAttempt = 0
        guard stateWritesEnabled, !isTerminating else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            _ = self.saveNow()
        }
    }

    /// 現在状態を保存する。失敗時は通常運転中に限り、短い指数バックオフで最大 3 回再試行する。
    @discardableResult
    func saveNow(scheduleRetry: Bool = true) -> Bool {
        saveTask?.cancel()
        saveTask = nil
        guard stateWritesEnabled else {
            logger.log("save skipped: state writes are disabled because the corrupt original could not be backed up")
            return false
        }
        do {
            try store.save(engine.state)
            stateIsDirty = false
            saveRetryAttempt = 0
            return true
        } catch {
            stateIsDirty = true
            logger.log("save failed: \(error)")
            if scheduleRetry, !isTerminating, saveRetryAttempt < 3 {
                saveRetryAttempt += 1
                let attempt = saveRetryAttempt
                let delay = Duration.seconds(1 << (attempt - 1))
                logger.log("save: retry \(attempt)/3 scheduled")
                saveTask = Task { [weak self] in
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled, let self, self.stateIsDirty, !self.isTerminating else { return }
                    self.saveTask = nil
                    _ = self.saveNow()
                }
            }
            return false
        }
    }

    // MARK: - 復元(未復元エントリへの紐付け)

    /// 起動直後は AX / 対象アプリがまだ準備中のことがあるため、未復元が残る間だけ 3 回まで試す。
    private func startInitialRestoreIfNeeded() {
        guard !initialRestoreDone, !isTerminating, restoreTask == nil else { return }
        restoreTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.restoreTask = nil
                self.startStrictRestoreIfNeeded()
            }
            for attempt in 1...3 {
                if attempt > 1 {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                }
                guard !Task.isCancelled, !self.isTerminating else { return }
                let remaining = await self.restoreUnboundWindows(strictness: .lenient)
                guard remaining > 0 else { break }
                self.logger.log("initial restore: \(remaining) window(s) still unbound after attempt \(attempt)/3")
            }
            guard !Task.isCancelled, !self.isTerminating else { return }
            self.initialRestoreDone = true
        }
    }

    /// 稼働中に新しい窓が現れたときの厳格照合。瞬間的な AX 失敗だけを救うため 2 回までに留める。
    private func startStrictRestoreIfNeeded() {
        guard initialRestoreDone, strictRestorePending, !isTerminating, restoreTask == nil else { return }
        strictRestorePending = false
        guard engine.state.allWindows.contains(where: { !$0.isBound }) else { return }
        restoreTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.restoreTask = nil
                // このTaskの列挙中に別の窓が現れたなら、そのイベントを捨てずもう一巡する。
                self.startStrictRestoreIfNeeded()
            }
            for attempt in 1...2 {
                if attempt > 1 {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                }
                guard !Task.isCancelled, !self.isTerminating else { return }
                let remaining = await self.restoreUnboundWindows(strictness: .strict)
                guard remaining > 0 else { break }
            }
        }
    }

    /// 未復元エントリに今ある窓を紐付ける。起動直後は緩め、稼働中は厳しめに照合する。
    @discardableResult
    func restoreUnboundWindows(strictness: WindowMatcher.Strictness) async -> Int {
        guard !isTerminating, !Task.isCancelled else { return engine.state.allWindows.filter { !$0.isBound }.count }
        let unbound = engine.state.allWindows.filter { !$0.isBound }
        guard !unbound.isEmpty else { return 0 }
        let records = await availableWindows()
        guard !isTerminating, !Task.isCancelled else { return engine.state.allWindows.filter { !$0.isBound }.count }
        let candidates = records.map {
            WindowMatcher.Candidate(
                windowID: $0.window.windowID, pid: $0.window.pid, bundleID: $0.bundleID, title: $0.title,
                size: $0.frame?.size ?? .zero)
        }
        let matches = WindowMatcher.match(unbound: unbound, candidates: candidates, strictness: strictness)
        var boundCount = 0
        for match in matches {
            guard !isTerminating, !Task.isCancelled else { break }
            guard let record = records.first(where: { $0.window.windowID == match.candidate.windowID }),
                engine.state.managedWindow(id: match.managedID)?.window.isBound == false  // 列挙中に別経路が紐付けたら飛ばす
            else { continue }
            if await bind(record, to: match.managedID) { boundCount += 1 }
        }
        let remaining = engine.state.allWindows.filter { !$0.isBound }.count
        logger.log("restore(\(strictness)): bound \(boundCount) of \(unbound.count) unbound window(s); \(remaining) remaining")
        return remaining
    }

    /// 手動割り当て・自動復元の共通経路。
    @discardableResult
    func bind(_ record: WindowRecord, to managedID: UUID) async -> Bool {
        guard !isTerminating else { return false }
        let windowID = record.window.windowID
        guard inFlight[windowID] == nil else { return false }
        inFlight[windowID] = record.window.pid
        defer {
            // observer の不要判定より先に in-flight 印を外す。逆順だと新規 observer が永遠に残る。
            inFlight.removeValue(forKey: windowID)
            if engine.state.managedWindow(forWindowID: windowID) == nil {
                driver.forget(windowID)
                dropObserverIfUnused(pid: record.window.pid)
            }
        }
        // 割り当て先が(自動復元との競合などで)既に紐付いていたら何もしない(bind は上書きを拒否する)。
        guard engine.state.managedWindow(id: managedID)?.window.isBound == false else { return false }
        do {
            _ = try establishObserver(pid: record.window.pid)
        } catch {
            logger.log("bind skipped (no observer): \(error)")  // 次の自動復元で再試行される
            return false
        }
        guard !isTerminating else { return false }
        driver.adopt(record.window)
        do {
            let oldIdentity = engine.state.managedWindow(id: managedID)?.window.identity
            let identity = WindowIdentity(
                bundleID: record.bundleID,
                appName: record.appName,
                title: record.title,
                registeredSize: record.frame?.size ?? oldIdentity?.registeredSize ?? .zero)
            try await engine.bind(
                managedID, windowID: windowID, pid: record.window.pid, identity: identity)
            guard !isTerminating,
                engine.state.managedWindow(id: managedID)?.window.windowID == windowID
            else { return false }
            elements[windowID] = (record.window.pid, record.window.element)
            watchDestroyed(of: record.window)
            return true
        } catch {
            logger.log("bind failed: \(error)")
            return false
        }
    }

    // MARK: - 権限

    var isTrusted: Bool { AXIsProcessTrusted() }

    func requestPermission() {
        // kAXTrustedCheckOptionPrompt は Swift 6 ではグローバル var として参照できないため文字列キーを直接使う。
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        logger.log("requestPermission: trusted=\(AXIsProcessTrustedWithOptions(options))")
    }

    /// 診断用: 実ウィンドウの現在 frame(AX 座標)。
    func currentFrame(of windowID: CGWindowID) throws -> CGRect {
        try driver.frame(of: windowID)
    }

    // MARK: - タブ切替とフォーカス連動

    /// タブ切替の入口。切替中に届いたフォーカス通知は保留し、完了後に実際のフォーカスと照合する。
    func activate(_ tabID: UUID) async throws {
        guard !isTerminating else { throw TabEngine.EngineError.shuttingDown }
        focusSwitchDepth += 1
        defer {
            focusSwitchDepth -= 1
            if focusSwitchDepth == 0 { schedulePendingFocusFollow() }
        }
        try await engine.activate(tabID)
    }

    /// 隣のタブへ(ホットキー用)。ターゲット解決はエンジンの直列区間内で行うため、連打しても 1 押下 = 1 タブ進む。
    func activateAdjacent(offset: Int) async throws {
        guard !isTerminating else { throw TabEngine.EngineError.shuttingDown }
        focusSwitchDepth += 1
        defer {
            focusSwitchDepth -= 1
            if focusSwitchDepth == 0 { schedulePendingFocusFollow() }
        }
        try await engine.activateAdjacent(offset: offset)
    }

    /// 非アクティブタブの窓にフォーカスが移ったら、そのタブへ切り替える。
    private func maybeFollowFocus(windowID: CGWindowID) {
        guard !isTerminating else { return }
        focusGeneration &+= 1
        pendingFocusedWindowID = windowID
        schedulePendingFocusFollow()
    }

    private func schedulePendingFocusFollow() {
        guard focusSwitchDepth == 0, let windowID = pendingFocusedWindowID, !isTerminating else { return }
        focusFollowTask?.cancel()
        let generation = focusGeneration
        focusFollowTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            await self.performFocusFollow(windowID: windowID, generation: generation)
        }
    }

    private func performFocusFollow(windowID: CGWindowID, generation: UInt64) async {
        // ユーザー起点の切替が進行中に割り込まれた場合は、通知を捨てずに保留へ残し、
        // activate() 完了後の schedulePendingFocusFollow に再検証を委ねる。
        var deferToPostSwitch = false
        defer {
            if focusGeneration == generation, !deferToPostSwitch {
                pendingFocusedWindowID = nil
                focusFollowTask = nil
            }
        }
        guard focusGeneration == generation, focusFollows.value, !isTerminating,
            let found = engine.state.managedWindow(forWindowID: windowID),
            found.window.isBound, found.tab.id != engine.state.activeTabID,
            let pid = found.window.pid,
            NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        else { return }
        guard focusSwitchDepth == 0 else {
            deferToPostSwitch = true
            focusFollowTask = nil
            return
        }

        // 遅れて届いた通知で古いタブへ戻らないよう、実際の最新フォーカスを AX で再確認する。
        guard await focusedWindowID(pid: pid) == windowID,
            focusGeneration == generation, focusFollows.value, !isTerminating,
            NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
            let current = engine.state.managedWindow(forWindowID: windowID),
            current.tab.id != engine.state.activeTabID
        else { return }
        // AX 再確認の await 中にユーザーの切替が始まっていたら、それを上書きせず保留に回す。
        guard focusSwitchDepth == 0 else {
            deferToPostSwitch = true
            focusFollowTask = nil
            return
        }
        logger.log("focus-follow: switching to \(current.tab.name)")
        do {
            try await activate(current.tab.id)
        } catch {
            logger.log("focus-follow activate failed: \(error)")
        }
    }

    /// 相手アプリへの同期 AX IPC は MainActor 外で行う。
    private func focusedWindowID(pid: pid_t) async -> CGWindowID? {
        await executor.run {
            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appElement, 0.5)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                appElement, kAXFocusedWindowAttribute as CFString, &value) == .success,
                let value, CFGetTypeID(value) == AXUIElementGetTypeID()
            else { return nil }
            let element = unsafeDowncast(value, to: AXUIElement.self)
            var windowID: CGWindowID = 0
            guard AXShimGetWindowID(element, &windowID) == .success else { return nil }
            return windowID
        }
    }

    private func recordFocusedWindow(_ windowID: CGWindowID) {
        engine.noteWindowFocused(windowID: windowID)
        maybeFollowFocus(windowID: windowID)
    }

    /// ホットキーから: いまフォーカスしている他アプリの窓をアクティブタブに登録する。
    func registerFocusedWindow() async {
        guard !isTerminating else { return }
        guard let tabID = engine.state.activeTabID else {
            logger.log("register-focused: no active tab")
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication, app != NSRunningApplication.current else {
            logger.log("register-focused: no frontmost app")
            return
        }
        let pid = app.processIdentifier
        let appName = app.localizedName ?? "pid \(pid)"
        let bundleID = app.bundleIdentifier ?? ""
        // フォーカス窓の特定と属性読取はすべて相手アプリへの IPC なのでバックグラウンドで行う。
        let record: WindowRecord? = await executor.run {
            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appElement, 1.0)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value) == .success,
                let value, CFGetTypeID(value) == AXUIElementGetTypeID()
            else { return nil }
            let element = unsafeDowncast(value, to: AXUIElement.self)
            AXUIElementSetMessagingTimeout(element, 1.0)
            guard let window = try? AXWindow(element: element, pid: pid), window.isStandard,
                !window.isFullscreen, !window.isMinimized
            else { return nil }
            return WindowRecord(
                window: window,
                appName: appName,
                bundleID: bundleID,
                title: window.title,
                frame: try? window.frame(),
                isMinimized: window.isMinimized,
                fullscreenRaw: window.fullscreenRaw)
        }
        guard !isTerminating, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
        guard let record else {
            logger.log("register-focused: no registrable focused window in \(appName) (standard かつ非フルスクリーン・非最小化が対象)")
            return
        }
        guard engine.state.managedWindow(forWindowID: record.window.windowID) == nil else {
            logger.log("register-focused: window \(record.window.windowID) is already registered")
            return
        }
        do {
            try await register(record, into: tabID)
            logger.log("register-focused: \(record.appName) — \(record.title)")
        } catch {
            logger.log("register-focused failed: \(error)")
        }
    }

    // MARK: - 登録候補

    /// 登録できる標準ウィンドウ(自分自身と登録済みを除く)と、AX を拒否した管理不可アプリの一覧。
    /// 全アプリへの AX IPC を伴うのでバックグラウンドで pid 並列に行い、MainActor は待つだけにする。
    func availableWindowsAndIssues() async -> (records: [WindowRecord], unavailableApps: [String]) {
        let (records, stats) = await WindowEnumerator.standardWindowsAsync()
        if !stats.appFailureDetails.isEmpty {
            logger.log("enumerate: unavailable apps: \(stats.appFailureDetails)")
        }
        // 除外は必ずログに残す(AXFullScreen の実測と、誤検知で普通の窓が消えた場合の発見手段)。
        if !stats.exclusionDetails.isEmpty {
            logger.log("enumerate: excluded: \(stats.exclusionDetails)")
        }
        // await の間に登録が進んでいることがあるので、除外判定は列挙後の状態で行う。
        let registered = Set(engine.state.allWindows.compactMap(\.windowID))
        return (records.filter { !registered.contains($0.window.windowID) }, stats.appFailureDetails)
    }

    func availableWindows() async -> [WindowRecord] {
        await availableWindowsAndIssues().records
    }

    /// タブのレイアウト(自由配置 / 縦の等幅カラム)を変更する。
    func setTabLayout(_ tabID: UUID, _ layout: TabLayout) async throws {
        guard !isTerminating else { throw TabEngine.EngineError.shuttingDown }
        try await engine.setTabLayout(tabID, layout)
    }

    /// タブ内のウィンドウを並べ替える(columns の列順)。
    func moveWindow(_ id: UUID, offset: Int) async throws {
        guard !isTerminating else { throw TabEngine.EngineError.shuttingDown }
        try await engine.moveWindow(id, offset: offset)
    }

    /// タブを削除する。Core の削除が成功したときだけ、その窓の AX 資源(driver / 要素 / observer)を片付ける。
    /// 復元できない窓があって Core が throw した場合は何も片付けない(登録も資源も保持される)。
    func deleteTab(_ id: UUID) async throws {
        guard !isTerminating else { throw TabEngine.EngineError.shuttingDown }
        // 削除対象は engine の直列化区間で確定した値を使い、並行 bind の AX 資源を取りこぼさない。
        let windowIDs = try await engine.deleteTab(id)
        for windowID in windowIDs {
            forgetWindow(windowID)
        }
    }

    // MARK: - 登録 / 解除

    /// ウィンドウをタブに登録する。主ディスプレイのコンテンツ領域に収まっていなければ引き込む。
    func register(_ record: WindowRecord, into tabID: UUID) async throws {
        guard !isTerminating else { throw TabEngine.EngineError.shuttingDown }
        let area = layout.contentArea
        let window = record.window
        // メニュー表示中に状態が変わりうるので、frame と一緒にフルスクリーン/最小化も登録直前に読み直す。
        let (current, fullscreen, minimized) = try await executor.run {
            (try window.frame(), window.isFullscreen, window.isMinimized)
        }
        guard !isTerminating else { throw TabEngine.EngineError.shuttingDown }
        guard !fullscreen, !minimized else {
            throw RegistrationError.notRegistrable(reason: fullscreen ? "fullscreen" : "minimized")
        }
        let frame: CGRect
        if area.contains(current) {
            frame = current
        } else {
            frame = CGRect(
                origin: area.origin,
                size: CGSize(width: min(current.width, area.width), height: min(current.height, area.height)))
        }
        let windowID = record.window.windowID
        guard inFlight[windowID] == nil else { throw RegistrationError.alreadyInProgress(windowID) }
        inFlight[windowID] = record.window.pid
        defer {
            inFlight.removeValue(forKey: windowID)
            if engine.state.managedWindow(forWindowID: windowID) == nil {
                driver.forget(windowID)
                dropObserverIfUnused(pid: record.window.pid)
            }
        }

        // 必須 observer(moved / resized)は窓に触れる前に確立する。取れないアプリは登録しない。
        _ = try establishObserver(pid: record.window.pid)
        driver.adopt(record.window)
        let identity = WindowIdentity(
            bundleID: record.bundleID, appName: record.appName, title: record.title, registeredSize: current.size)
        let managed = try await engine.register(
            windowID: windowID, pid: record.window.pid, identity: identity, frame: frame, into: tabID)
        guard !isTerminating else { throw TabEngine.EngineError.shuttingDown }
        guard engine.state.managedWindow(id: managed.id)?.window.windowID == windowID else {
            throw TabEngine.EngineError.unknownWindow(managed.id)
        }
        elements[windowID] = (record.window.pid, record.window.element)
        watchDestroyed(of: record.window)
    }

    func unregister(_ id: UUID) async throws {
        guard !isTerminating else { throw TabEngine.EngineError.shuttingDown }
        if let windowID = try await engine.unregister(id) {
            forgetWindow(windowID)
        }
    }

    /// 終了要求を受けた同期地点で barrier を立てる。cleanup Task の開始を待たない。
    func beginTermination() {
        guard !isTerminating else { return }
        isTerminating = true
        engine.beginShutdown()
        reconcileTimer?.invalidate()
        reconcileTimer = nil
        reconcileTask?.cancel()
        layoutReapplyTask?.cancel()
        restoreTask?.cancel()
        focusFollowTask?.cancel()
        focusGeneration &+= 1
        pendingFocusedWindowID = nil
        // 全窓解放が遅くても、最新の登録情報だけは期限前に保存しておく。
        _ = saveNow(scheduleRetry: false)
    }

    /// TabDesk 終了前のクリーンアップ。退避中の窓を元の位置に戻す。
    func prepareForTermination() async {
        beginTermination()
        await engine.releaseAllParkedWindows()
        let saved = saveNow(scheduleRetry: false)
        // Core が窓ごとの復元失敗を個別に記録するため、ここでは成功を断定しない。
        logger.log("terminating: parked-window release attempted; state \(saved ? "saved" : "save failed")")
    }

    // MARK: - AX 通知

    /// pid の observer を確立する(既にあれば再利用)。戻り値は「この呼び出しで新規作成したか」。
    /// moved / resized は必須(位置固定の要)、focused は任意。
    private func establishObserver(pid: pid_t) throws -> Bool {
        if observers[pid] != nil { return false }
        do {
            let observer = try AppWindowObserver(
                pid: pid,
                requiredNotifications: [kAXWindowMovedNotification, kAXWindowResizedNotification],
                optionalNotifications: [kAXFocusedWindowChangedNotification]
            ) { [weak self] notification, element in
                self?.handle(notification: notification, element: element, pid: pid)
            }
            if !observer.unavailableNotifications.isEmpty {
                logger.log("observer for pid \(pid): optional notifications unavailable: \(observer.unavailableNotifications)")
            }
            if observer.unavailableNotifications.contains(kAXFocusedWindowChangedNotification) {
                focusPollingPIDs.insert(pid)
            } else {
                focusPollingPIDs.remove(pid)
            }
            observers[pid] = observer
            return true
        } catch {
            throw RegistrationError.observerUnavailable(pid: pid, underlying: "\(error)")
        }
    }

    /// 登録・紐付けが失敗したとき、他に使い手のない observer を片付ける。
    private func dropObserverIfUnused(pid: pid_t) {
        guard observerIsUnused(pid: pid) else { return }
        observers[pid]?.invalidate()
        observers.removeValue(forKey: pid)
        focusPollingPIDs.remove(pid)
    }

    /// 消滅通知は任意(取れなくても 2 秒ポーリングで検知できる)。
    /// 競合で observer が捨てられていた場合は作り直す(黙って未購読のままにしない)。
    private func watchDestroyed(of window: AXWindow) {
        do {
            if observers[window.pid] == nil {
                _ = try establishObserver(pid: window.pid)
                logger.log("observer for pid \(window.pid) re-established")
            }
            try observers[window.pid]?.addNotification(kAXUIElementDestroyedNotification, element: window.element)
        } catch {
            logger.log("destroyed notification for \(window.windowID) unavailable: \(error)")
        }
    }

    private func handle(notification: String, element: AXUIElement, pid: pid_t) {
        guard !isTerminating else { return }
        switch notification {
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            var wid: CGWindowID = 0
            guard AXShimGetWindowID(element, &wid) == .success else { return }
            engine.windowFrameDidChange(windowID: wid)
        case kAXFocusedWindowChangedNotification:
            var wid: CGWindowID = 0
            guard AXShimGetWindowID(element, &wid) == .success else { return }
            recordFocusedWindow(wid)
        case kAXUIElementDestroyedNotification:
            // 壊れた要素からは ID が取れないので、登録時の要素と比較する。
            guard let entry = elements.first(where: { $0.value.pid == pid && CFEqual($0.value.element, element) }) else { return }
            // アプリごと終了した場合は除去せず「未復元」として保持する(再起動後に自動で戻す)。
            let app = NSRunningApplication(processIdentifier: pid)
            engine.noteWindowDestroyed(windowID: entry.key, appTerminated: app == nil || app!.isTerminated)
            forgetWindow(entry.key)
        default:
            break
        }
    }

    private func forgetWindow(_ windowID: CGWindowID) {
        driver.forget(windowID)
        guard let entry = elements.removeValue(forKey: windowID) else { return }
        observers[entry.pid]?.removeNotification(kAXUIElementDestroyedNotification, element: entry.element)
        // 同じ pid の登録/紐付けが await 中なら observer を残す(捨てると後から commit した窓が通知なしになる)。
        if observerIsUnused(pid: entry.pid) {
            observers[entry.pid]?.invalidate()
            observers.removeValue(forKey: entry.pid)
            focusPollingPIDs.remove(entry.pid)
        }
    }

    // MARK: - ポーリングと NSWorkspace

    private func reconcileTick() {
        guard isTrusted, !isTerminating, reconcileTask == nil else { return }  // 前回が終わるまで重ねない
        let live = WindowEnumerator.existingWindowIDs()
        let livePIDs = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        let appeared = live.subtracting(lastExistingIDs)
        lastExistingIDs = live
        let before = Set(engine.state.allWindows.compactMap(\.windowID))
        reconcileTask = Task { [weak self] in
            guard let self else { return }
            defer { self.reconcileTask = nil }
            await self.engine.reconcile(liveWindowIDs: live, livePIDs: livePIDs)
            guard !Task.isCancelled, !self.isTerminating else { return }
            let after = Set(self.engine.state.allWindows.compactMap(\.windowID))
            for gone in before.subtracting(after) {
                self.forgetWindow(gone)
            }
            if !appeared.isEmpty, self.engine.state.allWindows.contains(where: { !$0.isBound }) {
                // 復元中でもイベントを記憶し、現在の列挙完了後に必ず一度追走する。
                self.strictRestorePending = true
            }
            if !self.initialRestoreDone {
                self.startInitialRestoreIfNeeded()  // 起動時に権限が無かった場合はここで初回復元
            } else {
                // 新しい窓が現れたときだけ(列挙は全アプリへの IPC なので毎回はしない)厳しめに自動紐付け。
                self.startStrictRestoreIfNeeded()
            }
            // focused 通知を提供しないアプリでは、同一アプリ内の窓切替を低頻度で補完する。
            if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
                self.focusPollingPIDs.contains(pid),
                let windowID = await self.focusedWindowID(pid: pid),
                !Task.isCancelled, !self.isTerminating,
                NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            {
                self.recordFocusedWindow(windowID)
            }
        }
    }

    /// 画面変更・復帰は短時間に連発するので 1 秒でまとめてから再適用する。
    @objc private func layoutMayHaveChanged(_ notification: Notification) {
        guard !isTerminating else { return }
        layoutReapplyTask?.cancel()
        layoutReapplyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, self.isTrusted, !self.isTerminating else { return }
            self.logger.log("layout change (\(notification.name.rawValue)): reapplying")
            await self.engine.reapplyLayout()
        }
    }

    @objc private func appDidTerminate(_ notification: Notification) {
        guard !isTerminating else { return }
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        let gone = elements.filter { $0.value.pid == pid }.map(\.key)
        guard !gone.isEmpty else { return }
        logger.log("app terminated: \(app.localizedName ?? "pid \(pid)") (\(gone.count) windows kept as unbound)")
        engine.unbindWindows(pid: pid)
        for windowID in gone {
            forgetWindow(windowID)
        }
    }

    @objc private func appDidActivate(_ notification: Notification) {
        guard !isTerminating else { return }
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            observers[app.processIdentifier] != nil
        else { return }
        // アプリ切替でフォーカスが移った先の窓を記録する(同一アプリ内の切替は kAXFocusedWindowChanged が拾う)。
        let pid = app.processIdentifier
        Task { [weak self] in
            guard let self, let windowID = await self.focusedWindowID(pid: pid),
                !self.isTerminating,
                self.observers[pid] != nil,
                NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            else { return }
            self.recordFocusedWindow(windowID)
        }
    }
}
