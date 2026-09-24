#!/usr/bin/env bash
# guard-commit.sh — PreToolUse: не дать закоммитить, не прогнав гейты.
#
# Это замок, который делает всю остальную конструкцию обязательной. Без него
# гейты — доброе намерение: их прогоняют, когда помнят. С ним «работа сделана»
# и «проверки пройдены» — одно и то же событие.
#
# Логика: gauntlet.sh при полном успешном прогоне оставляет отметку
# с отпечатком рабочего дерева на момент начала прогона
# (worktree-fingerprint.sh). Перед коммитом отпечаток снимается заново;
# не совпал — значит содержимое изменилось после проверки.
#
# Отключить для конкретного проекта: .claude/gauntlet.json → "requireBeforeCommit": false
set -uo pipefail

INPUT=$(cat)

# std:hooks-off — человек отключил замки в этом проекте (.claude/std-hooks-off).
# Этот хук молчит целиком; правила остаются и грузятся как раньше. Запреты
# на необратимое маркер не снимает — они живут в guard-bash.sh и работают
# всегда. Что замки выключены, напоминает session-check.sh: единственный хук,
# которого маркер не глушит.
[[ -f "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/std-hooks-off" ]] && exit 0

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

# --- Что считается коммитом -----------------------------------------------------
# Раньше искали буквально «git commit» после пробела или ;&|. Мимо проходили
# git -C . commit, git -c user.name=x commit, git --no-pager commit,
# /usr/bin/git commit и bash -c "git commit" — а заодно всё, что создаёт
# коммит без слова commit: merge, cherry-pick, revert, am, pull.
#
# Разбор грубый и намеренно в сторону вопроса: «echo git commit» тоже спросит.
# Лишний вопрос раз в месяц дешевле коммита, прошедшего мимо проверок.
SEP='(^|[;&|(){}[:space:]"'\''`\\])'
GITBIN='([^[:space:];&|(){}"'\''`]*/)?git'
VAL='("[^"]*"|'\''[^'\'']*'\''|[^[:space:]"'\''])+'
GOPT='[[:space:]]+(-[Cc][[:space:]]+'"$VAL"'|--(git-dir|work-tree|namespace|exec-path|config-env|super-prefix)[[:space:]]+'"$VAL"'|-[-a-zA-Z]('"$VAL"')?)'
END='([[:space:];&|)"'\''`]|$)'
COMMIT_RE="$SEP$GITBIN($GOPT)*[[:space:]]+commit$END"
PRODUCE_RE="$SEP$GITBIN($GOPT)*[[:space:]]+(merge|cherry-pick|revert|am|pull)$END"

# Перенос строки через обратную косую — та же команда
FLAT=${CMD//$'\\\n'/ }
if printf '%s\n' "$FLAT" | grep -qE "$COMMIT_RE"; then
  :
elif printf '%s\n' "$FLAT" | grep -qE "$PRODUCE_RE" \
     && ! printf '%s\n' "$FLAT" | grep -qE -- '--(abort|quit)([[:space:]]|$)'; then
  # merge --abort и компания коммитов не создают — спрашивать незачем
  :
else
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
CFG="$PROJECT_DIR/.claude/gauntlet.json"
MARK="$PROJECT_DIR/.claude/.gauntlet-pass"

# has() вместо `// true`: оператор // в jq считает пустым не только null,
# но и false, поэтому `.requireBeforeCommit // true` для false вернул бы true
# и настройка молча не работала бы.
[[ "$(read_cfg "$CFG" requireBeforeCommit)" == "false" ]] && exit 0

ask() { emit ask "$1"; }

[[ -f "$MARK" ]] || ask "Гейты не прогонялись после последних изменений (или последний прогон не прошёл). Запусти /std-gauntlet:run — коммит без прохождения проверок означает, что качество кода никем не подтверждено."

# --- git: сверка отпечатка содержимого ------------------------------------------
if git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  WANT=$(sed -n 's/^fingerprint //p' "$MARK" 2>/dev/null | head -1)
  # Отметка без отпечатка — от прежней версии или оставлена не прогоном
  # (touch). Засчитывать её значило бы верить времени файла, а не проверке.
  [[ -n "$WANT" ]] || ask "Отметка прогона гейтов без отпечатка содержимого — она от старой версии или создана не прогоном. Запусти /std-gauntlet:run перед коммитом."

  # Неотслеживаемые файлы, которые записал сам прогон (отчёты покрытия),
  # gauntlet.sh перечислил в отметке: в сверку они не входят.
  FP_ARGS=()
  while IFS= read -r ex; do
    [[ -n "$ex" ]] && FP_ARGS+=(--exclude "$ex")
  done < <(sed -n 's/^exclude //p' "$MARK" 2>/dev/null)
  NOW=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$(dirname "${BASH_SOURCE[0]}")/worktree-fingerprint.sh" ${FP_ARGS[@]+"${FP_ARGS[@]}"} 2>/dev/null) \
    || ask "Не удалось снять отпечаток рабочего дерева (git вернул ошибку) — не видно, менялся ли код после прогона гейтов. Запусти /std-gauntlet:run перед коммитом."
  [[ "$NOW" == "$WANT" ]] && exit 0

  # Отпечатки — настоящие деревья git, поэтому можно назвать, что именно
  # изменилось. Дерево из отметки могло уйти при сборке мусора — тогда
  # просто без списка.
  LIST=$(git -C "$PROJECT_DIR" diff-tree -r --name-only --no-renames "$WANT" "$NOW" 2>/dev/null | head -5 | tr '\n' ' ')
  LIST=${LIST% }
  ask "После последнего успешного прогона гейтов изменилось содержимое рабочего дерева${LIST:+: $LIST}. Проверки устарели — запусти /std-gauntlet:run перед коммитом."
fi

# --- не git: время изменения, как раньше -------------------------------------
# Коммит здесь всё равно не состоится, но решение замка не должно зависеть
# от того, в какой момент человек сделает git init. Смотрим любые файлы,
# а не только исходники: package.json и сценарии — тоже работа.
#
# Сравниваем с mtime самого файла-отметки, а не с записанной в него секундой:
# у файлов время хранится с долями секунды, и правка, сделанная в ту же секунду
# что и прогон, выглядела бы более поздней. Каталоги сборки и зависимостей
# исключаем: их mtime меняется сам по себе. Сами каталоги смотрим тоже:
# удаление и переименование файла (mv сохраняет его mtime) меняют время
# каталога, в котором он лежал.
NEWER=$(find "$PROJECT_DIR" \
          \( -path '*/node_modules' -o -path '*/vendor' -o -path '*/.git' \
             -o -path '*/.venv' -o -path '*/dist' -o -path '*/build' \
             -o -path '*/__pycache__' -o -path '*/.claude' \) -prune -o \
          \( -type f -o -type d \) -newer "$MARK" -print 2>/dev/null | head -5)

[[ -z "$NEWER" ]] && exit 0

LIST=$(printf '%s' "$NEWER" | sed -e "s|^$PROJECT_DIR/||" -e "s|^$PROJECT_DIR\$|.|" | tr '\n' ' ')
LIST=${LIST% }
ask "После последнего успешного прогона гейтов изменялись файлы: $LIST. Проверки устарели — запусти /std-gauntlet:run перед коммитом."
