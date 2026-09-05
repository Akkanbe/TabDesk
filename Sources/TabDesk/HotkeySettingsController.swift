import AppKit
import Carbon.HIToolbox
import TabDeskCore

@MainActor
final class HotkeySettingsController: NSWindowController, NSWindowDelegate {
    private let configURL: URL
    private let apply: () -> [String]
    private let suspendHotkeys: () -> [String]
    private let resumeHotkeys: () -> [String]
    private var eventMonitor: Any?
    private(set) var recordingIndex: Int?
    private var extraTabBindings: [String] = []
    private(set) var fields: [HotkeyRecorderButton] = []
    private(set) var messageView = NSTextView()
    private let saveButton = NSButton(title: "保存して適用", target: nil, action: nil)
    private let resetButton = NSButton(title: "既定値を入力", target: nil, action: nil)

    init(
        configURL: URL,
        suspendHotkeys: @escaping () -> [String] = { [] },
        resumeHotkeys: @escaping () -> [String] = { [] },
        apply: @escaping () -> [String]
    ) {
        self.configURL = configURL
        self.apply = apply
        self.suspendHotkeys = suspendHotkeys
        self.resumeHotkeys = resumeHotkeys
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 710),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "ホットキー設定"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        if window?.isVisible != true { loadConfiguration() }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func loadConfiguration() {
        do {
            fill(try HotkeyConfig.load(from: configURL) ?? .default)
            saveButton.isEnabled = true
            resetButton.isEnabled = true
            showMessage("設定欄をクリックしてキーを押してください。×で解除できます。変更後は「保存して適用」を押してください。")
        } catch {
            saveButton.isEnabled = false
            resetButton.isEnabled = false
            showMessage("設定を読み込めませんでした。元のファイルは上書きしません。メニューの「ホットキー設定ファイルをFinderで表示」で場所を確認し、エディタで修正してから、この画面を開き直してください。\n\(error)", error: true)
        }
    }

    private func fill(_ config: HotkeyConfig) {
        let tabs = Array(config.activateTab.prefix(9))
        extraTabBindings = Array(config.activateTab.dropFirst(9))
        let values = tabs + Array(repeating: "", count: 9 - tabs.count) + [
            config.nextTab ?? "", config.previousTab ?? "", config.registerFocusedWindow ?? "",
            config.toggleEditMode ?? "", config.toggleSidebar ?? "",
        ]
        for (field, value) in zip(fields, values) { field.specification = value }
    }

    @objc func save() {
        guard saveButton.isEnabled else { return }
        let resumeIssues = finishRecording()
        guard resumeIssues.isEmpty else {
            showMessage(resumeIssues.joined(separator: "\n"), error: true)
            return
        }
        let values = fields.map { $0.specification.trimmingCharacters(in: .whitespacesAndNewlines) }
        func optional(_ index: Int) -> String? { values[index].isEmpty ? nil : values[index] }
        let config = HotkeyConfig(
            activateTab: Array(values.prefix(9)) + extraTabBindings,
            nextTab: optional(9), previousTab: optional(10), registerFocusedWindow: optional(11),
            toggleEditMode: optional(12), toggleSidebar: optional(13))
        let errors = config.resolve().errors
        guard errors.isEmpty else {
            showMessage("保存していません。入力を確認してください。\n" + errors.joined(separator: "\n"), error: true)
            return
        }
        do {
            try config.save(to: configURL)
        } catch {
            showMessage("保存できませんでした。現在の割り当ては変更していません。\n\(error)", error: true)
            return
        }
        let issues = apply()
        showMessage(issues.isEmpty ? "保存し、すべての割り当てを適用しました。" :
            "設定は保存しましたが、一部を適用できませんでした。\n" + issues.joined(separator: "\n"),
            error: !issues.isEmpty)
    }

    @objc private func reset() {
        let issues = finishRecording()
        fill(.default)
        showRecordingResult("既定値を入力しました。まだ保存していません。", issues: issues)
    }

    @objc private func dismiss() { close() }

    func beginRecording(at index: Int) {
        guard saveButton.isEnabled, fields.indices.contains(index) else { return }
        let previousIssues = finishRecording()
        guard previousIssues.isEmpty else {
            showRecordingResult("記録を開始できませんでした。", issues: previousIssues)
            return
        }
        let issues = suspendHotkeys()
        guard issues.isEmpty else {
            showRecordingResult("記録を開始できませんでした。", issues: issues + resumeHotkeys())
            return
        }
        recordingIndex = index
        fields[index].isRecording = true
        showMessage("キーの組み合わせを押してください。Escでキャンセル、Deleteで解除します。")
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // NSEvent 自体を actor 境界の戻り値にせず、消費するかだけを返す。
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.handleRecording(event) == nil
            }
            return consumed ? nil : event
        }
        if eventMonitor == nil {
            showRecordingResult("キー入力の監視を開始できませんでした。", issues: finishRecording())
        }
    }

    func handleRecording(_ event: NSEvent) -> NSEvent? {
        guard let index = recordingIndex, event.window === window else { return event }
        guard !event.isARepeat else { return nil }
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        if flags.isEmpty {
            switch event.keyCode {
            case UInt16(kVK_Escape):
                showRecordingResult("記録をキャンセルしました。", issues: finishRecording())
                return nil
            case UInt16(kVK_Delete), UInt16(kVK_ForwardDelete):
                clearBinding(at: index)
                return nil
            case UInt16(kVK_Tab):
                showRecordingResult("記録をキャンセルしました。", issues: finishRecording())
                return event
            default:
                showMessage("⌃ Control・⌥ Option・⇧ Shift・⌘ Commandのいずれかを一緒に押してください。", error: true)
                return nil
            }
        }
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        guard let specification = HotkeyParser.specification(keyCode: UInt32(event.keyCode), modifiers: modifiers) else {
            showMessage("このキーには対応していません。別のキーを押すか、Escでキャンセルしてください。", error: true)
            return nil
        }
        fields[index].specification = specification
        showRecordingResult("キーを記録しました。「保存して適用」で反映します。", issues: finishRecording())
        return nil
    }

    @discardableResult
    private func finishRecording() -> [String] {
        guard let index = recordingIndex else { return [] }
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        fields[index].isRecording = false
        recordingIndex = nil
        return resumeHotkeys()
    }

    func clearBinding(at index: Int) {
        guard saveButton.isEnabled, fields.indices.contains(index) else { return }
        let issues = finishRecording()
        fields[index].specification = ""
        showRecordingResult("割り当てを解除しました。「保存して適用」で反映します。", issues: issues)
    }

    @objc private func clearBinding(_ sender: NSButton) { clearBinding(at: sender.tag) }

    func windowDidResignKey(_ notification: Notification) {
        guard recordingIndex != nil else { return }
        showRecordingResult("記録をキャンセルしました。", issues: finishRecording())
    }

    func windowWillClose(_ notification: Notification) {
        let issues = finishRecording()
        if !issues.isEmpty {
            let alert = NSAlert()
            alert.messageText = "ホットキーを復帰できませんでした"
            alert.informativeText = issues.joined(separator: "\n") + "\nメニューの「ホットキーを再読み込み」で再試行してください。"
            alert.runModal()
        }
    }

    private func showRecordingResult(_ message: String, issues: [String]) {
        showMessage(message + (issues.isEmpty ? "" : "\n" + issues.joined(separator: "\n")), error: !issues.isEmpty)
    }

    private func showMessage(_ message: String, error: Bool = false) {
        messageView.string = message
        messageView.textColor = error ? .systemRed : .secondaryLabelColor
        messageView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let help = NSTextField(wrappingLabelWithString:
            "設定欄をクリックし、使いたいキーの組み合わせを押してください。\n記録中はTabDeskのホットキーを一時停止します。Escでキャンセル、×で解除できます。")
        help.font = .systemFont(ofSize: 12)
        let labels = (1...9).map { "タブ \($0) に切替" } + [
            "次のタブ", "前のタブ", "フォーカス窓を登録", "編集モード切替", "サイドバー折りたたみ",
        ]
        let rows: [[NSView]] = labels.enumerated().map { index, title in
            let label = NSTextField(labelWithString: title)
            let field = HotkeyRecorderButton()
            field.onRecord = { [weak self] in self?.beginRecording(at: index) }
            field.setAccessibilityLabel(title)
            fields.append(field)
            field.widthAnchor.constraint(equalToConstant: 310).isActive = true
            let clear = NSButton(title: "×", target: self, action: #selector(clearBinding(_:)))
            clear.tag = index
            clear.bezelStyle = .rounded
            clear.setAccessibilityLabel("\(title)の割り当てを解除")
            clear.toolTip = "割り当てを解除"
            let controls = NSStackView(views: [field, clear])
            controls.spacing = 6
            return [label, controls]
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 18
        grid.column(at: 0).width = 190
        grid.rowAlignment = .firstBaseline

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        messageView.isEditable = false
        messageView.isSelectable = true
        messageView.isRichText = false
        messageView.font = .systemFont(ofSize: 12)
        messageView.textContainerInset = NSSize(width: 6, height: 6)
        messageView.isVerticallyResizable = true
        messageView.isHorizontallyResizable = false
        messageView.autoresizingMask = [.width]
        messageView.textContainer?.widthTracksTextView = true
        scroll.documentView = messageView
        scroll.heightAnchor.constraint(equalToConstant: 96).isActive = true

        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        resetButton.target = self
        resetButton.action = #selector(reset)
        let cancel = NSButton(title: "閉じる", target: self, action: #selector(dismiss))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [resetButton, NSView(), cancel, saveButton])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [help, grid, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
            help.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }
}
