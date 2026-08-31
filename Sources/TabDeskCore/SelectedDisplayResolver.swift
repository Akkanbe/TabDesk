import CoreGraphics
import Foundation

/// ホットキーが作用する「選択中のディスプレイ」の解決(v4 段階 4)。純関数にしてテスト可能にする。
///
/// 優先順:
/// 1. 前面アプリが自分(改名ダイアログ等で TabDesk が前面)→ 直前のフォーカスキャッシュ
/// 2. 前面アプリの pid がキャッシュと一致 → キャッシュの画面
/// 3. マウスカーソルの画面(`display(containing:)` は最終的に主ディスプレイへ fallback する)
///
/// 非同期 AX での前面窓の問い合わせは**使わない**(ホットキー経路で 0.5〜1 秒の
/// タイムアウトは許容できない。キャッシュはフォーカス通知で無料更新される)。
public enum SelectedDisplayResolver {
    public static func resolve(
        frontmostPID: pid_t?,
        ownPID: pid_t,
        cached: (pid: pid_t, displayID: DisplayID)?,
        mousePointAX: CGPoint,
        layout: any ScreenLayout
    ) -> DisplayID? {
        if let cached, layout.display(id: cached.displayID) != nil,
            frontmostPID == ownPID || frontmostPID == cached.pid
        {
            return cached.displayID
        }
        return layout.display(containing: CGRect(origin: mousePointAX, size: .zero))?.id
    }
}
