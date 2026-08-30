import AppKit
import Testing
@testable import TabDeskCore

struct ScreenGeometryTests {
    /// axRect(fromCocoa:) は自己逆変換(y 反転を 2 回かけると元に戻る)。
    /// 枠ウィンドウ(v3 段階 4)は AX 座標の contentArea をこの性質で Cocoa へ変換している。
    @Test func axRectIsItsOwnInverse() {
        guard ScreenGeometry.primaryScreen != nil else { return }  // ヘッドレス環境では判定不能
        let rects = [
            CGRect(x: 240, y: 30, width: 1680, height: 1090),
            CGRect(x: -800, y: 100, width: 500, height: 400),
            CGRect(x: 2400, y: -200, width: 800, height: 600),
        ]
        for rect in rects {
            #expect(ScreenGeometry.axRect(fromCocoa: ScreenGeometry.axRect(fromCocoa: rect)) == rect)
        }
    }
}
