#!/usr/bin/env bash
set -euo pipefail

project_root=$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")"/../.. >/dev/null 2>&1 && pwd -P
)

print_file() {
  local path=$1
  [[ -r $path ]] || return
  printf '===== %s =====\n' "$path"
  cat -- "$path"
  printf '\n'
}

# 必須ルール
print_file "$project_root/.claude/CLAUDE.md"
print_file "$project_root/.cursor/rules/global.mdc"

# オプションルール (rulesディレクトリ以下の.mdcファイル)
find "$project_root/.cursor/rules" -mindepth 2 -type f -name '*.mdc' -print0 2>/dev/null |
  while IFS= read -r -d '' f; do
    print_file "$f"
  done

# オプション: ログ出力
# printf '[%s] user-prompt-submit hook executed\n' "$(date +'%F %T')" >>"$project_root/hook-log.txt"
