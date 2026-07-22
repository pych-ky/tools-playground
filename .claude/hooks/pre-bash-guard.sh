#!/usr/bin/env bash
#
# ============================================================================
# 危険な Bash コマンドをブロックする PreToolUse フックスクリプト
# ============================================================================

set -euo pipefail

# ============================================================================
# 入力
# ============================================================================

# PreToolUse イベント JSON から Bash コマンドを取り出し、前後の空白をトリムして返却
# Bash 以外・空コマンドのときは何も出力なし
extract_bash_command() {
  local input tool_name command
  if ! input=$(cat 2>/dev/null); then
    printf 'pre-bash-guard.sh: invalid PreToolUse input; Bash command blocked\n' >&2
    return 2
  fi

  if ! input=$(jq -cse '
    if length == 1 and (
      .[0] |
      type == "object" and
      (.tool_name | type) == "string" and
      (
        .tool_name != "Bash" or
        (
          (.tool_input | type) == "object" and
          (.tool_input.command | type) == "string" and
          (.tool_input.command | contains("\u0000") | not)
        )
      )
    )
    then .[0]
    else error("invalid PreToolUse input")
    end
  ' 2>/dev/null <<<"$input"); then
    printf 'pre-bash-guard.sh: invalid PreToolUse input; Bash command blocked\n' >&2
    return 2
  fi

  if ! tool_name=$(jq -er '.tool_name' 2>/dev/null <<<"$input"); then
    printf 'pre-bash-guard.sh: invalid PreToolUse input; Bash command blocked\n' >&2
    return 2
  fi
  [[ "$tool_name" == "Bash" ]] || return 0
  if ! command=$(jq -er '.tool_input.command' 2>/dev/null <<<"$input"); then
    printf 'pre-bash-guard.sh: invalid PreToolUse input; Bash command blocked\n' >&2
    return 2
  fi

  [[ -n "$command" ]] || return 0
  if ! command=$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    2>/dev/null <<<"$command"); then
    printf 'pre-bash-guard.sh: failed to normalize Bash command; Bash command blocked\n' >&2
    return 2
  fi
  printf '%s\n' "$command"
}

# ============================================================================
# 判定ルール
# ============================================================================

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

# ============================================================================
# 出力
# ============================================================================

# ブロック理由 (可変長引数) を JSON にまとめて出力し、Claude にブロックを通知
print_block_json() {
  local command="$1"
  shift

  local details='' reason decision
  for reason in "$@"; do
    if [[ -n "$details" ]]; then
      details+=$'\n'
    fi
    details+="- $reason"
  done

  local msg="危険な可能性がある Bash コマンドをブロックしました。"$'\n\n'"Command:"$'\n  '"$command"$'\n\n'"Reasons:"$'\n'"$details"
  if ! decision=$(jq -n --arg msg "$msg" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $msg
    }
  }' 2>/dev/null); then
    printf 'pre-bash-guard.sh: failed to create deny decision; Bash command blocked\n' >&2
    return 2
  fi
  printf '%s\n' "$decision"
}

# ============================================================================
# エントリポイント
# ============================================================================

main() {
  # ポリシーを検証できない場合は安全側に倒して Bash 呼び出しを拒否
  command -v jq >/dev/null 2>&1 || {
    printf 'pre-bash-guard.sh: jq is required; Bash command blocked\n' >&2
    return 2
  }

  # Bash コマンドを取り出し、対象外なら素通し
  local command reasons_output
  command=$(extract_bash_command) || return 2
  [[ -n "$command" ]] || return 0

  # 全ルールで判定し、ヒットが無ければ素通し
  local -a reasons=()
  local reason
  if ! reasons_output=$(detect_block_reasons "$command"); then
    printf 'pre-bash-guard.sh: failed to evaluate Bash command; Bash command blocked\n' >&2
    return 2
  fi
  [[ -n "$reasons_output" ]] || return 0
  while IFS= read -r reason; do
    reasons+=("$reason")
  done <<<"$reasons_output"

  # 1 件以上ヒットしたら permissionDecision: deny の JSON を返してブロック
  print_block_json "$command" "${reasons[@]}" || return 2
  return 0
}

main "$@"
