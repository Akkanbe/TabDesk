import AppKit
import TabDeskCore

@MainActor
final class TileEditorController: NSWindowController, NSWindowDelegate {
    private let manager: WindowManager
    let tabID: UUID
    private var original: TilePartition?
    private(set) var partition: TilePartition = .tile(UUID())
    private(set) var assignments: [UUID: UUID] = [:]
    private var originalAssignments: [UUID: UUID] = [:]
    private var selected: UUID?
    private var busy = false
    private var operationError: Error?
    private struct Draft {
        let partition: TilePartition
        let assignments: [UUID: UUID]
        let selected: UUID?
    }
    private var undoHistory: [Draft] = []
    private var redoHistory: [Draft] = []
    private var resizeStart: Draft?
    private var draft: Draft { Draft(partition: partition, assignments: assignments, selected: selected) }
    var canUndo: Bool { !undoHistory.isEmpty }
    var canRedo: Bool { !redoHistory.isEmpty }
    private(set) var canvas = TileCanvas()
    private let help = NSTextField(wrappingLabelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let tilePicker = NSPopUpButton()
    private let windowPicker = NSPopUpButton()
    private let assignmentLabel = NSTextField(labelWithString: "")
    private let splitLR = NSButton()
    private let splitTB = NSButton()
    private let merge = NSButton()
    private let applyButton = NSButton()
    private let reloadButton = NSButton()
    private let addButton = NSButton()
    private let closeButton = NSButton()
    private let undoButton = NSButton()
    private let redoButton = NSButton()
    private(set) var placementIssues = TilePlacementIssuesView()

    var hasChanges: Bool { partition != original || assignments != originalAssignments }

    init(manager: WindowManager, tabID: UUID) {
        self.manager = manager
        self.tabID = tabID
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 740),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 760, height: 660)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent()
        reload()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        if window?.isVisible != true, !busy { reload() }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// 外部の登録・解除は未適用の編集を上書きしない。確定時にもエンジンで競合を検証する。
    func refreshState() {
        guard !busy else { return }
        // 全操作を取り消した状態でも、通常の通知で「やり直す」を失わない。
        if !hasChanges, !canUndo, !canRedo, resizeStart == nil { loadState() } else { refreshPresentation() }
    }

    func refreshLocalization() { refreshPresentation() }

    @objc private func reload() {
        guard !busy, resizeStart == nil else { return }
        operationError = nil
        undoHistory.removeAll()
        redoHistory.removeAll()
        loadState()
    }

    private func remember(_ previous: Draft) {
        guard partition != previous.partition || assignments != previous.assignments else { return }
        undoHistory.append(previous)
        // 分割木のスナップショットを無制限に保持しない。直近 100 操作まで戻せる。
        if undoHistory.count > 100 { undoHistory.removeFirst() }
        redoHistory.removeAll()
    }

    private func restoreDraft(_ previous: Draft) {
        partition = previous.partition
        assignments = previous.assignments
        selected = previous.selected
        operationError = nil
        refreshPresentation()
    }

    @objc func undoEdit() {
        guard !busy, resizeStart == nil, let previous = undoHistory.popLast() else { return }
        redoHistory.append(draft)
        restoreDraft(previous)
    }

    @objc func redoEdit() {
        guard !busy, resizeStart == nil, let next = redoHistory.popLast() else { return }
        undoHistory.append(draft)
        restoreDraft(next)
    }

    func windowDidResignKey(_ notification: Notification) { canvas.finishResize() }
    func windowWillClose(_ notification: Notification) { canvas.finishResize() }

    private func loadState() {
        guard let tab = manager.engine.state.tab(withID: tabID), tab.layout == .tiled, let tiles = tab.tiles else {
            refreshPresentation()
            return
        }
        original = tiles
        partition = tiles
        assignments = tab.tileAssignments
        originalAssignments = assignments
        if !tiles.tileIDs.contains(where: { $0 == selected }) { selected = tiles.tileIDs.first }
        refreshPresentation()
    }

    private func refreshPresentation() {
        let tab = manager.engine.state.tab(withID: tabID)
        let usable = tab?.layout == .tiled
        window?.title = L10n.text(.tileEditorTitle, tab?.name ?? "TabDesk")
        help.stringValue = L10n.text(.tileEditorHelp)
        splitLR.title = L10n.text(.splitLeftRight)
        splitTB.title = L10n.text(.splitTopBottom)
        merge.title = L10n.text(.mergeTiles)
        applyButton.title = L10n.text(.applyTiles)
        reloadButton.title = L10n.text(.reloadTiles)
        addButton.title = L10n.text(.addToTile)
        closeButton.title = L10n.text(.close)
        undoButton.title = L10n.text(.undoTileEdit)
        redoButton.title = L10n.text(.redoTileEdit)
        assignmentLabel.stringValue = L10n.text(.tileAssignment)
        tilePicker.setAccessibilityLabel(L10n.text(.tileNumber, ""))
        windowPicker.setAccessibilityLabel(L10n.text(.tileAssignment))
        tilePicker.removeAllItems()
        for (index, id) in partition.tileIDs.enumerated() {
            tilePicker.addItem(withTitle: L10n.text(.tileNumber, String(index + 1)))
            tilePicker.lastItem?.representedObject = id
            if id == selected { tilePicker.selectItem(at: index) }
        }
        windowPicker.removeAllItems()
        windowPicker.addItem(withTitle: L10n.text(.emptyTile))
        windowPicker.item(at: 0)?.isEnabled = false
        for window in tab?.windows ?? [] {
            // addItem(withTitle:) は同名項目を置き換えるため、同名の窓は NSMenu に直接追加する。
            let item = NSMenuItem(title: SidebarText.windowTitle(appName: window.identity.appName, title: window.identity.title),
                                  action: nil, keyEquivalent: "")
            item.representedObject = window.id
            windowPicker.menu?.addItem(item)
            if assignments[window.id] == selected { windowPicker.selectItem(at: windowPicker.numberOfItems - 1) }
        }
        let canEdit = usable && !busy && resizeStart == nil
        let failedWindows = manager.engine.tilePlacementFailures(in: tabID)
        placementIssues.update(TilePlacementIssue.items(tab: tab, failedWindowIDs: failedWindows,
                                                        partition: partition, assignments: assignments), canSelect: canEdit)
        for button in [splitLR, splitTB, merge, applyButton, reloadButton] { button.isEnabled = canEdit }
        undoButton.isEnabled = canEdit && canUndo
        redoButton.isEnabled = canEdit && canRedo
        tilePicker.isEnabled = canEdit
        windowPicker.isEnabled = canEdit && !assignments.isEmpty
        addButton.isEnabled = canEdit && !hasChanges && !assignments.values.contains(where: { $0 == selected })
        canvas.isEnabled = usable && !busy
        canvas.partition = partition
        canvas.selected = selected
        canvas.labels = Dictionary(partition.tileIDs.enumerated().map { index, tileID in
            let window = tab?.windows.first { assignments[$0.id] == tileID }
            let name = window.map { SidebarText.windowTitle(appName: $0.identity.appName, title: $0.identity.title) } ?? L10n.text(.emptyTile)
            return (tileID, L10n.text(.tileNumber, String(index + 1)) + "\n" + name)
        }, uniquingKeysWith: { first, _ in first })
        if let tab, let display = manager.layout.display(id: tab.displayID) ?? manager.layout.primaryDisplay {
            canvas.areaSize = display.contentArea.size
        }
        canvas.needsDisplay = true
        window?.invalidateCursorRects(for: canvas)
        if !usable { showMessage(L10n.text(.tileTabUnavailable), error: true) }
        else if let operationError { showMessage(String(describing: operationError), error: true) }
        else if hasChanges { showMessage(L10n.text(.tileDraft)) }
        else if !failedWindows.isEmpty { showMessage(L10n.text(.tileFitWarning), error: true) }
        else { showMessage("") }
    }

    func splitSelected(axis: TileAxis) {
        guard let selected, !busy, resizeStart == nil else { return }
        do {
            let previous = draft
            operationError = nil
            partition = try partition.splitting(selected, axis: axis)
            remember(previous)
            refreshPresentation()
        } catch { showError(error) }
    }

    @objc private func splitLeftRight() { splitSelected(axis: .horizontal) }
    @objc private func splitTopBottom() { splitSelected(axis: .vertical) }

    @objc private func mergeSelected() {
        guard let selected, !busy, resizeStart == nil else { return }
        do {
            let previous = draft
            operationError = nil
            let result = try partition.merging(selected, occupied: Set(assignments.values))
            partition = result.partition
            self.selected = result.selected
            remember(previous)
            refreshPresentation()
        } catch { showError(error) }
    }

    @objc private func selectTile() {
        selected = tilePicker.selectedItem?.representedObject as? UUID
        refreshPresentation()
    }

    @objc private func assignWindow() {
        guard !busy, resizeStart == nil, let selected, let id = windowPicker.selectedItem?.representedObject as? UUID,
              let previous = assignments[id] else { return }
        let before = draft
        // 占有済みタイルへの割り当ては入れ替え。窓を未割り当てにして追跡不能にしない。
        if let other = assignments.first(where: { $0.value == selected })?.key { assignments[other] = previous }
        operationError = nil
        assignments[id] = selected
        remember(before)
        refreshPresentation()
    }

    @objc private func applyChanges() {
        Task { [weak self] in await self?.applyDraft() }
    }

    @discardableResult
    func applyDraft() async -> Bool {
        guard !busy, resizeStart == nil else { return false }
        operationError = nil
        busy = true
        refreshPresentation()
        do {
            try await manager.engine.updateTiles(tabID, partition: partition, assignments: assignments,
                                                 expected: original, expectedAssignments: originalAssignments)
            busy = false
            reload()
            if manager.engine.tilePlacementFailures(in: tabID).isEmpty { showMessage(L10n.text(.tilesApplied)) }
            return true
        } catch {
            busy = false
            refreshPresentation()
            showError(error)
            return false
        }
    }

    @objc private func addWindow() {
        guard let tileID = selected, !busy, !hasChanges else { return }
        operationError = nil
        busy = true
        refreshPresentation()
        Task { [weak self] in
            guard let self else { return }
            let records = await manager.availableWindows()
            busy = false
            refreshPresentation()
            guard window?.isVisible == true else { return }
            let menu = NSMenu()
            if records.isEmpty { menu.addItem(withTitle: L10n.text(.noAvailableWindows), action: nil, keyEquivalent: "") }
            for record in records {
                let item = NSMenuItem(title: SidebarText.windowTitle(appName: record.appName, title: record.title),
                                      action: #selector(registerWindow(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = TileWindowChoice(record: record, tileID: tileID)
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: addButton.bounds.height), in: addButton)
        }
    }

    @objc private func registerWindow(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? TileWindowChoice, !busy else { return }
        operationError = nil
        busy = true
        refreshPresentation()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await manager.register(choice.record, into: tabID, tileID: choice.tileID)
                busy = false
                reload()
            } catch {
                busy = false
                refreshPresentation()
                showError(error)
            }
        }
    }

    @objc private func dismiss() { close() }

    private func showError(_ error: Error) {
        operationError = error
        showMessage(String(describing: error), error: true)
    }

    private func showMessage(_ text: String, error: Bool = false) {
        message.stringValue = text
        message.textColor = error ? .systemRed : .secondaryLabelColor
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        for (button, action) in [(splitLR, #selector(splitLeftRight)), (splitTB, #selector(splitTopBottom)),
                                 (merge, #selector(mergeSelected)), (applyButton, #selector(applyChanges)),
                                 (reloadButton, #selector(reload)), (addButton, #selector(addWindow)),
                                 (closeButton, #selector(dismiss)), (undoButton, #selector(undoEdit)),
                                 (redoButton, #selector(redoEdit))] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
        }
        closeButton.keyEquivalent = "\u{1b}"
        applyButton.keyEquivalent = "\r"
        undoButton.keyEquivalent = "z"
        undoButton.keyEquivalentModifierMask = .command
        redoButton.keyEquivalent = "z"
        redoButton.keyEquivalentModifierMask = [.command, .shift]
        tilePicker.target = self
        tilePicker.action = #selector(selectTile)
        windowPicker.target = self
        windowPicker.action = #selector(assignWindow)
        windowPicker.widthAnchor.constraint(equalToConstant: 380).isActive = true
        placementIssues.onSelectWindow = { [weak self] id in
            guard let self, !busy, resizeStart == nil, let tileID = assignments[id],
                  partition.tileIDs.contains(tileID) else { return }
            selected = tileID
            refreshPresentation()
        }
        canvas.onSelect = { [weak self] id in self?.selected = id; self?.refreshPresentation() }
        canvas.onBeginResize = { [weak self] in
            guard let self else { return }
            resizeStart = draft
            refreshPresentation()
        }
        canvas.onEndResize = { [weak self] in
            guard let self, let previous = resizeStart else { return }
            resizeStart = nil
            remember(previous)
            refreshPresentation()
        }
        canvas.onResize = { [weak self] id, ratio in
            guard let self else { return }
            do {
                operationError = nil
                partition = try partition.resizing(id, ratio: ratio)
                refreshPresentation()
            } catch { showError(error) }
        }
        help.font = .systemFont(ofSize: 12)
        message.font = .systemFont(ofSize: 12)
        let toolbar = NSStackView(views: [tilePicker, splitLR, splitTB, merge])
        let assignment = NSStackView(views: [assignmentLabel, windowPicker])
        let buttons = NSStackView(views: [undoButton, redoButton, reloadButton, NSView(), closeButton, applyButton])
        let stack = NSStackView(views: [help, toolbar, canvas, assignment, addButton, placementIssues, message, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            canvas.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
            message.heightAnchor.constraint(equalToConstant: 44),
        ])
        for view in [help, canvas, placementIssues, message, buttons] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        canvas.setContentHuggingPriority(.defaultLow, for: .vertical)
    }
}

private final class TileWindowChoice: NSObject {
    let record: WindowRecord
    let tileID: UUID
    init(record: WindowRecord, tileID: UUID) { self.record = record; self.tileID = tileID }
}

/// 画面全体の縮小プレビュー。ドラッグは分割比率だけを変更し、実窓は「適用」で動かす。
@MainActor
final class TileCanvas: NSView {
    var partition: TilePartition = .tile(UUID())
    var selected: UUID?
    var labels: [UUID: String] = [:]
    var areaSize = NSSize(width: 16, height: 9)
    var isEnabled = true
    var onSelect: ((UUID) -> Void)?
    var onResize: ((UUID, Double) -> Void)?
    var onBeginResize: (() -> Void)?
    var onEndResize: (() -> Void)?
    private var dragging: TilePartition.Divider?
    override var isFlipped: Bool { true }

    var drawingArea: NSRect {
        guard bounds.width > 12, bounds.height > 12 else { return .zero }
        let available = bounds.insetBy(dx: 6, dy: 6)
        guard areaSize.width > 0, areaSize.height > 0 else { return available }
        let scale = min(available.width / areaSize.width, available.height / areaSize.height)
        let size = NSSize(width: areaSize.width * scale, height: areaSize.height * scale)
        return NSRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2, width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        for (id, rect) in partition.geometry(in: drawingArea).tiles {
            (id == selected ? NSColor.controlAccentColor.withAlphaComponent(0.22) : NSColor.windowBackgroundColor).setFill()
            rect.fill()
            NSColor.separatorColor.setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = id == selected ? 2 : 1
            path.stroke()
            let label = labels[id] ?? ""
            let textRect = NSRect(x: rect.minX + 8, y: rect.midY - 20, width: max(0, rect.width - 16), height: 44)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: rect).addClip()
            (label as NSString).draw(in: textRect, withAttributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
            ])
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    override func resetCursorRects() {
        guard isEnabled else { return }
        for divider in partition.geometry(in: drawingArea).dividers {
            addCursorRect(hitArea(divider), cursor: divider.axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
        }
    }

    private func hitArea(_ divider: TilePartition.Divider) -> NSRect {
        divider.axis == .horizontal
            ? NSRect(x: divider.position - 5, y: divider.area.minY, width: 10, height: divider.area.height)
            : NSRect(x: divider.area.minX, y: divider.position - 5, width: divider.area.width, height: 10)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        finishResize()
        let point = convert(event.locationInWindow, from: nil)
        let geometry = partition.geometry(in: drawingArea)
        dragging = geometry.dividers.reversed().first { hitArea($0).contains(point) }
        if dragging != nil { onBeginResize?() }
        if dragging == nil, let tile = geometry.tiles.first(where: { $0.value.contains(point) }) { onSelect?(tile.key) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, let dragging else { return }
        let point = convert(event.locationInWindow, from: nil)
        let ratio = dragging.axis == .horizontal
            ? (point.x - dragging.area.minX) / dragging.area.width
            : (point.y - dragging.area.minY) / dragging.area.height
        onResize?(dragging.id, ratio)
    }

    override func mouseUp(with event: NSEvent) {
        finishResize()
    }

    func finishResize() {
        guard dragging != nil else { return }
        dragging = nil
        onEndResize?()
        window?.invalidateCursorRects(for: self)
    }
}
