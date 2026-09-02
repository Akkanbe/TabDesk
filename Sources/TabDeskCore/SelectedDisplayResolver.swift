import CoreGraphics
import Foundation

/// ホットキーが作用する「選択中のディスプレイ」の解決(v4 段階 4)。純関数にしてテスト可能にする。
///
/// 優先順:
/// 1. 前面アプリが自分(改名ダイアログ等で TabDesk が前面)→ 直前のフォーカスキャッシュ
/// 2. 前面アプリの最前面ウィンドウを CGWindowList で解決できた → その画面
/// 3. 前面アプリの pid がキャッシュと一致 → キャッシュの画面
/// 4. マウスカーソルの画面(`display(containing:)` は最終的に主ディスプレイへ fallback する)
///
/// 非同期 AX での前面窓の問い合わせは**使わない**(ホットキー経路で 0.5〜1 秒の
/// タイムアウトは許容できない。キャッシュはフォーカス通知で無料更新される)。
public enum SelectedDisplayResolver {
    public static func resolve(
        frontmostPID: pid_t?,
        ownPID: pid_t,
        cached: (pid: pid_t, displayID: DisplayID)?,
        frontmostWindowDisplayID: DisplayID? = nil,
        mousePointAX: CGPoint,
        layout: any ScreenLayout
    ) -> DisplayID? {
        // 改名ダイアログなどで TabDesk 自身が前面になったときは、操作元の画面を維持する。
        if frontmostPID == ownPID, let cached, layout.display(id: cached.displayID) != nil {
            return cached.displayID
        }
        // キャッシュは管理対象窓の通知でしか更新できない場合がある。前面窓の現在位置を
        // 同期 IPC なしで取得できたときは、未登録窓や画面間ドラッグ後もこちらを優先する。
        if frontmostPID != nil, frontmostPID != ownPID,
            let frontmostWindowDisplayID, layout.display(id: frontmostWindowDisplayID) != nil
        {
            return frontmostWindowDisplayID
        }
        if let cached, layout.display(id: cached.displayID) != nil, frontmostPID == cached.pid {
            return cached.displayID
        }
        return layout.display(containing: CGRect(origin: mousePointAX, size: .zero))?.id
    }
}
