import AppKit
import AXShim
import TabDeskCore

/// PoC の操作画面。ボタンはすべて PoCController のメソッドに 1 対 1 で対応する。
@MainActor
final class MainWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window: NSWindow

    private let controller: PoCController
    private let table = NSTableView()
    private let logView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var parallelCheck: NSButton!
    private var watchCheck: NSButton!
    private var editCheck: NSButton!
    private var snapModePopup: NSPopUpButton!
    private var statusTimer: Timer?

    init(controller: PoCController) {
        self.controller = controller
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        super.init()

        window.title = "TabDesk PoC (v0)"
        window.center()
        window.contentView = buildContent()

        controller.onChanged = { [weak self] in self?.reloadTable() }
        controller.logger.setSink { [weak self] line in self?.appendLog(line) }

        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatus() }
        }
        updateStatus()
    }

    // MARK: - UI 構築

    private func buildContent() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        root.addArrangedSubview(row([
            statusLabel,
            button("権限をリクエスト", #selector(requestPermission)),
            button("status をログ", #selector(logStatus)),
        ]))

        root.addArrangedSubview(row([
            button("ウィンドウ一覧を更新", #selector(refresh)),
            label("選択したウィンドウを:"),
            button("セット A に追加", #selector(addToA)),
            button("セット B に追加", #selector(addToB)),
            button("セットから外す", #selector(removeSelected)),
        ]))

        let tableScroll = makeTable()
        root.addArrangedSubview(tableScroll)

        root.addArrangedSubview(row([
            label("配置:"),
            button("左半分", #selector(placeLeft)),
            button("右半分", #selector(placeRight)),
            button("全面", #selector(placeFull)),
            label("  退避/復元:"),
            button("退避(右下隅へ)", #selector(parkSelected)),
            button("復元", #selector(restoreSelected)),
        ]))

        parallelCheck = checkbox("pid 並列", #selector(toggleParallel))
        watchCheck = checkbox("スナップバック監視", #selector(toggleWatch))
        editCheck = checkbox("編集モード(動かした位置を記憶)", #selector(toggleEdit))
        snapModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        snapModePopup.addItems(withTitles: ["スナップ: デバウンス 250ms", "スナップ: 即時"])
        snapModePopup.target = self
        snapModePopup.action = #selector(changeSnapMode)
        root.addArrangedSubview(row([
            label("切替:"),
            button("A を表示", #selector(showA)),
            button("B を表示", #selector(showB)),
            button("往復ベンチ ×10", #selector(bench)),
            parallelCheck, watchCheck, snapModePopup, editCheck,
        ]))

        let logScroll = makeLogView()
        root.addArrangedSubview(logScroll)

        for v in [tableScroll, logScroll] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24).isActive = true
        }
        tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        logScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        return root
    }

    private func makeTable() -> NSScrollView {
        let columns: [(String, String, CGFloat)] = [
            ("set", "Set", 40), ("app", "App", 150), ("wid", "WID", 70),
            ("title", "Title", 330), ("frame", "Frame (AX 座標)", 200), ("state", "State", 90),
        ]
        for (id, title, width) in columns {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        return scroll
    }

    private func makeLogView() -> NSScrollView {
        logView.isEditable = false
        logView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.isVerticallyResizable = true
        logView.isHorizontallyResizable = false
        logView.autoresizingMask = [.width]
        logView.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = logView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        return scroll
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = 8
        return s
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    private func checkbox(_ title: String, _ action: Selector) -> NSButton {
        NSButton(checkboxWithTitle: title, target: self, action: action)
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    // MARK: - 表示更新

    private func updateStatus() {
        let trusted = controller.isTrusted
        statusLabel.stringValue = "Accessibility: \(trusted ? "許可済 ✅" : "未許可 ❌")   " +
            "_AXUIElementGetWindow: \(AXShimIsAvailable() ? "利用可 ✅" : "なし ❌")"
        parallelCheck.state = controller.parallel ? .on : .off
        watchCheck.state = controller.watching ? .on : .off
        editCheck.state = controller.editMode ? .on : .off
        snapModePopup.selectItem(at: controller.snapMode == .debounced ? 0 : 1)
    }

    private func reloadTable() {
        table.reloadData()
        updateStatus()
    }

    private func appendLog(_ line: String) {
        logView.textStorage?.append(NSAttributedString(
            string: line,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                         .foregroundColor: NSColor.textColor]))
        logView.scrollToEndOfDocument(nil)
    }

    private var selectedWIDs: [CGWindowID] {
        table.selectedRowIndexes.compactMap { idx in
            idx < controller.records.count ? controller.records[idx].window.windowID : nil
        }
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        controller.records.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, row < controller.records.count else { return nil }
        let r = controller.records[row]
        let entry = controller.entries[r.window.windowID]
        let text: String
        switch id {
        case "set": text = entry?.set.rawValue ?? ""
        case "app": text = r.appName
        case "wid": text = "\(r.window.windowID)"
        case "title": text = r.title
        case "frame":
            text = r.frame.map { String(format: "(%.0f,%.0f %.0fx%.0f)", $0.minX, $0.minY, $0.width, $0.height) } ?? "?"
        case "state":
            text = entry.map { $0.isParked ? "parked" : "" } ?? (r.isMinimized ? "minimized" : "")
        default: text = ""
        }
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    // MARK: - アクション

    @objc private func requestPermission() { controller.requestPermission() }
    @objc private func logStatus() { controller.status() }
    @objc private func refresh() { controller.refresh() }
    @objc private func addToA() { controller.add(selectedWIDs, to: .a) }
    @objc private func addToB() { controller.add(selectedWIDs, to: .b) }
    @objc private func removeSelected() { controller.remove(selectedWIDs) }
    @objc private func placeLeft() { controller.place(selectedWIDs, .left) }
    @objc private func placeRight() { controller.place(selectedWIDs, .right) }
    @objc private func placeFull() { controller.place(selectedWIDs, .full) }
    @objc private func parkSelected() { controller.park(selectedWIDs) }
    @objc private func restoreSelected() { controller.restore(selectedWIDs) }
    @objc private func showA() { controller.show(.a) }
    @objc private func showB() { controller.show(.b) }
    @objc private func bench() { controller.bench(rounds: 10) }
    @objc private func toggleParallel() { controller.parallel = parallelCheck.state == .on }
    @objc private func toggleWatch() { controller.setWatch(watchCheck.state == .on) }
    @objc private func toggleEdit() { controller.editMode = editCheck.state == .on }
    @objc private func changeSnapMode() {
        controller.snapMode = snapModePopup.indexOfSelectedItem == 0 ? .debounced : .immediate
        controller.logger.log("snapMode=\(controller.snapMode.rawValue)")
    }
}
