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
    let layout = PrimaryScreenLayout(sidebarWidth: WindowManager.sidebarWidth)
    let store: StateStore
    /// true を返す間は切替後のアプリ前面化を行わない(サイドバーで改名中など)。
    var suppressAppActivation: (@MainActor () -> Bool)?
    /// UI 向けの状態変更通知(エンジンの onStateChanged はここが占有し、保存とあわせて配る)。
    var onStateChanged: (@MainActor (WorkspaceState) -> Void)?
    private let driver = AXWindowDriver()
    private let logger: FileLogger
    private var saveTask: Task<Void, Never>?
    private var reconcileTask: Task<Void, Never>?
    private var layoutReapplyTask: Task<Void, Never>?
    private var isTerminating = false
    private var initialRestoreDone = false
    private var lastExistingIDs: Set<CGWindowID> = []
    private var observers: [pid_t: AppWindowObserver] = [:]
    /// destroyed 通知は壊れた要素で届くので ID を引けない。登録時の要素を覚えておき CFEqual で突き合わせる。
    private var elements: [CGWindowID: (pid: pid_t, element: AXUIElement)] = [:]
    private var reconcileTimer: Timer?
    private var mouseUpMonitor: Any?
    /// engine.register の await 中のウィンドウ。同じ窓の二重登録を入口で弾く(state にはまだ載っていないため)。
    private var registering: Set<CGWindowID> = []

    enum RegistrationError: Error, CustomStringConvertible {
        case alreadyInProgress(CGWindowID)
        /// 移動・リサイズ通知(位置固定の要)を購読できないアプリ。登録は行わない(半端な登録を残さない)。
        case observerUnavailable(pid: pid_t, underlying: String)

        var description: String {
            switch self {
            case .alreadyInProgress(let id): return "window \(id) is already being registered"
            case .observerUnavailable(let pid, let underlying): return "cannot observe pid \(pid): \(underlying)"
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
            try? store.backupCorruptFile()
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
            Task { [weak self] in await self?.runInitialRestore() }
        }
    }

    // MARK: - 永続化

    /// 変更が連続しても 0.5 秒にまとめて書く。
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        do {
            try store.save(engine.state)
        } catch {
            logger.log("save failed: \(error)")
        }
    }

    // MARK: - 復元(未復元エントリへの紐付け)

    private func runInitialRestore() async {
        guard !initialRestoreDone else { return }
        initialRestoreDone = true
        await restoreUnboundWindows(strictness: .lenient)
    }

    /// 未復元エントリに今ある窓を紐付ける。起動直後は緩め、稼働中は厳しめに照合する。
    func restoreUnboundWindows(strictness: WindowMatcher.Strictness) async {
        let unbound = engine.state.allWindows.filter { !$0.isBound }
        guard !unbound.isEmpty else { return }
        let records = await availableWindows()
        let candidates = records.map {
            WindowMatcher.Candidate(
                windowID: $0.window.windowID, pid: $0.window.pid, bundleID: $0.bundleID, title: $0.title,
                size: $0.frame?.size ?? .zero)
        }
        let matches = WindowMatcher.match(unbound: unbound, candidates: candidates, strictness: strictness)
        for match in matches {
            guard let record = records.first(where: { $0.window.windowID == match.candidate.windowID }) else { continue }
            await bind(record, to: match.managedID)
        }
        logger.log("restore(\(strictness)): bound \(matches.count) of \(unbound.count) unbound window(s)")
    }

    /// 手動割り当て・自動復元の共通経路。
    func bind(_ record: WindowRecord, to managedID: UUID) async {
        let windowID = record.window.windowID
        let createdObserver: Bool
        do {
            createdObserver = try establishObserver(pid: record.window.pid)
        } catch {
            logger.log("bind skipped (no observer): \(error)")  // 次の自動復元で再試行される
            return
        }
        driver.adopt(record.window)
        do {
            try await engine.bind(managedID, windowID: windowID, pid: record.window.pid, title: record.title)
            elements[windowID] = (record.window.pid, record.window.element)
            watchDestroyed(of: record.window)
        } catch {
            if engine.state.managedWindow(forWindowID: windowID) == nil {
                driver.forget(windowID)
                dropObserverIfUnused(pid: record.window.pid, createdNow: createdObserver)
            }
            logger.log("bind failed: \(error)")
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

    // MARK: - 登録候補

    /// 登録できる標準ウィンドウ(自分自身と登録済みを除く)。
    /// 全アプリへの AX IPC を伴うのでバックグラウンドで pid 並列に行い、MainActor は待つだけにする。
    func availableWindows() async -> [WindowRecord] {
        let (records, stats) = await WindowEnumerator.standardWindowsAsync()
        if !stats.appFailureDetails.isEmpty {
            logger.log("enumerate: unavailable apps: \(stats.appFailureDetails)")
        }
        // await の間に登録が進んでいることがあるので、除外判定は列挙後の状態で行う。
        let registered = Set(engine.state.allWindows.compactMap(\.windowID))
        return records.filter { !registered.contains($0.window.windowID) }
    }

    /// タブを削除する。Core の削除が成功したときだけ、その窓の AX 資源(driver / 要素 / observer)を片付ける。
    /// 復元できない窓があって Core が throw した場合は何も片付けない(登録も資源も保持される)。
    func deleteTab(_ id: UUID) async throws {
        let windowIDs = engine.state.tab(withID: id)?.windows.compactMap(\.windowID) ?? []
        try await engine.deleteTab(id)
        for windowID in windowIDs {
            forgetWindow(windowID)
        }
    }

    // MARK: - 登録 / 解除

    /// ウィンドウをタブに登録する。主ディスプレイのコンテンツ領域に収まっていなければ引き込む。
    func register(_ record: WindowRecord, into tabID: UUID) async throws {
        let area = layout.contentArea
        let current = try record.window.frame()
        let frame: CGRect
        if area.contains(current) {
            frame = current
        } else {
            frame = CGRect(
                origin: area.origin,
                size: CGSize(width: min(current.width, area.width), height: min(current.height, area.height)))
        }
        let windowID = record.window.windowID
        guard !registering.contains(windowID) else { throw RegistrationError.alreadyInProgress(windowID) }
        registering.insert(windowID)
        defer { registering.remove(windowID) }

        // 必須 observer(moved / resized)は窓に触れる前に確立する。取れないアプリは登録しない。
        let createdObserver = try establishObserver(pid: record.window.pid)
        driver.adopt(record.window)
        let identity = WindowIdentity(
            bundleID: record.bundleID, appName: record.appName, title: record.title, registeredSize: current.size)
        do {
            _ = try await engine.register(
                windowID: windowID, pid: record.window.pid, identity: identity, frame: frame, into: tabID)
        } catch {
            // windowAlreadyRegistered は「別の登録が成功済み」を意味する。そのドライバ登録を巻き添えにしない。
            if engine.state.managedWindow(forWindowID: windowID) == nil {
                driver.forget(windowID)
                dropObserverIfUnused(pid: record.window.pid, createdNow: createdObserver)
            }
            throw error
        }
        elements[windowID] = (record.window.pid, record.window.element)
        watchDestroyed(of: record.window)
    }

    func unregister(_ id: UUID) async throws {
        guard let found = engine.state.managedWindow(id: id) else { return }
        try await engine.unregister(id)
        if let windowID = found.window.windowID {
            forgetWindow(windowID)
        }
    }

    /// TabDesk 終了前のクリーンアップ。退避中の窓を元の位置に戻す。
    /// 先にポーリングを止める(止めないと reconcile が戻した窓を再び隅へ送ってしまう)。
    func prepareForTermination() async {
        isTerminating = true
        reconcileTimer?.invalidate()
        reconcileTimer = nil
        // 進行中の reconcile を待ってから戻す(エンジン側のフラグが二重の保険)。
        await reconcileTask?.value
        await engine.releaseAllParkedWindows()
        saveNow()
        logger.log("terminating: parked windows released, state saved")
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
            observers[pid] = observer
            return true
        } catch {
            throw RegistrationError.observerUnavailable(pid: pid, underlying: "\(error)")
        }
    }

    /// 登録が失敗したとき、この呼び出しで作ったばかりで他に使い手のない observer を片付ける。
    private func dropObserverIfUnused(pid: pid_t, createdNow: Bool) {
        guard createdNow, !elements.values.contains(where: { $0.pid == pid }) else { return }
        observers[pid]?.invalidate()
        observers.removeValue(forKey: pid)
    }

    /// 消滅通知は任意(取れなくても 2 秒ポーリングで検知できる)。
    private func watchDestroyed(of window: AXWindow) {
        do {
            try observers[window.pid]?.addNotification(kAXUIElementDestroyedNotification, element: window.element)
        } catch {
            logger.log("destroyed notification for \(window.windowID) unavailable: \(error)")
        }
    }

    private func handle(notification: String, element: AXUIElement, pid: pid_t) {
        switch notification {
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            var wid: CGWindowID = 0
            guard AXShimGetWindowID(element, &wid) == .success else { return }
            engine.windowFrameDidChange(windowID: wid)
        case kAXFocusedWindowChangedNotification:
            var wid: CGWindowID = 0
            guard AXShimGetWindowID(element, &wid) == .success else { return }
            engine.noteWindowFocused(windowID: wid)
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
        if !elements.values.contains(where: { $0.pid == entry.pid }) {
            observers[entry.pid]?.invalidate()
            observers.removeValue(forKey: entry.pid)
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
            let after = Set(self.engine.state.allWindows.compactMap(\.windowID))
            for gone in before.subtracting(after) {
                self.forgetWindow(gone)
            }
            if !self.initialRestoreDone {
                await self.runInitialRestore()  // 起動時に権限が無かった場合はここで初回復元
            } else if !appeared.isEmpty, self.engine.state.allWindows.contains(where: { !$0.isBound }) {
                // 新しい窓が現れたときだけ(列挙は全アプリへの IPC なので毎回はしない)厳しめに自動紐付け。
                await self.restoreUnboundWindows(strictness: .strict)
            }
        }
    }

    /// 画面変更・復帰は短時間に連発するので 1 秒でまとめてから再適用する。
    @objc private func layoutMayHaveChanged(_ notification: Notification) {
        guard !isTerminating else { return }
        layoutReapplyTask?.cancel()
        layoutReapplyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, self.isTrusted else { return }
            self.logger.log("layout change (\(notification.name.rawValue)): reapplying")
            await self.engine.reapplyLayout()
        }
    }

    @objc private func appDidTerminate(_ notification: Notification) {
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
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            observers[app.processIdentifier] != nil
        else { return }
        // アプリ切替でフォーカスが移った先の窓を記録する(同一アプリ内の切替は kAXFocusedWindowChanged が拾う)。
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return }
        let element = unsafeDowncast(value, to: AXUIElement.self)
        var wid: CGWindowID = 0
        if AXShimGetWindowID(element, &wid) == .success {
            engine.noteWindowFocused(windowID: wid)
        }
    }
}
