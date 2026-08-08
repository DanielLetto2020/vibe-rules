#!/usr/bin/env bash
# guard-secrets.sh — PreToolUse: чтение файла, который целиком является секретом.
#
# Закрывает дыру, которую не видит ни один линтер и не ловил ни один замок:
# прочитанный секрет попадает в контекст модели. Дальше он уезжает провайдеру,
# остаётся в истории сессии на диске и может всплыть где угодно — в примере
# кода, в фикстуре теста, в сообщении коммита. Момент утечки — не запись,
# а именно чтение, и после него отменить уже нечего.
#
# Решение — ask, а не deny. Прочитать .env иногда действительно нужно, и замок,
# который это запрещает совсем, отключают вместе со всеми остальными. Вопрос
# называет цену и предлагает способ обойтись без значений.
#
# Вход:  JSON на stdin (tool_name, tool_input.file_path | .path)
# Выход: exit 0 + JSON с permissionDecision: ask | (пусто = обычный поток)
set -uo pipefail

INPUT=$(cat)

# std:hooks-off — человек отключил замки в этом проекте (.claude/std-hooks-off).
# Этот хук молчит целиком; правила остаются и грузятся как раньше. Запреты
# на необратимое маркер не снимает — они живут в guard-bash.sh и работают
# всегда. Что замки выключены, напоминает session-check.sh: единственный хук,
# которого маркер не глушит.
[[ -f "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/std-hooks-off" ]] && exit 0
. "$(dirname "${BASH_SOURCE[0]}")/secret-lib.sh"

json_escape() {
  local s="$1"; s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
  printf '%s' "$s"
}
emit() { # <deny|ask> <причина>
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' \
    "$1" "$(json_escape "$2")"
  exit 0
}

# --- std:jq-guard — молчаливый пропуск здесь равен выключенной проверке -------
read_path() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$INPUT" | python3 -c 'import json,sys
try:
    t = json.load(sys.stdin).get("tool_input", {})
    print(t.get("file_path") or t.get("path") or "", end="")
except Exception:
    pass' 2>/dev/null
    return 0
  fi
  return 1
}

if ! FILE=$(read_path); then
  emit ask "Проверка на чтение секретов не работает: нет ни jq, ни python3. Подтверди осознанно, что этот файл не содержит ключей, или поставь jq."
fi
[[ -z "$FILE" ]] && exit 0

KIND=$(secret_path_kind "$FILE") || exit 0

emit ask "$FILE — $KIND. Прочитанное попадёт в контекст модели: уедет провайдеру, останется в истории сессии на диске и может всплыть в коде, тесте или сообщении коммита. Отменить это после чтения нельзя.

Если нужны только имена переменных, а не значения — возьми их безопасно:
  grep -oE '^[A-Za-z_][A-Za-z0-9_]*' \"$FILE\"
Если нужна структура — читай образец рядом (.env.example).
Значения читай, только если задача без них не решается."
