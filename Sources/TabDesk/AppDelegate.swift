import AppKit
import ServiceManagement
import TabDeskCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let logger = FileLogger(directoryName: "TabDesk", fileName: "tabdesk.log")
    private lazy var manager = WindowManager(logger: logger)
    private var sidebars: SidebarController?
    private var statusItem: NSStatusItem?
    private var loginItemMenuItem: NSMenuItem?
    private var sidebarCollapseMenuItem: NSMenuItem?
    private var saveStatusMenuItem: NSMenuItem?
    private var hotkeySettings: HotkeySettingsController?
    private var frameWindows: FrameWindowController?
    private var probeWindow: NSWindow?
    private var recoverySearchTask: Task<Void, Never>?
    private var recoverySearchMenuItem: NSMenuItem?
    private lazy var hotkeys = HotkeyCenter(logger: logger)

    /// tabdesk:// コマンドの受け付け(既定 OFF)。Accessibility 権限を持つ本アプリへの代理操作口になるため、
    /// メニューバーで明示的に有効化した場合のみ受け付ける(仕様 §5「配布前の必須対応」、docs/04_v2_design.md)。
    static let urlCommandsEnabled = PersistedToggle(key: "URLCommandsEnabled", defaultValue: false)

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.log("TabDesk started. log: \(logger.fileURL.path) trusted=\(manager.isTrusted)")
        // v4: 各ディスプレイに 1 本のサイドバー。生成・破棄は SidebarController が持つ。
        let controller = SidebarController(manager: manager, logger: logger)
        sidebars = controller
        // サイドバーの改名と設定画面の編集を、切替先アプリの前面化で中断しない。
        manager.suppressAppActivation = { [weak self] in
            guard let self else { return false }
            return self.sidebars?.isAnyRenaming == true || self.sidebars?.isAnyEditingTiles == true || self.hotkeySettings?.window?.isVisible == true
        }
        frameWindows = FrameWindowController(manager: manager)
        installStatusItem(alwaysOnTop: controller.alwaysOnTop)
        manager.onOperationError = { message in
            let alert = NSAlert()
            alert.messageText = L10n.text(.windowOperationFailed)
            alert.informativeText = message
            alert.addButton(withTitle: L10n.text(.close))
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        manager.onSaveStatusChanged = { [weak self] in self?.updateSaveStatus() }
        updateSaveStatus()
        controller.orderFrontAll()
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
            guard self.hotkeySettings?.window?.isKeyWindow != true else { return }
            switch action {
            case .activateTab, .nextTab, .previousTab, .nextDisplay, .previousDisplay:
                self.manager.navigate(action)
            case .registerFocusedWindow:
                Task { [manager = self.manager] in await manager.registerFocusedWindow() }
            case .toggleEditMode:
                self.manager.setEditMode(!self.manager.engine.editMode)
                self.logger.log("editMode=\(self.manager.engine.editMode) (hotkey)")
            case .toggleSidebar:
                // v4: 折りたたみは「選択中のディスプレイ」のパネルに作用する。
                guard let displayID = self.manager.selectedDisplayID() else { return }
                self.sidebars?.panel(for: displayID)?.toggleCollapse()
            }
        }
        hotkeys.reload()
    }

    // MARK: - メニューバー

    private func installStatusItem(alwaysOnTop: Bool) {
        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = StatusBarIcon.image
        let menu = NSMenu()
        menu.addItem(withTitle: L10n.text(.showSidebar), action: #selector(showSidebar), keyEquivalent: "")
        let collapse = NSMenuItem(title: L10n.text(.collapseSidebar), action: #selector(toggleSidebarCollapsed(_:)), keyEquivalent: "")
        collapse.state = menuCollapseState()
        sidebarCollapseMenuItem = collapse
        menu.addItem(collapse)
        let onTop = NSMenuItem(title: L10n.text(.alwaysOnTop), action: #selector(toggleAlwaysOnTop(_:)), keyEquivalent: "")
        onTop.state = alwaysOnTop ? .on : .off
        menu.addItem(onTop)
        let unregistered = NSMenuItem(title: L10n.text(.unregisteredWindowsOnTop),
            action: #selector(toggleUnregisteredWindowsOnTop(_:)), keyEquivalent: "")
        unregistered.state = manager.unregisteredWindowsOnTop.value ? .on : .off
        menu.addItem(unregistered)
        let follow = NSMenuItem(title: L10n.text(.followFocus), action: #selector(toggleFocusFollows(_:)), keyEquivalent: "")
        follow.state = manager.focusFollows.value ? .on : .off
        menu.addItem(follow)
        let login = NSMenuItem(title: L10n.text(.launchAtLogin), action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        loginItemMenuItem = login
        updateLaunchAtLoginMenuItem()
        menu.addItem(login)
        let frames = NSMenuItem(title: L10n.text(.showFrames), action: #selector(toggleFrameWindows(_:)), keyEquivalent: "")
        frames.state = FrameWindowController.enabledSetting.value ? .on : .off
        menu.addItem(frames)
        let thumbnails = NSMenuItem(title: L10n.text(.showThumbnails), action: #selector(toggleThumbnails(_:)), keyEquivalent: "")
        thumbnails.state = ThumbnailStore.enabledSetting.value ? .on : .off
        menu.addItem(thumbnails)
        let urlCommands = NSMenuItem(title: L10n.text(.allowURLs), action: #selector(toggleURLCommands(_:)), keyEquivalent: "")
        urlCommands.state = Self.urlCommandsEnabled.value ? .on : .off
        menu.addItem(urlCommands)
        menu.addItem(.separator())
        let saveStatus = NSMenuItem(title: "", action: #selector(showSaveFailure), keyEquivalent: "")
        saveStatusMenuItem = saveStatus
        menu.addItem(saveStatus)
        let languageItem = NSMenuItem(title: "表示言語 / Language", action: nil, keyEquivalent: "")
        let languages = NSMenu()
        for language in AppLanguage.allCases {
            let choice = NSMenuItem(title: language.nativeName, action: #selector(changeLanguage(_:)), keyEquivalent: "")
            choice.representedObject = language.rawValue
            choice.state = language == L10n.language ? .on : .off
            choice.target = self
            languages.addItem(choice)
        }
        languageItem.submenu = languages
        menu.addItem(languageItem)
        menu.addItem(withTitle: L10n.text(.openHotkeys), action: #selector(openHotkeySettings), keyEquivalent: "")
        menu.addItem(withTitle: L10n.text(.revealHotkeys), action: #selector(revealHotkeyConfig), keyEquivalent: "")
        menu.addItem(withTitle: L10n.text(.reloadHotkeys), action: #selector(reloadHotkeys), keyEquivalent: "")
        menu.addItem(withTitle: L10n.text(.openAccessibility), action: #selector(openAccessibilitySettings), keyEquivalent: "")
        menu.addItem(withTitle: L10n.text(.openLog), action: #selector(openLog), keyEquivalent: "")
        menu.addItem(withTitle: L10n.text(.windowRecovery), action: #selector(showWindowRecovery), keyEquivalent: "")
        let recoverySearch = menu.addItem(withTitle: L10n.text(.retryWindowSearch), action: #selector(retryWindowSearch), keyEquivalent: "")
        recoverySearchMenuItem = recoverySearch
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.text(.quit), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for menuItem in menu.items where menuItem.action != #selector(NSApplication.terminate(_:)) {
            menuItem.target = self
        }
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    @objc private func changeLanguage(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let language = AppLanguage(rawValue: rawValue), language != L10n.language else { return }
        LanguagePreference().value = language
        installStatusItem(alwaysOnTop: sidebars?.alwaysOnTop ?? SidebarPanel.alwaysOnTopSetting.value)
        updateSaveStatus()
        sidebars?.refreshLocalization()
        hotkeySettings?.refreshLocalization()
    }

    /// System Settings 側でログイン項目が変更されることがあるため、メニューを開くたびに実状態を読み直す。
    /// 折りたたみもホットキー/サイドバー側で変わるので同様に同期する。
    func menuWillOpen(_ menu: NSMenu) {
        updateLaunchAtLoginMenuItem()
        sidebarCollapseMenuItem?.state = menuCollapseState()
        recoverySearchMenuItem?.isEnabled = recoverySearchTask == nil && !manager.isTerminating
    }

    @objc private func toggleSidebarCollapsed(_ sender: NSMenuItem) {
        guard let displayID = manager.selectedDisplayID() else { return }
        sidebars?.panel(for: displayID)?.toggleCollapse()
        sender.state = menuCollapseState()
    }

    /// メニューのチェック状態は「選択中のディスプレイ」の折りたたみを映す(v4: 画面ごと)。
    private func menuCollapseState() -> NSControl.StateValue {
        guard let displayID = manager.selectedDisplayID() else { return .off }
        return manager.sidebarMetrics(for: displayID).isCollapsed ? .on : .off
    }

    @objc private func toggleAlwaysOnTop(_ sender: NSMenuItem) {
        guard let sidebars else { return }
        sidebars.alwaysOnTop.toggle()
        sender.state = sidebars.alwaysOnTop ? .on : .off
        logger.log("alwaysOnTop=\(sidebars.alwaysOnTop)")
    }

    @objc private func toggleUnregisteredWindowsOnTop(_ sender: NSMenuItem) {
        manager.setUnregisteredWindowsOnTop(!manager.unregisteredWindowsOnTop.value)
        sender.state = manager.unregisteredWindowsOnTop.value ? .on : .off
        logger.log("unregisteredWindowsOnTop=\(manager.unregisteredWindowsOnTop.value)")
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
        sidebars?.refreshThumbnailPresentation()
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
            item.title = L10n.text(.launchAtLogin)
            item.state = .on
        case .notRegistered:
            item.title = L10n.text(.launchAtLogin)
            item.state = .off
        case .requiresApproval:
            item.title = L10n.text(.loginApproval)
            item.state = .mixed
        case .notFound:
            item.title = L10n.text(.loginUnavailable)
            item.state = .off
            item.isEnabled = false
        @unknown default:
            item.title = L10n.text(.loginUnknown)
            item.state = .off
            item.isEnabled = false
        }
    }

    @objc private func revealHotkeyConfig() {
        // 無ければ既定を書いてから開く(reload が生成する)。
        if !FileManager.default.fileExists(atPath: HotkeyCenter.configURL.path) {
            hotkeys.reload()
        }
        // JSON の既定アプリがチャットアプリでも、意図せずファイルを渡さない。
        NSWorkspace.shared.activateFileViewerSelecting([HotkeyCenter.configURL])
    }

    @objc private func openHotkeySettings() {
        if hotkeySettings == nil {
            hotkeySettings = HotkeySettingsController(
                configURL: HotkeyCenter.configURL,
                suspendHotkeys: { [weak self] in self?.hotkeys.suspendForRecording() ?? [] },
                resumeHotkeys: { [weak self] in self?.hotkeys.resumeAfterRecording() ?? [] }
            ) { [weak self] in
                self?.hotkeys.reload() ?? []
            }
        }
        hotkeySettings?.present()
    }

    private func updateSaveStatus() {
        let failed = manager.saveFailure != nil
        saveStatusMenuItem?.isHidden = !failed
        saveStatusMenuItem?.title = manager.canRetrySave ? L10n.text(.saveFailedMenu) : L10n.text(.saveStoppedMenu)
        statusItem?.button?.image = failed
            ? NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: L10n.text(.saveErrorAccessibility))
            : StatusBarIcon.image
        statusItem?.button?.toolTip = failed ? L10n.text(.saveErrorTooltip) : "TabDesk"
    }

    @objc private func showSaveFailure() {
        guard let failure = manager.saveFailure else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text(.saveErrorTitle)
        alert.informativeText = L10n.text(.saveLocation, failure, manager.store.fileURL.path)
        alert.addButton(withTitle: L10n.text(.close))
        alert.addButton(withTitle: L10n.text(.openSaveFolder))
        if manager.canRetrySave { alert.addButton(withTitle: L10n.text(.retry)) }
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(manager.store.fileURL.deletingLastPathComponent())
        case .alertThirdButtonReturn:
            _ = manager.saveNow()
        default:
            break
        }
    }

    @objc private func reloadHotkeys() {
        let errors = hotkeys.reload()
        if !errors.isEmpty {
            let alert = NSAlert()
            alert.messageText = L10n.text(.hotkeyApplyError)
            alert.informativeText = errors.joined(separator: "\n")
            alert.runModal()
        }
    }

    @objc private func showSidebar() {
        sidebars?.rebuild()
        sidebars?.orderFrontAll()
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(logger.fileURL)
    }

    @objc private func showWindowRecovery() {
        presentWindowRecovery()
    }

    private func presentWindowRecovery(status: String? = nil) {
        guard !manager.isTerminating else { return }
        let alert = WindowRecoveryGuide.alert(status: status)
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn { showSidebar() }
    }

    @objc private func retryWindowSearch() {
        guard !manager.isTerminating, recoverySearchTask == nil else { return }
        guard manager.isTrusted else {
            presentWindowRecovery(status: L10n.text(.recoveryPermissionRequired))
            return
        }
        recoverySearchTask = Task { [weak self] in
            guard let self else { return }
            defer { self.recoverySearchTask = nil }
            // 手動でも稼働中の厳格照合を使い、曖昧な窓は利用者による割り当てに残す。
            let remaining = await self.manager.restoreUnboundWindows(strictness: .strict)
            self.presentWindowRecovery(status: L10n.text(.recoverySearchResult, remaining))
        }
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
            guard let name else {
                guard let displayID = manager.selectedDisplayID() else { return engine.state.activeTab }
                guard let activeID = engine.activeTabID(on: displayID) else { return nil }
                return engine.state.tab(withID: activeID)
            }
            return engine.state.tabs.first { $0.name == name }
        }

        switch command {
        case "status":
            let s = engine.state
            let unbound = s.allWindows.filter { !$0.isBound }
            // v4: アクティブは画面ごと。"name@display" 形式で列挙する。
            let actives = s.activeTabIDs
                .map { key, id in "\(s.tab(withID: id)?.name ?? "?")@\(key)" }
                .sorted()
            logger.log("status: trusted=\(manager.isTrusted) tabs=\(s.tabs.map { "\($0.name)(\($0.windows.count))" }) " +
                "actives=\(actives) parked=\(engine.parkedWindowIDs.count) unbound=\(unbound.count) " +
                "layoutSuspended=\(engine.layoutSuspendedWindowIDs.count) edit=\(engine.editMode) state=\(manager.store.fileURL.path)")
            for w in unbound {
                logger.log("  unbound: \(w.identity.appName) | \(w.identity.title) id=\(w.id)")
            }
        case "windows":
            // fs / min は除外実装の実測用に生値を出す(fs=nil は属性なし。docs/04_v2_design.md)。
            Task { [manager, logger] in
                for record in await manager.availableWindows() {
                    logger.log("  ref=\(record.window.windowID) pid=\(record.window.pid) " +
                        "layoutSuspended=\(record.layoutSuspension.map(String.init) ?? "nil") min=\(record.isMinimized) " +
                        "\(record.appName) | \(record.title)")
                }
            }
        case "tab":
            // v4: display=<layout.displays の index> で作成先を指定できる。省略時は選択中の画面。
            let displayID: DisplayID?
            if let indexText = q["display"] {
                guard let index = Int(indexText), manager.layout.displays.indices.contains(index) else {
                    logger.log("url: tab: invalid display index \(indexText)")
                    return
                }
                displayID = manager.layout.displays[index].id
            } else {
                displayID = manager.selectedDisplayID()
            }
            if let name = q["name"] {
                engine.createTab(name: name, on: displayID, layout: .tiled)
            } else {
                engine.createTab(on: displayID)
            }
        case "add":
            let reference = WindowReferenceID(uuidString: q["ref"] ?? "")
            let number = CGWindowID(q["wid"] ?? "")
            guard (reference != nil || number != nil), let target = tab(named: q["tab"]) else {
                logger.log("url: add needs ref=<runtime UUID> or wid=<OS window number> [&tab=name]")
                return
            }
            Task { [manager, logger] in
                let records = await manager.availableWindows()
                let matches = await BlockingExecutor().run {
                    records.filter { record in
                        if let reference { return record.window.windowID == reference }
                        return WindowServerMatch.windowNumber(for: record.window) == number
                    }
                }
                guard matches.count == 1, let record = matches.first else {
                    logger.log("url: add: target unavailable or ambiguous; use ref from windows")
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
            let reference = WindowReferenceID(uuidString: q["ref"] ?? "")
            let number = CGWindowID(q["wid"] ?? "")
            guard reference != nil || number != nil else {
                logger.log("url: remove needs ref=<runtime UUID> or wid=<OS window number>")
                return
            }
            Task { [manager, logger] in
                var matches: [WindowReferenceID] = []
                if let reference { matches = [reference] }
                else {
                    for id in manager.engine.state.allWindows.compactMap(\.windowID) {
                        if await manager.cgWindowID(for: id) == number { matches.append(id) }
                    }
                }
                guard matches.count == 1, let id = matches.first,
                      let found = manager.engine.state.managedWindow(forWindowID: id) else {
                    logger.log("url: remove: target unavailable or ambiguous; use ref from dump")
                    return
                }
                do { try await manager.unregister(found.window.id) } catch { logger.log("remove failed: \(error)") }
            }
        case "edit":
            manager.setEditMode((q["on"] ?? "1") != "0")
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
            for display in manager.layout.displays {
                if let panel = sidebars?.panel(for: display.id) {
                    logger.log("sidebar[\(display.id)]: cocoa=\(panel.frame) " +
                        "cg=\(cgBounds(CGWindowID(panel.windowNumber)).map { "\($0)" } ?? "?")")
                }
            }
            for display in manager.layout.displays {
                logger.log("display \(display.id): frame(AX)=\(display.frame) content=\(display.contentArea) park=\(display.parkPoint)")
            }
            for window in engine.state.allWindows {
                guard let wid = window.windowID else { continue }
                let ax = (try? manager.currentFrame(of: wid)).map { "\($0)" } ?? "?"
                logger.log("window \(window.identity.appName) ref=\(wid): recorded=\(window.frame) ax=\(ax) " +
                    "display=\(window.displayID ?? "primary")")
            }
        default:
            logger.log("url: unknown command '\(command)'")
        }
    }
}
