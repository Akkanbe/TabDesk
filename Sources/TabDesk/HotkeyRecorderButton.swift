import AppKit
import TabDeskCore

/// テキスト編集を開始せず、クリックまたはキーボード操作でキー記録を開始する。
@MainActor
final class HotkeyRecorderButton: NSButton {
    var specification = "" { didSet { refreshTitle() } }
    var isRecording = false { didSet { refreshTitle() } }
    var onRecord: (() -> Void)?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        font = .systemFont(ofSize: 13)
        target = self
        action = #selector(record)
        refreshTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func record() { onRecord?() }

    func refreshTitle() {
        title = isRecording ? L10n.text(.pressShortcut) :
            (specification.isEmpty ? L10n.text(.clickToRecord) : (try? HotkeyParser.parse(specification).symbolDisplay) ?? specification)
        setAccessibilityValue(title)
    }
}
