#!/usr/bin/env bash
# 危険な Bash コマンドをブロックする PreToolUse フックスクリプト

set -euo pipefail

# 理由を stderr に出力し、終了コード 2 で Bash 呼び出しをブロック
# コマンド置換内ではサブシェルだけが終了するため、呼び出し元で失敗を伝播させる
block_and_exit() {
  printf 'pre-bash-guard.sh: %s; Bash command blocked\n' "$1" >&2
  exit 2
}

# PreToolUse イベント JSON の Bash コマンドを、前後の空白を除いて返す
# Bash 以外・空コマンドは出力しない
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

# 引用外のコマンド区切りを、マスク処理と判定ルールで共有
readonly OPERATOR_CHARS=';&|()'

# command が pattern に一致すれば reason を 1 行出力
# 不正な pattern（=~ の終了コード 2）はブロック
emit_if_matches() {
  local command="$1" pattern="$2" reason="$3" status
  [[ $command =~ $pattern ]] && status=0 || status=$?
  case "$status" in
  0) printf '%s\n' "$reason" ;;
  1) ;;
  *) block_and_exit "invalid pattern for rule: $reason" ;;
  esac
}

# Bash の行継続（バックスラッシュ + 改行）を結合して返す
# 行末のバックスラッシュが偶数個の場合とコメント内では、改行を区切りとして残す
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

# echo と git commit の引用内演算子をマスクし、長い入力や複雑な構文はそのまま返す
mask_static_quoted_operators() {
  local command="$1"
  local mask_target='^[[:space:]]*((echo)([[:space:]]|$)|git[[:space:]]+commit([[:space:]]|$))'
  local static_command="^([^'\"${OPERATOR_CHARS}<>]|'[^']*'|\"[^\"]*\")*$"

  # Bash 3.2 での文字列処理の遅延を抑える
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

  # 引用が閉じ、引用外に演算子がなければ、置換対象はすべて引用内にある
  if [[ $command =~ $static_command ]]; then
    command="${command//[$OPERATOR_CHARS]/_}"
  fi
  printf '%s' "$command"
}

# 代表的な直接呼び出しのブロック理由を 1 行ずつ出力（予約語・前置代入・リダイレクト直後、パス・\ 付きに対応）
# 展開、ラッパー（find -exec / xargs / env 等）、引用したコマンド名・引用を含む値、別インタープリタ経由は網羅しない
detect_block_reasons() {
  local command masked_command
  command="$(join_line_continuations "$1")" || block_and_exit 'failed to join line continuations'
  masked_command="$(mask_static_quoted_operators "$command")"

  # コマンド内トークン区切りは空白のみ、改行はコマンド区切り
  local token_char="[^[:space:]${OPERATOR_CHARS}]"
  local token="${token_char}+"
  local token_gap="([[:blank:]]+${token})*[[:blank:]]+"
  local short_flags="[^-[:space:]${OPERATOR_CHARS}]*"

  # 予約語・前置代入・リダイレクトを任意の順で読み飛ばす
  # リダイレクト中の & と | はコマンド区切りより先に消費する
  local reserved_word="(if|then|elif|else|while|until|do|time([[:blank:]]+(-p|--))*|coproc|function[[:blank:]]+${token}|[{!])"
  local assignment="[[:alpha:]_][^[:space:]${OPERATOR_CHARS}=]*=${token_char}*"
  local redirect="([0-9]+|[{][[:alpha:]_][[:alnum:]_]*[}])?&?[<>]+[|&-]?[[:blank:]]*${token}"
  local skip_word="(${reserved_word}|${assignment}|${redirect})"

  # 入力先頭またはコマンド区切りの直後にマッチし、先頭空白を許す
  local newline=$'\n'
  local command_start="(^|[${OPERATOR_CHARS}${newline}])[[:space:]]*(${skip_word}[[:blank:]]+)*"

  # パス付き・alias 回避（\ 付き）の呼び出しも対象とする
  # 代入値をパスと誤認しないよう = を含む語を除く。文字クラス内の \ はリテラル
  local command_prefix="([^[:space:]${OPERATOR_CHARS}=]*/|[\\])?"

  # macOS の大文字小文字を区別しないファイルシステムに合わせ、コマンド名の大小文字を問わない
  local rm_name='[rR][mM]'
  local sudo_name='[sS][uU][dD][oO]'

  # 再帰削除（-r / -R）と強制（-f）は結合・分離・長いオプションに対応し、順序を問わない
  local recursive="(-${short_flags}[rR]${short_flags}|--recursive)"
  local force="(-${short_flags}f${short_flags}|--force)"
  local combined_flags="-${short_flags}([rR]${short_flags}f|f${short_flags}[rR])${short_flags}"
  local rm_flags="(${combined_flags}|${recursive}${token_gap}${force}|${force}${token_gap}${recursive})"
  local rm_recursive_force="${command_prefix}${rm_name}${token_gap}${rm_flags}"

  emit_if_matches "$masked_command" "$command_start$rm_recursive_force" "rm -rf / rm -Rf / rm --recursive --force は許可していません。"
  emit_if_matches "$masked_command" "${command_start}${command_prefix}${sudo_name}[[:space:]]+" "sudo の使用は Claude からは許可していません。"
  # sh / bash の直後が名前の構成文字（英数字 _ . -）なら除外し、リダイレクト直結は検知する
  emit_if_matches "$masked_command" '(curl|wget)[^|]*\|[[:space:]]*(sh|bash)($|[^[:alnum:]_.-])' "curl / wget ... | sh / bash 形式のコマンドは許可していません。"
}

# ブロック理由（1 行 1 件）を JSON にまとめて出力し、Claude に拒否を通知
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

main() {
  # jq がなければポリシーを検証できないためブロック
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
  return 0
}

main "$@"
