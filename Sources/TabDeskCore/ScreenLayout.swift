import AppKit

/// 退避先とコンテンツ領域の提供元。ディスプレイ構成は変わりうるので、値は都度計算する。
public protocol ScreenLayout: Sendable {
    /// 退避先(AX 座標)。
    var parkPoint: CGPoint { get }
    /// 管理対象ウィンドウを配置できる領域(AX 座標。サイドバー分を除いた範囲)。
    var contentArea: CGRect { get }
}

/// テスト用の固定値。
public struct FixedScreenLayout: ScreenLayout {
    public let parkPoint: CGPoint
    public let contentArea: CGRect

    public init(parkPoint: CGPoint, contentArea: CGRect) {
        self.parkPoint = parkPoint
        self.contentArea = contentArea
    }
}

/// 本番用。主ディスプレイ(メニューバーのある画面)を対象にする(v1 は単一ディスプレイ)。
public struct PrimaryScreenLayout: ScreenLayout {
    public let sidebarWidth: CGFloat

    public init(sidebarWidth: CGFloat) {
        self.sidebarWidth = sidebarWidth
    }

    public var parkPoint: CGPoint {
        guard let screen = ScreenGeometry.primaryScreen else { return .zero }
        return ScreenGeometry.parkPoint(on: screen)
    }

    public var contentArea: CGRect {
        guard let screen = ScreenGeometry.primaryScreen else { return .zero }
        let visible = ScreenGeometry.visibleFrameAX(of: screen)
        return CGRect(
            x: visible.minX + sidebarWidth, y: visible.minY,
            width: visible.width - sidebarWidth, height: visible.height)
    }
}
