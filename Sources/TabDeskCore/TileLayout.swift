import CoreGraphics
import Foundation

/// タブ内ウィンドウの配置方式(v2 段階 C。docs/04_v2_design.md)。
public enum TabLayout: String, Codable, Sendable {
    /// 自由配置(v1 の挙動)。各窓が個別の固定 frame を持つ。
    case free
    /// 縦の等幅カラム。`Tab.windows` の並び順(bound の窓のみ)に左から等分する。
    case columns
}

/// タイル frame の計算。純関数にしてエンジンから独立してテストする。
enum Tiler {
    /// area を bound の窓数で縦に等分割した frame を返す(全高、左から windows の並び順)。
    /// 境界 x は「累積値を丸める」ことで整数化する。各列の幅を先に丸めると端数の合計が
    /// 右端の隙間や画面外へのはみ出しになるが、境界方式なら合計が常に area とぴったり一致する。
    static func columnFrames(for windows: [ManagedWindow], in area: CGRect) -> [UUID: CGRect] {
        let bound = windows.filter(\.isBound)
        guard !bound.isEmpty, area.width > 0 else { return [:] }
        let n = CGFloat(bound.count)
        let edges = (0...bound.count).map { (area.minX + area.width * CGFloat($0) / n).rounded() }
        var frames: [UUID: CGRect] = [:]
        for (i, window) in bound.enumerated() {
            frames[window.id] = CGRect(
                x: edges[i], y: area.minY, width: edges[i + 1] - edges[i], height: area.height)
        }
        return frames
    }
}
