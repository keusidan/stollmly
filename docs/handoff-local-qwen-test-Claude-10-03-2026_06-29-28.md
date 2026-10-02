# 引き継ぎ: ローカル qwen2.5:0.5b + Android エミュレーターでの検証

ローカル (Arch) の Claude Code セッション向けの引き継ぎメモ。クラウドのセッションからは
ユーザーの PC・エミュレーター・ローカル LLM に届かないため、ここから先をローカルで進める。

## ゴール

1. CPU 専用のテスト用 LLM (`qwen2.5:0.5b`) で stollmly-host とアプリを通しで動かす
2. Android エミュレーター (android-sandbox) に APK を入れ、スクリーンショットを見ながら改善点を探す
3. 見つけた問題は **GitHub issue に登録 → 自分で修正 → PR → main にマージ** まで行う

## 絶対に守ること

- **GPU を使わない。** テスト用 Ollama は必ず次の設定で動かす (CUDA と Vulkan の両方を無効化)
  ```sh
  OLLAMA_HOST=127.0.0.1:11435 CUDA_VISIBLE_DEVICES=-1 OLLAMA_VULKAN=0 ollama serve
  ```
  起動ログの `inference compute` が `library=cpu` だけであることを確認する。本番用 Ollama (11434) には触らない。
- **他サービスを参考にしたことを書かない。** コード・コメント・コミット・PR・issue・ドキュメントのどこにも、特定の既存サービス名を出さない。
- **PR を作って main にマージするところまで毎回行う** (ユーザー承認済み)。マージ方法は rebase。
- ユーザーの好み: 説明には出典を付ける / 略称は初出で「略称(正式名称)」/ 英語由来の技術用語は英単語のまま / 新規ファイル名の末尾に `Claude-MM-dd-yyyy_HH-mm-ss` (ビルドに影響するソースは除く)。

## 現在の状態 (2026-10-03 時点)

| 項目 | 状態 |
|---|---|
| main | `c124140` (UI 修正 #6〜#9 まで反映) |
| 最新リリース | [alpha-20261002T211557Z](https://github.com/keusidan/stollmly/releases/tag/alpha-20261002T211557Z) (アプリ 5 種) |
| ホストの最新 | [alpha-20261002T202945Z](https://github.com/keusidan/stollmly/releases/tag/alpha-20261002T202945Z) の `stollmly-host-linux-x64` (0.2.0, `/api/v1/embed` 対応) |
| テスト用 Ollama | 127.0.0.1:11435 で CPU 専用で起動済み。**モデルはまだ未取得** (`total blobs: 0`) |
| 確認済み | Linux 版をスマホ幅で起動し偽 LLM で全画面を確認。ユニットテスト 33 件・CI 全ジョブ成功 |
| 未確認 | 実モデル (qwen) での応答の質・書式、Android 実機/エミュレーターでの表示と自動検出 |

## 手順

### 0. 準備

```sh
export OLLAMA_HOST=127.0.0.1:11435
ollama pull qwen2.5:0.5b
ollama list                              # qwen2.5:0.5b があること

# ホスト 0.2.0 を入れて、テスト用 Ollama につなぐ (常駐版は止める)
install -Dm755 ~/Downloads/stollmly-host-linux-x64 ~/.local/bin/stollmly-host
systemctl --user stop stollmly-host
stollmly-host --upstream http://127.0.0.1:11435/v1 --name arch-test   # 別ターミナルで起動したままにする
```

### 1. Ollama 単体

```sh
curl -s http://127.0.0.1:11435/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"qwen2.5:0.5b","messages":[{"role":"user","content":"自己紹介を一文で"}]}' | jq -r '.choices[0].message.content'
```
合格: 日本語の一文が返る。

### 2. ホスト経由 (接続・ストリーミング・出力フォーマット)

```sh
curl -s http://127.0.0.1:47320/api/v1/info | jq .          # version 0.2.0, features に embed
curl -s http://127.0.0.1:47320/api/v1/models               # qwen2.5:0.5b
curl -sN http://127.0.0.1:47320/api/v1/chat -H 'Content-Type: application/json' -d '{"model":"qwen2.5:0.5b","messages":[
 {"role":"system","content":"あなたは「ミオ」を演じる。地の文は *アスタリスク* で囲み、台詞はそのまま書いて交互に並べる。"},
 {"role":"user","content":"待たせてごめん、行こうか"}]}'
```
合格: `{"delta":"..."}` が逐次流れ、最後に `{"done":true}`。`*描写*` と台詞が交互になっているかを記録する
(0.5B は守れないことがある。崩れ方を issue に残す)。

### 3. 重要メモ抽出の書式 (長期記憶で一番崩れやすい)

```sh
curl -s http://127.0.0.1:47320/api/v1/chat -H 'Content-Type: application/json' -d '{"model":"qwen2.5:0.5b","temperature":0.3,"messages":[
 {"role":"system","content":"あなたは物語の記憶係です。会話から忘れたら困る事実を、各行 `- [重要度N] 内容` の形式 (N は 1〜3) の箇条書きだけで出力してください。"},
 {"role":"user","content":"ハル: 週末は海に行こう\nミオ: うん！ 約束だよ。あ、雷が鳴ったら帰るからね。私、雷苦手なの"}]}' \
 | sed -n 's/.*"delta":"\(.*\)"}/\1/p' | tr -d '\n'; echo
```
合格: `- [重要度3] 週末に海へ行く約束` のような行が出る。
崩れる場合: `lib/memory/memory_logic.dart` の `parseFacts` を緩める、または `factsUpdatePrompt` を小型モデル向けに調整し、
`test/memory_test.dart` に実際の崩れた出力を使ったテストを追加する。

### 4. embedding モデルが無いときの扱い

```sh
curl -s http://127.0.0.1:47320/api/v1/embed -H 'Content-Type: application/json' -d '{"model":"bge-m3","input":["テスト"]}'
```
合格: `{"error":"... not found ..."}`。アプリ側は検索だけ自動で無効になり、重要メモ・あらすじは動く。

### 5. Android エミュレーター (android-sandbox)

```sh
adb devices                                   # エミュレーターが見えること
adb install -r stollmly-android.apk           # 最新リリースの APK
adb shell monkey -p io.github.keusidan.stollmly 1
adb exec-out screencap -p > shot.png          # スクリーンショット (画像を見て確認)
adb shell input tap X Y                       # タップ
adb shell input text 'hello'                  # 英数字の入力 (日本語は ADB Keyboard などが必要)
adb logcat -d | grep -i flutter               # クラッシュやエラー
```

確認項目:
- [ ] 設定 → 接続先ホストで「arch-test (10.0.2.2)」が自動で出て、タップ 1 回で接続できる
  (エミュレーターからホスト PC の localhost は 10.0.2.2。#7 で自動検出に追加済み)
- [ ] 白瀬 ミオと新しいトーク → 返事が流れて表示される。書式の崩れ・文字化け・表示崩れがない
- [ ] ⚡ 返答のおすすめ、再生成とスワイプ、続きを書く、編集、編集して送り直す、ここまでで分岐、巻き戻し
- [ ] 記憶画面: 「過去の発言の検索: 一時停止中」(bge-m3 が無いため)、要約済み件数、次の整理まで N 往復
- [ ] 設定の長期記憶で間隔を 5 往復にして 6 往復ほど話す → 重要メモ・あらすじが実モデルで作られるか
- [ ] ダークテーマ、横画面、キーボード表示時のレイアウト
- [ ] アプリ内アップデート画面 (署名鍵は Secrets 登録済み。同じ鍵の APK 同士なら上書き更新できる)

## issue → 修正 → マージの流れ

1. 問題ごとに issue を作る (再現手順・スクリーンショットの説明・原因・対応方針)。末尾に Claude Code のフッター
2. `main` から作業ブランチを切って修正。小さな修正はまとめて 1 PR にしてよい
3. コミット前に必ず:
   ```sh
   flutter analyze
   flutter test
   dart format --output=none --set-exit-if-changed lib test
   (cd host && dart analyze --fatal-infos && dart format --output=none --set-exit-if-changed .)
   ```
4. コミットメッセージに `Fixes #番号`。push すると CI が変更のあったプラットフォームだけビルドしてリリースする
5. CI が全部緑になってから PR を作り、rebase でマージ → issue は自動で閉じる
6. 修正後の APK をエミュレーターに入れ直して、画面で直ったことを確認する

## コードの地図

| パス | 内容 |
|---|---|
| `lib/app_state.dart` | 状態・生成・記憶のスケジュール・接続 |
| `lib/prompt.dart` | プロンプト組み立て (固定部分 → ユーザーノート → 重要メモ → あらすじ → 関連設定 → 過去の発言 → 直近) |
| `lib/memory/` | 長期記憶 (`memory_logic.dart` は純粋関数、`memory_service.dart` はバックグラウンド処理) |
| `assets/prompts/output_format.md` | 応答の書き方の指示 (アプリ内で編集可) |
| `lib/net/` | ホスト探索 (UDP + /24 スキャン + 127.0.0.1 / 10.0.2.2) とクライアント |
| `lib/ui/` | 各画面 |
| `host/bin/stollmly_host.dart` | LAN ブリッジ (依存なしの Dart) |
| `.github/workflows/release.yml`, `.github/scripts/` | 差分ビルドとリリース |

## 既知の制約

- 0.5B は小さすぎてロールプレイの質・書式の遵守は不安定。書式の崩れはアプリ側の読み取りを堅くする方向で対処し、
  モデル自体の質の低さは issue にしない (本番は別モデルの予定)
- 長期記憶の要約・抽出はチャットの生成が始まると中断し、終わってから再開する。CPU 推論だと整理に時間がかかる
- iOS は未署名 IPA のためアプリ内アップデート不可 (リリースページを開くだけ)
