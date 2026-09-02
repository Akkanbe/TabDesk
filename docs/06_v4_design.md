# TabDesk v4 設計メモ: ディスプレイごとのタブ

作成日: 2026-08-31。v4(仕様 §5)の設計判断の記録。進行に合わせて追記する。

## スコープ(2026-08-29 決定、詳細は 2026-08-31 にユーザー確認で確定)

「1 つのアクティブタブが全ディスプレイの窓を支配する」モデルから、**ディスプレイごとの独立タブ**へ:

- タブは 1 ディスプレイに属し、そのディスプレイの窓だけを管理。切替はその画面だけに作用
- サイドバーは各ディスプレイの左端に 1 本(その画面のタブのみ表示)
- ホットキーは「選択中のディスプレイ」(フォーカス窓の画面 → マウスカーソルの画面)に作用

確定した設計課題:

- **移行**: 複数画面混在タブは窓の所属ディスプレイで自動分割。最大グループが元の id と名前を維持し、
  兄弟は「名前 (2)」…。単一画面のタブは無変更
- **切断時**: タブごと凍結(その画面のサイドバーはディスプレイとともに消え、タブは保存されたまま。
  窓は v3 D3 どおり放置。再接続でタブも配置も復活)
- **編集モードの画面間ドラッグ**: 移動先ディスプレイのアクティブタブへ**移籍**
  (タブが無ければ自動作成。ドラッグ=移動の意思表示)
- **サイドバー設定**: 幅は全画面共有、折りたたみは画面ごと(`SidebarCollapsed.<displayID>`)

## 横断設計

- **スキーマ(version=1 維持)**: `Tab.displayID: DisplayID?` — nil は「そのときの主ディスプレイ」
  (v1 純データと空タブ。主画面の役割が移っても凍結しないため)。具体 UUID は物理画面に固定。
  `WorkspaceState.activeTabIDs: [DisplayID: UUID]` を新カスタム init の寛容デコードで追加。
  **旧 `activeTabID` は主ディスプレイのアクティブのミラーとして書き続ける**(旧バイナリへの
  ダウングレード耐性。移行は冪等なので v3↔v4 を行き来しても壊れない)
- **不変量(段階 3 以降)**: タブ内の全窓は `window.displayID == tab.displayID`(両方 nil か同じ具体 ID)。
  タブが正。register / bind / 移籍でエンジンが窓へ書き込む。これにより v3 の窓ベースの
  ディスプレイ解決(clamp / 退避先 / D3 凍結 / columns のグループ化)が無改造で正しく動き、
  **タブごと凍結は D3 から自然に導出される**(凍結タブの全窓が個別に凍結されるため)
- **移行**: 純関数 `WorkspaceState.migratedForPerDisplayTabs(primaryID:)` を **TabEngine.init で適用**
  (アプリにもテストにも効く。init 中は didSet が発火しないので余計な保存や通知は出ない)。冪等
- その他: 選択画面にタブゼロの activateAdjacent は no-op / 画面の最後のタブ削除でその画面の
  active は nil / 凍結タブの activate は `tabDisplayDisconnected` を throw /
  **切替後のアプリ前面化は「切替した画面 == 選択中の画面」のときだけ**(別画面のサイドバークリックが
  キーボードフォーカスを奪わない — nonactivating パネルの思想と一貫)/
  タブの自動命名は「タブ\(その画面のタブ数+1)」(画面をまたぐ名前重複は許容し、URL の
  activate?name は先勝ちのまま)

## 段階構成

- 段階0: 準備(本ドキュメント・setFrame のチェック順・apply のログ・終了時解放のタブ横断 pid 並列化)
- 段階1: モデル+移行(挙動変更なし)
- 段階2: エンジンのディスプレイ別アクティベーション
- 段階3: タブを正とする register/bind+編集モード移籍
- 段階4: 選択ディスプレイ解決+ホットキー
- 段階5: SidebarController(画面ごとサイドバー)+メトリクス+URL

## 段階4〜5 の記録(2026-08-31 実装)

- 段階4: `SelectedDisplayResolver`(純関数)— TabDesk 前面(改名中)/前面 pid 一致なら
  フォーカスキャッシュの画面、それ以外はマウスの画面 → 主。**非同期 AX は使わない**。
  キャッシュはフォーカス通知で無料更新。前面化ルール(切替画面 == 選択画面のときだけ)適用。
  Ctrl+Option+R はフォーカス窓の画面のアクティブタブへ(無ければ自動作成)
- 段階5: `SidebarController` が `[DisplayID: SidebarPanel]` を所有(冪等 rebuild・パネル再利用・
  切断で破棄)。単一スロットのコールバック(onStateChanged / thumbnails.onUpdated /
  suppressAppActivation = 全パネル OR)と権限タイマー・画面変更 observer は controller が 1 つ持つ。
  `onContentAreaChanged` は observer 配列に多重化(枠とサイドバーが購読)。
  パネルは自画面のタブ+自画面のアクティブだけを描画し、「＋」は自画面にタブを作る。
  タブの「上へ/下へ」は同一画面内の隣と入れ替え(グローバル index に写像)。
  `SystemScreenLayout` は全画面から画面別実効幅を減算(プロバイダは `(DisplayID) -> CGFloat`)。
  折りたたみキーは `SidebarCollapsed.<displayID>`(旧キーからシード)。
  メニューの折りたたみ・ホットキー Ctrl+Option+S は選択中の画面のパネルに作用。
  URL: `tab?name[&display=<index>]`、status は `actives=[name@display]` を出力

(過渡状態の注記は解消済みのため削除)

## 仕上げレビュー(2026-09-01)

多エージェントの review workflow は利用上限で 2 回とも未実行に終わったため、レビュー依頼に挙げた
重点リスクを手動で点検した。実害があったのは 1 件:

- **主ディスプレイの役割が実行中に移る**(クラムシェル・配置変更)と、nil タブの実効キーが
  変わるのに activeTabIDs は旧キーに残り、新しい主画面には「アクティブなし」→ 次の reapplyLayout で
  主画面の全窓が退避される。さらに旧キーが接続中の画面(降格した旧主)なら、その画面のサイドバーが
  別画面のタブを active として表示し、新規タブも active になれない
  → `reseedActiveTabsForConnectedDisplays` を reapplyLayout の冒頭で実行: キーとタブの実効画面が
  食い違う entry を外して引き継ぎ候補にし、接続中の各画面で entry が無ければ候補 → 先頭タブで補う
  (移行の actives 規則と同じ)。回帰テスト PrimaryRoleChangeTests

点検して問題なしと判断したもの: 起動間で主が変わった場合の再移行(旧キー entry は移行の filter で
落ちて再播種)/ 凍結タブを指す active での activateAdjacent(index 解決失敗 → 先頭)/ 凍結タブの削除 /
移籍プリミティブの競合(最後の await 以降は同期)/ releaseAll のタブ文脈キャッシュ(旧実装と同じ回数)/
SidebarController と WindowManager の画面変更の二重処理(役割が分かれている)/
ホットキーの n 番目とサイドバーの並びの一致(同じ tabs(on:) 順)/ close() と isReleasedWhenClosed=false。
軽微で許容: 移籍直後のフォーカスキャッシュが旧画面を指す(次のフォーカス通知で更新)/
移行バックアップの判定がタブ id の変化のみ(分割を伴わない移行は退避しない)

## 段階1〜3 の記録(2026-08-31 実装)

- 段階1: スキーマ+移行(挙動変更なし)。移行は TabEngine.init で毎回適用(冪等)。
  分割が起きる初回は WindowManager が `state.v3.bak.json` に退避し、要約をログに残す
- 段階2: アクティブ判定 17 箇所を `isActiveTab`(activeTabIDs ベース)に集約。
  activateUnlocked は対象タブの画面内だけを park/restore し、凍結タブは throw。
  deleteTab の後継は同一画面から。activateAdjacent(offset:on:) は画面内巡回
- 段階3: register/bind は**タブの画面が正**(別画面の窓はタブの画面へ引き込み、
  凍結タブへの登録は throw)。bind コミット時に窓の displayID をタブ値へ正規化。
  編集モードの画面間ドラッグは移籍(reassignForEditedCrossDisplayMove — removeFromState を
  通らないので binding・vanished 猶予・復元世代・parked/fullscreen 状態を保持。
  clearRuntimeTracking の分割は不要になった)。移動先が columns なら組み直す
- **移籍は free タブからのみ**: columns タブは v2 以来「列が唯一の正・ドラッグは常に
  スナップバック」なので、画面間ドラッグも列へ戻す。columns の窓を別画面へ移したいときは
  レイアウトを自由配置に切り替えるか、解除→移動先で登録し直す(確定判断からの詳細化)

## 段階0 の記録(2026-08-31 実装)

- 0945a38(他 AI の v3 修正。精査済みクリーン)の残件: `setFrame` の IPC 後チェック順を
  他経路と同じ「切断 → fullscreen」に統一。apply の error 経路の silent-continue にログを追加
  (切断/fullscreen で反映しなかった失敗を診断できるように)
- **終了時解放のタブ横断化**: `releaseAll` をタブ引数なしにし、窓ごとに所属タブの文脈
  (desiredFrames / isActive)を引き直す方式へ。`releaseAllParkedWindows` は全窓 1 回の呼び出しになり、
  runRelease の pid 並列がタブをまたいで効く — タブ数が増える v4 でも遅いアプリの待ちが
  直列に積み上がらず、3 秒の終了期限を守る。12 箇所のバインディング再検証は逐語維持
