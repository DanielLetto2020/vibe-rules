#!/usr/bin/env bash
# worktree-fingerprint.sh — отпечаток содержимого рабочего дерева.
#
#   worktree-fingerprint.sh [--exclude <путь от корня репозитория>]…
#
# Печатает id дерева git, собранного из того, что лежит на диске сейчас:
# отслеживаемые файлы и новые, кроме игнорируемых. Им gauntlet.sh помечает
# успешный прогон, а guard-commit.sh сверяет отметку перед коммитом.
#
# Почему не время изменения файлов. Раньше замок сравнивал mtime исходников
# семи расширений с временем отметки. Мимо проходили .tsx, .rs, package.json
# и сценарии, удалённый тест (удаления mtime не оставляют) и переименование
# через mv (mtime сохраняется). Отпечаток видит любое изменение содержимого.
#
# Почему не индекс. git add и коммит содержимого не меняют, и прогон после них
# повторять незачем. Дерево собирается во временной копии индекса командой
# git add -A: настоящий индекс не трогается, а stat-кэш копии делает сборку
# быстрой — перечитываются только изменённые файлы.
#
# Локальное состояние проверок (.claude/.gauntlet-pass, планки храповиков,
# журнал правил) меняется самим прогоном и в отпечаток не входит.
#
# Коды: 0 — отпечаток напечатан; 3 — не git-репозиторий; 2 — ошибка git.
set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
cd "$PROJECT_DIR" 2>/dev/null || exit 2
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 3
prefix=$(git rev-parse --show-prefix 2>/dev/null)
top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 2
cd "$top" || exit 2

excl=()
for f in .gauntlet-pass .ratchet.json .debt.json .std-trace.jsonl settings.local.json; do
  excl+=("${prefix}.claude/$f")
done
while [[ $# -gt 0 ]]; do
  case "$1" in
    --exclude) [[ -n "${2:-}" ]] && excl+=("$2"); shift 2 ;;
    *) shift ;;
  esac
done

idx=$(git rev-parse --git-path index) || exit 2
tmp=$(mktemp) || exit 2
trap 'rm -f "$tmp" "$tmp.lock"' EXIT
# Пустой файл git за индекс не примет; без настоящего индекса (ни одного
# git add) пусть создаст новый.
if [[ -f "$idx" ]]; then cp "$idx" "$tmp" || exit 2; else rm -f "$tmp"; fi
export GIT_INDEX_FILE="$tmp"

# Сначала всё, потом исключения. Исключающий pathspec у git add не годится:
# на игнорируемый путь (а .gauntlet-pass обычно в .gitignore) add отвечает
# ошибкой, даже когда путь указан как исключение.
git add -A -- ':(top)' >/dev/null 2>&1 || exit 2
pathspec=()
for e in "${excl[@]}"; do pathspec+=(":(top,literal)$e"); done
git rm -r -q --cached --ignore-unmatch -- "${pathspec[@]}" >/dev/null 2>&1 || exit 2
git write-tree 2>/dev/null || exit 2
