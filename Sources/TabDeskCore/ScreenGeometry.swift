import AppKit

/// 座標系の変換。
///
/// AX API は「主画面の左上が原点、y は下向き」、Cocoa(NSScreen)は「主画面の左下が原点、y は上向き」。
/// この違いを忘れるとウィンドウが上下反転した位置に飛ぶので、変換はここに集約する。
public enum ScreenGeometry {
    /// 主画面(メニューバーのある画面)。
    public static var primaryScreen: NSScreen? {
        NSScreen.screens.first
    }

    public static func axRect(fromCocoa r: CGRect) -> CGRect {
        guard let primary = primaryScreen else { return r }
        let h = primary.frame.height
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    /// 画面全体(Dock/メニューバー含む)の AX 座標 frame。
    public static func fullFrameAX(of screen: NSScreen) -> CGRect {
        axRect(fromCocoa: screen.frame)
    }

    /// メニューバー・Dock を除いた作業領域の AX 座標 frame。
    public static func visibleFrameAX(of screen: NSScreen) -> CGRect {
        axRect(fromCocoa: screen.visibleFrame)
    }

    /// 退避先の座標。画面右下隅に置き、1px だけ残す(macOS が完全画面外を許さないため)。
    /// 注意: このトリックは配置全体の外縁でしか成立しない。複数ディスプレイでは parkPoints を使うこと。
    public static func parkPoint(on screen: NSScreen) -> CGPoint {
        let full = fullFrameAX(of: screen)
        return CGPoint(x: full.maxX - 1, y: full.maxY - 1)
    }

    /// 各画面の退避点を、画面配置を考慮して決める(v2 段階 D レビュー対応。docs/04_v2_design.md)。
    ///
    /// 「右下隅 −1px」で 1px 線だけが残るのは、その隅が**配置全体の外縁**にある場合だけ。
    /// 右側に別の画面がある画面で自画面の隅に退避すると、隅は合法な座標なので OS はクランプせず、
    /// 窓本体が隣の画面上に丸見えのまま残る(クリックするとフォーカス連動切替まで誘発する)。
    /// そのため右側に画面がある画面は、配置全体の右下隅(外縁)へフォールバックする。
    /// その窓の切替は画面をまたぐぶん遅くなる(実測 50〜270ms/窓)が、見えないことを優先する。
    public static func parkPoints(forDisplayFrames frames: [CGRect]) -> [CGPoint] {
        let fallback = CGPoint(
            x: (frames.map(\.maxX).max() ?? 1) - 1,
            y: (frames.map(\.maxY).max() ?? 1) - 1)
        return frames.map { frame in
            // 「右側に画面があるか」だけを見る(縦のずれは判定しない)。斜め配置では過剰に
            // フォールバックすることがあるが、誤って見える側に倒れるよりよい。
            let blockedRight = frames.contains { other in
                other != frame && other.minX >= frame.maxX - 1
            }
            return blockedRight ? fallback : CGPoint(x: frame.maxX - 1, y: frame.maxY - 1)
        }
    }

    /// 画面の永続識別子。CGDirectDisplayID は再起動で変わりうるので、
    /// CGDisplayCreateUUIDFromDisplayID の UUID 文字列にする(接続をまたいで同じディスプレイを同定できる)。
    /// UUID が取れない場合は番号ベースの予備 ID(再起動をまたぐ安定性は劣るがセッション内では機能する)。
    public static func displayID(of screen: NSScreen) -> DisplayID {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return "unknown-display"
        }
        let directID = CGDirectDisplayID(number.uint32Value)
        if let uuid = CGDisplayCreateUUIDFromDisplayID(directID)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, uuid) as String
        }
        return "display-\(directID)"
    }

    /// 2 つの frame が許容誤差内で一致するか(スナップバック判定用)。
    public static func approximatelyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 1.0) -> Bool {
        abs(a.minX - b.minX) <= tolerance
            && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance
            && abs(a.height - b.height) <= tolerance
    }
}
