#!/usr/bin/env bash
# Bash 実行前ガードのフック

set -euo pipefail

# 理由を表示して終了コード 2 で終了
# コマンド置換の exit はサブシェルだけに効くため、呼び出し元でも終了させる
block_and_exit() {
  printf 'pre-bash-guard.sh: %s; Bash command blocked\n' "$1" >&2
  exit 2
}

# hook 入力から前後の空白を除いた Bash コマンドを返す
extract_bash_command() {
  local command
  if ! command=$(jq -rse '
    select(length == 1) | .[0]
    | select(type == "object" and (.tool_name | type) == "string")
    | if .tool_name != "Bash" then ""
      else .tool_input
        | select(type == "object")
        | .command
        | select(type == "string" and (contains("\u0000") | not))
      end
  ' 2>/dev/null); then
    block_and_exit 'invalid PreToolUse input'
  fi

  local leading_space='^[[:space:]]+' trailing_space='[[:space:]]+$'
  if [[ $command =~ $leading_space ]]; then
    command="${command:${#BASH_REMATCH[0]}}"
  fi
  if [[ $command =~ $trailing_space ]]; then
    command="${command:0:${#command}-${#BASH_REMATCH[0]}}"
  fi
  [[ -n "$command" ]] || return 0
  printf '%s\n' "$command"
}

readonly OPERATOR_CHARS=';&|()'

# コマンドがパターンに一致すれば理由を出力
emit_if_matches() {
  local command="$1" pattern="$2" reason="$3" status
  [[ $command =~ $pattern ]] && status=0 || status=$?
  case "$status" in
  0) printf '%s\n' "$reason" ;;
  1) ;;
  *) block_and_exit "invalid pattern for rule: $reason" ;;
  esac
}

# 行末の \ による行継続を1行に連結
# 偶数個の行末 \ とコメントでは改行を残す
join_line_continuations() {
  local text="$1" line joined=''
  local continuation=$'\\\n' odd_trailing_backslashes='(^|[^\\])(\\\\)*\\$'
  local comment_start="(^|[[:blank:]${OPERATOR_CHARS}])#"

  if [[ $text != *"$continuation"* ]]; then
    printf '%s' "$text"
    return 0
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ $line =~ $odd_trailing_backslashes && ! $line =~ $comment_start ]]; then
      joined+="${line%\\}"
    else
      joined+="${line}"$'\n'
    fi
  done <<<"$text" || return 1
  printf '%s' "$joined"
}

# echo・git commit の引用内の演算子を _ に置き換えて返す
mask_static_quoted_operators() {
  local command="$1"
  local mask_target='^[[:space:]]*(echo|git[[:space:]]+commit)([[:space:]]|$)'
  local static_command="^([^'\"${OPERATOR_CHARS}<>]|'[^']*'|\"[^\"]*\")*$"

  # Bash 3.2 の長文処理による遅延防止
  if ((${#command} > 1024)) || [[ ! $command =~ $mask_target ]]; then
    printf '%s' "$command"
    return 0
  fi

  case "$command" in
  *'$'* | *'`'* | *$'\\'* | *$'\n'* | *$'\r'*)
    printf '%s' "$command"
    return 0
    ;;
  esac

  # 引用が閉じ、演算子がすべて引用内なら一括置換できる
  if [[ $command =~ $static_command ]]; then
    command="${command//[$OPERATOR_CHARS]/_}"
  fi
  printf '%s' "$command"
}

# コマンドを検査し、該当する拒否理由を1行ずつ出力
# 展開・ラッパー・引用したコマンド名や引用を含む値・別インタープリタ経由は網羅しない
detect_block_reasons() {
  local command masked_command
  command="$(join_line_continuations "$1")" || block_and_exit 'failed to join line continuations'
  masked_command="$(mask_static_quoted_operators "$command")"

  local token_char="[^[:space:]${OPERATOR_CHARS}]"
  local token="${token_char}+"
  local argument="[^[:space:]${OPERATOR_CHARS}<>]+"
  local short_flags="[^-[:space:]${OPERATOR_CHARS}<>]*"

  local reserved_word="(if|then|elif|else|while|until|do|time([[:blank:]]+(-p|--))*|coproc|function[[:blank:]]+${token}|[{!])"
  local assignment="[[:alpha:]_][^[:space:]${OPERATOR_CHARS}=]*=${token_char}*"
  # リダイレクト内の &・| は区切りにしない
  local redirect_body="&?[<>]+[|&-]?[[:blank:]]*"
  local redirect="([0-9]+|[{][[:alpha:]_][[:alnum:]_]*[}])?${redirect_body}${token}"
  local skip_word="(${reserved_word}|${assignment}|${redirect})"
  # 直結するリダイレクトは宛先まで読み飛ばす
  local token_gap="([[:blank:]]+${argument}|[[:blank:]]*${redirect_body}${argument})*[[:blank:]]+"

  # 改行はコマンド区切り
  local newline=$'\n'
  local command_start="(^|[${OPERATOR_CHARS}${newline}])[[:space:]]*(${skip_word}[[:blank:]]+)*"
  local command_end="($|[[:space:]${OPERATOR_CHARS}<>])"

  # 代入値をパスと誤認しないよう = を含む語を除外
  local command_prefix="([^[:space:]${OPERATOR_CHARS}<>=]*/|[\\])?"

  # macOS の大小文字を区別しないファイルシステムに対応
  local rm_name='[rR][mM]'
  local sudo_name='[sS][uU][dD][oO]'

  local recursive="(-${short_flags}[rR]${short_flags}|--recursive)"
  local force="(-${short_flags}f${short_flags}|--force)"
  local combined_flags="-${short_flags}([rR]${short_flags}f|f${short_flags}[rR])${short_flags}"
  local rm_flags="(${combined_flags}|${recursive}${token_gap}${force}|${force}${token_gap}${recursive})"
  local rm_recursive_force="${command_prefix}${rm_name}${token_gap}${rm_flags}"

  emit_if_matches "$masked_command" "$command_start$rm_recursive_force" "rm -rf / rm -Rf / rm --recursive --force は許可していません。"
  emit_if_matches "$masked_command" "${command_start}${command_prefix}${sudo_name}${command_end}" "sudo の使用は Claude からは許可していません。"
  # sh / bash の部分一致を除外し、直結リダイレクトを検知
  emit_if_matches "$masked_command" "(curl|wget)[^|]*\\|[[:space:]]*${command_prefix}(sh|bash)${command_end}" "curl / wget ... | sh / bash 形式のコマンドは許可していません。"
}

# 拒否理由を含む deny 判定の JSON を出力
print_block_json() {
  local command="$1" reasons="$2" decision
  if ! decision=$(jq -n --arg command "$command" --arg reasons "$reasons" '
    ($reasons | split("\n") | map("- " + .) | join("\n")) as $details
    | {
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason: "危険な可能性がある Bash コマンドをブロックしました。\n\nCommand:\n  \($command)\n\nReasons:\n\($details)"
        }
      }
  ' 2>/dev/null); then
    block_and_exit 'failed to create deny decision'
  fi
  printf '%s\n' "$decision"
}

# hook 入力の Bash コマンドを検査し、危険なら deny を返す
main() {
  if ! command -v jq >/dev/null 2>&1; then
    block_and_exit 'jq is required'
  fi

  local command reasons
  command=$(extract_bash_command) || return 2
  [[ -n "$command" ]] || return 0

  if ! reasons=$(detect_block_reasons "$command"); then
    block_and_exit 'failed to evaluate Bash command'
  fi
  [[ -n "$reasons" ]] || return 0

  print_block_json "$command" "$reasons" || return 2
}

main "$@"
