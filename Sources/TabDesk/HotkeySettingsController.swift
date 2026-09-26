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
    private var helpLabel: NSTextField?
    private var actionLabels: [NSTextField] = []
    private var clearButtons: [NSButton] = []
    private var closeButton: NSButton?
    private var currentMessage: (() -> String)?
    private var messageIsError = false

    private var localizedActionNames: [String] {
        (1...9).map { L10n.text(.activateTab, String($0)) } + [
            L10n.text(.nextTab), L10n.text(.previousTab), L10n.text(.registerFocused),
            L10n.text(.toggleEdit), L10n.text(.toggleSidebar),
            L10n.text(.nextDisplay), L10n.text(.previousDisplay),
        ]
    }

    /// コントロールは再生成せず、未保存の入力と記録状態を保持する。
    func refreshLocalization() {
        window?.title = L10n.text(.hotkeySettings)
        helpLabel?.stringValue = L10n.text(.hotkeyHelp)
        saveButton.title = L10n.text(.saveHotkeys)
        resetButton.title = L10n.text(.defaultHotkeys)
        closeButton?.title = L10n.text(.close)
        for (index, name) in localizedActionNames.enumerated() {
            actionLabels[index].stringValue = name
            fields[index].setAccessibilityLabel(name)
            fields[index].refreshTitle()
            clearButtons[index].setAccessibilityLabel(L10n.text(.clearShortcutLabel, name))
            clearButtons[index].toolTip = L10n.text(.clearShortcut)
        }
        renderMessage()
    }

    private let saveButton = NSButton(title: L10n.text(.saveHotkeys), target: nil, action: nil)
    private let resetButton = NSButton(title: L10n.text(.defaultHotkeys), target: nil, action: nil)

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
        window.title = L10n.text(.hotkeySettings)
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
            showMessage(L10n.text(.hotkeyInstructions))
        } catch {
            saveButton.isEnabled = false
            resetButton.isEnabled = false
            showMessage(L10n.text(.hotkeyLoadError, String(describing: error)), error: true)
        }
    }

    private func fill(_ config: HotkeyConfig) {
        let tabs = Array(config.activateTab.prefix(9))
        extraTabBindings = Array(config.activateTab.dropFirst(9))
        let values = tabs + Array(repeating: "", count: 9 - tabs.count) + [
            config.nextTab ?? "", config.previousTab ?? "", config.registerFocusedWindow ?? "",
            config.toggleEditMode ?? "", config.toggleSidebar ?? "",
            config.nextDisplay ?? "", config.previousDisplay ?? "",
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
            toggleEditMode: optional(12), toggleSidebar: optional(13),
            nextDisplay: optional(14), previousDisplay: optional(15))
        guard config.resolve().errors.isEmpty else {
            showMessage(L10n.text(.hotkeyNotSaved) + config.resolve().errors.joined(separator: "\n"), error: true)
            return
        }
        do {
            try config.save(to: configURL)
        } catch {
            showMessage(L10n.text(.hotkeySaveError, String(describing: error)), error: true)
            return
        }
        let issues = apply()
        showMessage(issues.isEmpty ? L10n.text(.hotkeySaved) :
            L10n.text(.hotkeyPartial) + issues.joined(separator: "\n"),
            error: !issues.isEmpty)
    }

    @objc private func reset() {
        let issues = finishRecording()
        fill(.default)
        showRecordingResult(L10n.text(.defaultsFilled), issues: issues)
    }

    @objc private func dismiss() { close() }

    func beginRecording(at index: Int) {
        guard saveButton.isEnabled, fields.indices.contains(index) else { return }
        let previousIssues = finishRecording()
        guard previousIssues.isEmpty else {
            showRecordingResult(L10n.text(.recordingFailed), issues: previousIssues)
            return
        }
        let issues = suspendHotkeys()
        guard issues.isEmpty else {
            showRecordingResult(L10n.text(.recordingFailed), issues: issues + resumeHotkeys())
            return
        }
        recordingIndex = index
        fields[index].isRecording = true
        showMessage(L10n.text(.recordingInstructions))
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // NSEvent 自体を actor 境界の戻り値にせず、消費するかだけを返す。
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.handleRecording(event) == nil
            }
            return consumed ? nil : event
        }
        if eventMonitor == nil {
            showRecordingResult(L10n.text(.monitorFailed), issues: finishRecording())
        }
    }

    func handleRecording(_ event: NSEvent) -> NSEvent? {
        guard let index = recordingIndex, event.window === window else { return event }
        guard !event.isARepeat else { return nil }
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        if flags.isEmpty {
            switch event.keyCode {
            case UInt16(kVK_Escape):
                showRecordingResult(L10n.text(.recordingCancelled), issues: finishRecording())
                return nil
            case UInt16(kVK_Delete), UInt16(kVK_ForwardDelete):
                clearBinding(at: index)
                return nil
            case UInt16(kVK_Tab):
                showRecordingResult(L10n.text(.recordingCancelled), issues: finishRecording())
                return event
            default:
                showMessage(L10n.text(.modifierRequired), error: true)
                return nil
            }
        }
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        guard let specification = HotkeyParser.specification(keyCode: UInt32(event.keyCode), modifiers: modifiers) else {
            showMessage(L10n.text(.unsupportedKey), error: true)
            return nil
        }
        fields[index].specification = specification
        showRecordingResult(L10n.text(.recorded), issues: finishRecording())
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
        showRecordingResult(L10n.text(.cleared), issues: issues)
    }

    @objc private func clearBinding(_ sender: NSButton) { clearBinding(at: sender.tag) }

    func windowDidResignKey(_ notification: Notification) {
        guard recordingIndex != nil else { return }
        showRecordingResult(L10n.text(.recordingCancelled), issues: finishRecording())
    }

    func windowWillClose(_ notification: Notification) {
        let issues = finishRecording()
        if !issues.isEmpty {
            let alert = NSAlert()
            alert.messageText = L10n.text(.resumeFailed)
            alert.informativeText = issues.joined(separator: "\n") + L10n.text(.resumeHelp)
            alert.runModalInFront()
        }
    }

    private func showRecordingResult(_ message: @autoclosure @escaping () -> String, issues: [String]) {
        showMessage(message() + (issues.isEmpty ? "" : "\n" + issues.joined(separator: "\n")), error: !issues.isEmpty)
    }

    private func showMessage(_ message: @autoclosure @escaping () -> String, error: Bool = false) {
        currentMessage = message
        messageIsError = error
        renderMessage()
    }

    private func renderMessage() {
        messageView.string = currentMessage?() ?? ""
        messageView.textColor = messageIsError ? .systemRed : .secondaryLabelColor
        messageView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let help = NSTextField(wrappingLabelWithString:
            L10n.text(.hotkeyHelp))
        help.font = .systemFont(ofSize: 12)
        helpLabel = help
        let labels = localizedActionNames
        let rows: [[NSView]] = labels.enumerated().map { index, title in
            let label = NSTextField(labelWithString: title)
            actionLabels.append(label)
            let field = HotkeyRecorderButton()
            field.onRecord = { [weak self] in self?.beginRecording(at: index) }
            field.setAccessibilityLabel(title)
            fields.append(field)
            field.widthAnchor.constraint(equalToConstant: 310).isActive = true
            let clear = NSButton(title: "×", target: self, action: #selector(clearBinding(_:)))
            clearButtons.append(clear)
            clear.tag = index
            clear.bezelStyle = .rounded
            clear.setAccessibilityLabel(L10n.text(.clearShortcutLabel, title))
            clear.toolTip = L10n.text(.clearShortcut)
            let controls = NSStackView(views: [field, clear])
            controls.spacing = 6
            return [label, controls]
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 4
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
        let cancel = NSButton(title: L10n.text(.close), target: self, action: #selector(dismiss))
        closeButton = cancel
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [resetButton, NSView(), cancel, saveButton])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [help, grid, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
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
