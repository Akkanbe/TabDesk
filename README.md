# TabDesk

macOS で他アプリのウィンドウを「タブ」として管理するユーティリティ(開発中)。
リポジトリ: https://github.com/Akkanbe/TabDesk
仕様は [docs/01_spec.md](docs/01_spec.md) を参照。

## 現在の状態: v3 実装済み(実機確認中)

フル Xcode は不要(Command Line Tools の Swift で足ります)。

```bash
./scripts/build_app.sh      # swift build → build/TabDesk.app を組み立て
                            # 署名: CODESIGN_IDENTITY > 「WTC Dev」証明書があれば自動使用 > ad-hoc
open build/TabDesk.app
```

TabDesk はメニューバー常駐アプリ(Dock には出ない)。起動すると主ディスプレイの左端にサイドバーが出る。
初回起動時にシステムの権限ダイアログが自動で出るので、システム設定 > プライバシーとセキュリティ >
アクセシビリティ で TabDesk を ON にする(ダイアログを閉じてしまった場合はサイドバー上部の「権限をリクエスト」で再表示できる)。

**注意(ad-hoc 署名の制約)**: 「WTC Dev」証明書が無い環境では ad-hoc 署名になります(ビルド末尾に `signed with: -` と出ます)。
この場合、再ビルドすると署名ハッシュが変わり、設定上は ON のままでも権限が効かなくなります(ログ先頭の `trusted=false` で分かります)。OFF → ON では直らないので、アクセシビリティの一覧で TabDesk を
「−」で削除してから「+」で `build/TabDesk.app` を追加し直してください。

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

## テスト

```bash
./scripts/test.sh        # TabDeskCore のユニットテスト(Accessibility 権限不要)
```

エンジンは `WindowDriver` プロトコル越しにしかウィンドウを触らないので、テストでは偽のドライバを
差し込んで切替・復元・整合性維持のロジックを検証している。設計は [docs/03_core_design.md](docs/03_core_design.md)。


### サイドバーの使い方

- 「＋」でタブを作成。タブはクリックで切替、ダブルクリックで改名、右クリックで並べ替え(上へ/下へ移動)・改名・削除
- 「＋ ウィンドウを追加」で開いているウィンドウをアクティブタブに登録。ウィンドウはそのときいた
  ディスプレイに留まる。退避は原則その画面の右下隅だが、そこから別画面へ窓が露出する配置では
  配置全体の安全な右端へ退避する(退避先に 1px の線が残る)。
  ネイティブフルスクリーン中・最小化中のウィンドウは登録候補に出ない(登録済みの窓を後から最小化した場合は登録のまま)
- ウィンドウ行の「×」で登録解除(退避中なら元の位置に戻してから解除)
- タブの右クリックで「レイアウト: 自由配置 / 縦に等分割」を選べる。「縦に等分割」は登録ウィンドウを
  一覧の並び順に左から等幅カラムで敷き詰める(ウィンドウ行の右クリック「上へ/下へ移動」で列順を変更)。
  ウィンドウの追加・削除で列は自動で組み直される。アプリの最小幅制約で列に収まらない窓は
  実際に到達したサイズで記録され、隣の列と重なることがある(仕様)
- 「編集モード」ON の間は、動かした位置・サイズがそのまま固定位置として記憶される。
  OFF のときは、動かしても離して約 0.25 秒後に固定位置へ戻る。
  「縦に等分割」のタブでは編集モードでも記録されず、常に列へ戻る
- サイドバーをクリックしても作業中のアプリのフォーカスは奪わない
- サイドバーの右端をドラッグすると幅を変えられる(160〜400px。離した時点で保存され、窓の配置範囲も追従)
- ヘッダの「«」(または **Ctrl+Option+S**、メニューバーの「サイドバーを折りたたむ」)でサイドバーを
  細いバーに畳める。畳んだ分だけ窓の配置範囲が広がる。細いバーのクリックで元に戻る
  (注意: 自由配置の窓は畳んでも自動では広がらない。「縦に等分割」のタブは追従する)

### ホットキーとフォーカス連動

- 既定のホットキー: **Ctrl+Option+1〜9** でタブ切替、**Ctrl+Tab / Ctrl+Shift+Tab** でタブの順送り/逆送り、
  **Ctrl+Option+R** でフォーカス中の窓をアクティブタブに登録、**Ctrl+Option+E** で編集モード切替、
  **Ctrl+Option+S** でサイドバーの折りたたみ切替。
  注意: グローバルホットキーなので、TabDesk 起動中は Ctrl+Tab が他アプリ(ブラウザのタブ切替等)に届かなくなる。
  不要なら hotkeys.json で `"nextTab": null` のように無効化できる。割当は `~/Library/Application Support/TabDesk/hotkeys.json` を編集して
  メニューバーの「ホットキーを再読み込み」で反映する(`"ctrl+alt+1"` のような表記。修飾キーは ctrl / alt / cmd / shift)
- **フォーカスで自動切替**(既定 ON): Cmd-Tab などで非アクティブタブの窓にフォーカスが移ると、そのタブへ自動で切り替わる。
  メニューバーで OFF にできる
- メニューバーに「ログイン時に起動」トグルあり
- メニューバーの「背景の枠を表示」を ON にすると、窓の配置範囲(コンテンツ領域)の背後に
  うっすらした枠が敷かれ、タブが「容れ物」のように見える(既定 OFF。クリックは素通し)
- メニューバーの「タブサムネイルを表示」を ON にすると、タブを切り替えるたびに離れたタブの
  代表ウィンドウが撮影され、タブ行の下にサムネイルとして表示される(既定 OFF)。
  初回 ON 時に**画面収録**の権限を求められる(付与後は再起動が必要な場合あり。
  macOS の仕様で月次の再承認ダイアログも出る)

タブ構成は `~/Library/Application Support/TabDesk/state.json` に自動保存され、次回起動時に復元される。
再起動後は bundle ID・タイトル・サイズで同じウィンドウを推定して紐付け直す。推定できなかったものは
一覧に「(未復元)」とグレー表示され、クリックするといま開いているウィンドウを手で割り当てられる。
登録したアプリを終了した場合も「未復元」として残り、アプリを起動し直すと自動で戻る(窓だけ閉じた場合は登録から外れる)。

ログ: `~/Library/Logs/TabDesk/tabdesk.log`(メニューバーの「ログを開く」)

### URL スキームによる操作(動作確認・自動化用)

**既定では無効**です。`tabdesk://` は Accessibility 権限を持つ TabDesk への代理操作口になるため、
使うときだけメニューバーの「URL コマンドを許可(自動化用)」を ON にしてください(設定は再起動後も維持されます)。
無効のまま送ったコマンドはログに `URL commands are disabled` と出て無視されます。

```bash
open -g 'tabdesk://status'
open -g 'tabdesk://windows'                # 登録可能なウィンドウ一覧をログに出す
open -g 'tabdesk://tab?name=Work'
open -g 'tabdesk://add?wid=123&tab=Work'   # tab 省略時はアクティブタブ
open -g 'tabdesk://activate?name=Work'
open -g 'tabdesk://remove?wid=123'
open -g 'tabdesk://edit?on=1'
open -g 'tabdesk://restore'               # 未復元エントリの紐付けをやり直す(strict=1 で厳しめ)
open -g 'tabdesk://save'                  # 今すぐ保存
open -g 'tabdesk://dump'                  # 座標の突き合わせ(診断)
open -g 'tabdesk://quit'
```

## v0 技術検証 PoC(TabDeskPoC)

`TabDeskPoC` は仕様書 §5 の v0 チェックリストを実機で確認した検証アプリ(結果は docs/02_poc_results.md)。
ベンチ計測の再実行用に残している。

```bash
PRODUCT=TabDeskPoC ./scripts/build_app.sh
open build/TabDeskPoC.app
```

署名と TCC の注意は上記 TabDesk と同じ(名前は TabDeskPoC / `build/TabDeskPoC.app` に読み替え)。
PoC を証明書で署名し直す場合は `PRODUCT=TabDeskPoC CODESIGN_IDENTITY="WTC Dev" ./scripts/build_app.sh`。

### PoC 画面の使い方

1. 「ウィンドウ一覧を更新」で他アプリの標準ウィンドウを列挙(WID = CGWindowID)
2. 行を選んで「セット A に追加」「セット B に追加」(A/B がタブに相当)
3. 「左半分」「右半分」「全面」で、サイドバー幅 240px を除いたコンテンツ領域に配置
4. 「A を表示」「B を表示」で切替(非表示側は画面右下隅へ退避、1px だけ残る)
5. 「往復ベンチ ×10」で切替時間を計測。「pid 並列」の ON/OFF で比較
6. 「スナップバック監視」ON にして、表示中のウィンドウを手でドラッグ → 元の位置に戻るか確認
7. 「編集モード」ON の間は、動かした位置が新しい固定位置として記憶される

ログは画面下部と `~/Library/Logs/TabDeskPoC/poc.log` に出ます。

### PoC の URL スキーム

起動中の PoC に `tabdeskpoc://` で同じ操作を送れます。

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
Sources/TabDesk/       本体アプリ: サイドバー(NSPanel)・メニューバー・AX 通知とエンジンの配線
Sources/TabDeskCore/   コアモジュール: データモデル・TabEngine(切替/復元/整合性)・AX ラッパー
Tests/TabDeskCoreTests/ エンジンのユニットテスト(偽ドライバ使用)
Sources/TabDeskPoC/    v0 検証アプリ
Resources/<Product>/   各アプリの Info.plist(TabDesk / TabDeskPoC)
scripts/           ビルド・操作スクリプト
docs/              仕様書
```
