#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"

# CLAUDE.md
[[ -f "$PROJECT_DIR/.claude/CLAUDE.md" ]] && {
  echo "===== CLAUDE.md の内容 ====="
  cat "$PROJECT_DIR/.claude/CLAUDE.md"
  echo ""
}

# global.mdc
[[ -f "$PROJECT_DIR/.cursor/rules/global.mdc" ]] && {
  echo "===== .cursor/rules/global.mdc の内容 ====="
  cat "$PROJECT_DIR/.cursor/rules/global.mdc"
  echo ""
}

# .cursor/rules 内のすべての .mdc ファイル
# find "$PROJECT_DIR/.cursor/rules"/*/ -name "*.mdc" 2>/dev/null | sort | while read -r file; do
#   [[ -f "$file" ]] && {
#     echo "===== $(basename "$file") の内容 ====="
#     cat "$file"
#     echo ""
#   }
# done

# オプション: ログ出力
# echo "[$(date '+%Y-%m-%d %H:%M:%S')] user-prompt-submit hook executed" >>"$PROJECT_DIR/hook-log.txt"
