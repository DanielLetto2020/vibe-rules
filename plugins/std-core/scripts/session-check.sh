#!/usr/bin/env bash
# session-check.sh — SessionStart: самодиагностика подключения стандартов.
#
# Симлинк на правила ломается в двух случаях: репозиторий стандартов переехал
# или проект склонировали на другую машину. Молчаливо сломанное правило хуже
# отсутствующего — все думают, что оно работает. Хук замечает это на старте.
set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
RULES_DIR="$PROJECT_DIR/.claude/rules"

# Проект не подключён к стандартам — это нормально, молчим
[[ -d "$RULES_DIR" ]] || exit 0

broken=() ok=()
shopt -s nullglob
for l in "$RULES_DIR"/std-*; do
  if [[ -L "$l" && ! -d "$l" ]]; then
    broken+=("$(basename "$l")")
  elif [[ -d "$l" ]]; then
    ok+=("$(basename "$l")")
  fi
done
shopt -u nullglob

if [[ ${#broken[@]} -gt 0 ]]; then
  msg="Битые ссылки на стандарты: ${broken[*]}. Правила НЕ загружены. Почини: /std-core:update"
  jq -n --arg m "$msg" '{
    systemMessage: $m,
    hookSpecificOutput: {
      hookEventName: "SessionStart",
      additionalContext: ("ВНИМАНИЕ: " + $m + " До починки не считай, что стандарты проекта тебе известны.")
    }
  }'
  exit 0
fi

# Требования профиля доносим до модели явно. Раньше они жили только
# в .claude/gauntlet.json, который читают скрипты, но не модель: настройка
# specFirst стояла, а поведение не менялось — и выглядело это как «правило
# не работает», хотя правило до модели просто не доезжало.
CFG="$PROJECT_DIR/.claude/gauntlet.json"
[[ -f "$CFG" ]] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

NOTES=()
[[ "$(jq -r 'if has("specFirst") then .specFirst else false end' "$CFG" 2>/dev/null)" == "true" ]] \
  && NOTES+=("Прежде чем писать код новой функциональности, сформулируй критерий приёмки на человеческом языке, перечисли несчастливые пути и получи подтверждение. Тест, написанный после реализации, проверяет то, что получилось, а не то, что требовалось.")

[[ "$(jq -r 'if has("requireBeforeCommit") then .requireBeforeCommit else false end' "$CFG" 2>/dev/null)" == "true" ]] \
  && NOTES+=("Перед коммитом должны быть пройдены гейты проекта: /std-gauntlet:run.")

[[ "$(jq -r '.profile // empty' "$CFG" 2>/dev/null)" == "legacy" ]] \
  && NOTES+=("Профиль проекта — legacy: спецификации нет, поведение известно частично. Прежде чем менять непокрытый тестами код, зафиксируй текущее поведение как эталон.")

[[ ${#NOTES[@]} -eq 0 ]] && exit 0

PROFILE=$(jq -r '.profile // "не задан"' "$CFG" 2>/dev/null)
CTX="Профиль стандартов в этом проекте: $PROFILE."
for n in "${NOTES[@]}"; do CTX+=" $n"; done

jq -n --arg c "$CTX" '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$c}}'
exit 0
