#!/usr/bin/env bash
# code-siblings.sh — PostToolUse: как в этом проекте уже пишут такие файлы.
#
# Закрывает разнобой, которого не видит ни один линтер. Форматирование
# приводит к общему виду pint или eslint, типы проверяет анализатор, а вот
# «здесь бизнес-логика живёт в Action, а не в контроллере», «тесты пишутся
# от поведения, а не от метода», «репозиторий возвращает коллекцию, а не
# массив» — это структура, и она у каждого нового файла своя, если агент
# не видел соседних.
#
# Он их и не видит: правила модуля описывают идеал, а не то, что принято
# здесь. Поэтому хук называет ближайшие файлы того же вида и показывает их
# шапки — дальше сверять обязан агент.
#
# Один раз на вид файла за сессию: контроллер, тест и компонент — разные
# образцы, а второй контроллер той же сессии в напоминании уже не нуждается.
#
# Отключить: export STD_SIBLINGS=0
set -uo pipefail

[[ "${STD_SIBLINGS:-1}" == "0" ]] && exit 0

INPUT=$(cat)

# Разбор как в остальных хуках. Этот не защищает, а подсказывает, поэтому при
# отсутствии разборщика молчит: о поломке скажет session-check.
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
json_escape() {
  local s="$1"; s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

FILE=$(read_field file_path) || exit 0
[[ -z "$FILE" ]] && exit 0

case "$FILE" in
  *.php|*.py|*.ts|*.tsx|*.js|*.jsx|*.vue|*.go|*.rb|*.java|*.kt|*.cs|*.rs) ;;
  *) exit 0 ;;
esac

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
[[ -d "$PROJECT_DIR/.claude/rules" ]] || exit 0

REL="${FILE#"$PROJECT_DIR"/}"
case "$REL" in
  vendor/*|*/vendor/*|node_modules/*|*/node_modules/*|.venv/*|*/.venv/*) exit 0 ;;
  dist/*|*/dist/*|build/*|*/build/*|.claude/*) exit 0 ;;
esac

# Только для нового файла. У существующего стиль уже задан им самим, и
# показывать ему соседей — шум; о правилах для него напомнит rules-recheck.
if git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$PROJECT_DIR" ls-files --error-unmatch -- "$FILE" >/dev/null 2>&1 && exit 0
fi

BASE=${FILE##*/}
EXT="${BASE##*.}"
NAME="${BASE%.*}"

# Вид файла — по хвосту имени: UserController и OrderController это один вид,
# а UserController и UserTest — разные, и образцы у них разные.
KIND=""
case "$NAME" in
  *Controller) KIND="Controller" ;;
  *Test|Test*|test_*|*_test|*.test|*.spec|*Spec) KIND="Test" ;;
  *Service)    KIND="Service" ;;
  *Repository) KIND="Repository" ;;
  *Action)     KIND="Action" ;;
  *Request)    KIND="Request" ;;
  *Resource)   KIND="Resource" ;;
  *Job)        KIND="Job" ;;
  *Event)      KIND="Event" ;;
  *Listener)   KIND="Listener" ;;
  *Middleware) KIND="Middleware" ;;
  *Factory)    KIND="Factory" ;;
  *Migration|[0-9]*_*) KIND="Migration" ;;
  *Command)    KIND="Command" ;;
  *Model)      KIND="Model" ;;
esac

SESSION="nosession"
if command -v jq >/dev/null 2>&1; then
  SESSION=$(printf '%s' "$INPUT" | jq -r '.session_id // "nosession"' 2>/dev/null)
elif command -v python3 >/dev/null 2>&1; then
  SESSION=$(printf '%s' "$INPUT" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("session_id") or "nosession", end="")
except Exception:
    print("nosession", end="")' 2>/dev/null)
fi
STAMP="${TMPDIR:-/tmp}/std-siblings-${SESSION}"
KEY="${EXT}:${KIND:-plain}"
[[ -f "$STAMP" ]] && grep -qxF "$KEY" "$STAMP" 2>/dev/null && exit 0

DIR=$(dirname "$FILE")

# Сначала соседи по каталогу — они ближе всего к тому, что пишется сейчас.
# Затем однотипные по всему проекту: каталог может быть новым и пустым.
find_siblings() {
  local pattern="*.$EXT"
  [[ -n "$KIND" ]] && pattern="*${KIND}.$EXT"
  find "$DIR" -maxdepth 1 -name "$pattern" -type f ! -path "$FILE" 2>/dev/null | head -3
  [[ -n "$KIND" ]] && find "$PROJECT_DIR" \
      \( -path '*/node_modules' -o -path '*/vendor' -o -path '*/.git' \
         -o -path '*/.venv' -o -path '*/dist' -o -path '*/build' \) -prune -o \
      -name "$pattern" -type f ! -path "$FILE" -print 2>/dev/null | head -3
}

mapfile -t SIBS < <(find_siblings | grep -v "^${FILE}$" | awk '!seen[$0]++' | head -3)

mkdir -p "$(dirname "$STAMP")" 2>/dev/null
printf '%s\n' "$KEY" >> "$STAMP" 2>/dev/null

[[ ${#SIBS[@]} -eq 0 ]] && exit 0

# Шапка файла: первые значимые строки, где видно пространство имён, импорты
# и объявление. Разнобой начинается именно там, а не в теле метода.
head_of() { # <файл>
  grep -vE '^[[:space:]]*(//|#|\*|/\*|$)' "$1" 2>/dev/null | head -6 \
    | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//' | paste -sd'|' - | cut -c1-400
}

LIST=""
for s in "${SIBS[@]}"; do
  LIST+="  ${s#"$PROJECT_DIR"/} → $(head_of "$s")"$'\n'
done

WHAT="файлы того же вида"
[[ -n "$KIND" ]] && WHAT="другие $KIND"

CTX="Создан новый файл ${REL}. В проекте уже есть $WHAT — прежде чем считать файл готовым, открой хотя бы один и сверь структуру: расположение, состав шапки, где живёт логика, что возвращается наружу, как называются методы.
$LIST
Единообразие внутри проекта важнее соответствия любому внешнему образцу: правила модулей описывают идеал, а соседний файл — то, как здесь принято. Если принятое здесь противоречит правилу, скажи об этом человеку и спроси, что важнее, — не выбирай молча."

printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "$(json_escape "$CTX")"
exit 0
