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
FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[[ -z "$FILE" ]] && exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
GAUNTLET="$PROJECT_DIR/.claude/gauntlet.json"
CFG="$PROJECT_DIR/.claude/std-guard.json"

DEFAULT_PATTERNS='tests/|/tests/|Test\.php$|_test\.py$|test_.*\.py$|\.spec\.(ts|js)$|\.test\.(ts|js)$|/Feature/|/Unit/'
MODE="ask"

# Строгость задаётся профилем проекта: на прототипе замок мешает, в регулируемой
# среде нужен запрет, а не запись о том, что человек подтвердил.
if [[ -f "$GAUNTLET" ]] && command -v jq >/dev/null 2>&1; then
  g=$(jq -r '.guardTests // empty' "$GAUNTLET" 2>/dev/null); [[ -n "$g" ]] && MODE="$g"
fi

# Отдельный файл переопределяет профиль — для точечных исключений в проекте
if [[ -f "$CFG" ]] && command -v jq >/dev/null 2>&1; then
  m=$(jq -r '.mode // empty' "$CFG" 2>/dev/null); [[ -n "$m" ]] && MODE="$m"
  p=$(jq -r '.protectedRegex // empty' "$CFG" 2>/dev/null); [[ -n "$p" ]] && DEFAULT_PATTERNS="$p"
fi

# На прототипе надзор за тестами выключен целиком: там их обычно нет,
# а замок на каждую правку черновика — верный способ отключить стандарты.
[[ "$MODE" == "off" ]] && exit 0

# Не защищённый путь — выходим молча
printf '%s' "$FILE" | grep -Eq "$DEFAULT_PATTERNS" || exit 0

# Новый файл — создавать тесты можно свободно
[[ -e "$FILE" ]] || exit 0

REASON="Правка существующего теста: $(basename "$FILE"). Тест — это надзор над кодом; ослабить его проще, чем починить реализацию. Подтверди, что тест меняется осознанно, а не подгоняется под текущее поведение."

if [[ "$MODE" == "deny" ]]; then
  jq -n --arg r "$REASON" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
else
  jq -n --arg r "$REASON" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
fi
exit 0
