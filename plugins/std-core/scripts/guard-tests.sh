#!/usr/bin/env bash
# guard-tests.sh — PreToolUse-замок на правку существующих тестов.
#
# Закрывает главную дыру подхода «не читать код»: когда тест падает, у модели
# есть два пути — починить код или ослабить тест. Второй быстрее.
# Замок различает:
#   создание нового теста  -> разрешено (файла ещё нет)
#   правка существующего   -> эскалация к человеку (ask)
# Так тесты остаются надзором, а не подстраиваются под реализацию.
#
# Настройка в проекте (необязательно): .claude/std-guard.json
#   { "protected": ["tests/**", "**/*Test.php"], "mode": "ask" }
set -uo pipefail

INPUT=$(cat)

# std:hooks-off — человек отключил замки в этом проекте (.claude/std-hooks-off).
# Этот хук молчит целиком; правила остаются и грузятся как раньше. Запреты
# на необратимое маркер не снимает — они живут в guard-bash.sh и работают
# всегда. Что замки выключены, напоминает session-check.sh: единственный хук,
# которого маркер не глушит.
[[ -f "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/std-hooks-off" ]] && exit 0

# --- std:jq-guard — без разборщика JSON замок молчать не должен ----------------
# Раньше отсутствие jq давало пустое поле и тихий выход: защита выключалась,
# и узнать об этом было неоткуда. Теперь решение печатается своими силами,
# а при полном отсутствии разборщика правка эскалируется человеку.
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
# Настройки читаются тем же способом. Иначе на машине без jq профиль
# «замок выключен» не прочитался бы и прототип получал вопрос на каждую правку —
# верный способ отключить стандарты целиком.
read_cfg() { # <файл> <ключ>
  [[ -f "$1" ]] || return 0
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$2" '.[$k] // empty' "$1" 2>/dev/null; return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys
try:
    v = json.load(open(sys.argv[1])).get(sys.argv[2], "")
    print("" if v is None else (v if isinstance(v, str) else json.dumps(v)), end="")
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

if ! FILE=$(read_field file_path); then
  emit ask "Замок на правку тестов не может прочитать запрос: на машине нет ни jq, ни python3. Молча пропустить правку нельзя — подтверди её сам или поставь jq."
fi
[[ -z "$FILE" ]] && exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
GAUNTLET="$PROJECT_DIR/.claude/gauntlet.json"
CFG="$PROJECT_DIR/.claude/std-guard.json"

DEFAULT_PATTERNS='tests/|/tests/|Test\.php$|_test\.py$|test_.*\.py$|\.spec\.(ts|js)$|\.test\.(ts|js)$|/Feature/|/Unit/'
MODE="ask"

# Строгость задаётся профилем проекта: на прототипе замок мешает, в регулируемой
# среде нужен запрет, а не запись о том, что человек подтвердил.
g=$(read_cfg "$GAUNTLET" guardTests); [[ -n "$g" ]] && MODE="$g"

# Отдельный файл переопределяет профиль — для точечных исключений в проекте
m=$(read_cfg "$CFG" mode);            [[ -n "$m" ]] && MODE="$m"
p=$(read_cfg "$CFG" protectedRegex);  [[ -n "$p" ]] && DEFAULT_PATTERNS="$p"

# На прототипе надзор за тестами выключен целиком: там их обычно нет,
# а замок на каждую правку черновика — верный способ отключить стандарты.
[[ "$MODE" == "off" ]] && exit 0

# Не защищённый путь — выходим молча
printf '%s' "$FILE" | grep -Eq "$DEFAULT_PATTERNS" || exit 0

# Новый файл — создавать тесты можно свободно
[[ -e "$FILE" ]] || exit 0

REASON="Правка существующего теста: $(basename "$FILE"). Тест — это надзор над кодом; ослабить его проще, чем починить реализацию. Подтверди, что тест меняется осознанно, а не подгоняется под текущее поведение."

if [[ "$MODE" == "deny" ]]; then
  emit deny "$REASON"
else
  emit ask "$REASON"
fi
exit 0
