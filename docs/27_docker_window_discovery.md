# Docker Desktopのウィンドウ候補が表示されない問題

- [x] 実機のAX属性、アプリ一覧、登録状態を確認する
- [x] `launchDate == nil` による `processUnavailable` を再現する
- [x] 公開APIで起動時刻を補完し、PID再利用時の保護を維持する
- [x] 回帰テストと既存テスト、Releaseビルドを確認する
- [x] 新しいビルドでDockerの候補表示を確認する

Docker Desktop（com.electron.dockerdesktop）は通常アプリで、標準ウィンドウの位置変更も可能だったが、`NSRunningApplication.launchDate` がnilだった。AX参照管理が起動日時を必須としていたため、列挙時に除外されていた。登録済みや最小化による除外ではない。

起動日時が欠ける場合のみ、macOS SDKに公開されている `proc_pidinfo(PROC_PIDTBSDINFO)` のプロセス起動時刻で補完する。時刻を取得できなければ従来どおり操作を拒否する。保存データの形式は変更しない。

## 検証結果

- `./scripts/test.sh`: Core 291件 + App 48件、計339件成功。
- 起動時刻の補完、PID再利用、遅延終了通知、取得失敗後の再取得を回帰テストで確認。
- Releaseビルドと署名検証に成功。
- 修正版を `build/TabDesk.app` に反映し、実機の「ウィンドウを追加」に **Docker Desktop — Containers - Docker Desktop** が表示されることを確認。登録操作は実施せずメニューを閉じた。
- 再起動前後でタブ・登録ウィンドウのID、アクティブタブ、ホットキー設定を比較し一致。既存7窓の復元に成功。再起動で解除された編集モードは元のONに戻した。
- 旧ビルドと状態バックアップは `build/docker-investigation/` に保存。

手動確認: サイドバーの「ウィンドウを追加」を開き、Docker Desktopの項目が表示されることを確認する。
