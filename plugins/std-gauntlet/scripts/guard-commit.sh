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

# --- std:jq-guard — решение печатается своими силами --------------------------
# Без этого отсутствие jq выключало замок молча, и «работа сделана» переставало
# означать «проверки пройдены» — ровно то, ради чего замок и заведён.
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
read_cfg() { # <файл> <ключ> — с отличием пустого от отсутствующего
  [[ -f "$1" ]] || return 0
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$2" 'if has($k) then .[$k] else "" end' "$1" 2>/dev/null; return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys
try:
    d = json.load(open(sys.argv[1]))
    v = d.get(sys.argv[2], "")
    print("" if v == "" else json.dumps(v).strip(chr(34)), end="")
except Exception:
    pass' "$1" "$2" 2>/dev/null; return 0
  fi
  return 0
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

if ! CMD=$(read_field command); then
  emit ask "Замок на коммит не может прочитать запрос: нет ни jq, ни python3. Подтверди, что гейты пройдены, или поставь jq."
fi
[[ -z "$CMD" ]] && exit 0

# Интересует только фиксация изменений
printf '%s' "$CMD" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+commit' || exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
CFG="$PROJECT_DIR/.claude/gauntlet.json"
MARK="$PROJECT_DIR/.claude/.gauntlet-pass"

# has() вместо `// true`: оператор // в jq считает пустым не только null,
# но и false, поэтому `.requireBeforeCommit // true` для false вернул бы true
# и настройка молча не работала бы.
[[ "$(read_cfg "$CFG" requireBeforeCommit)" == "false" ]] && exit 0

ask() { emit ask "$1"; }

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
