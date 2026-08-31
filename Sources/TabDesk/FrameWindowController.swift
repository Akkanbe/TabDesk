import AppKit
import TabDeskCore

/// 管理対象ウィンドウの背後に敷く「枠」ウィンドウ(ディスプレイごとに 1 枚。v3 段階 4)。
///
/// 通常ウィンドウより 1 段下のレベルに置き、クリックは素通しする(見た目だけの容れ物。
/// 仕様 §3.2 で v1 では見送った「背景の枠」)。`[DisplayID: NSWindow]` で持つ構造は、
/// v4(ディスプレイごとのサイドバー)の下敷きを兼ねる。
@MainActor
final class FrameWindowController: NSObject {
    /// 既定 OFF: 明示登録制では未登録の窓が枠の上に浮くため「容れ物」の錯視が弱く、
    /// アップデートで突然見た目が変わるのも避ける(docs/05_v3_design.md)。メニューで ON にする。
    static let enabledSetting = PersistedToggle(key: "FrameWindowsEnabled", defaultValue: false)

    private let manager: WindowManager
    private var windows: [DisplayID: NSWindow] = [:]

    init(manager: WindowManager) {
        self.manager = manager
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // サイドバーの幅変更・折りたたみで contentArea が変わったら追従する(段階 3 のフック)。
        manager.addContentAreaObserver { [weak self] in self?.rebuild() }
        rebuild()
    }

    @objc private func screenParametersChanged() {
        rebuild()
    }

    /// 現在の設定とディスプレイ構成に合わせて枠を作り直す(冪等)。
    func rebuild() {
        guard Self.enabledSetting.value else {
            windows.values.forEach { $0.orderOut(nil) }
            windows.removeAll()
            return
        }
        var seen = Set<DisplayID>()
        for display in manager.layout.displays {
            seen.insert(display.id)
            // contentArea は AX 座標。axRect(fromCocoa:) は自己逆変換なので Cocoa への変換にも使える。
            let cocoaFrame = ScreenGeometry.axRect(fromCocoa: display.contentArea)
            let window = windows[display.id] ?? Self.makeFrameWindow()
            windows[display.id] = window
            window.setFrame(cocoaFrame, display: true)
            window.orderBack(nil)
        }
        // 切断されたディスプレイの枠は片付ける。
        for (id, window) in windows where !seen.contains(id) {
            window.orderOut(nil)
            windows.removeValue(forKey: id)
        }
    }

    private static func makeFrameWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        // 通常ウィンドウの 1 段下 = 全アプリの窓の背後、デスクトップの手前。
        window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        // クリック素通しは必須(無いと管理対象ウィンドウの隙間のクリックを枠が奪う)。
        window.ignoresMouseEvents = true
        // 見た目だけの装飾を VoiceOver の「空のウィンドウ」として列挙させない。
        window.setAccessibilityElement(false)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.contentView = FrameBackgroundView()
        return window
    }
}

/// 枠の見た目: 角丸のうっすらした塗り+1px の境界線。
private final class FrameBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: inset, xRadius: 10, yRadius: 10)
        NSColor.underPageBackgroundColor.withAlphaComponent(0.5).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
