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
    /// true を返す間は切替後のアプリ前面化を行わない(サイドバーで改名中など)。
    var suppressAppActivation: (@MainActor () -> Bool)?
    private let driver = AXWindowDriver()
    private let logger: FileLogger
    private var observers: [pid_t: AppWindowObserver] = [:]
    /// destroyed 通知は壊れた要素で届くので ID を引けない。登録時の要素を覚えておき CFEqual で突き合わせる。
    private var elements: [CGWindowID: (pid: pid_t, element: AXUIElement)] = [:]
    private var reconcileTimer: Timer?
    private var mouseUpMonitor: Any?
    /// engine.register の await 中のウィンドウ。同じ窓の二重登録を入口で弾く(state にはまだ載っていないため)。
    private var registering: Set<CGWindowID> = []

    enum RegistrationError: Error, CustomStringConvertible {
        case alreadyInProgress(CGWindowID)

        var description: String {
            switch self {
            case .alreadyInProgress(let id): return "window \(id) is already being registered"
            }
        }
    }

    init(logger: FileLogger) {
        self.logger = logger
        engine = TabEngine(driver: driver, layout: layout)
        engine.log = { logger.log($0) }
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
    func availableWindows() -> [WindowRecord] {
        let registered = Set(engine.state.allWindows.compactMap(\.windowID))
        let (records, stats) = WindowEnumerator.standardWindows()
        if !stats.appFailureDetails.isEmpty {
            logger.log("enumerate: unavailable apps: \(stats.appFailureDetails)")
        }
        return records.filter { !registered.contains($0.window.windowID) }
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
            }
            throw error
        }
        elements[record.window.windowID] = (record.window.pid, record.window.element)
        ensureObserver(for: record.window)
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
        reconcileTimer?.invalidate()
        reconcileTimer = nil
        await engine.releaseAllParkedWindows()
        logger.log("terminating: parked windows released")
    }

    // MARK: - AX 通知

    private func ensureObserver(for window: AXWindow) {
        let pid = window.pid
        if observers[pid] == nil {
            do {
                let observer = try AppWindowObserver(
                    pid: pid,
                    notifications: [kAXWindowMovedNotification, kAXWindowResizedNotification, kAXFocusedWindowChangedNotification]
                ) { [weak self] notification, element in
                    self?.handle(notification: notification, element: element, pid: pid)
                }
                observers[pid] = observer
            } catch {
                logger.log("observer for pid \(pid) failed: \(error)")
                return
            }
        }
        do {
            try observers[pid]?.addNotification(kAXUIElementDestroyedNotification, element: window.element)
        } catch {
            // 通知が取れなくても 2 秒ポーリングで消滅は検知できる。
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
            engine.noteWindowDestroyed(windowID: entry.key)
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
        let live = WindowEnumerator.existingWindowIDs()
        let before = Set(engine.state.allWindows.compactMap(\.windowID))
        Task { [weak self] in
            guard let self else { return }
            await self.engine.reconcile(liveWindowIDs: live)
            let after = Set(self.engine.state.allWindows.compactMap(\.windowID))
            for gone in before.subtracting(after) {
                self.forgetWindow(gone)
            }
        }
    }

    @objc private func appDidTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        let gone = elements.filter { $0.value.pid == pid }.map(\.key)
        guard !gone.isEmpty else { return }
        logger.log("app terminated: \(app.localizedName ?? "pid \(pid)") (\(gone.count) windows)")
        for windowID in gone {
            engine.noteWindowDestroyed(windowID: windowID)
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
