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
FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[[ -z "$FILE" ]] && exit 0

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

base=$(basename "$FILE")
case "$base" in
  composer.json|package.json|pyproject.toml|requirements.txt|go.mod|Cargo.toml) ;;
  *) exit 0 ;;
esac

# Новый файл — это создание проекта, а не подмена зависимости
[[ -e "$FILE" ]] || exit 0

NEW=$(printf '%s' "$INPUT" | jq -r '.tool_input.new_string // .tool_input.content // empty' 2>/dev/null)

# Правка, не добавляющая строк вида "пакет": "версия", безобидна (скрипты, метаданные)
if [[ -n "$NEW" ]] && ! printf '%s' "$NEW" | grep -qE '["'"'"'][a-z0-9@._/-]+["'"'"']\s*[:=]\s*["'"'"'][\^~>=<0-9*]' \
   && ! printf '%s' "$NEW" | grep -qE '^\s*[a-zA-Z0-9._-]+\s*[><=~]=' ; then
  exit 0
fi

jq -n --arg f "$base" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "ask",
    permissionDecisionReason: ("Правка зависимостей в \($f). Пакет проходит любые тесты и линтеры идеально — этот риск автопроверками не закрывается. Проверь имя пакета (опечатка в имени популярного пакета — типовая атака), его источник и число загрузок.")
  }
}'
exit 0
