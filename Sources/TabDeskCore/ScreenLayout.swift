import AppKit

/// ディスプレイの永続識別子。CGDirectDisplayID は再起動をまたいで安定しないため、
/// CGDisplayCreateUUIDFromDisplayID の UUID 文字列で持つ(docs/04_v2_design.md 段階 D)。
public typealias DisplayID = String

/// 1 ディスプレイ分の配置情報(すべて AX 座標)。
public struct DisplayLayout: Sendable, Hashable {
    public let id: DisplayID
    /// 画面の全体 frame(ウィンドウの所属判定用)。
    public let frame: CGRect
    /// 管理対象ウィンドウを配置できる領域(サイドバーのある画面はその分を除いた範囲)。
    public let contentArea: CGRect
    /// 退避先(この画面の右下隅)。
    public let parkPoint: CGPoint

    public init(id: DisplayID, frame: CGRect, contentArea: CGRect, parkPoint: CGPoint) {
        self.id = id
        self.frame = frame
        self.contentArea = contentArea
        self.parkPoint = parkPoint
    }
}

/// 退避先とコンテンツ領域の提供元。ディスプレイ構成は変わりうるので、値は都度計算する。
public protocol ScreenLayout: Sendable {
    /// 接続中の全ディスプレイ。**先頭 = 主ディスプレイ**(メニューバー・サイドバーのある画面)。
    var displays: [DisplayLayout] { get }
}

public extension ScreenLayout {
    var primaryDisplay: DisplayLayout? { displays.first }

    /// 主ディスプレイの退避先(v1 互換。窓ごとの退避先は display(id:) を使う)。
    var parkPoint: CGPoint { primaryDisplay?.parkPoint ?? .zero }

    /// 主ディスプレイのコンテンツ領域(v1 互換)。
    var contentArea: CGRect { primaryDisplay?.contentArea ?? .zero }

    /// id のディスプレイ。見つからない(切断中・nil)場合は nil を返し、呼び手が主ディスプレイへ fallback する。
    func display(id: DisplayID?) -> DisplayLayout? {
        guard let id else { return nil }
        return displays.first { $0.id == id }
    }

    /// rect が属するディスプレイ。中心点を含む画面 → 交差面積が最大の画面 → 主ディスプレイ の順で決める。
    func display(containing rect: CGRect) -> DisplayLayout? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let hit = displays.first(where: { $0.frame.contains(center) }) {
            return hit
        }
        let best = displays
            .map { (display: $0, overlap: $0.frame.intersection(rect)) }
            .filter { !$0.overlap.isEmpty }
            .max { $0.overlap.width * $0.overlap.height < $1.overlap.width * $1.overlap.height }
        return best?.display ?? primaryDisplay
    }
}

/// テスト用の固定値。
public struct FixedScreenLayout: ScreenLayout {
    public let displays: [DisplayLayout]

    public init(displays: [DisplayLayout]) {
        self.displays = displays
    }

    /// 単一ディスプレイの簡易版(v1 からのテスト互換)。frame はコンテンツ領域と退避点を含む範囲にする。
    public init(parkPoint: CGPoint, contentArea: CGRect) {
        self.displays = [
            DisplayLayout(
                id: "fixed",
                frame: contentArea.union(CGRect(origin: .zero, size: CGSize(width: parkPoint.x + 1, height: parkPoint.y + 1))),
                contentArea: contentArea,
                parkPoint: parkPoint)
        ]
    }
}

/// 本番用。NSScreen.screens から全ディスプレイ分を構築する(v1 の PrimaryScreenLayout を置き換え。
/// 先頭が主ディスプレイなのは NSScreen.screens の仕様と一致)。
/// sidebarWidth はサイドバーのある主ディスプレイのコンテンツ領域からだけ除く。
public struct SystemScreenLayout: ScreenLayout {
    public let sidebarWidth: CGFloat

    public init(sidebarWidth: CGFloat) {
        self.sidebarWidth = sidebarWidth
    }

    public var displays: [DisplayLayout] {
        let screens = NSScreen.screens
        return screens.enumerated().map { index, screen in
            let visible = ScreenGeometry.visibleFrameAX(of: screen)
            let content: CGRect
            if index == 0 {
                content = CGRect(
                    x: visible.minX + sidebarWidth, y: visible.minY,
                    width: visible.width - sidebarWidth, height: visible.height)
            } else {
                content = visible
            }
            return DisplayLayout(
                id: ScreenGeometry.displayID(of: screen),
                frame: ScreenGeometry.fullFrameAX(of: screen),
                contentArea: content,
                parkPoint: ScreenGeometry.parkPoint(on: screen))
        }
    }
}
