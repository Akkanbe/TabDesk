import AppKit
import TabDeskCore

@MainActor
enum WindowRecoveryGuide {
    static func alert(status: String? = nil) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = L10n.text(.windowRecovery)
        alert.informativeText = [status, L10n.text(.windowRecoveryHelp)].compactMap { $0 }.joined(separator: "\n\n")
        alert.addButton(withTitle: L10n.text(.close))
        alert.addButton(withTitle: L10n.text(.showSidebar))
        return alert
    }
}
