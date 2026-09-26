import AppKit
import TabDeskCore

struct TilePlacementIssue: Equatable {
    let windowID: UUID
    let tileID: UUID
    let tileNumber: Int
    let windowName: String

    var title: String { L10n.text(.tileIssueItem, String(tileNumber), windowName) }

    static func items(tab: Tab?, failedWindowIDs: [UUID], partition: TilePartition,
                      assignments: [UUID: UUID]) -> [TilePlacementIssue] {
        let failed = Set(failedWindowIDs)
        return (tab?.windows ?? []).compactMap { window in
            guard failed.contains(window.id), let tileID = assignments[window.id],
                  let index = partition.tileIDs.firstIndex(of: tileID) else { return nil }
            return TilePlacementIssue(windowID: window.id, tileID: tileID, tileNumber: index + 1,
                                      windowName: SidebarText.windowTitle(appName: window.identity.appName, title: window.identity.title))
        }
    }
}

/// 失敗した窓が多くても編集領域を押し出さないよう、選択式の一覧にする。
@MainActor
final class TilePlacementIssuesView: NSStackView {
    private let heading = NSTextField(labelWithString: "")
    private let help = NSTextField(wrappingLabelWithString: "")
    private(set) var picker = NSPopUpButton()
    private(set) var selectButton = NSButton()
    private(set) var issues: [TilePlacementIssue] = []
    var onSelectWindow: ((UUID) -> Void)?

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.textColor = .systemRed
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        picker.target = self
        picker.action = #selector(selectionChanged)
        picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        selectButton.target = self
        selectButton.action = #selector(selectWindow)
        selectButton.bezelStyle = .rounded
        let row = NSStackView(views: [picker, selectButton])
        for view in [heading, row, help] {
            addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        help.heightAnchor.constraint(equalToConstant: 32).isActive = true
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(_ issues: [TilePlacementIssue], canSelect: Bool) {
        let selection = picker.selectedItem?.representedObject as? UUID
        self.issues = issues
        heading.stringValue = L10n.text(.tileIssuesTitle, String(issues.count))
        help.stringValue = L10n.text(.tileIssuesHelp)
        selectButton.title = L10n.text(.selectIssueTile)
        picker.setAccessibilityLabel(L10n.text(.tileIssuesTitle, String(issues.count)))
        picker.removeAllItems()
        for issue in issues {
            // addItem(withTitle:) は同名項目を置き換えるため、同名の問題窓は NSMenu に直接追加する。
            let item = NSMenuItem(title: issue.title, action: nil, keyEquivalent: "")
            item.representedObject = issue.windowID
            item.toolTip = issue.title
            picker.menu?.addItem(item)
            if issue.windowID == selection { picker.selectItem(at: picker.numberOfItems - 1) }
        }
        selectionChanged()
        picker.isEnabled = canSelect && !issues.isEmpty
        selectButton.isEnabled = canSelect && !issues.isEmpty
        isHidden = issues.isEmpty
    }

    @objc private func selectionChanged() {
        picker.toolTip = picker.selectedItem?.title
    }

    @objc private func selectWindow() {
        guard selectButton.isEnabled, let id = picker.selectedItem?.representedObject as? UUID,
              issues.contains(where: { $0.windowID == id }) else { return }
        onSelectWindow?(id)
    }
}
