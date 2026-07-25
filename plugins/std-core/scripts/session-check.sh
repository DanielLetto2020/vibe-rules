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
  msg="Битые ссылки на стандарты: ${broken[*]}. Правила НЕ загружены. Почини: /std-core:link"
  jq -n --arg m "$msg" '{
    systemMessage: $m,
    hookSpecificOutput: {
      hookEventName: "SessionStart",
      additionalContext: ("ВНИМАНИЕ: " + $m + " До починки не считай, что стандарты проекта тебе известны.")
    }
  }'
  exit 0
fi

# Всё цело — молчим, чтобы не тратить контекст на служебный шум
exit 0
