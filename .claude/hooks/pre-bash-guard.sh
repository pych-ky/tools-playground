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

  [[ -n "$command" ]] || return 0
  if ! command=$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    2>/dev/null <<<"$command"); then
    block_and_exit 'failed to normalize Bash command'
  fi
  printf '%s\n' "$command"
}

# 判定ルール

# command が pattern に一致したら reason を 1 行出力
emit_if_matches() {
  local command="$1" pattern="$2" reason="$3"
  [[ $command =~ $pattern ]] && printf '%s\n' "$reason"
  return 0
}

# echo と git commit の引用内演算子をマスクし、長い入力や複雑な構文はそのまま返す
mask_static_quoted_operators() {
  local command="$1"
  local masked_command='' quote='' char i
  local mask_target='^((echo)([[:space:]]|$)|git[[:space:]]+commit([[:space:]]|$))'
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
      ';' | '&' | '|' | '(' | ')' | '<' | '>')
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
      ';' | '&' | '|' | '(' | ')') masked_command+='_' ;;
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

# 代表的な直接呼び出しのブロック理由を 1 行ずつ出力し、展開・ラッパー・別インタープリタ経由は網羅しない
detect_block_reasons() {
  local command="$1"
  local masked_command
  masked_command="$(mask_static_quoted_operators "$command")"

  # コマンド先頭、または複合コマンドの区切り (; & | 括弧 / 改行) 直後にマッチ
  local command_start=$'(^|[;&|()\n][[:space:]]*)'

  # コマンド内トークン区切りは空白のみ、改行はコマンド区切り
  local token_char='[^[:space:];&|()]'
  local token="${token_char}+"
  local token_gap="([[:blank:]]+${token})*[[:blank:]]+"
  local short_opt_char='[^-[:space:];&|()]'

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
  local rm_recursive_force="rm${token_gap}(${joined%|})"

  emit_if_matches "$masked_command" "$command_start$rm_recursive_force" "rm -rf / rm -Rf / rm --recursive --force は許可していません。"
  emit_if_matches "$masked_command" "${command_start}sudo[[:space:]]+" "sudo の使用は Claude からは許可していません。"
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
