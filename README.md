# TabDesk

macOS で他アプリのウィンドウを「タブ」として管理するユーティリティ(開発中)。
リポジトリ: https://github.com/Akkanbe/TabDesk
仕様は [docs/01_spec.md](docs/01_spec.md) を参照。

## 現在の状態: v0 技術検証 PoC

`TabDeskPoC` は、仕様書 §5 の v0 チェックリストを実機で確認するための検証アプリです。
製品 UI ではありません。

### ビルドと起動

フル Xcode は不要(Command Line Tools の Swift で足ります)。

```bash
./scripts/build_app.sh      # swift build → build/TabDeskPoC.app を組み立て
                            # 署名: CODESIGN_IDENTITY > 「WTC Dev」証明書があれば自動使用 > ad-hoc
open build/TabDeskPoC.app
```

初回起動時に「権限をリクエスト」を押し、システム設定 > プライバシーとセキュリティ >
アクセシビリティ で TabDeskPoC を ON にしてください。

**注意(ad-hoc 署名の制約)**: 再ビルドすると署名ハッシュが変わり、設定上は ON のままでも
権限が効かなくなります。OFF → ON では直らないので、アクセシビリティの一覧で TabDeskPoC を
「−」で削除してから「+」で `build/TabDeskPoC.app` を追加し直してください。

#### 再ビルドごとの再付与を避ける(推奨): 自己署名証明書で署名する

TCC はアプリを「署名の識別情報」で覚えます。ad-hoc 署名はビルドごとに識別情報が変わりますが、
自己署名でも証明書で署名すれば識別情報が安定し、再ビルド後も権限が維持されます。

1. キーチェーンアクセス.app を開く → メニュー「キーチェーンアクセス」>「証明書アシスタント」>「証明書を作成...」
2. 名前: `WTC Dev`(任意の名前でよい。別名にした場合は `CODESIGN_IDENTITY` で指定)/
   固有名のタイプ: 自己署名ルート / 証明書のタイプ: **コード署名** → 「作成」
3. 作成した証明書をダブルクリック → 「信頼」>「コード署名」を「常に信頼」にする
4. 以後は識別名を指定してビルドする(`WTC Dev` なら自動検出されるので指定不要):

```bash
CODESIGN_IDENTITY="WTC Dev" ./scripts/build_app.sh
```

証明書を切り替えた直後の 1 回だけは、上記の「−」→「+」で再登録が必要です。

### 画面の使い方

1. 「ウィンドウ一覧を更新」で他アプリの標準ウィンドウを列挙(WID = CGWindowID)
2. 行を選んで「セット A に追加」「セット B に追加」(A/B がタブに相当)
3. 「左半分」「右半分」「全面」で、サイドバー幅 240px を除いたコンテンツ領域に配置
4. 「A を表示」「B を表示」で切替(非表示側は画面右下隅へ退避、1px だけ残る)
5. 「往復ベンチ ×10」で切替時間を計測。「pid 並列」の ON/OFF で比較
6. 「スナップバック監視」ON にして、表示中のウィンドウを手でドラッグ → 元の位置に戻るか確認
7. 「編集モード」ON の間は、動かした位置が新しい固定位置として記憶される

ログは画面下部と `~/Library/Logs/TabDeskPoC/poc.log` に出ます。

### URL スキームによる操作(自動化用)

起動中のアプリに `tabdeskpoc://` で同じ操作を送れます。

```bash
scripts/poc.sh status
scripts/poc.sh list                         # ウィンドウ一覧をログに出す
scripts/poc.sh 'add?set=A&wid=123,456'
scripts/poc.sh 'place?wid=123&where=left'   # left | right | full
scripts/poc.sh 'show?set=B'
scripts/poc.sh 'bench?rounds=10&parallel=1'
scripts/poc.sh 'watch?on=1&mode=debounced&ms=250'   # スナップバック監視(mode=immediate で即時)
scripts/poc.sh 'edit?on=1'                  # 編集モード
scripts/poc.sh 'move?wid=123&x=100&y=50&w=800&h=600'  # 任意 frame へ移動(AX 座標)
scripts/poc.sh log                          # ログ末尾を表示
```

## 構成

```text
Sources/AXShim/    私有関数 _AXUIElementGetWindow を dlsym で解決する C シム(私有 API 依存はここだけ)
Sources/TabDeskCore/   AX ラッパー(ウィンドウ操作・列挙・通知・座標変換)。v1 本体で再利用
Sources/TabDeskPoC/    v0 検証アプリ
Resources/PoC/     PoC の Info.plist
scripts/           ビルド・操作スクリプト
docs/              仕様書
```
