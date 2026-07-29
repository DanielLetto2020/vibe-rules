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

json_escape() {
  local s="$1"; s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

# --- std:jq-guard — о поломке защиты человек узнаёт на старте сессии -----------
# Раньше при отсутствии jq этот хук просто выходил, а замки в это время молча
# ничего не проверяли. Теперь отсутствие разборщика — первое, что видно в сессии:
# сообщение печатается без jq, иначе предупреждать было бы нечем.
if ! command -v jq >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
  MSG="Ни jq, ни python3 не найдены. Замки не могут разобрать запросы и блокируют команды вместо тихого пропуска. Поставь jq: apt install jq / brew install jq / dnf install jq"
  printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' \
    "$(json_escape "$MSG")" \
    "$(json_escape "ВНИМАНИЕ: $MSG До установки считай, что автоматических проверок в этом проекте нет.")"
  exit 0
fi

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
  printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' \
    "$(json_escape "$msg")" \
    "$(json_escape "ВНИМАНИЕ: $msg До починки не считай, что стандарты проекта тебе известны.")"
  exit 0
fi

# Требования профиля доносим до модели явно. Раньше они жили только
# в .claude/gauntlet.json, который читают скрипты, но не модель: настройка
# specFirst стояла, а поведение не менялось — и выглядело это как «правило
# не работает», хотя правило до модели просто не доезжало.
CFG="$PROJECT_DIR/.claude/gauntlet.json"
[[ -f "$CFG" ]] || exit 0

# Читаем тем же способом, что и замки: где есть jq — им, иначе python3.
# Одинаковое чтение важнее краткости: иначе на машине без jq замок считает
# профиль так, а подсказка модели — иначе, и расхождение никак не видно.
read_cfg() { # <ключ>
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$1" 'if has($k) then .[$k] else "" end' "$CFG" 2>/dev/null; return 0
  fi
  python3 -c 'import json,sys
try:
    v = json.load(open(sys.argv[1])).get(sys.argv[2], "")
    print("" if v == "" else json.dumps(v).strip(chr(34)), end="")
except Exception:
    pass' "$CFG" "$1" 2>/dev/null
}

NOTES=()
[[ "$(read_cfg specFirst)" == "true" ]] \
  && NOTES+=("Прежде чем писать код новой функциональности, сформулируй критерий приёмки на человеческом языке, перечисли несчастливые пути и получи подтверждение. Тест, написанный после реализации, проверяет то, что получилось, а не то, что требовалось.")

[[ "$(read_cfg requireBeforeCommit)" == "true" ]] \
  && NOTES+=("Перед коммитом должны быть пройдены гейты проекта: /std-gauntlet:run.")

[[ "$(read_cfg profile)" == "legacy" ]] \
  && NOTES+=("Профиль проекта — legacy: спецификации нет, поведение известно частично. Прежде чем менять непокрытый тестами код, зафиксируй текущее поведение как эталон.")

[[ ${#NOTES[@]} -eq 0 ]] && exit 0

PROFILE=$(read_cfg profile); [[ -z "$PROFILE" ]] && PROFILE="не задан"
CTX="Профиль стандартов в этом проекте: $PROFILE."
for n in "${NOTES[@]}"; do CTX+=" $n"; done

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$(json_escape "$CTX")"
exit 0
