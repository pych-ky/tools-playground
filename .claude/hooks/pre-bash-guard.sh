#!/usr/bin/env bash
# Bash 実行前ガード

set -euo pipefail

# 拒否理由を表示して終了
block_and_exit() {
  printf 'pre-bash-guard.sh: %s; Bash command blocked\n' "$1" >&2
  exit 2
}

# hook 入力から Bash コマンドを取得し、前後の空白を除く
extract_bash_command() {
  local command
  command=$(jq -rse '
    select(length == 1) | .[0]
    | select(type == "object" and (.tool_name | type) == "string")
    | if .tool_name != "Bash" then ""
      else .tool_input
        | select(type == "object")
        | .command
        | select(type == "string" and (contains("\u0000") | not))
      end
  ' 2>/dev/null) || block_and_exit 'invalid PreToolUse input'

  # 長い末尾空白で遅くなるパラメーター展開を避ける
  local leading_space='^[[:space:]]+' trailing_space='[[:space:]]+$'
  if [[ $command =~ $leading_space ]]; then
    command="${command:${#BASH_REMATCH[0]}}"
  fi
  if [[ $command =~ $trailing_space ]]; then
    command="${command:0:${#command}-${#BASH_REMATCH[0]}}"
  fi
  printf '%s' "$command"
}

readonly OPERATOR_CHARS=';&|()'

# 一致するルールの拒否理由を出力
emit_if_matches() {
  local status
  [[ $1 =~ $2 ]] && status=0 || status=$?
  case "$status" in
  0) printf '%s\n' "$3" ;;
  1) ;;
  *) block_and_exit "invalid pattern for rule: $3" ;;
  esac
}

# コメント以外の奇数個の行末 \ を行継続として結合
join_line_continuations() {
  local text="$1" line
  local odd_trailing_backslashes='(^|[^\\])(\\\\)*\\$'
  local comment_start="(^|[[:blank:]$OPERATOR_CHARS])#"

  if [[ $text == *$'\\\n'* ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ $line =~ $odd_trailing_backslashes && ! $line =~ $comment_start ]]; then
        printf '%s' "${line%\\}"
      else
        printf '%s\n' "$line"
      fi || return 1
    done <<<"$text" || return 1
  else
    printf '%s' "$text"
  fi
}

# echo・git commit の引用内演算子をマスク
mask_static_quoted_operators() {
  local command="$1"
  local mask_target='^[[:space:]]*(echo|git[[:space:]]+commit)([[:space:]]|$)'
  local static_command="^([^'\"$OPERATOR_CHARS<>]|'[^']*'|\"[^\"]*\")*$"

  # Bash 3.2 の長文処理による遅延防止
  if ((${#command} <= 1024)) && [[ $command =~ $mask_target ]]; then
    case "$command" in
    *'$'* | *'`'* | *$'\\'* | *$'\n'* | *$'\r'*) ;;
    *)
      if [[ $command =~ $static_command ]]; then
        command="${command//[$OPERATOR_CHARS]/_}"
      fi
      ;;
    esac
  fi
  printf '%s' "$command"
}

# コマンドの拒否理由を出力
# 展開・ラッパー・引用を含むコマンド名や値・別インタープリタ経由は網羅しない
detect_block_reasons() {
  local command
  command="$(join_line_continuations "$1")" || block_and_exit 'failed to join line continuations'
  command="$(mask_static_quoted_operators "$command")" || return 1

  local token_char="[^[:space:]$OPERATOR_CHARS]"
  local token="$token_char+"
  local argument="[^[:space:]$OPERATOR_CHARS<>]+"
  local short_flags="[^-[:space:]$OPERATOR_CHARS<>]*"

  local reserved_word="(if|then|elif|else|while|until|do|time([[:blank:]]+(-p|--))*|coproc|function[[:blank:]]+$token|[{!])"
  local assignment="[[:alpha:]_][^[:space:]$OPERATOR_CHARS=]*=$token_char*"
  # リダイレクト内の &・| を区切らない
  local redirect_body="&?[<>]+[|&-]?[[:blank:]]*"
  local redirect="([0-9]+|[{][[:alpha:]_][[:alnum:]_]*[}])?$redirect_body$token"
  local skip_word="($reserved_word|$assignment|$redirect)"
  # 直結リダイレクトは宛先も読み飛ばす
  local token_gap="([[:blank:]]+$argument|[[:blank:]]*$redirect_body$argument)*[[:blank:]]+"

  local newline=$'\n'
  local command_start="(^|[$OPERATOR_CHARS$newline])[[:space:]]*(${skip_word}[[:blank:]]+)*"
  local command_end="($|[[:space:]$OPERATOR_CHARS<>])"

  # 代入値をパスと誤認しない
  local command_prefix="([^[:space:]$OPERATOR_CHARS<>=]*/|[\\])?"

  local recursive="(-${short_flags}[rR]$short_flags|--recursive)"
  local force="(-${short_flags}f$short_flags|--force)"
  local combined_flags="-$short_flags([rR]${short_flags}f|f${short_flags}[rR])$short_flags"
  local rm_flags="($combined_flags|$recursive$token_gap$force|$force$token_gap$recursive)"

  # macOS の大小文字を区別しないパスに対応
  emit_if_matches "$command" "$command_start${command_prefix}[rR][mM]$token_gap$rm_flags" "rm -rf / rm -Rf / rm --recursive --force は許可していません。" || return 1
  emit_if_matches "$command" "$command_start${command_prefix}[sS][uU][dD][oO]$command_end" "sudo の使用は Claude からは許可していません。" || return 1
  emit_if_matches "$command" "(curl|wget)[^|]*\\|[[:space:]]*$command_prefix(sh|bash)$command_end" "curl / wget ... | sh / bash 形式のコマンドは許可していません。"
}

# 拒否理由を deny JSON に整形
print_block_json() {
  local decision
  decision=$(jq -n --arg command "$1" --arg reasons "$2" '
    ($reasons | split("\n") | map("- " + .) | join("\n")) as $details
    | {
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason: "危険な可能性がある Bash コマンドをブロックしました。\n\nCommand:\n  \($command)\n\nReasons:\n\($details)"
        }
      }
  ' 2>/dev/null) || block_and_exit 'failed to create deny decision'
  printf '%s\n' "$decision"
}

# Bash コマンドを検査し、危険なら拒否
main() {
  command -v jq >/dev/null 2>&1 || block_and_exit 'jq is required'

  local command reasons
  command=$(extract_bash_command) || return 2
  [[ -n "$command" ]] || return 0

  reasons=$(detect_block_reasons "$command") || block_and_exit 'failed to evaluate Bash command'
  [[ -n "$reasons" ]] || return 0

  print_block_json "$command" "$reasons" || return 2
}

main "$@"
