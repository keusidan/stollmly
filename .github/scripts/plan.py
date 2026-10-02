"""前回そのコンポーネントを出したリリースから変更があったものだけをビルド対象にする。

各コンポーネントについて「そのアセットを含む最新の alpha リリース」の commit を基準に
git diff を取り、関係するパスに変更があれば build=true を出力する。
基準が見つからない・取得できない・FORCE_ALL=true のときはビルドする。
"""

import json
import os
import subprocess
import sys

SHARED = ['lib/', 'assets/', 'pubspec.yaml', 'pubspec.lock', '.github/']

# コンポーネント名 → (関係するパス, 判定に使うアセット名)
# アセット名は lib/update/updater.dart の assetNameForPlatform と揃えること
COMPONENTS = {
    'android': (['android/', *SHARED], 'stollmly-android.apk'),
    'ios': (['ios/', *SHARED], 'stollmly-ios-unsigned.ipa'),
    'macos': (['macos/', *SHARED], 'stollmly-macos.zip'),
    'windows': (['windows/', *SHARED], 'stollmly-windows-x64.zip'),
    'linux': (['linux/', *SHARED], 'stollmly-linux-x64.tar.gz'),
    'host': (['host/', '.github/'], 'stollmly-host-linux-x64'),
}


def git(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(['git', *args], capture_output=True, text=True)


def releases() -> list[dict]:
    out = subprocess.run(
        ['gh', 'api', f"repos/{os.environ['GITHUB_REPOSITORY']}/releases?per_page=100"],
        capture_output=True, text=True, check=True,
    ).stdout
    items = [r for r in json.loads(out) if not r['draft'] and r['tag_name'].startswith('alpha-')]
    return sorted(items, key=lambda r: r['tag_name'], reverse=True)


def baseline(rels: list[dict], asset: str) -> str | None:
    for r in rels:
        if any(a['name'] == asset for a in r['assets']):
            return r['target_commitish']
    return None


def main() -> None:
    force = os.environ.get('FORCE_ALL') == 'true'
    rels = releases()
    head = git('rev-parse', 'HEAD').stdout.strip()
    results: dict[str, tuple[bool, str]] = {}

    for name, (paths, asset) in COMPONENTS.items():
        base = baseline(rels, asset)
        if force:
            results[name] = (True, '強制ビルド')
        elif base is None:
            results[name] = (True, '過去のリリースなし')
        elif git('cat-file', '-e', f'{base}^{{commit}}').returncode != 0:
            # リベースマージでは祖先関係が切れるが、コミット自体はタグ経由で取れる。
            # 祖先かどうかではなく、ツリーの差分だけを見る
            results[name] = (True, f'基準 {base[:7]} を取得できない')
        elif git('diff', '--quiet', base, head, '--', *paths).returncode != 0:
            results[name] = (True, f'{base[:7]} から変更あり')
        else:
            results[name] = (False, f'{base[:7]} から変更なし')

    with open(os.environ['GITHUB_OUTPUT'], 'a') as out:
        for name, (build, _) in results.items():
            out.write(f'{name}={"true" if build else "false"}\n')
        out.write(f'any={"true" if any(b for b, _ in results.values()) else "false"}\n')

    lines = ['| コンポーネント | ビルド | 理由 |', '|---|---|---|']
    lines += [f'| {n} | {"✅" if b else "⏭️"} | {why} |' for n, (b, why) in results.items()]
    print('\n'.join(lines))
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary, 'a') as f:
            f.write('\n'.join(lines) + '\n')


if __name__ == '__main__':
    sys.exit(main())
