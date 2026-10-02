# stollmly

AI キャラクターとロールプレイで会話するチャットアプリです。
LLM はクラウドではなく **自分の PC (LAN 上) で動いているもの** を使います。

- 対応: Android / iOS / Windows / macOS / Linux (Flutter)
- LLM: Ollama / llama.cpp / LM Studio / vLLM など OpenAI 互換 API を話すもの
- ビルド済みファイル: [Releases](../../releases) (push のたびに `alpha-YYYYMMDDTHHMMSSZ` で自動公開)

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

## アプリのインストール

| OS | ファイル | 備考 |
|---|---|---|
| Android | `stollmly-android.apk` | 「提供元不明のアプリ」を許可してインストール |
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
| `lib/prompt.dart` | system プロンプト組み立て (設定・ロア・ノート・履歴の切り詰め) |
| `lib/net/` | ホスト探索 (UDP + サブネットスキャン) とストリーミングクライアント |
| `lib/update/updater.dart` | GitHub Releases からの自己更新 |
| `host/bin/stollmly_host.dart` | LAN ブリッジ (依存パッケージなしの Dart) |
| `.github/workflows/release.yml` | 5 OS + ホストのビルドとリリース |

## 注意事項

- 個人による非営利の実験的プロジェクトです。特定のサービス・企業とは関係ありません。
- 同梱のサンプルキャラクターはすべてこのプロジェクトのオリジナルです。
- 会話の生成内容は、あなたが動かしている LLM とキャラクター設定に依存します。既存作品のキャラクターを作る場合は、権利者のガイドラインに従い、私的な範囲で楽しんでください。
- `stollmly-host` はインターネットに公開しないでください (ルーターのポート開放は不要です)。
- 本ソフトウェアは MIT License で提供され、無保証です。
