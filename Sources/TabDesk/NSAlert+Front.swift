import AppKit

extension NSAlert {
    /// アクセサリアプリは前面化しないとアラートが他アプリの窓の背後に隠れ、見えないまま操作を塞ぐ。
    /// モーダル表示は必ずこれを通す。
    @MainActor
    @discardableResult
    func runModalInFront() -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        return runModal()
    }
}
