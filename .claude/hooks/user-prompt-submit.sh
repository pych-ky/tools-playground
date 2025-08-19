#!/usr/bin/env bash
set -euo pipefail

# プロジェクトルート
readonly project_root=$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")"/../.. >/dev/null 2>&1 && pwd -P
)

# ファイルを読み込んで表示する関数
print_file() {
  local path=$1
  [[ -r "$path" ]] || return 0

  local rel=${path#"$project_root"/}
  printf '===== %s =====\n' "${rel:-$path}"
  cat -- "$path"
  printf '\n'

  return 0
}

# 必須ルール
print_file "$project_root/.claude/CLAUDE.md"
print_file "$project_root/.cursor/rules/global.mdc"

# オプションルール (rulesディレクトリ以下の.mdcファイル)
readonly rules_dir="$project_root/.cursor/rules"
if [[ -d "$rules_dir" ]]; then
  find "$rules_dir" -mindepth 2 -type f -name '*.mdc' -print0 |
    while IFS= read -r -d '' f; do
      print_file "$f"
    done
fi

# オプション: ログ出力
# printf '[%s] user-prompt-submit hook executed\n' "$(date +'%F %T')" >>"$project_root/hook-log.txt"
