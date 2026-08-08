#!/usr/bin/env bash
# precommit-secrets.sh — PreToolUse: не дать закоммитить секрет.
#
# Последняя точка, где утечку ещё можно отменить бесплатно. После коммита
# секрет живёт в истории: удаление файла следующим коммитом ничего не даёт,
# нужен переписанный история плюс ротация ключа — а ротацию делает не тот,
# кто коммитил, и обычно не в тот же день.
#
# Поэтому здесь единственный случай, где решение — deny, а не ask. Цена
# ложного срабатывания (одна строка в .claude/secret-allow) несопоставима
# с ценой пропуска.
#
# Отключить нельзя. Разрешить конкретную строку: .claude/secret-allow,
# по одной подстроке на строку.
set -uo pipefail

INPUT=$(cat)

# std:hooks-off — человек отключил замки в этом проекте (.claude/std-hooks-off).
# Этот хук молчит целиком; правила остаются и грузятся как раньше. Запреты
# на необратимое маркер не снимает — они живут в guard-bash.sh и работают
# всегда. Что замки выключены, напоминает session-check.sh: единственный хук,
# которого маркер не глушит.
[[ -f "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/std-hooks-off" ]] && exit 0
. "$(dirname "${BASH_SOURCE[0]}")/secret-lib.sh"

json_escape() {
  local s="$1"; s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
  printf '%s' "$s"
}
emit() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' \
    "$1" "$(json_escape "$2")"
  exit 0
}
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

if ! CMD=$(read_command); then
  emit ask "Проверка индекса на секреты не работает: нет ни jq, ни python3. Убедись сам, что в коммит не уходит ключ, или поставь jq."
fi
[[ -z "$CMD" ]] && exit 0

# Интересует фиксация изменений. `git commit` внутри строки любой сложности:
# разбор здесь не нужен, ложное срабатывание стоит одного лишнего скана.
printf '%s' "$CMD" | grep -qE '(^|[;&|[:space:]])git([[:space:]]+-[^[:space:]]+)*[[:space:]]+commit' || exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1 || exit 0

# Разрешённые находки берутся из общего механизма (.claude/secret-allow):
# один список на все точки проверки, иначе исключение, добавленное здесь,
# не действует при записи файла и наоборот.
allowed() { secret_allowed "$1" "$PROJECT_DIR"; }

# `git commit -a` кладёт в коммит то, чего в индексе ещё нет, — сравнивать
# надо с HEAD, иначе проверка смотрит не на то, что уедет.
RANGE="--cached"
printf '%s' "$CMD" | grep -qE 'git[^;&|]*commit[^;&|]*([[:space:]]-[a-zA-Z]*a[a-zA-Z]*([[:space:]]|$)|--all([[:space:]]|$))' && RANGE="HEAD"

FILES=$(git -C "$PROJECT_DIR" diff $RANGE --name-only --diff-filter=ACMR 2>/dev/null)
[[ -z "$FILES" ]] && exit 0

# 1. Файл, который является секретом целиком. Содержимое неважно: `.env`
#    в истории — это выданные наружу доступы независимо от того, что внутри.
SECRET_FILES=""
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  allowed "$f" && continue
  kind=$(secret_path_kind "$f") || continue
  SECRET_FILES+="  $f — $kind"$'\n'
done <<< "$FILES"

if [[ -n "$SECRET_FILES" ]]; then
  emit deny "В коммит уходят файлы с доступами:
$SECRET_FILES
После коммита это уже не отменить удалением файла — секрет остаётся в истории, и его придётся ротировать. Убери из индекса и закрой правилом:
  git rm --cached <файл>
  echo '<файл>' >> .gitignore
Если файл действительно безопасен — добавь его в .claude/secret-allow."
fi

# 2. Секрет в добавленных строках. Смотрим только на «+»: существующая строка
#    в файле, который правили по другому поводу, уже в истории, и блокировать
#    из-за неё коммит бессмысленно — это остановит работу, ничего не спасая.
HITS=""
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  added=$(git -C "$PROJECT_DIR" diff $RANGE -U0 -- "$f" 2>/dev/null \
            | grep '^+' | grep -v '^+++' | sed 's/^+//')
  [[ -z "$added" ]] && continue
  found=$(printf '%s\n' "$added" | secret_text_hits "$PROJECT_DIR")
  [[ -z "$found" ]] && continue
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    allowed "$line" && continue
    HITS+="  $f: ${line#*:}"$'\n'
  done <<< "$found"
done <<< "$FILES"

[[ -z "$HITS" ]] && exit 0

emit deny "Похоже на секрет в строках, которые уходят в коммит:
$HITS
Секрет, попавший в историю, удалением файла не убирается — нужна перезапись истории и ротация ключа. Вынеси значение в переменную окружения, в .env.example положи плейсхолдер.
Если это не секрет — добавь отличительную подстроку в .claude/secret-allow, и проверка перестанет на неё реагировать."
