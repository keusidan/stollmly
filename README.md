# stollmly

AI キャラクターとロールプレイで会話するチャットアプリです。
LLM はクラウドではなく **自分の PC (LAN 上) で動いているもの** を使います。

- 対応: Android / iOS / Windows / macOS / Linux (Flutter)
- LLM: Ollama / llama.cpp / LM Studio / vLLM など OpenAI 互換 API を話すもの
- ビルド済みファイル: [Releases](../../releases) (push のたびに `alpha-YYYYMMDDTHHMMSSZ` で自動公開)
  - 前回から変更があったプラットフォームだけをビルドし、できた順にアップロードします。各リリースのノートに「各プラットフォームの最新版がどのリリースにあるか」の表があります
  - 全部ビルドし直したいときは Actions → Build & Release → Run workflow で `force_all` をオン

## しくみ

```
 スマホ / PC の stollmly アプリ                 LLM が入っている PC (例: Arch)
 ┌──────────────────────┐   ① UDP 47321 で発見   ┌──────────────────────────┐
 │ 設定 → 接続           │ ───────────────────▶ │ stollmly-host             │
 │ [arch (192.168.1.10)] │ ◀─────────────────── │  (LAN 専用ブリッジ)        │
 │   ↑ タップで接続       │   ② TCP 47320 で会話   │        │ localhost のみ    │
 └──────────────────────┘ ◀══════════════════▶ │        ▼                  │
                            NDJSON ストリーム     │ Ollama :11434 など        │
                                                 └──────────────────────────┘
```

- LLM 本体 (Ollama など) は `127.0.0.1` に閉じたまま。LAN に出るのは `stollmly-host` だけです。
- `stollmly-host` はプライベート IP (192.168.x.x / 10.x.x.x / 172.16-31.x.x / Tailscale の 100.64/10) 以外からの接続を拒否します。
- アプリは UDP ブロードキャストと /24 サブネットの HTTP スキャンを併用してホストを探すので、**一覧に出た PC をタップするだけ** で接続できます。
- IP が DHCP で変わっても、ホストの永続 ID で同じ PC を見つけ直して自動再接続します。

## LLM ホストのセットアップ

以下は Arch Linux + Ollama の例です。

### 1. LLM を用意する

```sh
sudo pacman -S ollama          # GPU を使うなら ollama-cuda (NVIDIA) / ollama-rocm (AMD)
sudo systemctl enable --now ollama
ollama pull qwen3:14b          # 好きなモデル
ollama pull bge-m3             # 長期記憶の「過去の発言の検索」用 (無くても動きます)
```

llama.cpp (`llama-server`)、LM Studio、vLLM でも構いません。`stollmly-host` が
11434 (Ollama) → 8080 (llama.cpp) → 1234 (LM Studio) → 8000 (vLLM) の順に自動検出します。

### 2. stollmly-host を入れる

[Releases](../../releases) から `stollmly-host-linux-x64` をダウンロードして:

```sh
install -Dm755 stollmly-host-linux-x64 ~/.local/bin/stollmly-host
stollmly-host            # 起動すると接続先の IP が表示されます
```

ソースから動かす場合は `cd host && dart run bin/stollmly_host.dart` です。

常駐させる場合 (systemd ユーザーサービス):

```sh
install -Dm644 host/systemd/stollmly-host.service ~/.config/systemd/user/stollmly-host.service
systemctl --user daemon-reload
systemctl --user enable --now stollmly-host
sudo loginctl enable-linger "$USER"   # ログインしていなくても動かす場合
journalctl --user -u stollmly-host -f # ログ
```

主なオプション (`stollmly-host --help`):

| オプション | 説明 |
|---|---|
| `--upstream URL` | 上流を固定 (例 `http://127.0.0.1:11434/v1`) |
| `--name NAME` | アプリに表示される名前 (既定: ホスト名) |
| `--token TOKEN` | 接続にトークンを要求する (共有 Wi-Fi などで推奨) |
| `--port N` | HTTP ポート (既定 47320) |

### 3. ファイアウォールを開ける

Arch は既定ではファイアウォールが無効です。有効にしている場合だけ、LAN からの TCP 47320 / UDP 47321 を許可します。

```sh
# ufw
sudo ufw allow from 192.168.0.0/16 to any port 47320 proto tcp
sudo ufw allow from 192.168.0.0/16 to any port 47321 proto udp
# firewalld
sudo firewall-cmd --permanent --add-port=47320/tcp --add-port=47321/udp && sudo firewall-cmd --reload
```

### 4. アプリから接続

スマホを PC と同じ Wi-Fi につなぎ、アプリの **設定 → 接続先ホスト** を開くと自動で探します。
一覧に出た PC をタップすれば接続完了です。見つからない場合は「IP アドレスを直接入力」も使えます。

## 長いトークの記憶

1000 往復を超えるような長いトークでも大事なことを忘れないよう、トークごとに 3 段の記憶を持ちます。
毎回 LLM に送る量は会話の長さに関係なくほぼ一定です。

| 記憶 | 中身 | プロンプトに入るタイミング |
|---|---|---|
| 重要メモ | 名前・関係性・約束・出来事・好みなど「忘れたら困る事実」の箇条書き (約 3000 字まで) | 毎回 |
| あらすじ | 区切りごとの要約を畳み込んだ、物語全体のあらすじ (約 1000 字) | 毎回 |
| 過去の発言の検索 | 直近の発言と意味が近い過去の発言を、原文のまま上位 3 件 | 関連するものがあるときだけ |

- 20 往復ごと (設定で変更可) に、新しい会話から事実を抽出して既存の重要メモと統合し、重複削除・矛盾の解消をして書き換えます。上限を超えたら重要度の低いものから圧縮します。
- 要約・抽出はバックグラウンドで行い、チャットの応答を優先します (応答の生成が始まると中断し、終わってから続きを処理)。
- プロンプトは「出力フォーマット・キャラ設定 (固定) → ユーザーノート → 重要メモ → あらすじ → 関連設定 → 過去の発言 → 直近 6 往復」の順です。先頭が毎回同じなので、LLM 側のプレフィックスキャッシュが効きます。
- トーク画面のメニュー →「記憶」で、重要メモとあらすじの閲覧・編集・ピン留め・今すぐ再生成ができます。ピン留めした項目は自動整理で消えません。
- 既存のトークは、開いたときに今までの履歴からまとめて作られます。
- 過去の発言の検索は、ホストの embedding モデル (既定 `bge-m3`) を使います。モデルが無い・失敗したときは検索だけ自動で無効になり、重要メモとあらすじだけで動きます。embedding は端末に保存されます。

### 編集・巻き戻し・分岐との関係

- 発言の編集、「編集して送り直す」、巻き戻し、再生成の候補の切り替えをすると、影響を受けた範囲の記憶は自動で巻き戻り、バックグラウンドで作り直されます (区切りごとにスナップショットを保存しているため)。ピン留めした項目は巻き戻しでも残ります。
- 「ここまでで分岐」で作ったトークは、分岐点までの記憶と embedding を引き継ぎます。分岐元のトークには影響しません。

## アプリのインストール

| OS | ファイル | 備考 |
|---|---|---|
| Android | `stollmly-android.apk` | arm64 端末向け。「提供元不明のアプリ」を許可してインストール |
| iOS | `stollmly-ios-unsigned.ipa` | 未署名。AltStore / SideStore などで自分の Apple ID で署名して入れる |
| Windows | `stollmly-windows-x64.zip` | 展開して `stollmly.exe`。自動更新のため書き込み可能なフォルダ (例: `%LOCALAPPDATA%\stollmly`) に置く |
| macOS | `stollmly-macos.zip` | 未公証。初回は右クリック →「開く」 |
| Linux | `stollmly-linux-x64.tar.gz` | 展開して `./stollmly`。GTK3 が必要 |

## アプリ内アップデート

起動時 (と 設定 → アップデート) に GitHub Releases の最新 `alpha-*` を確認し、新しければ:

- **Android**: APK をダウンロードしてシステムのインストーラーを起動
- **Windows / macOS / Linux**: アーカイブをダウンロード → アプリ終了後に置き換え → 自動で再起動
- **iOS**: 未署名アプリを自分で置き換えられないため、リリースページを開きます

### Android の署名鍵

Android は **同じ鍵で署名された APK** でないと上書き更新できません。鍵はリポジトリに置かず、
GitHub の Settings → Secrets and variables → Actions に次の 4 つを登録して CI に渡します。

| Secret | 内容 |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | keystore (.jks) を `base64 -w0` した文字列 |
| `ANDROID_KEYSTORE_PASSWORD` | keystore のパスワード |
| `ANDROID_KEY_ALIAS` | 鍵のエイリアス |
| `ANDROID_KEY_PASSWORD` | 鍵のパスワード |

未登録の場合はビルドごとに使い捨ての debug 鍵で署名されます (ビルドは通りますが、APK の上書き更新はできません)。

## 開発

```sh
flutter pub get
flutter run                   # 接続先ホストは上の手順で起動しておく
flutter test
cd host && dart run bin/stollmly_host.dart --help
```

| パス | 内容 |
|---|---|
| `lib/models.dart` | キャラ・トーク・プロフィール等のデータ |
| `lib/prompt.dart` | system プロンプト組み立て (固定部分 → 記憶 → 直近の発言) |
| `lib/memory/` | 長期記憶 (要約・重要メモの抽出と統合・巻き戻し・embedding 検索) |
| `assets/prompts/output_format.md` | 応答の書き方 (`*描写*` と台詞を交互に書くチャット形式) の指示。アプリの「設定 → 出力フォーマット」でも編集可 |
| `lib/net/` | ホスト探索 (UDP + サブネットスキャン) とストリーミングクライアント |
| `lib/update/updater.dart` | GitHub Releases からの自己更新 |
| `host/bin/stollmly_host.dart` | LAN ブリッジ (依存パッケージなしの Dart) |
| `.github/workflows/release.yml` | 5 OS + ホストのビルドとリリース |

## 注意事項

- 個人による非営利の実験的プロジェクトです。特定のサービス・企業とは関係ありません。
- 同梱のサンプルキャラクターはすべてこのプロジェクトのオリジナルです。
- 日本語フォント [Noto Sans JP](https://fonts.google.com/noto/specimen/Noto+Sans+JP) (SIL Open Font License 1.1) を同梱しています。ライセンス全文は `assets/fonts/OFL.txt` とアプリの「設定 → オープンソースライセンス」にあります。
- 会話の生成内容は、あなたが動かしている LLM とキャラクター設定に依存します。既存作品のキャラクターを作る場合は、権利者のガイドラインに従い、私的な範囲で楽しんでください。
- `stollmly-host` はインターネットに公開しないでください (ルーターのポート開放は不要です)。
- 本ソフトウェアは MIT License で提供され、無保証です。
