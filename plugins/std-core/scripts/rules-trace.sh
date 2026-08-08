#!/usr/bin/env bash
# rules-trace.sh — InstructionsLoaded: журнал того, что реально попало в контекст.
#
# Это ответ на вопрос «а правила вообще работают?». Без него любой репозиторий
# стандартов — акт веры: текст написан, но проверить, что он доехал до модели,
# нечем. Хук пишет факт загрузки каждого CLAUDE.md и .claude/rules/*.md,
# а тесты (tests/test-context.sh) проверяют журнал автоматически.
#
# Отключить: export STD_TRACE=0
set -uo pipefail

[[ "${STD_TRACE:-1}" == "0" ]] && exit 0

INPUT=$(cat)

# std:hooks-off — человек отключил замки в этом проекте (.claude/std-hooks-off).
# Правила при этом остаются и грузятся как раньше: стандарт возвращается
# к тексту без проверки. Что замки выключены, напоминает session-check.sh —
# единственный хук, которого маркер не глушит.
[[ -f "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/std-hooks-off" ]] && exit 0
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
LOG="${STD_TRACE_FILE:-$PROJECT_DIR/.claude/.std-trace.jsonl}"

mkdir -p "$(dirname "$LOG")" 2>/dev/null || exit 0

printf '%s' "$INPUT" | jq -c --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  {
    ts: $ts,
    event: (.hook_event_name // "InstructionsLoaded"),
    file: (.file_path // .path // .filePath // empty),
    reason: (.load_reason // .reason // .trigger // empty),
    session: (.session_id // empty),
    raw_keys: (keys)
  }' >> "$LOG" 2>/dev/null

exit 0
