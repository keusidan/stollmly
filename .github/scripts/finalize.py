"""ビルド後にリリースノートを書く。何もアップロードされなかったリリースは削除する。

ノートには「各プラットフォームの最新版がどのリリースにあるか」の表を載せる
(差分ビルドなので、1 つのリリースに全プラットフォームが揃うとは限らないため)。
"""

import json
import os
import subprocess

REPO = os.environ['GITHUB_REPOSITORY']
TAG = os.environ['TAG']

PLATFORMS = [
    ('Android', 'stollmly-android.apk', 'arm64 端末向け'),
    ('iOS', 'stollmly-ios-unsigned.ipa', '未署名。AltStore / SideStore 等で署名してインストール'),
    ('Windows', 'stollmly-windows-x64.zip', 'Windows 10/11 x64'),
    ('macOS', 'stollmly-macos.zip', '未公証。初回は右クリック →「開く」'),
    ('Linux', 'stollmly-linux-x64.tar.gz', 'x64, GTK3'),
    ('ホスト (Linux)', 'stollmly-host-linux-x64', 'LLM が入っている PC で動かすブリッジ'),
    ('ホスト (macOS)', 'stollmly-host-macos-arm64', ''),
    ('ホスト (Windows)', 'stollmly-host-windows-x64.exe', ''),
]


def gh(*args: str) -> str:
    return subprocess.run(['gh', *args], capture_output=True, text=True, check=True).stdout


def main() -> None:
    current = json.loads(gh('api', f'repos/{REPO}/releases/tags/{TAG}'))
    uploaded = {a['name'] for a in current['assets']}
    if not any(name in uploaded for _, name, _ in PLATFORMS):
        print('アップロードされたアセットが無いのでリリースを削除します')
        gh('release', 'delete', TAG, '--repo', REPO, '--cleanup-tag', '--yes')
        return

    rels = [
        r for r in json.loads(gh('api', f'repos/{REPO}/releases?per_page=100'))
        if not r['draft'] and r['tag_name'].startswith('alpha-')
        # main のリリースノートでは、変更なしの参照先も main のリリースから選ぶ
        and (os.environ['GITHUB_REF_NAME'] != 'main' or not r['prerelease'])
    ]
    rels.sort(key=lambda r: r['tag_name'], reverse=True)

    def latest_with(asset: str) -> dict | None:
        return next((r for r in rels if any(a['name'] == asset for a in r['assets'])), None)

    rows = []
    for label, asset, note in PLATFORMS:
        if asset in uploaded:
            rows.append(f'| {label} | ✅ このリリース | `{asset}` | {note} |')
            continue
        r = latest_with(asset)
        where = f"[{r['tag_name']}]({r['html_url']})" if r else '—'
        rows.append(f'| {label} | 変更なし → {where} | `{asset}` | {note} |')

    notes = '\n'.join([
        f"Commit: {os.environ['GITHUB_SHA']} ({os.environ['GITHUB_REF_NAME']})",
        '',
        '差分ビルドのため、変更のあったプラットフォームだけをこのリリースに載せています。',
        '',
        '| 対象 | 最新版 | ファイル | 備考 |',
        '|---|---|---|---|',
        *rows,
        '',
        '各ファイルの SHA-256 は同名の `.sha256` を参照してください。セットアップ手順は README にあります。',
    ])
    gh('release', 'edit', TAG, '--repo', REPO, '--notes', notes)
    print(notes)


if __name__ == '__main__':
    main()
