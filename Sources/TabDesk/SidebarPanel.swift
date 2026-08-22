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
    private let tabsStack = NSStackView()
    private let windowsHeader = NSTextField(labelWithString: "")
    private let windowsStack = NSStackView()
    private let addWindowButton = NSButton(title: "＋ ウィンドウを追加", target: nil, action: nil)
    private let editModeCheck = NSButton(checkboxWithTitle: "編集モード(動かした位置を記憶)", target: nil, action: nil)
    private var permissionTimer: Timer?

    static let alwaysOnTopDefaultsKey = "SidebarAlwaysOnTop"

    /// true: 常に最前面(他の窓に隠れない)。false: 通常の窓と同じ階層(隠れることがある。メニューバーから再表示)。
    var alwaysOnTop: Bool {
        didSet {
            level = alwaysOnTop ? .floating : .normal
            UserDefaults.standard.set(alwaysOnTop, forKey: Self.alwaysOnTopDefaultsKey)
            if alwaysOnTop { orderFrontRegardless() }
        }
    }

    init(manager: WindowManager, logger: FileLogger) {
        self.manager = manager
        self.logger = logger
        UserDefaults.standard.register(defaults: [Self.alwaysOnTopDefaultsKey: true])
        self.alwaysOnTop = UserDefaults.standard.bool(forKey: Self.alwaysOnTopDefaultsKey)
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: WindowManager.sidebarWidth, height: 600),
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
        reposition()

        manager.engine.onStateChanged = { [weak self] _ in self?.render() }
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
        setFrame(NSRect(x: visible.minX, y: visible.minY, width: WindowManager.sidebarWidth, height: visible.height), display: true)
    }

    @objc private func screenParametersChanged() {
        reposition()
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
        background.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: background.topAnchor),
            root.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: background.bottomAnchor),
        ])

        // ヘッダ
        let title = NSTextField(labelWithString: "TabDesk")
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let addTab = NSButton(title: "＋", target: self, action: #selector(addTab))
        addTab.bezelStyle = .inline
        addTab.toolTip = "タブを追加"
        let header = NSStackView(views: [title, NSView(), addTab])
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
        for tab in state.tabs {
            let row = TabRowView(tab: tab, isActive: tab.id == state.activeTabID)
            row.onSelect = { [weak self] in self?.activate(tab.id) }
            row.onRenameRequested = { [weak self] in self?.promptRename(tab) }
            row.onDelete = { [weak self] in self?.delete(tab.id) }
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
            for window in active.windows {
                let row = WindowRowView(window: window)
                row.onRemove = { [weak self] in self?.unregister(window.id) }
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
        let menu = NSMenu()
        let candidates = manager.availableWindows()
        if candidates.isEmpty {
            menu.addItem(withTitle: "登録できるウィンドウがありません", action: nil, keyEquivalent: "")
        }
        for record in candidates {
            let title = record.title.isEmpty ? record.appName : "\(record.appName) — \(record.title)"
            let item = NSMenuItem(title: String(title.prefix(60)), action: #selector(addWindow(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = WindowRecordBox(record)
            menu.addItem(item)
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

    private func activate(_ tabID: UUID) {
        Task { [manager, logger] in
            do {
                try await manager.engine.activate(tabID)
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

    private func delete(_ tabID: UUID) {
        Task { [manager, logger] in
            do {
                try await manager.engine.deleteTab(tabID)
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

/// NSMenuItem.representedObject に載せるための箱(WindowRecord は struct なので)。
private final class WindowRecordBox: NSObject {
    let record: WindowRecord
    init(_ record: WindowRecord) { self.record = record }
}

// MARK: - 行ビュー

/// タブ 1 行。クリックで切替、ダブルクリックで改名(ダイアログ)、右クリックでメニュー。
@MainActor
final class TabRowView: NSView {
    var onSelect: (() -> Void)?
    var onRenameRequested: (() -> Void)?
    var onDelete: (() -> Void)?

    private let tab: Tab

    /// キーでないウィンドウへの最初のクリックも受け取る(既定では「キーにするためのクリック」として消費される)。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(tab: Tab, isActive: Bool) {
        self.tab = tab
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = isActive ? NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor : nil

        let label = NSTextField(labelWithString: tab.name)
        label.font = NSFont.systemFont(ofSize: 13, weight: isActive ? .semibold : .regular)
        label.lineBreakMode = .byTruncatingTail
        let count = NSTextField(labelWithString: "\(tab.windows.count)")
        count.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [label, NSView(), count])
        stack.orientation = .horizontal
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onRenameRequested?()
        } else {
            onSelect?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "名前を変更", action: #selector(renameAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "タブを削除", action: #selector(deleteAction), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func renameAction() { onRenameRequested?() }
    @objc private func deleteAction() { onDelete?() }
}

/// 登録ウィンドウ 1 行。
@MainActor
final class WindowRowView: NSView {
    var onRemove: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(window: ManagedWindow) {
        super.init(frame: .zero)
        let title = window.identity.title.isEmpty ? window.identity.appName : "\(window.identity.appName) — \(window.identity.title)"
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = title
        let remove = NSButton(title: "×", target: self, action: #selector(removeAction))
        remove.bezelStyle = .inline
        remove.isBordered = false
        remove.toolTip = "登録を解除"
        let stack = NSStackView(views: [label, NSView(), remove])
        stack.orientation = .horizontal
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func removeAction() { onRemove?() }
}
