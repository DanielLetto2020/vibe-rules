#!/usr/bin/env bash
# guard-commit.sh — PreToolUse: не дать закоммитить, не прогнав гейты.
#
# Это замок, который делает всю остальную конструкцию обязательной. Без него
# гейты — доброе намерение: их прогоняют, когда помнят. С ним «работа сделана»
# и «проверки пройдены» — одно и то же событие.
#
# Логика: gauntlet.sh при полном успешном прогоне оставляет отметку времени.
# Если после неё исходники менялись — значит проверки устарели.
#
# Отключить для конкретного проекта: .claude/gauntlet.json → "requireBeforeCommit": false
set -uo pipefail

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[[ -z "$CMD" ]] && exit 0

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

# Интересует только фиксация изменений
printf '%s' "$CMD" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+commit' || exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
CFG="$PROJECT_DIR/.claude/gauntlet.json"
MARK="$PROJECT_DIR/.claude/.gauntlet-pass"

if [[ -f "$CFG" ]] && command -v jq >/dev/null 2>&1; then
  # has() вместо `// true`: оператор // в jq считает пустым не только null,
  # но и false, поэтому `.requireBeforeCommit // true` для false вернул бы true
  # и настройка молча не работала бы.
  if [[ "$(jq -r 'if has("requireBeforeCommit") then .requireBeforeCommit else true end' "$CFG" 2>/dev/null)" == "false" ]]; then
    exit 0
  fi
fi

ask() {
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
  exit 0
}

[[ -f "$MARK" ]] || ask "Гейты ни разу не прогонялись в этом проекте. Запусти /std-gauntlet:run — коммит без прохождения проверок означает, что качество кода никем не подтверждено."

# Сравниваем с mtime самого файла-отметки, а не с записанной в него секундой:
# у файлов время хранится с долями секунды, и правка, сделанная в ту же секунду
# что и прогон, выглядела бы более поздней.
#
# Каталоги сборки и зависимостей исключаем: их mtime меняется сам по себе.
NEWER=$(find "$PROJECT_DIR" \
          \( -path '*/node_modules' -o -path '*/vendor' -o -path '*/.git' \
             -o -path '*/.venv' -o -path '*/dist' -o -path '*/build' \
             -o -path '*/__pycache__' -o -path '*/.claude' \) -prune -o \
          -type f \( -name '*.php' -o -name '*.py' -o -name '*.ts' -o -name '*.js' \
             -o -name '*.vue' -o -name '*.sql' -o -name '*.go' \) \
          -newer "$MARK" -print 2>/dev/null | head -5)

[[ -z "$NEWER" ]] && exit 0

LIST=$(printf '%s' "$NEWER" | sed "s|^$PROJECT_DIR/||" | tr '\n' ' ')
ask "После последнего успешного прогона гейтов изменялись исходники: $LIST. Проверки устарели — запусти /std-gauntlet:run перед коммитом."
