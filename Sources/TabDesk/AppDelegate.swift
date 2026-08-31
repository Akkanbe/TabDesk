import AppKit
import ServiceManagement
import TabDeskCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let logger = FileLogger(directoryName: "TabDesk", fileName: "tabdesk.log")
    private lazy var manager = WindowManager(logger: logger)
    private var sidebar: SidebarPanel?
    private var statusItem: NSStatusItem?
    private var loginItemMenuItem: NSMenuItem?
    private var sidebarCollapseMenuItem: NSMenuItem?
    private var frameWindows: FrameWindowController?
    private var probeWindow: NSWindow?
    private lazy var hotkeys = HotkeyCenter(logger: logger)

    /// tabdesk:// コマンドの受け付け(既定 OFF)。Accessibility 権限を持つ本アプリへの代理操作口になるため、
    /// メニューバーで明示的に有効化した場合のみ受け付ける(仕様 §5「配布前の必須対応」、docs/04_v2_design.md)。
    static let urlCommandsEnabled = PersistedToggle(key: "URLCommandsEnabled", defaultValue: false)

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.log("TabDesk started. log: \(logger.fileURL.path) trusted=\(manager.isTrusted)")
        // メニューの「常に最前面」表示はサイドバーの実状態から作るので、サイドバーを先に用意する。
        let panel = SidebarPanel(manager: manager, logger: logger)
        sidebar = panel
        frameWindows = FrameWindowController(manager: manager)
        installStatusItem(alwaysOnTop: panel.alwaysOnTop)
        panel.orderFrontRegardless()
        logger.log("sidebar shown at \(panel.frame)")
        installHotkeys()
        if !manager.isTrusted {
            manager.requestPermission()
        }
    }

    /// 終了前に退避中の窓を戻す。非同期なので terminateLater で保留し、cleanup 完了か 3 秒の期限で 1 回だけ返事する。
    private lazy var termination = TerminationCoordinator(
        deadline: .seconds(3),
        cleanup: { [manager] in await manager.prepareForTermination() },
        reply: { [logger] reason in
            logger.log("terminate: \(reason)")
            NSApp.reply(toApplicationShouldTerminate: true)
        })

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // cleanup 中の再要求も待たせる(terminateNow を返すと復元完了前に終了してしまう)。
        // Task を起動する前に同期的に入口を閉じ、復元後に新しい操作が窓を再退避するのを防ぐ。
        manager.beginTermination()
        hotkeys.stop()
        termination.requestTermination()
        return .terminateLater
    }

    /// tabdesk://... で届いたコマンド(動作確認・自動化用)。
    func application(_ application: NSApplication, open urls: [URL]) {
        guard Self.urlCommandsEnabled.value else {
            logger.log("url: ignored \(urls.count) command(s); URL commands are disabled " +
                "(メニューバーの「URL コマンドを許可(自動化用)」で有効化)")
            return
        }
        guard !manager.isTerminating else {
            logger.log("url: ignored \(urls.count) command(s) during termination")
            return
        }
        for url in urls {
            handle(url: url)
        }
    }

    // MARK: - ホットキー

    private func installHotkeys() {
        hotkeys.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .activateTab(let number):
                let tabs = self.manager.engine.state.tabs
                guard tabs.indices.contains(number - 1) else { return }
                let tabID = tabs[number - 1].id
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.manager.activate(tabID)
                    } catch {
                        self.logger.log("hotkey activate failed: \(error)")
                    }
                }
            case .nextTab, .previousTab:
                // ブラウザ風のタブ順送り(末尾/先頭で回る)。ターゲットの解決はエンジンの直列区間内で
                // 行う(ここで先に計算すると、切替中の連打が古い activeTabID から同じタブを選んでしまう)。
                let offset = action == .nextTab ? 1 : -1
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.manager.activateAdjacent(offset: offset)
                    } catch {
                        self.logger.log("hotkey cycle failed: \(error)")
                    }
                }
            case .registerFocusedWindow:
                Task { [manager = self.manager] in await manager.registerFocusedWindow() }
            case .toggleEditMode:
                self.manager.engine.editMode.toggle()
                self.sidebar?.render()
                self.logger.log("editMode=\(self.manager.engine.editMode) (hotkey)")
            case .toggleSidebar:
                self.sidebar?.toggleCollapse()
            }
        }
        hotkeys.reload()
    }

    // MARK: - メニューバー

    private func installStatusItem(alwaysOnTop: Bool) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "TabDesk")
        let menu = NSMenu()
        menu.addItem(withTitle: "サイドバーを表示", action: #selector(showSidebar), keyEquivalent: "")
        let collapse = NSMenuItem(title: "サイドバーを折りたたむ", action: #selector(toggleSidebarCollapsed(_:)), keyEquivalent: "")
        collapse.state = manager.sidebarMetrics.isCollapsed ? .on : .off
        sidebarCollapseMenuItem = collapse
        menu.addItem(collapse)
        let onTop = NSMenuItem(title: "サイドバーを常に最前面にする", action: #selector(toggleAlwaysOnTop(_:)), keyEquivalent: "")
        onTop.state = alwaysOnTop ? .on : .off
        menu.addItem(onTop)
        let follow = NSMenuItem(title: "フォーカスで自動切替", action: #selector(toggleFocusFollows(_:)), keyEquivalent: "")
        follow.state = manager.focusFollows.value ? .on : .off
        menu.addItem(follow)
        let login = NSMenuItem(title: "ログイン時に起動", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        loginItemMenuItem = login
        updateLaunchAtLoginMenuItem()
        menu.addItem(login)
        let frames = NSMenuItem(title: "背景の枠を表示", action: #selector(toggleFrameWindows(_:)), keyEquivalent: "")
        frames.state = FrameWindowController.enabledSetting.value ? .on : .off
        menu.addItem(frames)
        let thumbnails = NSMenuItem(title: "タブサムネイルを表示", action: #selector(toggleThumbnails(_:)), keyEquivalent: "")
        thumbnails.state = ThumbnailStore.enabledSetting.value ? .on : .off
        menu.addItem(thumbnails)
        let urlCommands = NSMenuItem(title: "URL コマンドを許可(自動化用)", action: #selector(toggleURLCommands(_:)), keyEquivalent: "")
        urlCommands.state = Self.urlCommandsEnabled.value ? .on : .off
        menu.addItem(urlCommands)
        menu.addItem(.separator())
        menu.addItem(withTitle: "ホットキー設定を開く", action: #selector(openHotkeyConfig), keyEquivalent: "")
        menu.addItem(withTitle: "ホットキーを再読み込み", action: #selector(reloadHotkeys), keyEquivalent: "")
        menu.addItem(withTitle: "アクセシビリティ設定を開く", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        menu.addItem(withTitle: "ログを開く", action: #selector(openLog), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "TabDesk を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for menuItem in menu.items where menuItem.action != #selector(NSApplication.terminate(_:)) {
            menuItem.target = self
        }
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// System Settings 側でログイン項目が変更されることがあるため、メニューを開くたびに実状態を読み直す。
    /// 折りたたみもホットキー/サイドバー側で変わるので同様に同期する。
    func menuWillOpen(_ menu: NSMenu) {
        updateLaunchAtLoginMenuItem()
        sidebarCollapseMenuItem?.state = manager.sidebarMetrics.isCollapsed ? .on : .off
    }

    @objc private func toggleSidebarCollapsed(_ sender: NSMenuItem) {
        sidebar?.toggleCollapse()
        sender.state = manager.sidebarMetrics.isCollapsed ? .on : .off
    }

    @objc private func toggleAlwaysOnTop(_ sender: NSMenuItem) {
        guard let sidebar else { return }
        sidebar.alwaysOnTop.toggle()
        sender.state = sidebar.alwaysOnTop ? .on : .off
        logger.log("alwaysOnTop=\(sidebar.alwaysOnTop)")
    }

    @objc private func toggleFocusFollows(_ sender: NSMenuItem) {
        manager.focusFollows.value.toggle()
        sender.state = manager.focusFollows.value ? .on : .off
        logger.log("focusFollows=\(manager.focusFollows.value)")
    }

    @objc private func toggleURLCommands(_ sender: NSMenuItem) {
        Self.urlCommandsEnabled.value.toggle()
        sender.state = Self.urlCommandsEnabled.value ? .on : .off
        logger.log("urlCommandsEnabled=\(Self.urlCommandsEnabled.value)")
    }

    @objc private func toggleThumbnails(_ sender: NSMenuItem) {
        ThumbnailStore.enabledSetting.value.toggle()
        let enabled = ThumbnailStore.enabledSetting.value
        sender.state = enabled ? .on : .off
        if !enabled {
            // opt-out 後に開始済みの ScreenCaptureKit 処理を継続させず、再ON時の古い表示も防ぐ。
            manager.thumbnails.cancelAll(clearImages: true)
        }
        // 有効化時にまだ権限が無ければ、この場でシステムのプロンプトを出す(初回のみ表示される)。
        if enabled, !ThumbnailStore.hasPermission {
            CGRequestScreenCaptureAccess()
        }
        sidebar?.refreshThumbnailPresentation()
        logger.log("tabThumbnailsEnabled=\(enabled) permission=\(ThumbnailStore.hasPermission)")
    }

    @objc private func toggleFrameWindows(_ sender: NSMenuItem) {
        FrameWindowController.enabledSetting.value.toggle()
        sender.state = FrameWindowController.enabledSetting.value ? .on : .off
        frameWindows?.rebuild()
        logger.log("frameWindowsEnabled=\(FrameWindowController.enabledSetting.value)")
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            case .notRegistered:
                try service.register()
            case .requiresApproval:
                // この状態は登録済み。再登録では復旧しないため、ユーザーが承認できる画面へ案内する。
                logger.log("launch-at-login requires approval; opening System Settings")
                SMAppService.openSystemSettingsLoginItems()
            case .notFound:
                logger.log("launch-at-login unavailable: service not found")
            @unknown default:
                logger.log("launch-at-login unavailable: unknown status \(service.status.rawValue)")
            }
        } catch {
            logger.log("launch-at-login failed: \(error)")
        }
        updateLaunchAtLoginMenuItem()
        logger.log("launchAtLoginStatus=\(service.status.rawValue)")
    }

    private func updateLaunchAtLoginMenuItem() {
        guard let item = loginItemMenuItem else { return }
        item.isEnabled = true
        switch SMAppService.mainApp.status {
        case .enabled:
            item.title = "ログイン時に起動"
            item.state = .on
        case .notRegistered:
            item.title = "ログイン時に起動"
            item.state = .off
        case .requiresApproval:
            item.title = "ログイン時に起動（承認が必要）"
            item.state = .mixed
        case .notFound:
            item.title = "ログイン時に起動（利用不可）"
            item.state = .off
            item.isEnabled = false
        @unknown default:
            item.title = "ログイン時に起動（状態不明）"
            item.state = .off
            item.isEnabled = false
        }
    }

    @objc private func openHotkeyConfig() {
        // 無ければ既定を書いてから開く(reload が生成する)。
        if !FileManager.default.fileExists(atPath: HotkeyCenter.configURL.path) {
            hotkeys.reload()
        }
        NSWorkspace.shared.open(HotkeyCenter.configURL)
    }

    @objc private func reloadHotkeys() {
        hotkeys.reload()
    }

    @objc private func showSidebar() {
        sidebar?.reposition()
        sidebar?.orderFrontRegardless()
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(logger.fileURL)
    }

    private func cgBounds(_ windowID: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
            let info = list.first,
            let dict = info[kCGWindowBounds as String] as? NSDictionary
        else { return nil }
        return CGRect(dictionaryRepresentation: dict as CFDictionary)
    }

    // MARK: - URL コマンド

    private func handle(url: URL) {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let command = comps.host ?? ""
        var q: [String: String] = [:]
        for item in comps.queryItems ?? [] { q[item.name] = item.value ?? "" }
        logger.log("url: \(url.absoluteString)")
        let engine = manager.engine

        func tab(named name: String?) -> Tab? {
            guard let name else { return engine.state.activeTab }
            return engine.state.tabs.first { $0.name == name }
        }

        switch command {
        case "status":
            let s = engine.state
            let unbound = s.allWindows.filter { !$0.isBound }
            logger.log("status: trusted=\(manager.isTrusted) tabs=\(s.tabs.map { "\($0.name)(\($0.windows.count))" }) " +
                "active=\(s.activeTab?.name ?? "-") parked=\(engine.parkedWindowIDs.count) unbound=\(unbound.count) " +
                "fullscreen=\(engine.fullscreenWindowIDs.count) edit=\(engine.editMode) state=\(manager.store.fileURL.path)")
            for w in unbound {
                logger.log("  unbound: \(w.identity.appName) | \(w.identity.title) id=\(w.id)")
            }
        case "windows":
            // fs / min は除外実装の実測用に生値を出す(fs=nil は属性なし。docs/04_v2_design.md)。
            Task { [manager, logger] in
                for record in await manager.availableWindows() {
                    logger.log("  wid=\(record.window.windowID) pid=\(record.window.pid) " +
                        "fs=\(record.fullscreenRaw.map(String.init) ?? "nil") min=\(record.isMinimized) " +
                        "\(record.appName) | \(record.title)")
                }
            }
        case "tab":
            engine.createTab(name: q["name"] ?? "タブ\(engine.state.tabs.count + 1)")
        case "add":
            guard let wid = CGWindowID(q["wid"] ?? ""), let target = tab(named: q["tab"]) else {
                logger.log("url: add needs wid=<available window id> [&tab=name]")
                return
            }
            Task { [manager, logger] in
                guard let record = await manager.availableWindows().first(where: { $0.window.windowID == wid }) else {
                    logger.log("url: add: wid \(wid) is not an available window")
                    return
                }
                do { try await manager.register(record, into: target.id) } catch { logger.log("add failed: \(error)") }
            }
        case "activate":
            guard let target = tab(named: q["name"]) else {
                logger.log("url: activate needs name=<tab>")
                return
            }
            Task { [manager, logger] in
                do { try await manager.activate(target.id) } catch { logger.log("activate failed: \(error)") }
            }
        case "remove":
            guard let wid = CGWindowID(q["wid"] ?? ""), let found = engine.state.managedWindow(forWindowID: wid) else {
                logger.log("url: remove needs wid=<registered window id>")
                return
            }
            Task { [manager, logger] in
                do { try await manager.unregister(found.window.id) } catch { logger.log("remove failed: \(error)") }
            }
        case "edit":
            engine.editMode = (q["on"] ?? "1") != "0"
            sidebar?.render()
            logger.log("editMode=\(engine.editMode)")
        case "restore":
            Task { [manager] in await manager.restoreUnboundWindows(strictness: (q["strict"] ?? "0") == "1" ? .strict : .lenient) }
        case "save":
            let saved = manager.saveNow()
            logger.log(saved
                ? "saved to \(manager.store.fileURL.path)"
                : "save failed for \(manager.store.fileURL.path)")
        case "quit":
            NSApp.terminate(nil)
        case "probe":
            // 座標系の切り分け用: 自アプリの赤い窓をコンテンツ領域の左上(サイドバーの右隣)に 15 秒出す。
            // これがサイドバーと被って見えるなら、描画がサイドバーの bounds からはみ出している。
            let area = manager.layout.contentArea
            let cocoaRect = NSRect(
                x: area.minX, y: (NSScreen.screens.first?.frame.height ?? 0) - area.minY - 200, width: 300, height: 200)
            let probe = NSWindow(contentRect: cocoaRect, styleMask: [.borderless], backing: .buffered, defer: false)
            probe.backgroundColor = .systemRed
            probe.level = .floating
            probe.isReleasedWhenClosed = false
            probe.orderFrontRegardless()
            probeWindow = probe
            logger.log("probe: red window at cocoa=\(probe.frame) cg=\(cgBounds(CGWindowID(probe.windowNumber)).map { "\($0)" } ?? "?")")
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                MainActor.assumeIsolated {
                    self?.probeWindow?.orderOut(nil)
                    self?.probeWindow = nil
                }
            }
        case "dump":
            // 座標系の突き合わせ用。AX 座標(主画面左上原点)と CGWindowList の bounds は同じはずだが、
            // サイドバーと窓の見た目が食い違うときにここで確認する。
            for screen in NSScreen.screens {
                logger.log("screen '\(screen.localizedName)': frame=\(screen.frame) visible=\(screen.visibleFrame) " +
                    "scale=\(screen.backingScaleFactor) id=\(ScreenGeometry.displayID(of: screen))")
            }
            if let sidebar {
                logger.log("sidebar: cocoa=\(sidebar.frame) cg=\(cgBounds(CGWindowID(sidebar.windowNumber)).map { "\($0)" } ?? "?")")
            }
            for display in manager.layout.displays {
                logger.log("display \(display.id): frame(AX)=\(display.frame) content=\(display.contentArea) park=\(display.parkPoint)")
            }
            for window in engine.state.allWindows {
                guard let wid = window.windowID else { continue }
                let ax = (try? manager.currentFrame(of: wid)).map { "\($0)" } ?? "?"
                let cg = cgBounds(wid).map { "\($0)" } ?? "?"
                logger.log("window \(window.identity.appName) wid=\(wid): recorded=\(window.frame) ax=\(ax) cg=\(cg) " +
                    "display=\(window.displayID ?? "primary")")
            }
        default:
            logger.log("url: unknown command '\(command)'")
        }
    }
}
