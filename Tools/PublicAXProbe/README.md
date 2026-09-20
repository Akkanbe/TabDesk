# 公開Accessibility APIの検証ツール

本体を切り替える前に、CGWindowIDなしで同じ窓を追跡できるか調べる試作。
`PublicAXProbe` はAX情報の読み取りと通知購読だけを行い、窓の位置変更・前面化・設定保存は行わない。
`PublicAXFixture` は検証用の独立したAppKitアプリで、自分の窓だけを操作する。
窓番号はFixture自身の `NSWindow.windowNumber` を比較記録に出すだけで、Probeの識別には使わない。

## ビルド

```bash
./scripts/build_public_ax_probe.sh
```

macOS標準のSwiftコンパイラとフレームワークだけを使用する。
Probeは必要な公開API実装ファイルを直接コンパイルし、AXShimやTabDeskCore全体をリンクしない。
Fixtureは開発用のad-hoc署名。配布用アプリではない。検証実行中は再ビルドしないこと。

## 専用窓での確認

以下をリポジトリのターミナルで実行する。検証中は専用の窓が表示され、フルスクリーン操作では作業画面が一時的に切り替わる。

```bash
tabdesk_probe_run="$(mktemp -d "$PWD/build/public-ax-probe/run.XXXXXX")"
echo "$tabdesk_probe_run"
build/public-ax-probe/PublicAXFixture.app/Contents/MacOS/PublicAXFixture "$tabdesk_probe_run" > "$tabdesk_probe_run/fixture.jsonl" 2> "$tabdesk_probe_run/fixture.err" &
tabdesk_fixture_pid=$!
build/public-ax-probe/PublicAXProbe "$tabdesk_fixture_pid" 240 0.25 > "$tabdesk_probe_run/probe.jsonl"
```

Probeが開始前に失敗した場合も、Fixtureは残るので末尾の終了手順を実施する。
権限がなければProbeはエラー終了し、自動で権限ダイアログを要求しない。実行元のターミナル等のアクセシビリティ設定を確認する。
起動直後は窓情報が不完全な場合がある。Fixtureを前面に表示し、Probeの出力で `AXRole=AXWindow` を確認する。

別ターミナルで、表示された実際のrunフォルダを指定してコマンドを書く。`番号:操作` の形式で、番号を変えると同じ操作も再送できる。

```bash
printf '%s\n' '1:focus-a' > /実際のrunフォルダ/command.txt
printf '%s\n' '2:focus-b' > /実際のrunフォルダ/command.txt
```

各操作後に `state.json` の `command` を確認し、フルスクリーンなどのアニメーション完了も待つ。
続けて `rename`、`maximize`、`fullscreen`、`normal`、`overlap`、`minimize`、`restore`、`close-a`、`create-a` を試せる。
`maximize` は通常窓を画面まで拡大し、`fullscreen` はmacOSのネイティブフルスクリーンへ入る操作で、別々に比較する。

最後に `99:quit` を同じファイルへ書き、Fixtureを通常終了する。Fixtureは元の前面アプリへの復帰を試みる。

## 見る項目

- 初期状態の2枚はタイトル・位置・サイズが同じでも、`reference` が別々になること。
- フォーカスを変えると `focus` が対応する参照IDに変わること。
- 移動・改名・最小化・フルスクリーン前後でも、同じ窓の参照IDを保持すること。
- `close-a` の破棄通知で元の参照IDが検出され、`create-a` では新しいIDになること。
- `AXFullScreen` は読み取らない。公開のフルスクリーンボタン属性や位置・サイズの書き込み可否を記録し、Fixtureの `fullscreen`（NSWindow自身の状態）と比較する。
- `unknown`、属性取得エラー、`rejectedNonWindowReference` を成功として数えない。

窓のタイトルそのものは記録せず、同じタイトルに同じ `titleGroup` 番号を割り当てる。
ボタンのヘルプ文字列や座標は記録されるため、他アプリのログを共有する場合は確認する。
終了後に開き直したProbeは新しいセッションなので、同じ窓にも新しい実行時IDが付く。

この試作は参照の追跡だけを検証する。本体の消滅判定・終了時の復旧・再同定・メモリ上の参照回収を完成させるものではない。
公開属性の値の変化を観測できても、それだけで全アプリ共通のフルスクリーン判定が成立したとは扱わない。

## 本体の書き込み保護を確認する

```bash
./scripts/build_layout_write_check.sh
```

Fixtureを起動した状態で、実際のcontrolフォルダを指定して次を実行する。

```bash
build/public-ax-probe/LayoutWriteCheck /実際のrunフォルダ movable
```

Fixtureの窓Aだけを10px移動して元に戻し、実際の位置変更が成功することを確認する。
`fullscreen` コマンドを送り、`state.json` の窓Aが `fullscreen: true` になってアニメーションが終わったら、次を実行する。

```bash
build/public-ax-probe/LayoutWriteCheck /実際のrunフォルダ fixed
```

位置・サイズ・配置・前面化の4操作がすべて拒否され、窓の位置とサイズが変わらないことを確認する。
`normal` で通常状態に戻し、再び `movable` の確認を行ってからFixtureを終了する。
対象のbundle ID・PID・Fixtureが記録した窓番号を確認し、一意に特定できない場合は操作せず失敗する。

このチェックは製品と同じTabDeskCoreをリンクする。非公開関数のシムは使用しない。
先にFixtureへ `rename` コマンドを送り、Aだけ固有名にしてからLayoutWriteCheckを実行する。
読み取り専用のPublicAXProbeとは異なり、「非公開関数が一切ない実行ファイル」の確認用ではない。

## 製品Coreによるタブ切り替え・復旧の検証

`./scripts/build_layout_write_check.sh` は `ReferenceEngineCheck` もビルドする。
新しく起動したFixture（同名・同サイズ・同位置の2枚）に対して次を実行する。

```bash
build/public-ax-probe/ReferenceEngineCheck <fixture-control-directory>
```

登録・退避・タブ変更・保存JSONの往復・終了時復旧をメモリ内のWorkspaceStateで実行する。
最後にFixtureのAだけを閉じ、通知を使わない失効検出と登録保持を検証する。
実ユーザーのTabDesk設定は読み書きしない。ロック中や画面構成の変更中には操作試験を開始しない。
