#!/usr/bin/env bash
# 危険な Bash コマンドをブロックする PreToolUse フックスクリプト

set -euo pipefail

# 入力

# 安全側に倒して、理由を stderr へ通知したうえで終了コード 2 で Bash 呼び出しをブロック
# コマンド置換の中から呼ぶとサブシェルだけが終了するため、呼び出し元は失敗を伝播させる
block_and_exit() {
  printf 'pre-bash-guard.sh: %s; Bash command blocked\n' "$1" >&2
  exit 2
}

# PreToolUse イベント JSON から Bash コマンドを取り出し、前後の空白をトリムして返却
# Bash 以外・空コマンドのときは何も出力なし
extract_bash_command() {
  local command
  if ! command=$(jq -rse '
    if length == 1 and (.[0] | type == "object" and (.tool_name | type) == "string")
    then .[0]
    else error("invalid PreToolUse input")
    end
    | if .tool_name != "Bash" then ""
      elif (.tool_input | type) == "object"
        and (.tool_input.command | type) == "string"
        and (.tool_input.command | contains("\u0000") | not)
      then .tool_input.command
      else error("invalid PreToolUse input")
      end
  ' 2>/dev/null); then
    block_and_exit 'invalid PreToolUse input'
  fi

  # 外部コマンドを使わず bash の正規表現で前後の空白を削る
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

# 判定ルール

# 引用外で複合コマンドを区切る演算子文字
# マスク処理と判定ルールで同じ集合を使う
readonly OPERATOR_CHARS=';&|()'

# command が pattern に一致したら reason を 1 行出力
# pattern 自体が不正 (=~ が 2 を返す) なら素通しにせず安全側に倒してブロック
emit_if_matches() {
  local command="$1" pattern="$2" reason="$3" status=0
  [[ $command =~ $pattern ]] || status=$?
  case "$status" in
  0) printf '%s\n' "$reason" ;;
  1) ;;
  *) block_and_exit "invalid pattern for rule: $reason" ;;
  esac
}

# バックスラッシュ + 改行の行継続を bash の字句解析と同じく結合して返却
# 行末のバックスラッシュが偶数個 (\\ など) ならエスケープ済み、コメント内なら継続ではないので改行を区切りのまま残す
join_line_continuations() {
  local text="$1" line joined='' pending=''
  local continuation=$'\\\n' odd_trailing_backslashes='(^|[^\\])(\\\\)*\\$'
  local comment_start="(^|[[:blank:]${OPERATOR_CHARS}])#"

  if [[ $text != *"$continuation"* ]]; then
    printf '%s' "$text"
    return 0
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ $line =~ $odd_trailing_backslashes && ! $line =~ $comment_start ]]; then
      pending+="${line%\\}"
    else
      joined+="${pending}${line}"$'\n'
      pending=''
    fi
  done <<<"$text" || return 1
  printf '%s' "${joined}${pending}"
}

# echo と git commit の引用内演算子をマスクし、長い入力や複雑な構文はそのまま返す
mask_static_quoted_operators() {
  local command="$1"
  local masked_command='' quote='' char i
  local mask_target='^[[:space:]]*((echo)([[:space:]]|$)|git[[:space:]]+commit([[:space:]]|$))'
  local max_command_length=1024

  # Bash 3.2 の文字単位処理による遅延を抑える
  if ((${#command} > max_command_length)); then
    printf '%s' "$command"
    return 0
  fi

  if [[ ! $command =~ $mask_target ]]; then
    printf '%s' "$command"
    return 0
  fi

  for ((i = 0; i < ${#command}; i++)); do
    char="${command:i:1}"

    case "$char" in
    '$' | '`' | $'\\' | $'\n' | $'\r')
      printf '%s' "$command"
      return 0
      ;;
    esac

    if [[ -z "$quote" ]]; then
      case "$char" in
      "'" | '"')
        quote="$char"
        masked_command+="$char"
        ;;
      [$OPERATOR_CHARS] | '<' | '>')
        printf '%s' "$command"
        return 0
        ;;
      *) masked_command+="$char" ;;
      esac
    elif [[ "$char" == "$quote" ]]; then
      quote=''
      masked_command+="$char"
    else
      case "$char" in
      [$OPERATOR_CHARS]) masked_command+='_' ;;
      *) masked_command+="$char" ;;
      esac
    fi
  done

  if [[ -n "$quote" ]]; then
    printf '%s' "$command"
  else
    printf '%s' "$masked_command"
  fi
}

# 代表的な直接呼び出し (予約語・前置代入・リダイレクトの直後、パス付き・\ 付きを含む) のブロック理由を 1 行ずつ出力し、
# 展開・ラッパー (find -exec / xargs / env 等)・引用したコマンド名や引用を含む値・別インタープリタ経由は網羅しない
detect_block_reasons() {
  local command masked_command
  command="$(join_line_continuations "$1")" || block_and_exit 'failed to join line continuations'
  masked_command="$(mask_static_quoted_operators "$command")"

  # コマンド内トークン区切りは空白のみ、改行はコマンド区切り
  local token_char="[^[:space:]${OPERATOR_CHARS}]"
  local token="${token_char}+"
  local token_gap="([[:blank:]]+${token})*[[:blank:]]+"
  local short_opt_char="[^-[:space:]${OPERATOR_CHARS}]"

  # コマンド語の前に置ける語を列挙して任意の順で読み飛ばす
  # 予約語 (if then elif else while until do time coproc function { !)、前置代入 (NAME=value NAME+=value NAME[i]=value)、
  # リダイレクト (>f 2>&1 >|f >&- {fd}>f <<<s 等。演算子に含まれる & | は区切りより先にここで消費する)
  local reserved_word="(if|then|elif|else|while|until|do|time([[:blank:]]+(-p|--))*|coproc|function[[:blank:]]+${token}|[{!])"
  local assignment="[[:alpha:]_][^[:space:]${OPERATOR_CHARS}=]*=${token_char}*"
  local redirect="([0-9]+|[{][[:alpha:]_][[:alnum:]_]*[}])?&?[<>]+[|&-]?[[:blank:]]*${token}"
  local skip_word="(${reserved_word}|${assignment}|${redirect})"

  # コマンド先頭 (先頭空白可)、または複合コマンドの区切り (; & | 括弧 / 改行) 直後にマッチ
  local newline=$'\n'
  local command_start="(^|[${OPERATOR_CHARS}${newline}])[[:space:]]*(${skip_word}[[:blank:]]+)*"

  # パス付き (/bin/rm ./rm) と alias 回避 (\rm) の呼び出しも対象にする
  # 前置代入の値 (X=/usr/bin/) をパスと誤認しないよう = を含む語は除き、括弧内の \ はリテラル
  local command_prefix="([^[:space:]${OPERATOR_CHARS}=]*/|[\\])?"

  # macOS の大文字小文字を区別しない FS では RM も rm に解決されるため、コマンド名の大文字小文字は問わない
  local rm_name='[rR][mM]'
  local sudo_name='[sS][uU][dD][oO]'

  # 再帰削除 (-r / -R) かつ強制 (-f) を表す各オプション表記を列挙
  local short_recursive="-${short_opt_char}*[rR]${short_opt_char}*"
  local short_force="-${short_opt_char}*f${short_opt_char}*"
  local recursive="(${short_recursive}|--recursive)"
  local force="(${short_force}|--force)"
  local alts=(
    "-${short_opt_char}*[rR]${short_opt_char}*f${short_opt_char}*" # -rf / -Rf 同居
    "-${short_opt_char}*f${short_opt_char}*[rR]${short_opt_char}*" # -fr / -fR 同居
    "${recursive}${token_gap}${force}"                             # -r ... -f / --recursive ... --force
    "${force}${token_gap}${recursive}"                             # -f ... -r / --force ... --recursive
  )
  local joined
  printf -v joined '%s|' "${alts[@]}"
  local rm_recursive_force="${command_prefix}${rm_name}${token_gap}(${joined%|})"

  emit_if_matches "$masked_command" "$command_start$rm_recursive_force" "rm -rf / rm -Rf / rm --recursive --force は許可していません。"
  emit_if_matches "$masked_command" "${command_start}${command_prefix}${sudo_name}[[:space:]]+" "sudo の使用は Claude からは許可していません。"
  # (sh|bash) の直後がコマンド名構成文字 (英数字 _ . -) でないことを要求し、
  # shasum / shuf など前方一致コマンドの誤検知を防ぎつつ、リダイレクト直結 (| sh>log 等) は検知する
  emit_if_matches "$masked_command" '(curl|wget)[^|]*\|[[:space:]]*(sh|bash)($|[^[:alnum:]_.-])' "curl / wget ... | sh / bash 形式のコマンドは許可していません。"
}

# 出力

# ブロック理由 (1 行 1 件) を JSON にまとめて出力し、Claude にブロックを通知
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

# エントリポイント

main() {
  # ポリシーを検証できない場合は安全側に倒して Bash 呼び出しを拒否
  if ! command -v jq >/dev/null 2>&1; then
    block_and_exit 'jq is required'
  fi

  # Bash コマンドを取り出し、対象外なら素通し
  local command reasons
  command=$(extract_bash_command) || return 2
  [[ -n "$command" ]] || return 0

  # 全ルールで判定し、ヒットが無ければ素通し
  if ! reasons=$(detect_block_reasons "$command"); then
    block_and_exit 'failed to evaluate Bash command'
  fi
  [[ -n "$reasons" ]] || return 0

  # 1 件以上ヒットしたら permissionDecision: deny の JSON を返してブロック
  print_block_json "$command" "$reasons" || return 2
  return 0
}

main "$@"
