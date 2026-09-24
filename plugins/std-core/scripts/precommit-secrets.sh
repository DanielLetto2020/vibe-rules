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

. "$(dirname "${BASH_SOURCE[0]}")/bash-min.sh"; std_bash_min pre "${BASH_SOURCE[0]}"   # до чтения stdin
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

# Интересует фиксация изменений. Перенос строки через «\» склеивается заранее:
# `git \⏎ commit` — одна команда.
CMD=${CMD//$'\\\n'/ }
# `git commit` внутри строки любой сложности: после скобки, кавычки (bash -c
# 'git commit'), с полным путём и с глобальными опциями перед подкомандой —
# -C <каталог>, -c <ключ=значение>, --no-pager. Раньше опция с аргументом
# (`git -C . commit`) выводила команду из-под проверки целиком.
GIT_COMMIT_RE='(^|[;&|(`[:space:]"'"'"'])([^[:space:];&|]*/)?git([[:space:]]+(-[Cc][[:space:]]+[^[:space:]]+|--(git-dir|work-tree)[=[:space:]][^[:space:]]+|-[^[:space:]]+))*[[:space:]]+commit([[:space:]]|$|[;&|)"'"'"'])'
printf '%s' "$CMD" | grep -qE "$GIT_COMMIT_RE" || exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"

# `git -C <каталог> commit` коммитит в другом репозитории — проверять надо его.
REPO="$PROJECT_DIR"
cdir=$(printf '%s' "$CMD" | grep -oE 'git[[:space:]]+(-[^[:space:]]+[[:space:]]+)*-C[[:space:]]+[^[:space:];&|]+' | head -1 | sed -E 's/.*-C[[:space:]]+//')
cdir=${cdir//[\"\']/}
if [[ -n "$cdir" ]]; then
  [[ "$cdir" == /* ]] && REPO="$cdir" || REPO="$PROJECT_DIR/$cdir"
fi
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || exit 0

# Разрешённые находки берутся из общего механизма (.claude/secret-allow):
# один список на все точки проверки, иначе исключение, добавленное здесь,
# не действует при записи файла и наоборот.
allowed() { secret_allowed "$1" "$PROJECT_DIR"; }

# Что уедет в коммит. Хук срабатывает ДО команды, поэтому индекс в этот момент
# ещё не тот, что будет закоммичен, если команда сама его меняет:
#   git add . && git commit        — индекс наполнится после проверки;
#   git commit -a / --all          — возьмёт изменённые отслеживаемые файлы;
#   git commit <путь> / -o / -i    — возьмёт файлы из рабочей копии.
# Раньше во всех этих формах сканировался старый индекс, и секрет уезжал.
# В этих случаях проверяется всё, что может попасть в коммит: изменения
# относительно HEAD и неотслеживаемые файлы, не закрытые .gitignore.
# Лишний файл в скане стоит одного вопроса; пропущенный — ротации ключа.
MODE="index"
# Хвост после `commit`, одной строкой и без строк в кавычках: текст сообщения
# (включая привычное `-m "$(cat <<'EOF' … EOF)"`) не должен читаться как пути.
after_commit=$(printf '%s' "$CMD" | tr '\n' ' ' | sed -E 's/.*[[:space:]]commit([[:space:]]|$)//' \
                 | sed -E "s/\"[^\"]*\"/ MSG /g; s/'[^']*'/ MSG /g")
if printf '%s' "$CMD" | grep -qE '(^|[;&|(`[:space:]"'"'"'])git([[:space:]]+-[^[:space:]]+([[:space:]]+[^-][^[:space:]]*)?)*[[:space:]]+(add|stage|rm|mv)([[:space:]]|$)'; then
  MODE="worktree"
elif printf '%s' "$after_commit" | grep -qE '(^|[[:space:]])(-[a-zA-Z]*[aoi][a-zA-Z]*|--all|--only|--include|--)([[:space:]]|$)'; then
  MODE="worktree"
else
  # Путь после опций: всё, что не опция и не аргумент опции.
  set -f
  # shellcheck disable=SC2046  # слова нужны раздельно, маски выключены set -f
  set -- $(printf '%s' "$after_commit" | sed -E 's/[;&|)].*//')
  set +f
  while (($#)); do
    case "$1" in
      -m|-F|-c|-C|-t|--author|--date|--template|--fixup|--squash|--cleanup|--trailer|--file|--message|--reuse-message|--reedit-message)
        shift ;;                                   # опция с отдельным аргументом
      -[a-zA-Z]*[mFcCt])
        shift ;;                                   # склеенные флаги, последний берёт аргумент
      -*) ;;
      *) MODE="worktree"; break ;;
    esac
    shift
  done
  # Если кавычки не сбалансированы, слово из сообщения может показаться путём.
  # Это только расширяет скан — пропустить секрет так нельзя.
fi

# Пустое дерево — база для первого коммита, когда HEAD ещё нет.
BASE=HEAD
git -C "$REPO" rev-parse --verify -q HEAD >/dev/null 2>&1 || BASE=$(git -C "$REPO" hash-object -t tree /dev/null)

# Имена — через -z и без кавычек: с core.quotePath имя конфиг/.env приходило
# как "\320\272…/.env", и ни проверка имени, ни diff по нему не срабатывали.
g() { git -C "$REPO" -c core.quotePath=false "$@"; }
declare -A UNTRACKED=()
FILES=()
if [[ "$MODE" == "index" ]]; then
  while IFS= read -r -d '' f; do FILES+=("$f"); done \
    < <(g diff --cached --name-only -z --diff-filter=ACMR 2>/dev/null)
else
  while IFS= read -r -d '' f; do FILES+=("$f"); done \
    < <(g diff "$BASE" --name-only -z --diff-filter=ACMR 2>/dev/null)
  while IFS= read -r -d '' f; do FILES+=("$f"); UNTRACKED["$f"]=1; done \
    < <(g ls-files -o --exclude-standard -z 2>/dev/null)
fi
# `git add -f` кладёт в индекс и игнорируемое: такие пути проверяем по имени.
if [[ "$MODE" == "worktree" ]]; then
  while IFS= read -r f; do
    f=${f//[\"\']/}
    [[ -n "$f" && -e "$REPO/$f" ]] && FILES+=("$f") && UNTRACKED["$f"]=1
  done < <(printf '%s' "$CMD" | grep -oE 'git[[:space:]]+(add|stage)[[:space:]]+([^;&|]*[[:space:]])?(-f|--force)([[:space:]]+[^;&|]*)?' \
             | sed -E 's/git[[:space:]]+(add|stage)//; s/(^|[[:space:]])-[^[:space:]]*//g' | tr ' ' '\n')
fi
[[ ${#FILES[@]} -eq 0 ]] && exit 0

# Добавленные строки файла: из diff для отслеживаемых, всё содержимое —
# для новых, которых git ещё не знает.
added_lines() { # <файл>
  local f="$1"
  if [[ -n "${UNTRACKED[$f]:-}" ]]; then
    [[ -f "$REPO/$f" ]] || return 0
    LC_ALL=C grep -qP '\x00' "$REPO/$f" 2>/dev/null && return 0
    head -c 1048576 "$REPO/$f"
    return 0
  fi
  local range="--cached"; [[ "$MODE" == "worktree" ]] && range="$BASE"
  g diff $range -U0 -- "$f" 2>/dev/null | grep '^+' | grep -v '^+++' | sed 's/^+//'
}

# 1. Файл, который является секретом целиком. Содержимое неважно: `.env`
#    в истории — это выданные наружу доступы независимо от того, что внутри.
SECRET_FILES=""
for f in "${FILES[@]}"; do
  [[ -z "$f" ]] && continue
  allowed "$f" && continue
  kind=$(secret_path_kind "$f") || continue
  SECRET_FILES+="  $f — $kind"$'\n'
done

if [[ -n "$SECRET_FILES" ]]; then
  emit deny "В коммит уходят файлы с доступами:
$SECRET_FILES
После коммита это уже не отменить удалением файла — секрет остаётся в истории, и его придётся ротировать. Убери из индекса и закрой правилом:
  git rm --cached <файл>
  echo '<файл>' >> .gitignore
Если файл действительно безопасен — скажи об этом человеку: исключение в .claude/secret-allow добавляет он, а не модель по ходу задачи."
fi

# 2. Секрет в добавленных строках. Смотрим только на «+»: существующая строка
#    в файле, который правили по другому поводу, уже в истории, и блокировать
#    из-за неё коммит бессмысленно — это остановит работу, ничего не спасая.
HITS=""
for f in "${FILES[@]}"; do
  [[ -z "$f" ]] && continue
  added=$(added_lines "$f")
  [[ -z "$added" ]] && continue
  found=$(printf '%s\n' "$added" | secret_text_hits "$PROJECT_DIR")
  [[ -z "$found" ]] && continue
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    allowed "$line" && continue
    HITS+="  $f: ${line#*:}"$'\n'
  done <<< "$found"
done

[[ -z "$HITS" ]] && exit 0

emit deny "Похоже на секрет в строках, которые уходят в коммит:
$HITS
Секрет, попавший в историю, удалением файла не убирается — нужна перезапись истории и ротация ключа. Вынеси значение в переменную окружения, в .env.example положи плейсхолдер.
Если это не секрет — покажи строку человеку. Исключение (отличительная подстрока в .claude/secret-allow) добавляет он: строка там снимает запрет для всего, что её содержит."
