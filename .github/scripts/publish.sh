#!/usr/bin/env bash
# 使い方: publish.sh <ファイル>...
# 同じ run の test ジョブが成功するのを待ってから、ファイルと .sha256 をリリースにアップロードする。
# (ビルドはテストと並行して走らせ、公開の直前でだけテスト結果を見る)
set -euo pipefail
: "${TAG:?}" "${GITHUB_REPOSITORY:?}" "${GITHUB_RUN_ID:?}"

for _ in $(seq 1 120); do
  state=$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/jobs?per_page=100" \
    --jq '.jobs[] | select(.name == "test") | "\(.status) \(.conclusion)"' | tail -n 1)
  case "$state" in
    "completed success") break ;;
    completed*) echo "::error::test ジョブが失敗したため公開しません ($state)"; exit 1 ;;
  esac
  echo "test ジョブ待ち: ${state:-not started}"
  sleep 10
done
[ "${state:-}" = "completed success" ] || { echo "::error::test ジョブの完了待ちがタイムアウトしました"; exit 1; }

files=()
for f in "$@"; do
  (cd "$(dirname "$f")" && sha256sum "$(basename "$f")" > "$(basename "$f").sha256")
  files+=("$f" "$f.sha256")
done
gh release upload "$TAG" "${files[@]}" --clobber --repo "$GITHUB_REPOSITORY"
