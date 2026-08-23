import AppKit
import TabDeskCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = FileLogger(directoryName: "TabDesk", fileName: "tabdesk.log")
    private lazy var manager = WindowManager(logger: logger)
    private var sidebar: SidebarPanel?
    private var statusItem: NSStatusItem?
    private var probeWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.log("TabDesk started. log: \(logger.fileURL.path) trusted=\(manager.isTrusted)")
        // メニューの「常に最前面」表示はサイドバーの実状態から作るので、サイドバーを先に用意する。
        let panel = SidebarPanel(manager: manager, logger: logger)
        sidebar = panel
        installStatusItem(alwaysOnTop: panel.alwaysOnTop)
        panel.orderFrontRegardless()
        logger.log("sidebar shown at \(panel.frame)")
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
        termination.requestTermination()
        return .terminateLater
    }

    /// tabdesk://... で届いたコマンド(動作確認・自動化用)。
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handle(url: url)
        }
    }

    // MARK: - メニューバー

    private func installStatusItem(alwaysOnTop: Bool) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "TabDesk")
        let menu = NSMenu()
        menu.addItem(withTitle: "サイドバーを表示", action: #selector(showSidebar), keyEquivalent: "")
        let onTop = NSMenuItem(title: "サイドバーを常に最前面にする", action: #selector(toggleAlwaysOnTop(_:)), keyEquivalent: "")
        onTop.state = alwaysOnTop ? .on : .off
        menu.addItem(onTop)
        menu.addItem(withTitle: "アクセシビリティ設定を開く", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        menu.addItem(withTitle: "ログを開く", action: #selector(openLog), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "TabDesk を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for menuItem in menu.items where menuItem.action != #selector(NSApplication.terminate(_:)) {
            menuItem.target = self
        }
        item.menu = menu
        statusItem = item
    }

    @objc private func toggleAlwaysOnTop(_ sender: NSMenuItem) {
        guard let sidebar else { return }
        sidebar.alwaysOnTop.toggle()
        sender.state = sidebar.alwaysOnTop ? .on : .off
        logger.log("alwaysOnTop=\(sidebar.alwaysOnTop)")
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
            let info = list.first, let dict = info[kCGWindowBounds as String]
        else { return nil }
        return CGRect(dictionaryRepresentation: dict as! CFDictionary)
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
                "edit=\(engine.editMode) state=\(manager.store.fileURL.path)")
            for w in unbound {
                logger.log("  unbound: \(w.identity.appName) | \(w.identity.title) id=\(w.id)")
            }
        case "windows":
            Task { [manager, logger] in
                for record in await manager.availableWindows() {
                    logger.log("  wid=\(record.window.windowID) pid=\(record.window.pid) \(record.appName) | \(record.title)")
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
            Task { [logger] in
                do { try await engine.activate(target.id) } catch { logger.log("activate failed: \(error)") }
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
            manager.saveNow()
            logger.log("saved to \(manager.store.fileURL.path)")
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
                logger.log("screen '\(screen.localizedName)': frame=\(screen.frame) visible=\(screen.visibleFrame) scale=\(screen.backingScaleFactor)")
            }
            if let sidebar {
                logger.log("sidebar: cocoa=\(sidebar.frame) cg=\(cgBounds(CGWindowID(sidebar.windowNumber)).map { "\($0)" } ?? "?")")
            }
            logger.log("contentArea(AX)=\(manager.layout.contentArea) park=\(manager.layout.parkPoint)")
            for window in engine.state.allWindows {
                guard let wid = window.windowID else { continue }
                let ax = (try? manager.currentFrame(of: wid)).map { "\($0)" } ?? "?"
                let cg = cgBounds(wid).map { "\($0)" } ?? "?"
                logger.log("window \(window.identity.appName) wid=\(wid): recorded=\(window.frame) ax=\(ax) cg=\(cg)")
            }
        default:
            logger.log("url: unknown command '\(command)'")
        }
    }
}
