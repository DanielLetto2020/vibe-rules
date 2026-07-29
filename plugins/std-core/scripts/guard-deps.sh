#!/usr/bin/env bash
# guard-deps.sh — PreToolUse: прямая правка файлов зависимостей.
#
# guard-bash.sh перехватывает `composer require` и `npm install`. Но зависимость
# можно добавить и в обход — дописав строку в composer.json или package.json.
# Этот замок закрывает обходной путь.
#
# Почему это важнее, чем кажется: вредоносный пакет проходит все тесты, весь
# статический анализ и всё мутационное тестирование идеально. Это единственный
# вектор, который система автопроверок не закрывает в принципе.
set -uo pipefail

INPUT=$(cat)

# --- std:jq-guard — отсутствие разборщика не открывает ворота ------------------
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
read_field() { # <поле в tool_input>
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$INPUT" | jq -r --arg f "$1" '.tool_input[$f] // empty' 2>/dev/null; return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$INPUT" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("tool_input", {}).get(sys.argv[1], "") or "", end="")
except Exception:
    pass' "$1" 2>/dev/null; return 0
  fi
  return 1
}

# Проект подключён к стандартам? Признак — конфигурация гейтов или слинкованные
# правила. Плагин ставится на машину и виден во всех проектах, но вмешиваться
# он должен только там, где стандарты приняли: иначе первый же чужой проект
# встречает вопросы, которых человек не просил, и замки отключают целиком.
project_uses_standards() {
  local d="${CLAUDE_PROJECT_DIR:-$PWD}"
  [[ -f "$d/.claude/gauntlet.json" ]] && return 0
  compgen -G "$d/.claude/rules/std-*" >/dev/null 2>&1 && return 0
  return 1
}

project_uses_standards || exit 0

if ! FILE=$(read_field file_path); then
  emit ask "Замок на зависимости не может прочитать запрос: нет ни jq, ни python3. Вредоносный пакет проходит все тесты идеально, поэтому молча пропустить правку нельзя — подтверди сам или поставь jq."
fi
[[ -z "$FILE" ]] && exit 0

base=$(basename "$FILE")
case "$base" in
  composer.json|package.json|pyproject.toml|requirements.txt|go.mod|Cargo.toml) ;;
  *) exit 0 ;;
esac

# Новый файл — это создание проекта, а не подмена зависимости
[[ -e "$FILE" ]] || exit 0

NEW=$(read_field new_string); [[ -z "$NEW" ]] && NEW=$(read_field content)

# Правка, не добавляющая строк вида "пакет": "версия", безобидна (скрипты, метаданные)
if [[ -n "$NEW" ]] && ! printf '%s' "$NEW" | grep -qE '["'"'"'][a-z0-9@._/-]+["'"'"']\s*[:=]\s*["'"'"'][\^~>=<0-9*]' \
   && ! printf '%s' "$NEW" | grep -qE '^\s*[a-zA-Z0-9._-]+\s*[><=~]=' ; then
  exit 0
fi

emit ask "Правка зависимостей в $base. Пакет проходит любые тесты и линтеры идеально — этот риск автопроверками не закрывается. Проверь имя пакета (опечатка в имени популярного пакета — типовая атака), его источник и число загрузок."
