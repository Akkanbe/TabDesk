# 日本語・英語の表示設定

- [x] UI 文言を翻訳ファイルへ集約し、日本語・英語を追加
- [x] メニューからの言語変更と保存、既存画面への即時反映
- [x] 翻訳の整合性と切り替え時のデータ保持をテスト
- [x] 既存テスト、本体・PoC ビルド、画面レイアウトを検証
- [x] 翻訳リソースを同梱した署名済みアプリを準備
- [x] 起動中のアプリを通常終了後、更新版へ入れ替え

メニューバーの「表示言語 / Language」から「日本語」「English」を選ぶ。初期値は日本語。設定は UserDefaults の `DisplayLanguage` に保存する。再起動は不要で、メニュー・全ディスプレイのサイドバー・開いているホットキー設定画面へ反映する。

既存のタブ名、他アプリのウィンドウタイトル、未保存のホットキー入力は変更しない。新しいタブの初期名のみ選択中の言語になる。macOS が提供する権限画面やエラーの詳細は OS 側の言語に従う。開発・診断用 PoC の画面は対象外。

翻訳は `Sources/TabDeskCore/Resources/{ja,en}.lproj/Localizable.strings` に置く。文言追加時は `Localization.swift` の `L10n.Key` と両言語のキー・`%@` の個数をそろえる。引数は `String` で渡す。`scripts/build_app.sh` は翻訳バンドルを `.app/Contents/Resources` に同梱する。

## 操作による確認

1. メニューで「表示言語 / Language」→「English」を選び、メニューとサイドバーが英語になることを確認する。
2. 「Hotkey Settings…」を開き、キーを記録して保存せずに日本語へ切り替える。キー表示が保持されることを確認する。
3. 日本語と英語で、タブの作成・切り替え・名前変更、ホットキーの保存ができることを確認する。
4. 通常終了して再起動し、選んだ言語と既存のタブ名が保持されることを確認する。

## 検証結果

- `./scripts/test.sh`: Core 240 件、UI・運用 16 件が成功（設定画面の配置テストは日英の 2 ケース）。
- `swift build --product TabDesk`、`swift build --product TabDeskPoC` が成功。
- 日英のホットキー設定画面を画像として描画し、ラベルとボタンの収まりを確認。
- `.app/Contents/Resources` に置いた翻訳に識別用の文言を入れる独立プローブで、開発用 `.build` ではなく同梱リソースを読むことを確認。
- `bash -n scripts/build_app.sh`、`git diff --check`、準備済みアプリの `codesign --verify --strict` が成功。

更新版は `build/staged-localization-20260906-002756/TabDesk.app` に準備済み。

タイル機能を含めた最新版は `build/staged-tiles-20260906-090824/TabDesk.app`。上記の言語対応のみの準備版を置き換える。

2026-09-06: タイル機能と合わせて `build/TabDesk.app` に反映し、起動を確認済み。
