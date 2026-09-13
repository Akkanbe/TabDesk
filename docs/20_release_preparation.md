# 加入前の配布準備（2026-09-13）

- [x] 現行ビルド、ロゴ、設定・ログ保存先、復旧操作を確認
- [x] 開発用と分離したRelease成果物と検証情報の生成
- [x] 既存ロゴからmacOSアイコンを生成してバンドルへ同梱
- [x] 導入・操作・更新・バックアップ・復旧・アンインストールの案内
- [x] テスト、本体・PoCビルド、ZIP展開後の署名・リソース確認
- [x] 実施結果と未検証項目を記録

アプリの操作ロジック・保存形式・依存関係は変更しない。配布準備用成果物は未公証であり、一般配布用の完成版ではない。
ライセンスと正式な対応OS範囲の決定、Developer ID署名・公証、別のMacでの導入検証は後続作業。

## 変更内容

- `scripts/prepare_release.sh`: Apple Siliconのローカル検証用Releaseビルド。毎回新しい出力フォルダを使い、ZIP・SHA-256・版番号・CPU・コミット・未コミット変更の有無・ツール情報・実際の署名情報・利用ガイドを記録する。未公証と明記し、公開は行わない。
- `scripts/build_app.sh`: 出力先を `APP_OUTPUT_DIR` で変更可能にした。署名・バンドル検証を終えてから既存アプリを退避し、新版を配置する。失敗した組み立て内容と旧版は削除せず残す。
- `scripts/build_icon.sh` とInfo.plist: 採用済みPNGから16〜1024pxのアイコンを生成し、アプリへ同梱。macOS標準ツールだけを使用する。
- `docs/user_guide.md` とREADME: 利用者向け手順と開発者向け配布準備コマンドを追加。macOS設定領域のバックアップも、JSONファイルのコピーとは分けて説明する。

## 検証結果

- `./scripts/test.sh`: Core 267件、アプリ層29件、計296件成功。
- `./scripts/prepare_release.sh`: 成功。`0.1.0` / build `1`、arm64、`WTC Dev`署名のRelease版を作成。
- 通常のDebug版と `PRODUCT=TabDeskPoC` のビルドも、専用出力先で成功。
- スペース入りの出力パスで検証。意図的に存在しない署名IDを指定したビルドは失敗し、配置済み実行ファイルのSHA-256は不変。その後の正常ビルドで旧版が `previous-TabDesk.app` として保持され、元のハッシュと一致。
- ZIPを `/tmp` の新規フォルダに展開し、`codesign --verify --deep --strict` とInfo.plist検証が成功。
- 同梱ICNSを再展開でき、256pxのプレビューで図案・透過・余白を目視確認。
- 展開した翻訳バンドルを使い、実際の `Localization.swift` を組み込んだ検証用実行ファイルで日英各144キーの読み込み成功。SwiftPMの開発用リソースへフォールバックした場合は失敗する構成で検証した。
- `bash -n` と `git diff --check`: 成功。
- 既存 `build/TabDesk.app` の実行ファイルSHA-256は作業前後で一致。普段使っているアプリや設定の入れ替え・起動・終了は行っていない。

検証用成果物: `build/release-preparation/TabDesk.dZRZ5U/`

ZIP: `TabDesk-0.1.0-build1-arm64-unnotarized.zip`

SHA-256: `98c58b9fb8d64aa39cc8ed48aa164fdc951bfd04b8de4ab49c94eff7fde9696a`

コミット `9efe66d` に今回の未コミット変更を加えた状態。`working_tree_dirty=true` と記録されている。
この成果物は署名済みだがDeveloper ID署名・公証済みではなく、一般公開可能という意味ではない。

## 再確認手順

1. リポジトリで `./scripts/test.sh` を実行する。
2. `./scripts/prepare_release.sh` を実行し、末尾の出力先を開く。
3. 出力先で `shasum -a 256 -c SHA256SUMS` を実行する。
4. ZIPを別フォルダへ展開し、`codesign --verify --deep --strict /展開先/TabDesk.app` を実行する。パスは実際のものへ置き換える。
5. Finderの「情報を見る」でバージョンとアイコンを確認し、付属の `USER_GUIDE.md` を読む。
6. アプリの起動確認を行う場合は、利用ガイドに沿って旧版の通常終了・窓の復元・設定バックアップを先に済ませる。

## 残る確認

- [ ] ライセンス・公開範囲を所有者が決定する。
- [ ] macOS 15を含む正式な対応OS範囲を実機検証で確定する。
- [ ] 最終配布版を別のMacにブラウザ経由で取得し、Gatekeeper、初回権限、実際のGUI表示、更新と復旧を確認する。
- [ ] Developer ID署名・公証後に同じ検証を実施する。

今回のリソース検証は、実際のアプリのGUI起動や別のMacでの導入試験を代替するものではない。
