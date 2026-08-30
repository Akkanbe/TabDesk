import AppKit
import TabDeskCore

enum SidebarText {
    static func windowTitle(appName: String, title: String) -> String {
        title.isEmpty ? appName : "\(appName) — \(title)"
    }
}

/// タブ 1 行。クリックで切替、ダブルクリックで改名(ダイアログ)、右クリックでメニュー。
@MainActor
final class TabRowView: NSView {
    var onSelect: (() -> Void)?
    var onRenameRequested: (() -> Void)?
    var onDelete: (() -> Void)?
    /// 並べ替え(-1 = 上へ、+1 = 下へ)。
    var onMove: ((Int) -> Void)?
    var onSetLayout: ((TabLayout) -> Void)?

    private let tab: Tab
    private let canMoveUp: Bool
    private let canMoveDown: Bool

    /// キーでないウィンドウへの最初のクリックも受け取る(既定では「キーにするためのクリック」として消費される)。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(tab: Tab, isActive: Bool, canMoveUp: Bool, canMoveDown: Bool) {
        self.tab = tab
        self.canMoveUp = canMoveUp
        self.canMoveDown = canMoveDown
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = isActive ? NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor : nil

        let label = NSTextField(labelWithString: tab.name)
        label.font = NSFont.systemFont(ofSize: 13, weight: isActive ? .semibold : .regular)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        // 端のタブでは移動項目を無効化する(自動 enable は端の判定を知らないので手動制御)。
        menu.autoenablesItems = false
        let up = menu.addItem(withTitle: "上へ移動", action: #selector(moveUpAction), keyEquivalent: "")
        up.target = self
        up.isEnabled = canMoveUp
        let down = menu.addItem(withTitle: "下へ移動", action: #selector(moveDownAction), keyEquivalent: "")
        down.target = self
        down.isEnabled = canMoveDown
        menu.addItem(.separator())
        // レイアウト切替。現在値にチェックを付ける(仕様 §3.1: タブごとに自由配置/タイルを選択)。
        let free = menu.addItem(withTitle: "レイアウト: 自由配置", action: #selector(layoutFreeAction), keyEquivalent: "")
        free.target = self
        free.state = tab.layout == .free ? .on : .off
        let columns = menu.addItem(withTitle: "レイアウト: 縦に等分割", action: #selector(layoutColumnsAction), keyEquivalent: "")
        columns.target = self
        columns.state = tab.layout == .columns ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "名前を変更", action: #selector(renameAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "タブを削除", action: #selector(deleteAction), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func renameAction() { onRenameRequested?() }
    @objc private func deleteAction() { onDelete?() }
    @objc private func moveUpAction() { onMove?(-1) }
    @objc private func moveDownAction() { onMove?(1) }
    @objc private func layoutFreeAction() { onSetLayout?(.free) }
    @objc private func layoutColumnsAction() { onSetLayout?(.columns) }
}

/// 登録ウィンドウ 1 行。未復元(実ウィンドウに紐付いていない)ならグレー表示し、クリックで割り当てメニューを出す。
@MainActor
final class WindowRowView: NSView {
    var onRemove: (() -> Void)?
    var onAssignRequested: (() -> Void)?
    /// 並べ替え(-1 = 上へ、+1 = 下へ)。columns レイアウトの列順を兼ねる。
    var onMove: ((Int) -> Void)?

    private let isBound: Bool
    private let canMoveUp: Bool
    private let canMoveDown: Bool

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(window: ManagedWindow, canMoveUp: Bool, canMoveDown: Bool) {
        isBound = window.isBound
        self.canMoveUp = canMoveUp
        self.canMoveDown = canMoveDown
        super.init(frame: .zero)
        let title = SidebarText.windowTitle(appName: window.identity.appName, title: window.identity.title)
        let label = NSTextField(labelWithString: isBound ? title : "\(title)(未復元)")
        label.font = NSFont.systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingTail
        // 幅が足りなければ末尾省略で縮む(サイドバーを押し広げない)。
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.textColor = isBound ? .labelColor : .secondaryLabelColor
        label.toolTip = isBound ? title : "\(title)\nクリックして、いま開いているウィンドウを割り当てます"
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

    override func mouseDown(with event: NSEvent) {
        if !isBound {
            onAssignRequested?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.autoenablesItems = false  // 端の行では移動項目を無効化する(TabRowView と同じ手動制御)
        let up = menu.addItem(withTitle: "上へ移動", action: #selector(moveUpAction), keyEquivalent: "")
        up.target = self
        up.isEnabled = canMoveUp
        let down = menu.addItem(withTitle: "下へ移動", action: #selector(moveDownAction), keyEquivalent: "")
        down.target = self
        down.isEnabled = canMoveDown
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func removeAction() { onRemove?() }
    @objc private func moveUpAction() { onMove?(-1) }
    @objc private func moveDownAction() { onMove?(1) }
}
