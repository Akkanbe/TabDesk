import AppKit

/// 採用ロゴの縦タブと重なったウィンドウを、メニューバーの18ptでも読める線幅で描く。
@MainActor
enum StatusBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let frame = NSBezierPath(roundedRect: NSRect(x: 1, y: 2, width: 16, height: 14), xRadius: 3, yRadius: 3)
            frame.lineWidth = 1.5
            frame.stroke()

            let sidebar = NSBezierPath()
            sidebar.move(to: NSPoint(x: 6, y: 2))
            sidebar.line(to: NSPoint(x: 6, y: 16))
            sidebar.lineWidth = 1.5
            sidebar.stroke()

            for y: CGFloat in [4.5, 8, 11.5] {
                NSBezierPath(roundedRect: NSRect(x: 1.5, y: y, width: 3, height: 2), xRadius: 0.6, yRadius: 0.6).fill()
            }

            let window = NSBezierPath(roundedRect: NSRect(x: 9, y: 5, width: 8, height: 8), xRadius: 1.5, yRadius: 1.5)
            window.lineWidth = 1.5
            window.stroke()
            return true
        }
        // 背景色・メニュー選択状態に応じた着色はmacOSに任せる。
        image.isTemplate = true
        image.accessibilityDescription = "TabDesk"
        return image
    }()
}
