# TabDeskCore 設計メモ

v1 段階 1 で作成し、段階 5 までの実装を反映した設計。仕様は docs/01_spec.md、実測根拠は docs/02_poc_results.md。

## レイヤ構成

```text
UI / アプリ層(段階 2 以降)
   │  register / activate / windowFrameDidChange / reconcile ...
   ▼
TabEngine(@MainActor)        状態 = WorkspaceState(値型)。変更は onStateChanged で通知
   │  WindowDriver プロトコル(frame / setFrame / setPosition / raise)
   ▼
AXWindowDriver(本番)          CGWindowID → AXWindow を引いて AX API を呼ぶ
FakeWindowDriver(テスト)      辞書で frame を持ち、最小サイズ制約・消滅・遅延を再現
```

- **エンジンは AX を知らない。** 実ウィンドウは `CGWindowID` と `pid` でしか扱わず、操作は `WindowDriver` に委ねる。
  これにより Accessibility 権限なしでロジックを検証できる(`scripts/test.sh`)。
- **退避先・配置領域も注入する**(`ScreenLayout`)。本番は主ディスプレイから都度計算、テストは固定値。

## スレッドモデル

- `TabEngine` は `@MainActor`。状態と UI の整合のため。
- AX 呼び出しは相手アプリへの**同期 IPC でブロックしうる**ので、`BlockingExecutor` で GCD のグローバルキューに
  逃がして `await` する。Swift Concurrency の協調スレッド(コア数ぶん)を IPC で塞がないため。
- タブ切替は **pid ごとに直列、pid 間は並列**(`withTaskGroup`)。1 アプリの無応答が他アプリの移動を止めない。
  無応答の上限は `AXWindowDriver.messagingTimeout`(既定 1 秒)で切る。

### 非同期操作の直列化

切替・登録・解除・復元・reconcile は `await` をまたぐ。同時に走ると「古い状態から組み立てた操作」が後から
適用されて整合が崩れる(例: タブ連打で B と C が同時に表示される)。そこで `TabEngine.serialized {}` という
単純な非同期ロック(`isBusy` フラグ+待機側の continuation キュー)で状態を変える操作を直列化している。
`@MainActor` 上なのでフラグ自体に競合はない。内部から別の操作を呼ぶときは `*Unlocked` 版を使い、再入しない。

**IPC はロックの外で**: frame の読み取り(スナップバック前の確認、reconcile のずれ検出)はロックを取らずに
pid 並列で行い、ロック取得後に「まだ登録されているか・退避中でないか・アクティブタブか」を再検証してから
状態を変える。ロック内で逐次 IPC すると、退避中の無応答アプリ 1 つが以後の切替を丸ごと待たせてしまう。
また同期操作(`moveTab` 等)は await の合間に割り込めるので、await 後は配列 index をタブ ID から引き直す。

## 状態の持ち方

- `WorkspaceState`(tabs / activeTabID)は Codable。`ManagedWindow.windowID` / `pid` は実行時専用で JSON に出さない
  (nil = 未復元。再起動後の再同定は段階 4 で実装)。
- 「退避中か」は `TabEngine.parkedWindowIDs` として実行時にだけ持つ。永続化すると再起動後の実態と食い違うため。
  このフラグは「退避操作が成功した」記録であり、操作が失敗すると実位置とずれうる。ずれは `reconcile` が
  「あるべき状態」(アクティブタブの窓は固定 frame に、他は隅に)へ収束させる。
- 固定 frame は「要求値」ではなく「適用後に読み戻した到達 frame」。最小サイズ制約のあるアプリでも、
  以後の比較(スナップバック判定)が成立する。

## 不変条件と判断

| 場面 | 振る舞い | 理由 |
|---|---|---|
| 切替で操作が失敗(無応答・消滅) | 読み戻して到達していれば成功扱い、確認できなければフラグを進めない | AX は「適用後に throw」することがある。実位置とフラグを一致させつつ、不明なら次の切替と reconcile で再試行 |
| 登録・紐付けの配置が失敗 | 読み戻して隅にいれば退避済みとして commit、動いていなければ未登録のまま throw | **エラー時に窓を追跡不能にしない**。適用後 throw で隅へ送った窓を捨てない |
| 解除・タブ削除で復元できない窓がある | throw して登録・退避フラグ・AX 資源を保持する。タブ削除はタブごと残す | 相手アプリが応答したら再試行できる。戻せた窓は reconcile が再び退避する |
| 必須通知(moved / resized)を購読できないアプリ | 登録・紐付けを行わない(窓に触れる前に確立する) | 位置固定が効かない半端な登録を残さない。focused / destroyed は任意で、欠けてもポーリングで補う |
| スナップバックの古い Task | 窓ごとの世代で無効化(sleep 後・IPC 後・ロック取得後に確認) | Task.cancel は IPC 中の Task を止められない。古い値の書き戻しと新しい予約の上書きを防ぐ |
| 終了処理 | `isReleasingForShutdown` を立ててから release。reconcile は入口とロック取得後で中止。終了の返事は cleanup 完了か 3 秒期限の早い方で 1 回だけ | 終了時の release をプロセス終了前の最後の実窓操作にする。AX は cancel 非協調なので期限はタイマーで切る |
| 画面構成の変更・スリープ/ロック解除 | 1 秒デバウンスして `reapplyLayout`(アクティブ窓を新領域へ clamp、非アクティブ窓を新退避点へ) | OS に動かされた窓を配置に戻す |
| 復元の setFrame は成功したが raise が失敗 | 成功扱い(ログのみ) | 窓は見えているのに「退避中」扱いにすると reconcile が隅へ送り返してしまう |
| 既にアクティブなタブを activate | 自タブの窓には触らない(他タブの未退避窓だけ退避) | ドラッグ中の一時 frame を「到達 frame」として採用しないため |
| 復元後に到達 frame ≠ 要求 | 到達 frame を採用 | 自分の操作なのでユーザー操作との競合はなく、制約とみなせる |
| ユーザーの移動/リサイズ通知 | デバウンス(250 ms)後に復元。不一致なら静止を待って最大 3 回、その後採用 | ドラッグ中は ~100 ms 間隔で通知が来る。掴まれている最中の一時状態を制約と誤認しない |
| 退避中ウィンドウの通知 | 無視(編集モードでも) | 退避操作自体が通知を発火させる |
| 編集モードの記録 | 静止後(デバウンス)に記録。サイドバー領域に置かれていればコンテンツ領域へ寄せて窓も動かす | ドラッグ中の一時位置を記録しない。サイドバーの下に固定位置を作らない |
| 固定 frame の入力(登録・配置・編集) | 必ずコンテンツ領域(サイドバーの右側)に寄せる。サイズは変えない | 仕様 §3.2「サイドバー領域は配置領域から除外」。ドラッグ中に一時的に重なるのは許容し、静止後に戻す |
| マウスアップ(全アプリ) | デバウンス待ちの復元/記録を即時実行(`flushPendingRestores`) | ドラッグ終了と同時に戻る。通知の取りこぼし時はデバウンスが保険 |
| 登録解除・タブ削除 | 非アクティブタブの窓(フラグにかかわらず)と退避フラグ付きの窓を固定 frame に戻してから手放す | 画面隅に 1px で取り残さない。「適用済みだが失敗扱い」の退避も拾う |
| 非アクティブタブへの登録 | frame を記録だけして即退避 | 表示されないタブの窓を一瞬出さない。正規化は初回の切替時 |
| アプリごと終了 | 登録は保持し windowID/pid を外す(未復元) | 翌日アプリを起動し直したら自動で戻す |
| destroyed 通知(終了確定でない) | 紐付けだけ外して**消滅保留**にし、猶予 3 秒内に pid が消えたら未復元として保持、生きていれば除去(判定は reconcile) | Chrome 等は全窓を閉じてからプロセスを終えるため、通知時点では区別できない |
| bind(復元・手動割り当て) | 既に別の窓に紐付いたエントリへの bind は拒否(同じ窓なら冪等)。配置が要求に到達しなければ**保存 frame を維持**して紐付けだけ commit | 上書きすると前の窓が追跡不能になる。復元では保存レイアウトこそ守るべき値(実窓は reconcile が寄せる) |
| 登録/紐付けの await 中 | その pid の observer を捨てない(inFlight で保護)。destroyed 購読時に observer が無ければ作り直す | commit 後の窓が必須通知なしになる穴を塞ぐ |
| 再起動後の照合 | `WindowMatcher`: bundle ID 必須、タイトル完全一致 +4 / 部分一致 +2 / サイズ一致 +1 / そのアプリの窓が唯一 +2。起動直後は閾値 2、稼働中は 4 | 誤った窓を引き込む事故より、未復元で残す方を選ぶ |
| TabDesk の終了 | 退避中の全窓を固定 frame に戻してから終了(上限 3 秒) | 永続化がなくても窓を画面隅に取り残さない |
| reconcile(2 秒ポーリング) | 消えた窓を外す(**存在する全窓** `existingWindowIDs()` を渡す。空集合なら削除しない)。アクティブタブなのに退避フラグ付きの窓は復元し直し、非アクティブなのに未退避/隅から外れた窓は退避し直す | AX 通知の取りこぼし(Sequoia 以降の destroyed 欠落)と、失敗した操作によるフラグと実位置のずれに備える。画面上の窓だけ渡すと最小化・別 Space の窓が登録解除されてしまう |

## アプリ層(段階 2、Sources/TabDesk)

- `WindowManager`: `AXWindowDriver` と `TabEngine` を持ち、AX 通知(moved / resized / focusedWindowChanged をアプリ要素に、
  destroyed をウィンドウ要素に登録)をエンジンのメソッドに翻訳する。2 秒ごとに `existingWindowIDs()` で reconcile、
  `NSWorkspace` のアプリ終了通知で登録を外す。destroyed 通知は壊れた要素で届くため、登録時の要素を覚えておき `CFEqual` で突き合わせる
- `SidebarPanel`: 既定で常に最前面(`.floating`)。メニューバーの「サイドバーを常に最前面にする」で通常階層(`.normal`)へ
  切り替えられる(他の窓の下に隠れることがあり、「サイドバーを表示」で前面化する)。設定は UserDefaults に保存
- `SidebarPanel`: `.nonactivatingPanel` + `becomesKeyOnlyIfNeeded` で、クリックしても作業中アプリのキー入力を奪わない。
  改名欄の操作時だけキーになり、終了時に作業アプリへキーを返す。行ビューは `acceptsFirstMouse` を true にして
  「キーでない窓への最初のクリック」も受け取る。状態変更のたびに行を作り直すが、改名中は描画を保留する
- 改名はダイアログ(NSAlert)。非アクティブなパネル内のインライン編集はキー入力が届かず不安定だった
- 座標の検証: `tabdesk://dump` で「記録 frame / AX frame / CGWindowList bounds / サイドバー bounds」を同じ座標系で出し、
  `tabdesk://probe` で自アプリの赤い窓をコンテンツ領域の左上に出す。2026-08-22 の実機確認で、登録した窓は
  サイドバー(x 0〜240)にぴったり隣接していることを全画面スクリーンショットで確認済み
- 開発中は `NSApplicationCrashOnExceptions` を有効にし、AppKit が握りつぶす ObjC 例外(Auto Layout の制約エラー等)で
  気付かないまま UI が出ない事故を防ぐ(ログにも残す)

## 永続化(段階 4)

- `StateStore`: `~/Library/Application Support/TabDesk/state.json` にアトミック書き込み。`WorkspaceState.version` が
  合わなければ `.bak.json` に退避して初期化
- 保存のトリガは `WindowManager` が持つ(エンジンの `onStateChanged` を占有し、0.5 秒デバウンスで保存しつつ UI へ転送)
- 起動時: 権限があれば即座に緩め照合で紐付け。権限が後から付いた場合は最初の reconcile で行う
- 稼働中: reconcile で「新しい窓 ID が現れた」ときだけ(全アプリへの IPC を毎回しないため)厳しめ照合で紐付け

## 列挙(段階 2 レビュー F09 対応)

- `WindowEnumerator.regularApps()`(MainActor、NSWorkspace のみ)→ `enumerateInParallel`(pid ごとに
  `BlockingExecutor` 上で `enumerateWindows(of:)`)の 2 段。MainActor は await するだけで、遅いアプリの
  タイムアウトが積み上がらない。サイドバーは列挙中「読み込み中…」にして完了後にメニューを出す
- reconcile も bound 窓全体の frame を pid 並列で読み、アクティブ窓のずれはデバウンス復元経路へ流す
  (通知を取りこぼしても位置固定が回復する)

## 段階 3〜5の実装状況

- [x] 段階 3: 登録 UI の仕上げ(管理不可アプリの理由表示)、登録ホットキー
- [x] 段階 4: state.json の保存と、再起動後のベストエフォート再同定(`WindowIdentity` を使用)、未復元 UI
- [x] 段階 5: フォーカス連動切替、ホットキー、設定

## 未実装

- ネイティブフルスクリーン中の窓の除外(v2 段階 A で対応中。docs/04_v2_design.md)

(タブの前後移動ホットキーは 2026-08-26、並べ替え UI は 2026-08-28 に実装済み)
