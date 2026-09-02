#!/usr/bin/env bash

set -u

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
patterns_file="${script_dir}/../protected-files.txt"

fail() {
  printf '%s\n' "Failed to enforce protected-file policy: $1" >&2
  exit 1
}

glob_to_regex() {
  local pattern="$1"
  local regex=""
  local character
  local index

  for ((index = 0; index < ${#pattern}; index++)); do
    character="${pattern:index:1}"
    case "$character" in
      '*')
        if [[ "${pattern:index+1:1}" == "*" ]]; then
          regex+=".*"
          ((index++))
        else
          regex+="[^/]*"
        fi
        ;;
      '?') regex+="[^/]" ;;
      '.'|'+'|'('|')'|'['|']'|'{'|'}'|'^'|'$'|'|')
        regex+="\\${character}"
        ;;
      *) regex+="$character" ;;
    esac
  done
  printf '%s' "$regex"
}

references_protected_file() {
  local value="${1//\\//}"
  local pattern
  local regex

  value="${value,,}"
  for pattern in "${patterns[@]}"; do
    regex="$(glob_to_regex "${pattern,,}")"
    local reference_regex="(^|[^a-z0-9_.-])${regex}($|[[:space:]\"'=:;|&>)])"
    if [[ "$value" =~ $reference_regex ]]; then
      return 0
    fi
  done
  return 1
}

command -v awk >/dev/null 2>&1 || fail "awk is required."
[[ -r "$patterns_file" ]] || fail "cannot read .github/protected-files.txt."

payload="$(cat)" || fail "could not read the hook payload."
[[ -n "$payload" ]] || fail "the hook payload is empty."

mapfile -t extracted < <(
  printf '%s' "$payload" | awk '
function emit(value) {
  gsub(/\r|\n|\t/, " ", value)
  values[++value_count] = value
  if (expect_tool && tool_name == "") {
    tool_name = value
    expect_tool = 0
  } else if (value == "toolName" && tool_name == "") {
    expect_tool = 1
  }
}
{
  input = input $0 "\n"
}
END {
  position = 1
  while (position <= length(input)) {
    if (substr(input, position, 1) != "\"") {
      position++
      continue
    }

    position++
    value = ""
    closed = 0
    while (position <= length(input)) {
      character = substr(input, position, 1)
      if (character == "\"") {
        closed = 1
        position++
        break
      }
      if (character == "\\") {
        position++
        escape = substr(input, position, 1)
        if (escape == "\"" || escape == "\\" || escape == "/") {
          value = value escape
        } else if (escape == "n") {
          value = value "\n"
        } else if (escape == "r") {
          value = value "\r"
        } else if (escape == "t") {
          value = value "\t"
        } else if (escape == "b" || escape == "f") {
          value = value " "
        } else if (escape == "u") {
          value = value "\\u" substr(input, position + 1, 4)
          position += 4
        } else {
          print "Invalid JSON escape in hook payload." > "/dev/stderr"
          exit 1
        }
      } else {
        value = value character
      }
      position++
    }
    if (!closed) {
      print "Unterminated JSON string in hook payload." > "/dev/stderr"
      exit 1
    }
    emit(value)
  }

  if (tool_name == "") {
    print "Missing toolName in hook payload." > "/dev/stderr"
    exit 1
  }
  print tool_name
  for (value_index = 1; value_index <= value_count; value_index++) {
    print values[value_index]
  }
}
  '
  ) || fail "the hook payload is invalid."

((${#extracted[@]} > 0)) || fail "the hook payload is invalid."
tool_name="${extracted[0],,}"
values=("${extracted[@]:1}")

patterns=()
while IFS= read -r pattern || [[ -n "$pattern" ]]; do
  pattern="${pattern#"${pattern%%[![:space:]]*}"}"
  pattern="${pattern%"${pattern##*[![:space:]]}"}"
  pattern="${pattern//\\//}"
  [[ -z "$pattern" || "$pattern" == \#* ]] && continue
  patterns+=("$pattern")
done < "$patterns_file"

((${#patterns[@]} > 0)) ||
  fail "the protected-files configuration has no patterns."

protected_reference=0
for value in "${values[@]}"; do
  if references_protected_file "$value"; then
    protected_reference=1
    break
  fi
done

((protected_reference)) || exit 0

case "$tool_name" in
  apply_patch|create|delete|edit|str_replace_editor|write)
    should_deny=1
    ;;
  bash|powershell)
    command_text="$(printf '%s\n' "${values[@]}")"
    if printf '%s' "$command_text" | grep -Eiq \
      '\b(add-content|clear-content|copy-item|del|erase|move-item|remove-item|rename-item|set-content|cp|install|mv|rm|truncate|tee)\b|\bgit[[:space:]]+(checkout|clean|mv|reset|restore|rm)\b|\b(perl|sed)\b[^;&|]*[[:space:]]-[^;&|]*i|(^|[[:space:];|&])(echo|printf)\b[^;&|]*(>>|>)|(>>|>)'; then
      should_deny=1
    else
      should_deny=0
    fi
    ;;
  *) should_deny=0 ;;
esac

if ((should_deny)); then
  printf '%s\n' \
    '{"permissionDecision":"deny","permissionDecisionReason":"A política do repositório impede que agentes modifiquem, movam ou excluam arquivos correspondentes aos padrões em .github/protected-files.txt."}'
fi
