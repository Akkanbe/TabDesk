# TabDesk v3 設計メモ

作成日: 2026-08-30。v3(仕様 §5)の設計判断の記録。進行に合わせて追記する。

## スコープ(2026-08-29 決定、§5 参照)

- 段階0: 外部リファクタ(4c1244f, b40727e)精査で見つかった問題の後始末
- 段階1: D3 — ディスプレイ切断中の論理 frame 温存(精査 High の修正を含む)
- 段階2: 登録済みの窓がネイティブフルスクリーンになった場合の対処
- 段階3: サイドバーの幅ドラッグ変更+全体折りたたみ(確定: 右端ドラッグ / クリック+ホットキー)
- 段階4: 背景「枠」ウィンドウ
- 段階5: タブサムネイル(確定: タブ切替時に静止画撮影)

横断方針: **スキーマ変更なし**(version=1 維持。新しい状態はすべて実行時 or UserDefaults)。
エンジンの AX 非依存維持(ドライバ表面の追加は段階2の isFullscreen のみ)。
ScreenCaptureKit は TabDesk モジュールの 1 ファイルに隔離。

## 段階0 の記録(2026-08-30 実装)

外部リファクタの精査結論: 良い修正が多い(L字配置の退避点、シャットダウン中の復元競合の実バグ修正、
列挙のスナップショット一貫性)。SidebarRows.swift への分離は逐語移動。一方で以下を修正した:

- **Space 切替の再照合ストーム**: activeSpaceDidChange が未復元エントリの存在中、Space 切替のたびに
  全アプリ AX 列挙(リトライ込み×2)を起動していた → 15 秒クールダウンを追加。
  フルスクリーン解除後の再照合という本来の目的は 1 クールダウン以内に果たされる
- **形骸化テストの復元**: parkPoints 導出値は仕組み上すべての画面で隅 x が一致するため、
  「自分の画面の隅と比較する」規則のテストが検証不能になっていた → 隅 x が異なる退避点を
  手書きしたフィクスチャに変更
- endLayoutTransition のガードを無条件化(フラグを下ろす操作を条件付きにしない)
- restoreGeneration の剪定(removeFromState / unbindWindows。isLatest はキー欠損 = 無効なので安全)
- releaseAll の到達 frame 採用に apply と同じ許容誤差ゲート(終了のたびのサブポイント蓄積を防止)
- 仕様書 §5 に tabdesk:// 既定 OFF の安全性根拠を復元(リファクタで消えていた)

**段階1 で直す High**(このコミットでは未修正): reapplyLayout / releaseAll が未復元エントリを含む
全窓の論理 frame を主ディスプレイへ clamp して保存するため、モニタ電源サイクル・スリープ復帰・
切断中の終了で保存配置が不可逆に壊れる。

## 段階1 の判断(2026-08-30 実装): D3 = 切断退避

`displayID` が非 nil かつ接続中ディスプレイに無い窓は「切断退避」として扱う:

- **記録 frame / displayID を凍結**し、**op を一切発行しない**(park / restore / retile / snapback)。
  op を出すと macOS が生きている画面へ clamp した結果を採用経路(apply / releaseAll /
  performRestore)が記録へ書き戻すため、clamp の抑止だけでは足りない — これが設計の本質
- 実窓は macOS が置いた場所に放置。bind(place 省略)・生存管理・focus 追跡は継続。
  解除・タブ削除・終了時も実窓に触らず、退避フラグだけ畳む(記録座標は次回の復元材料)
- **再接続は無状態で自動復帰**: displays は毎アクセス再計算なので、次の reapplyLayout の
  通常経路が記録 frame へ復元する。ディスプレイ集合の差分検知は不要
- `displayID == nil`(v1 データ)は従来どおり「主ディスプレイ」の意味で、切断扱いにしない
- **計画からの変更**: 編集モードでの「切断中の窓を生きている画面へ引っ越し記録する」例外は
  実装しなかった。OS による切断時の移動とユーザーのドラッグは通知から区別できず、barrier 解除後に
  遅延して届いた OS 移動の通知 1 発で凍結 frame が上書きされる(テストで実証)。
  位置を変えたい場合は解除→再登録(サイドバーのツールチップに記載)
- UI: 該当ウィンドウ行に「(別ディスプレイ待機)」+グレー表示。画面構成変更時に描画キャッシュを破棄
- 既知の許容: 非アクティブタブの切断窓は再接続まで画面に見えたまま(v4 のディスプレイごとタブで再訪)

これにより精査 High(電源サイクル・スリープ復帰・切断中終了での保存配置の不可逆破壊)は解消。

## 段階2 の判断(2026-08-30 実装): フルスクリーン化した登録済み窓

- `WindowDriver` に `isFullscreen(of:)` を追加(AX 実装は保持済み AXWindow の属性読み。fail-open)。
  エンジンの AX 非依存は維持(ドライバが唯一の窓感覚器官という設計のまま)
- エンジンは実行時集合 `fullscreenWindowIDs` を持ち、reconcile の既存 pid 並列バッチ
  (observedFrames → observedStates)で毎 tick 更新。読めなかった窓は前回判定を維持
- **op 発行の抑止は D3 と共通ゲート**(`opsSuppressed(for:)`)。D3 との意図的な差:
  フルスクリーン中も記録 frame の更新(clamp / 列計算)は続ける — ディスプレイは接続中なので
  論理配置を正しく保ち、解除後にそこへ戻す。op だけを止める
- **進入レース対策**: 進入時の resize 通知は次の reconcile より先に届く。performRestore が
  frame と同じ IPC バッチで isFullscreen を読み直し、真なら集合に入れて即 return —
  「3 回試行 → フルスクリーン寸法を採用」という記録破壊を構造的に防ぐ
- 解除は次の reconcile(2 秒以内)が検出して自動復帰。解除直後のずれは既存のずれ検知が復元
- 解除・タブ削除・終了はフルスクリーン窓に触れず登録だけ手放す。`tabdesk://status` に
  fullscreen カウントを追加
- 残存する既知の狭い競合: op の IPC 実行中とちょうど同時に進入した場合、その 1 op 分の採用が
  起こりうる(次の構造イベントまで無害、ウィンドウは最大 2 秒で集合入り)

## 段階3 の判断(2026-08-30 実装): サイドバー幅ドラッグ+折りたたみ

- `PersistedNumber`(PersistedToggle の数値版)+ `SidebarMetrics`(min 160 / max 400 /
  折りたたみ 16 / 既定 240)。実体は UserDefaults なのでコピー間・モジュール間で共有される
- `SystemScreenLayout` の幅を `@Sendable () -> CGFloat` プロバイダに変更。TabEngine は
  existential として**独立コピー**を持つため、stored let では変更が伝わらない — closure 越しの
  共有参照が本質(固定幅の互換 init も残した)
- `WindowManager.applySidebarWidthChange()`: ユーザー操作起点なので 1 秒デバウンスを挟まず
  begin → reapply → end を即時実行。generation を進めて並行する画面変更 Task の早期解除を防ぐ。
  完了後に `onContentAreaChanged` フック(段階 4 の枠が使う)。権限が無くてもフックは呼ぶ
- リサイズハンドル(右端 8px): パネルは `.nonactivatingPanel` でキーにならないため、
  カーソル追跡は `.activeAlways` が必須。ドラッグ中はパネルだけライブリサイズし、
  離した時点で幅を確定して窓をリフローする(ドラッグ中に窓を動かすと 100ms 級の AX IPC が連発するため)
- 折りたたみ: ヘッダ「«」/ 細いバー全面の「»」ボタン / ホットキー(既定 ctrl+alt+s、
  hotkeys.json 後方互換: キー無し = 既定、明示 null = 無効)/ メニュー項目。
  表示切替は render() の state 差分と独立のメソッドで行う
- 既知の非対称: clamp は位置しか動かさないので、狭めた/畳んだとき free の窓は空いた領域へ
  **広がらない**(columns は追従する)。広げたときは free の窓も押し出される

## 段階4 の判断(2026-08-30 実装): 背景「枠」ウィンドウ

- `FrameWindowController` がディスプレイごとに 1 枚、contentArea を覆う borderless ウィンドウを敷く
  (`[DisplayID: NSWindow]` — v4 のディスプレイごとサイドバーの下敷きを兼ねる構造)
- レベルは `.normal - 1`(全アプリの窓の背後、デスクトップの手前)。**`ignoresMouseEvents = true` は必須**
  (無いと窓の隙間のクリックを枠が奪う)。canJoinAllSpaces + stationary + fullScreenAuxiliary
- 座標は `ScreenGeometry.axRect(fromCocoa:)` の自己逆変換で AX → Cocoa(手書きの反転はしない)
- 再構築の契機: 画面構成変更通知+段階 3 の `onContentAreaChanged`(幅変更・折りたたみ)
- **既定 OFF**: 明示登録制では未登録の窓が枠の上に浮くため「容れ物」の錯視が弱く、
  アップデートで突然見た目が変わるのも避ける。メニュー「背景の枠を表示」でワンクリック ON。
  実運用の感触で既定を再検討する
- 見た目は角丸 10 + underPageBackgroundColor 50% + separatorColor 1px(実機で微調整前提)

## 段階5 の判断(2026-08-30 実装): タブサムネイル

- **既定 OFF・メニュー「タブサムネイルを表示」でオプトイン**。画面収録権限のプロンプト
  (と macOS 仕様の月次再承認ダイアログ)は、機能を有効にしたときだけ出す
- 撮影は `SCScreenshotManager.captureImage` のワンショット静止画(常時ストリームなし =
  メニューバーの収録インジケータも出ない)。`SCContentFilter(desktopIndependentWindow:)` は
  退避中・隠れた窓もそのまま撮れるため、**切替完了後の撮影でタイミング競合が無い**
- 撮影タイミングはタブ切替時(確定済み)。全切替経路(クリック・ホットキー・フォーカス連動)が
  通る `performFocusSwitch` にフックし、離れたタブの代表窓
  (`Tab.representativeWindow` = lastFocused → 先頭 bound)を撮る
- キャッシュは `ThumbnailStore`(tab.id キー)。行ビューは state 変更のたびに作り直されるため、
  行にキャッシュは置けない。撮影完了は onUpdated → 差分キャッシュ破棄 → 再描画
- 失敗(権限剥奪・窓消滅・SCK エラー)はサイレント劣化(古い画像を残す)+初回のみログ
- UI: タブ行の名前の下に高さ 64px(右横では行幅 200px 級に対して小さすぎる)。OFF 時は従来と同一
- 権限 UX: アクセシビリティと同型の第 2 バナー(`CGPreflightScreenCaptureAccess` 判定、
  Privacy_ScreenCapture への deep link)。有効化時に `CGRequestScreenCaptureAccess()`。
  Info.plist の purpose-string は**追加しない**: macOS の画面収録 TCC に対応する purpose-string
  キーは存在せず(NSScreenCaptureUsageDescription を tccd は読まない)、ダイアログ文言はシステム固定
- サムネイルはセッション内のみ(永続化しない。次回起動時は切替のたびに埋まっていく)
