# TabDeskCore 設計メモ

v1 段階 1(コアモデル+切替エンジン)時点の設計。仕様は docs/01_spec.md、実測根拠は docs/02_poc_results.md。

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
  (nil = 未復元。再起動後の再同定は段階 4)。
- 「退避中か」は `TabEngine.parkedWindowIDs` として実行時にだけ持つ。永続化すると再起動後の実態と食い違うため。
  このフラグは「退避操作が成功した」記録であり、操作が失敗すると実位置とずれうる。ずれは `reconcile` が
  「あるべき状態」(アクティブタブの窓は固定 frame に、他は隅に)へ収束させる。
- 固定 frame は「要求値」ではなく「適用後に読み戻した到達 frame」。最小サイズ制約のあるアプリでも、
  以後の比較(スナップバック判定)が成立する。

## 不変条件と判断

| 場面 | 振る舞い | 理由 |
|---|---|---|
| 切替で操作が失敗(無応答・消滅) | その窓の退避/復元フラグを進めない | 実位置が不明。次の切替と reconcile で再試行される |
| 復元の setFrame は成功したが raise が失敗 | 成功扱い(ログのみ) | 窓は見えているのに「退避中」扱いにすると reconcile が隅へ送り返してしまう |
| 既にアクティブなタブを activate | 自タブの窓には触らない(他タブの未退避窓だけ退避) | ドラッグ中の一時 frame を「到達 frame」として採用しないため |
| 復元後に到達 frame ≠ 要求 | 到達 frame を採用 | 自分の操作なのでユーザー操作との競合はなく、制約とみなせる |
| ユーザーの移動/リサイズ通知 | デバウンス(250 ms)後に復元。不一致なら静止を待って最大 3 回、その後採用 | ドラッグ中は ~100 ms 間隔で通知が来る。掴まれている最中の一時状態を制約と誤認しない |
| 退避中ウィンドウの通知 | 無視(編集モードでも) | 退避操作自体が通知を発火させる |
| 登録解除・タブ削除 | 非アクティブタブの窓(フラグにかかわらず)と退避フラグ付きの窓を固定 frame に戻してから手放す | 画面隅に 1px で取り残さない。「適用済みだが失敗扱い」の退避も拾う |
| 非アクティブタブへの登録 | frame を記録だけして即退避 | 表示されないタブの窓を一瞬出さない。正規化は初回の切替時 |
| reconcile(2 秒ポーリング) | 消えた窓を外す(**存在する全窓** `existingWindowIDs()` を渡す。空集合なら削除しない)。アクティブタブなのに退避フラグ付きの窓は復元し直し、非アクティブなのに未退避/隅から外れた窓は退避し直す | AX 通知の取りこぼし(Sequoia 以降の destroyed 欠落)と、失敗した操作によるフラグと実位置のずれに備える。画面上の窓だけ渡すと最小化・別 Space の窓が登録解除されてしまう |

## 未実装(以降の段階)

- 段階 2: サイドバー UI、AX 通知(AppWindowObserver)とエンジンの接続、ポーリングの駆動
- 段階 3: 登録 UI(管理不可アプリのグレーアウト)、登録ホットキー
- 段階 4: state.json の保存と、再起動後のベストエフォート再同定(`WindowIdentity` を使用)
- 段階 5: フォーカス連動切替、ホットキー、設定
