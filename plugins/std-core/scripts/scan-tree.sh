#!/usr/bin/env bash
# scan-tree.sh — PostToolUse на Bash: секреты в файлах, созданных мимо Write/Edit.
#
# Дыра, которую закрывает: проверка записи висела на Write|Edit, то есть видела
# только то, что агент напечатал сам. Файл, появившийся из `> config.yml`,
# `sed -i`, `cp .env.example .env`, генератора фреймворка или установщика,
# не проверялся вообще — при том что именно так секрет и попадает в проект
# чаще всего.
#
# Смотрим глазами git: что изменилось в рабочем дереве. Вне git-репозитория
# слой не работает — но там нет и коммита, то есть нет способа увезти секрет
# в историю.
#
# Отключить: export STD_SCAN_TREE=0
set -uo pipefail

[[ "${STD_SCAN_TREE:-1}" == "0" ]] && exit 0

INPUT=$(cat)

# std:hooks-off — человек отключил замки в этом проекте (.claude/std-hooks-off).
# Этот хук молчит целиком; правила остаются и грузятся как раньше. Запреты
# на необратимое маркер не снимает — они живут в guard-bash.sh и работают
# всегда. Что замки выключены, напоминает session-check.sh: единственный хук,
# которого маркер не глушит.
[[ -f "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/std-hooks-off" ]] && exit 0
. "$(dirname "${BASH_SOURCE[0]}")/secret-lib.sh"

read_command() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null; return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$INPUT" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("tool_input", {}).get("command", "") or "", end="")
except Exception:
    pass' 2>/dev/null; return 0
  fi
  return 1
}

# Этот хук — дополнительный слой, а не единственный: при сломанном разборе
# о поломке скажет session-check, а Write/Edit проверяет secret-scan. Молча
# выходим, чтобы не дублировать одно и то же предупреждение на каждой команде.
CMD=$(read_command) || exit 0
[[ -z "$CMD" ]] && exit 0

# Признаки записи. Гонять git status после каждой команды дорого на большом
# репозитории, а после `ls` и `grep` ещё и бессмысленно.
printf '%s' "$CMD" | grep -qE '>|tee|sed[[:space:]]+-i|cp[[:space:]]|mv[[:space:]]|touch[[:space:]]|install[[:space:]]|make([[:space:]]|$)|artisan|rails|django-admin|npx|npm[[:space:]]+(run|init|install)|yarn|pnpm|composer|pip[[:space:]]+install|python3?[[:space:]]|node[[:space:]]|php[[:space:]]|go[[:space:]]+(run|generate)|terraform|ansible|helm|openssl|ssh-keygen|base64[[:space:]]+-d' \
  || exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1 || exit 0

# Изменённое и неотслеживаемое. Игнорируемое git не берём: это сборка, кэш
# и сам .env, который уже закрыт правилом, — их содержимое никуда не уедет.
mapfile -t FILES < <(git -C "$PROJECT_DIR" status --porcelain --untracked-files=all 2>/dev/null \
                       | sed 's/^...//' | head -50)
[[ ${#FILES[@]} -eq 0 ]] && exit 0

# Один и тот же файл не сканируем повторно, пока он не менялся: за сессию
# команд с записью десятки, а файлов в дереве может быть полсотни.
STATE="${TMPDIR:-/tmp}/std-scan-tree-$$-cache"
SESSION_STATE="${TMPDIR:-/tmp}/std-scan-tree-${CLAUDE_SESSION_ID:-nosession}"
[[ -f "$SESSION_STATE" ]] && STATE="$SESSION_STATE"
touch "$SESSION_STATE" 2>/dev/null && STATE="$SESSION_STATE"

REPORT=""
for f in "${FILES[@]}"; do
  [[ -z "$f" ]] && continue
  # Переименование git печатает как «было -> стало»
  f=${f##* -> }
  f=${f%\"}; f=${f#\"}
  full="$PROJECT_DIR/$f"
  [[ -f "$full" ]] || continue

  # Большие файлы: дампы, архивы, ассеты. Скан по ним стоит дорого, а секрет
  # в дампе — отдельная задача, которую этот слой всё равно не решает.
  size=$(stat -c%s "$full" 2>/dev/null || stat -f%z "$full" 2>/dev/null || echo 0)
  [[ "$size" -gt 1048576 ]] && continue

  case "$f" in
    *.lock|*lock.json|*.min.js|*.map|*.svg|*.png|*.jpg|*.jpeg|*.gif|*.pdf|*.zip|*.gz) continue ;;
    .git/*|node_modules/*|vendor/*|.venv/*|dist/*|build/*) continue ;;
  esac

  mtime=$(stat -c%Y "$full" 2>/dev/null || stat -f%m "$full" 2>/dev/null || echo 0)
  key="$f|$mtime"
  grep -qxF "$key" "$STATE" 2>/dev/null && continue
  printf '%s\n' "$key" >> "$STATE" 2>/dev/null

  hits=$(secret_content_hits "$full" "$PROJECT_DIR")
  [[ -n "$hits" ]] && REPORT+="$f:"$'\n'"$(printf '%s\n' "$hits" | sed 's/^/    /')"$'\n'
done

[[ -z "$REPORT" ]] && exit 0

printf '%s\n' "Похоже на секреты в файлах, изменённых этой командой:
$REPORT
Файл появился не через Write/Edit, поэтому обычная проверка записи его не видела. Вынеси значения в переменные окружения, в образец положи плейсхолдер, а сам файл закрой в .gitignore." >&2
exit 2
