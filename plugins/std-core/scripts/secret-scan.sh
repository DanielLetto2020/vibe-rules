#!/usr/bin/env bash
# secret-scan.sh — PostToolUse: ищет секреты в только что записанном файле.
#
# Тесты, типизация и линтеры этот класс проблем не ловят в принципе:
# захардкоженный ключ не мешает коду работать. Поэтому — отдельный слой.
#
# Не блокирует запись (файл уже создан), но возвращает Claude текст ошибки,
# чтобы он немедленно исправил, и показывает предупреждение человеку.
#
# Словарь общий с остальными точками проверки — secret-lib.sh. Раньше он был
# записан прямо здесь, и это означало, что чтение, коммит и команды проверяются
# по другому списку или не проверяются вовсе.
#
# Слепых зон нет намеренно. Раньше из скана были исключены `*.md` и `tests/`
# — как раз те два места, где секрет оказывается чаще всего: токен в примере
# из README и живой ключ в фикстуре. Ложные срабатывания на примерах снимает
# распознавание заглушек, а не отключение проверки для целых каталогов.
set -uo pipefail

INPUT=$(cat)

# std:hooks-off — человек отключил замки в этом проекте (.claude/std-hooks-off).
# Правила при этом остаются и грузятся как раньше: стандарт возвращается
# к тексту без проверки. Что замки выключены, напоминает session-check.sh —
# единственный хук, которого маркер не глушит.
[[ -f "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/std-hooks-off" ]] && exit 0
. "$(dirname "${BASH_SOURCE[0]}")/secret-lib.sh"

# --- std:jq-guard — «не проверено» должно быть слышно -------------------------
# Молчаливый выход здесь означал бы, что записанный файл никто не смотрел,
# а выглядело бы это как пройденная проверка.
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

if ! FILE=$(read_field file_path); then
  printf '%s\n' "Файл записан, но на секреты не проверен: на машине нет ни jq, ни python3. Поставь jq — до тех пор этот слой защиты не работает." >&2
  exit 2
fi
[[ -z "$FILE" || ! -f "$FILE" ]] && exit 0

case "$FILE" in
  *lock.json|*.lock|*.min.js|*.map) exit 0 ;;
esac

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"

# Записан файл, который является секретом целиком. Содержимое проверять
# бессмысленно — важно, чтобы он не уехал в историю.
if KIND=$(secret_path_kind "$FILE"); then
  REL="${FILE#"$PROJECT_DIR"/}"
  if git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    if ! git -C "$PROJECT_DIR" check-ignore -q "$FILE" 2>/dev/null; then
      printf '%s\n' "$REL — $KIND, и git его не игнорирует: при следующем 'git add .' он уедет в историю, откуда убирается только перезаписью истории и ротацией ключей.

Закрой правилом сейчас:
  echo '$REL' >> .gitignore
Если файл уже отслеживается: git rm --cached '$REL'" >&2
      exit 2
    fi
  fi
  exit 0
fi

HITS=$(secret_content_hits "$FILE" "$PROJECT_DIR")
[[ -z "$HITS" ]] && exit 0

printf '%s\n' "Похоже на секрет в открытом виде в $FILE:
$HITS

Вынеси значение в переменную окружения и добавь плейсхолдер в .env.example.
Если это заведомо не секрет (пример в документации, значение из публичного набора) — добавь отличительную подстроку в .claude/secret-allow." >&2
exit 2
