import AppKit
import TabDeskCore

/// 画面左端に常駐するサイドバー。
///
/// `.nonactivatingPanel` にしているので、タブをクリックしても TabDesk がアクティブにならず、
/// 作業中のアプリのキー入力を奪わない(名前の編集時だけキーウィンドウになる)。
@MainActor
final class SidebarPanel: NSPanel {
    private let manager: WindowManager
    private let logger: FileLogger

    private let permissionBanner = NSStackView()
    private let capturePermissionBanner = NSStackView()
    private let tabsStack = NSStackView()
    private let windowsHeader = NSTextField(labelWithString: "")
    private let windowsStack = NSStackView()
    private let addWindowButton = NSButton(title: "＋ ウィンドウを追加", target: nil, action: nil)
    private let editModeCheck = NSButton(checkboxWithTitle: "編集モード(動かした位置を記憶)", target: nil, action: nil)
    private var permissionTimer: Timer?
    /// 幅を変えられるように保持する(v3 段階 3。生成時の activate だけだと変更できない)。
    private var widthConstraint: NSLayoutConstraint?
    private var scrollView: NSScrollView?
    private var resizeHandle: SidebarResizeHandle?
    private var expandButton: NSButton?

    /// 「常に最前面」設定。既定 true。メニューとパネルはこの値を唯一の真実として同期する。
    static let alwaysOnTopSetting = PersistedToggle(key: "SidebarAlwaysOnTop", defaultValue: true)

    /// true: 常に最前面(他の窓に隠れない)。false: 通常の窓と同じ階層(隠れることがある。メニューバーから再表示)。
    var alwaysOnTop: Bool {
        didSet {
            level = alwaysOnTop ? .floating : .normal
            Self.alwaysOnTopSetting.value = alwaysOnTop
            if alwaysOnTop { orderFrontRegardless() }
        }
    }

    init(manager: WindowManager, logger: FileLogger) {
        self.manager = manager
        self.logger = logger
        self.alwaysOnTop = Self.alwaysOnTopSetting.value
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: manager.sidebarMetrics.effectiveWidth, height: 600),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false)
        level = alwaysOnTop ? .floating : .normal
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        // borderless パネルはキーウィンドウになれない = クリックしても作業中アプリのキー入力を奪わない。
        // 文字入力が必要な操作(改名)はダイアログで行う。
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        hasShadow = true
        contentView = buildContent()
        applyCollapsedAppearance()  // 前回終了時の折りたたみ状態を復元
        reposition()

        manager.onStateChanged = { [weak self] _ in self?.render() }
        // サムネイルは state 外のデータなので、撮影完了時は差分キャッシュを捨てて描き直す。
        manager.thumbnails.onUpdated = { [weak self] _ in
            self?.lastRendered = nil
            self?.render()
        }
        // 改名中に切替先アプリを前面化するとサイドバーがキーを失い、編集が即終了してしまう。
        manager.suppressAppActivation = { [weak self] in self?.isRenaming ?? false }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePermissionBanner() }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        render()
        updatePermissionBanner()
    }

    // MARK: - 配置

    func reposition() {
        guard let screen = ScreenGeometry.primaryScreen else { return }
        let visible = screen.visibleFrame
        setFrame(
            NSRect(x: visible.minX, y: visible.minY,
                width: manager.sidebarMetrics.effectiveWidth, height: visible.height),
            display: true)
    }

    @objc private func screenParametersChanged() {
        reposition()
        // 「(別ディスプレイ待機)」表示は state 外(接続中ディスプレイ集合)に依存するので、
        // 画面構成が変わったら差分キャッシュを捨てて描き直す。
        lastRendered = nil
        render()
    }

    // MARK: - 幅変更・折りたたみ(v3 段階 3)

    /// ドラッグ中のライブリサイズ(パネルと制約のみ動かす。窓のリフローは commit 時にまとめて)。
    /// ドラッグ中にホットキーで折りたたまれた場合は無視する(畳んだ 16px を広げ直さない)。
    private func previewResize(to width: CGFloat) {
        guard !manager.sidebarMetrics.isCollapsed else { return }
        let clamped = min(max(width, SidebarMetrics.minWidth), SidebarMetrics.maxWidth)
        widthConstraint?.constant = clamped
        var f = frame
        f.size.width = clamped
        setFrame(f, display: true)
    }

    /// ドラッグ終了: 幅を保存し、コンテンツ領域(窓の配置範囲)を追従させる。
    /// ドラッグ中に折りたたまれていたら保存しない(mouseUp は隠れたハンドルにも届くため、
    /// ここで frame.width=16 を保存すると設定済みの展開幅が minWidth に化ける)。
    private func commitResize() {
        guard !manager.sidebarMetrics.isCollapsed else { return }
        manager.sidebarMetrics.expandedWidth = frame.width
        widthConstraint?.constant = manager.sidebarMetrics.effectiveWidth
        reposition()
        manager.applySidebarWidthChange()
        logger.log("sidebarWidth=\(Int(manager.sidebarMetrics.expandedWidth))")
    }

    /// 折りたたみ切替(ヘッダの「«」/ 細いバーのクリック / ホットキー / メニュー共通の入口)。
    func toggleCollapse() {
        manager.sidebarMetrics.isCollapsed.toggle()
        applyCollapsedAppearance()
        reposition()
        manager.applySidebarWidthChange()
        logger.log("sidebarCollapsed=\(manager.sidebarMetrics.isCollapsed)")
    }

    @objc private func toggleCollapseAction() { toggleCollapse() }

    /// 折りたたみ状態を見た目へ反映する。render() の state 差分とは独立に扱う
    /// (state が変わらなくても折りたたみは切り替わるため)。
    private func applyCollapsedAppearance() {
        let collapsed = manager.sidebarMetrics.isCollapsed
        scrollView?.isHidden = collapsed
        resizeHandle?.isHidden = collapsed
        expandButton?.isHidden = !collapsed
        widthConstraint?.constant = manager.sidebarMetrics.effectiveWidth
    }

    // MARK: - UI 構築

    private func buildContent() -> NSView {
        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        background.state = .active

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 6
        root.edgeInsets = NSEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        root.translatesAutoresizingMaskIntoConstraints = false

        // タブ・窓が増えても下部の操作に届くよう、内容全体を縦スクロールに入れる。
        // NSClipView は既定で非 flipped(内容が短いと下寄せになる)ので flipped な ClipView を使う。
        // 長いタイトルの行が Auto Layout 経由でパネルごと広げないよう、幅を固定する。
        background.translatesAutoresizingMaskIntoConstraints = false
        let width = background.widthAnchor.constraint(equalToConstant: manager.sidebarMetrics.effectiveWidth)
        width.isActive = true
        widthConstraint = width

        let scroll = NSScrollView()
        scroll.contentView = FlippedClipView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = root
        scroll.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: background.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            root.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            root.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            root.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        scrollView = scroll

        // 右端のリサイズハンドル(スクロールの上に重ねる。v3 段階 3)。
        let handle = SidebarResizeHandle()
        handle.onDrag = { [weak self] width in self?.previewResize(to: width) }
        handle.onCommit = { [weak self] in self?.commitResize() }
        handle.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(handle)
        NSLayoutConstraint.activate([
            handle.topAnchor.constraint(equalTo: background.topAnchor),
            handle.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            handle.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            handle.widthAnchor.constraint(equalToConstant: 8),
        ])
        resizeHandle = handle

        // 折りたたみ中の展開つまみ(細いバー全体がクリック領域)。
        let expand = NSButton(title: "»", target: self, action: #selector(toggleCollapseAction))
        expand.bezelStyle = .inline
        expand.isBordered = false
        expand.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        expand.toolTip = "サイドバーを展開"
        expand.setAccessibilityLabel("サイドバーを展開")
        expand.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(expand)
        NSLayoutConstraint.activate([
            expand.topAnchor.constraint(equalTo: background.topAnchor),
            expand.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            expand.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            expand.trailingAnchor.constraint(equalTo: background.trailingAnchor),
        ])
        expandButton = expand

        // ヘッダ
        let title = NSTextField(labelWithString: "TabDesk")
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let collapse = NSButton(title: "«", target: self, action: #selector(toggleCollapseAction))
        collapse.bezelStyle = .inline
        collapse.toolTip = "サイドバーを折りたたむ"
        collapse.setAccessibilityLabel("サイドバーを折りたたむ")
        let addTab = NSButton(title: "＋", target: self, action: #selector(addTab))
        addTab.bezelStyle = .inline
        addTab.toolTip = "タブを追加"
        let header = NSStackView(views: [title, NSView(), collapse, addTab])
        header.orientation = .horizontal
        root.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -20).isActive = true

        // 権限バナー
        let bannerLabel = NSTextField(wrappingLabelWithString: "アクセシビリティ権限が必要です。システム設定で TabDesk を ON にしてください。")
        bannerLabel.font = NSFont.systemFont(ofSize: 11)
        let bannerButton = NSButton(title: "権限をリクエスト", target: self, action: #selector(requestPermission))
        bannerButton.bezelStyle = .rounded
        bannerButton.controlSize = .small
        permissionBanner.orientation = .vertical
        permissionBanner.alignment = .leading
        permissionBanner.addArrangedSubview(bannerLabel)
        permissionBanner.addArrangedSubview(bannerButton)
        root.addArrangedSubview(permissionBanner)
        bannerLabel.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -20).isActive = true

        // 画面収録権限バナー(タブサムネイル有効時のみ。v3 段階 5)
        let captureLabel = NSTextField(wrappingLabelWithString:
            "タブサムネイルには画面収録の権限が必要です(付与後は TabDesk の再起動が必要な場合があります)。")
        captureLabel.font = NSFont.systemFont(ofSize: 11)
        let captureButton = NSButton(title: "画面収録設定を開く", target: self, action: #selector(openScreenCaptureSettings))
        captureButton.bezelStyle = .rounded
        captureButton.controlSize = .small
        capturePermissionBanner.orientation = .vertical
        capturePermissionBanner.alignment = .leading
        capturePermissionBanner.addArrangedSubview(captureLabel)
        capturePermissionBanner.addArrangedSubview(captureButton)
        root.addArrangedSubview(capturePermissionBanner)
        captureLabel.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -20).isActive = true

        // タブ一覧
        tabsStack.orientation = .vertical
        tabsStack.alignment = .leading
        tabsStack.spacing = 2
        root.addArrangedSubview(tabsStack)
        tabsStack.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -20).isActive = true

        addSeparator(to: root)

        // アクティブタブのウィンドウ
        windowsHeader.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        windowsHeader.textColor = .secondaryLabelColor
        root.addArrangedSubview(windowsHeader)
        windowsStack.orientation = .vertical
        windowsStack.alignment = .leading
        windowsStack.spacing = 2
        root.addArrangedSubview(windowsStack)
        windowsStack.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -20).isActive = true

        addWindowButton.target = self
        addWindowButton.action = #selector(showAddWindowMenu(_:))
        addWindowButton.bezelStyle = .rounded
        addWindowButton.controlSize = .small
        root.addArrangedSubview(addWindowButton)

        addSeparator(to: root)

        editModeCheck.target = self
        editModeCheck.action = #selector(toggleEditMode)
        editModeCheck.font = NSFont.systemFont(ofSize: 11)
        root.addArrangedSubview(editModeCheck)

        return background
    }

    /// 区切り線を root に追加してから幅制約を張る。
    /// 階層に入れる前に制約を activate すると共通祖先が無く NSGenericException になる(順序が重要)。
    private func addSeparator(to root: NSStackView) {
        let box = NSBox()
        box.boxType = .separator
        root.addArrangedSubview(box)
        box.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -20).isActive = true
    }

    // MARK: - 描画

    private var lastRendered: (state: WorkspaceState, editMode: Bool)?
    /// 改名ダイアログを表示中か(この間は切替先アプリの前面化を抑止する)。
    private(set) var isRenaming = false

    func render() {
        let state = manager.engine.state
        // エンジンの state は同じ値でも didSet が発火する。見た目が変わらないなら行を作り直さない
        // (ダブルクリックの 2 回目が作り直し直後の行に届き、レイアウト前で編集欄が出ない事故を防ぐ)。
        if let last = lastRendered, last.state == state, last.editMode == manager.engine.editMode {
            return
        }
        lastRendered = (state, manager.engine.editMode)
        tabsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, tab) in state.tabs.enumerated() {
            let row = TabRowView(
                tab: tab, isActive: tab.id == state.activeTabID,
                canMoveUp: index > 0, canMoveDown: index < state.tabs.count - 1,
                thumbnail: ThumbnailStore.enabledSetting.value ? manager.thumbnails.images[tab.id] : nil)
            row.onSelect = { [weak self] in self?.activate(tab.id) }
            row.onRenameRequested = { [weak self] in self?.promptRename(tab) }
            row.onDelete = { [weak self] in self?.delete(tab.id) }
            row.onMove = { [weak self] offset in self?.moveTab(tab.id, offset: offset) }
            row.onSetLayout = { [weak self] layout in self?.setLayout(tab.id, layout) }
            tabsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: tabsStack.widthAnchor).isActive = true
        }
        if state.tabs.isEmpty {
            let hint = NSTextField(labelWithString: "「＋」でタブを作成")
            hint.textColor = .secondaryLabelColor
            hint.font = NSFont.systemFont(ofSize: 11)
            tabsStack.addArrangedSubview(hint)
        }

        windowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let active = state.activeTab {
            windowsHeader.stringValue = "\(active.name) のウィンドウ(\(active.windows.count))"
                + (active.layout == .columns ? " — 縦に等分割" : "")
            // 切断退避(displayID があるのに接続中の画面に無い)を行の表示に反映する。
            let connected = Set(manager.layout.displays.map(\.id))
            for (index, window) in active.windows.enumerated() {
                let row = WindowRowView(
                    window: window,
                    canMoveUp: index > 0, canMoveDown: index < active.windows.count - 1,
                    isDisplayDisconnected: window.displayID.map { !connected.contains($0) } ?? false)
                row.onRemove = { [weak self] in self?.unregister(window.id) }
                row.onMove = { [weak self] offset in self?.moveWindow(window.id, offset: offset) }
                row.onAssignRequested = { [weak self, weak row] in
                    guard let self, let row else { return }
                    self.showAssignMenu(for: window, anchor: row)
                }
                windowsStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: windowsStack.widthAnchor).isActive = true
            }
            addWindowButton.isEnabled = true
        } else {
            windowsHeader.stringValue = "タブがありません"
            addWindowButton.isEnabled = false
        }
        editModeCheck.state = manager.engine.editMode ? .on : .off
    }

    private func updatePermissionBanner() {
        permissionBanner.isHidden = manager.isTrusted
        capturePermissionBanner.isHidden = !(ThumbnailStore.enabledSetting.value && !ThumbnailStore.hasPermission)
    }

    /// メニューでサムネイル表示を切り替えたあとに呼ぶ(行の作り直しとバナー更新)。
    func refreshThumbnailPresentation() {
        lastRendered = nil
        render()
        updatePermissionBanner()
    }

    @objc private func openScreenCaptureSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - アクション

    @objc private func requestPermission() {
        manager.requestPermission()
    }

    @objc private func addTab() {
        let count = manager.engine.state.tabs.count + 1
        manager.engine.createTab(name: "タブ\(count)")
    }

    @objc private func toggleEditMode() {
        manager.engine.editMode = editModeCheck.state == .on
        logger.log("editMode=\(manager.engine.editMode)")
    }

    @objc private func showAddWindowMenu(_ sender: NSButton) {
        // 列挙は全アプリへの IPC なのでバックグラウンドで行い、終わってからメニューを出す。
        guard sender.isEnabled else { return }
        let originalTitle = sender.title
        sender.isEnabled = false
        sender.title = "読み込み中…"
        Task { [weak self, weak sender] in
            guard let self else { return }
            let (candidates, unavailable) = await self.manager.availableWindowsAndIssues()
            guard let sender else { return }
            sender.title = originalTitle
            sender.isEnabled = self.manager.engine.state.activeTabID != nil
            self.presentAddWindowMenu(candidates, unavailableApps: unavailable, anchor: sender)
        }
    }

    private func presentAddWindowMenu(_ candidates: [WindowRecord], unavailableApps: [String], anchor sender: NSView) {
        let menu = NSMenu()
        if candidates.isEmpty {
            menu.addItem(withTitle: "登録できるウィンドウがありません", action: nil, keyEquivalent: "")
        }
        for record in candidates {
            let title = SidebarText.windowTitle(appName: record.appName, title: record.title)
            let item = NSMenuItem(title: String(title.prefix(60)), action: #selector(addWindow(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = WindowRecordBox(record)
            menu.addItem(item)
        }
        if !unavailableApps.isEmpty {
            menu.addItem(.separator())
            // AX を拒否するアプリは理由つきでグレー表示する(仕様 §3.3、段階 3)。
            for detail in unavailableApps {
                let item = NSMenuItem(title: "管理不可: \(String(detail.prefix(60)))", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func addWindow(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? WindowRecordBox,
            let tabID = manager.engine.state.activeTabID
        else { return }
        Task { [manager, logger] in
            do {
                try await manager.register(box.record, into: tabID)
            } catch {
                logger.log("register failed: \(error)")
            }
        }
    }

    /// 未復元エントリに窓を手で割り当てる。同じアプリの窓を先に並べる。
    private func showAssignMenu(for window: ManagedWindow, anchor: NSView) {
        Task { [weak self, weak anchor] in
            guard let self else { return }
            let candidates = await self.manager.availableWindows()
            guard let anchor else { return }
            self.presentAssignMenu(candidates, for: window, anchor: anchor)
        }
    }

    private func presentAssignMenu(_ candidates: [WindowRecord], for window: ManagedWindow, anchor: NSView) {
        let menu = NSMenu()
        let sameApp = candidates.filter { $0.bundleID == window.identity.bundleID }
        let others = candidates.filter { $0.bundleID != window.identity.bundleID }
        if candidates.isEmpty {
            menu.addItem(withTitle: "割り当てできるウィンドウがありません", action: nil, keyEquivalent: "")
        }
        for (index, record) in (sameApp + others).enumerated() {
            if index == sameApp.count, !sameApp.isEmpty, !others.isEmpty {
                menu.addItem(.separator())
            }
            let title = SidebarText.windowTitle(appName: record.appName, title: record.title)
            let item = NSMenuItem(title: String(title.prefix(60)), action: #selector(assignWindow(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = AssignmentBox(record: record, managedID: window.id)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height), in: anchor)
    }

    @objc private func assignWindow(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? AssignmentBox else { return }
        Task { [manager] in await manager.bind(box.record, to: box.managedID) }
    }

    private func activate(_ tabID: UUID) {
        Task { [manager, logger] in
            do {
                try await manager.activate(tabID)  // フォーカス連動の抑止つき入口
            } catch {
                logger.log("activate failed: \(error)")
            }
        }
    }

    /// 改名ダイアログ。パネル自体はキーになれない(作業アプリの入力を奪わない)ので、
    /// 文字入力はアプリをアクティブにした上でモーダルダイアログで受け取り、終わったら元のアプリへ戻す。
    private func promptRename(_ tab: Tab) {
        let previous = NSWorkspace.shared.frontmostApplication
        isRenaming = true
        defer { isRenaming = false }

        let alert = NSAlert()
        alert.messageText = "タブ名を変更"
        alert.informativeText = "「\(tab.name)」の新しい名前を入力してください。"
        alert.addButton(withTitle: "変更")
        alert.addButton(withTitle: "キャンセル")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = tab.name
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate()
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            rename(tab.id, to: field.stringValue)
        }
        if let previous, previous != NSRunningApplication.current, !previous.isTerminated {
            previous.activate()
        }
    }

    private func rename(_ tabID: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            try manager.engine.renameTab(tabID, to: trimmed)
        } catch {
            logger.log("rename failed: \(error)")
        }
    }

    /// タブを 1 つ上/下へ移動する。index は render 時の値ではなくクリック時点で引き直す
    /// (メニュー表示中に state が変わりうるため。範囲外は Core が invalidTabOrder で弾く)。
    private func moveTab(_ tabID: UUID, offset: Int) {
        guard let index = manager.engine.state.tabs.firstIndex(where: { $0.id == tabID }) else { return }
        do {
            try manager.engine.moveTab(fromIndex: index, toIndex: index + offset)
        } catch {
            logger.log("moveTab failed: \(error)")
        }
    }

    private func setLayout(_ tabID: UUID, _ layout: TabLayout) {
        Task { [manager, logger] in
            do {
                try await manager.setTabLayout(tabID, layout)
            } catch {
                logger.log("setTabLayout failed: \(error)")
            }
        }
    }

    /// ウィンドウを一覧内で 1 つ上/下へ移動する(columns の列順)。範囲外は Core が弾く。
    private func moveWindow(_ id: UUID, offset: Int) {
        Task { [manager, logger] in
            do {
                try await manager.moveWindow(id, offset: offset)
            } catch {
                logger.log("moveWindow failed: \(error)")
            }
        }
    }

    private func delete(_ tabID: UUID) {
        Task { [manager, logger] in
            do {
                try await manager.deleteTab(tabID)  // Core 削除と AX 資源の清掃をまとめて行う
            } catch {
                logger.log("delete failed: \(error)")
            }
        }
    }

    private func unregister(_ id: UUID) {
        Task { [manager, logger] in
            do {
                try await manager.unregister(id)
            } catch {
                logger.log("unregister failed: \(error)")
            }
        }
    }
}

/// 内容を上端から並べるための ClipView(既定は下寄せ)。
private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// サイドバー右端のリサイズハンドル(v3 段階 3)。
///
/// パネルは `.nonactivatingPanel` でキーウィンドウにならないため、カーソル追跡は
/// `.activeAlways` が必須(`.activeInKeyWindow` では発火しない)。ドラッグ中は onDrag に
/// 希望幅を流し、マウスを離した時点で onCommit(幅の確定と窓のリフロー)を呼ぶ。
@MainActor
private final class SidebarResizeHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onCommit: (() -> Void)?
    /// 掴んだ点と右端の相対位置。保持しないとドラッグ開始時に最大 8px(ハンドル幅ぶん)跳ねる。
    private var grabOffset: CGFloat = 0

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // マウスドラッグだけでなく VoiceOver の増減アクションからも同じ確定経路を通す。
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityLabel() -> String? { "サイドバーの幅" }
    override func accessibilityValue() -> Any? { window?.frame.width }
    override func accessibilityMinValue() -> Any? { SidebarMetrics.minWidth }
    override func accessibilityMaxValue() -> Any? { SidebarMetrics.maxWidth }

    override func accessibilityPerformIncrement() -> Bool {
        adjustWidth(by: 16)
    }

    override func accessibilityPerformDecrement() -> Bool {
        adjustWidth(by: -16)
    }

    private func adjustWidth(by delta: CGFloat) -> Bool {
        guard let width = window?.frame.width else { return false }
        let target = min(max(width + delta, SidebarMetrics.minWidth), SidebarMetrics.maxWidth)
        guard target != width else { return false }
        onDrag?(target)
        onCommit?()
        NSAccessibility.post(element: self, notification: .valueChanged)
        return true
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.cursorUpdate, .activeAlways], owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    // イベントを受け取り、以降の mouseDragged / mouseUp がこのビューへ届くようにする
    // (responder chain へ流すとパネル移動などの既定処理に化けうる)。
    override func mouseDown(with event: NSEvent) {
        grabOffset = (window?.frame.maxX ?? 0) - NSEvent.mouseLocation.x
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        // 希望幅 = (マウスの画面 x + 掴みオフセット) − パネル左端(Cocoa 座標だが x はそのまま使える)。
        onDrag?(NSEvent.mouseLocation.x + grabOffset - window.frame.minX)
    }

    override func mouseUp(with event: NSEvent) {
        onCommit?()
        NSAccessibility.post(element: self, notification: .valueChanged)
    }
}

/// NSMenuItem.representedObject に載せるための箱(WindowRecord は struct なので)。
private final class WindowRecordBox: NSObject {
    let record: WindowRecord
    init(_ record: WindowRecord) { self.record = record }
}

private final class AssignmentBox: NSObject {
    let record: WindowRecord
    let managedID: UUID
    init(record: WindowRecord, managedID: UUID) {
        self.record = record
        self.managedID = managedID
    }
}
