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

    private func refreshTitle() {
        title = isRecording ? "キーを押してください…" :
            (specification.isEmpty ? "クリックして設定" : (try? HotkeyParser.parse(specification).symbolDisplay) ?? specification)
        setAccessibilityValue(title)
    }
}
