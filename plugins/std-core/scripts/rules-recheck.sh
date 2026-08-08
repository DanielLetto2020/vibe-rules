#!/usr/bin/env bash
# rules-recheck.sh — PostToolUse: какие правила действуют на только что
# записанный файл.
#
# Закрывает разрыв между «правило загружено» и «правило применено». Правила
# приезжают в контекст при чтении файла, но правка идёт последней в длинной
# цепочке рассуждений, и к моменту записи из пятнадцати пунктов применяются
# три. Остальные не нарушены осознанно — про них забыли.
#
# Поэтому после каждой записи хук называет модули, чьи paths совпали с путём
# файла, и требует сверки. Это дешёвый способ получить главное свойство,
# ради которого репозиторий и заводится: файл, которого коснулись, постепенно
# приходит в соответствие со стандартом, даже если проект написан вразнобой.
#
# Радиус ограничен намеренно: сверяется файл целиком, исправляется то, что
# в границах правки. Иначе одна правка порождает диффы на сотни строк, а в
# проекте без тестов это опаснее, чем несоответствие стилю.
#
# Напоминание выдаётся один раз на файл за сессию: повтор на каждый Edit
# превращается в шум, а шум отключают вместе с проверкой.
#
# Отключить: export STD_RECHECK=0
set -uo pipefail

[[ "${STD_RECHECK:-1}" == "0" ]] && exit 0

INPUT=$(cat)

# std:hooks-off — человек отключил замки в этом проекте (.claude/std-hooks-off).
# Правила при этом остаются и грузятся как раньше: стандарт возвращается
# к тексту без проверки. Что замки выключены, напоминает session-check.sh —
# единственный хук, которого маркер не глушит.
[[ -f "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/std-hooks-off" ]] && exit 0

# Разбор входа тем же способом, что и в замках. Этот хук не защищает, а
# напоминает, поэтому при полном отсутствии разборщика он молчит: блокировать
# работу из-за пропущенного напоминания несоразмерно. О самой поломке скажет
# session-check при старте сессии — там это видно один раз и в нужном месте.
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

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
RULES_DIR="$PROJECT_DIR/.claude/rules"
[[ -d "$RULES_DIR" ]] || exit 0

# Путь относительно корня проекта: paths в правилах резолвятся от него
REL="${FILE#"$PROJECT_DIR"/}"
case "$REL" in
  .claude/*|.git/*) exit 0 ;;
  # Чужой и сгенерированный код: маски правил начинаются с `**/`, чтобы
  # находить приложение в подкаталоге, и той же ценой достают до vendor,
  # node_modules и сборки. Напоминать про стандарты в файле, который никто
  # не пишет руками, — шум, а шум отключают вместе с проверкой.
  vendor/*|*/vendor/*|node_modules/*|*/node_modules/*) exit 0 ;;
  .venv/*|*/.venv/*|dist/*|*/dist/*|build/*|*/build/*) exit 0 ;;
esac

# Один раз на файл за сессию. Файл состояния привязан к сессии: новая сессия
# начинает заново, потому что контекст к тому моменту уже другой.
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
SEEN="${TMPDIR:-/tmp}/std-recheck-${SESSION}"
if [[ -f "$SEEN" ]] && grep -qxF "$REL" "$SEEN" 2>/dev/null; then
  exit 0
fi

# Совпадение glob'а из frontmatter с путём файла.
#
# Сопоставление bash (`[[ p == glob ]]`) здесь не годится: оно не раскрывает
# `{ts,js}` внутри шаблона и трактует `**` как обычную звёздочку, поэтому
# `pages/**/*.vue` не совпадает с `pages/index.vue`. Ошибка была бы незаметной —
# хук просто молчал бы про часть модулей. Поэтому glob переводится в регулярное
# выражение, где каждая конструкция имеет однозначный смысл:
#
#   **/  ноль или больше каталогов        (.*/)?
#   **   любая глубина                    .*
#   *    в пределах одного сегмента       [^/]*
#   {a,b} перечисление                    (a|b)
#
# Квадратные скобки не экранируются: `[Cc]onsumers` — класс символов и в glob,
# и в регулярном выражении, смысл совпадает.
glob_to_regex() { # <glob> -> regex
  local g="$1" out="" i c n=${#1}
  for ((i = 0; i < n; i++)); do
    c=${g:i:1}
    case "$c" in
      '*')
        if [[ "${g:i:3}" == '**/' ]]; then out+='(.*/)?'; ((i += 2))
        elif [[ "${g:i:2}" == '**' ]]; then out+='.*'; ((i += 1))
        else out+='[^/]*'; fi ;;
      '?') out+='[^/]' ;;
      '{') out+='(' ;;
      '}') out+=')' ;;
      ',') out+='|' ;;
      '.' | '+' | '(' | ')' | '|' | '^' | '$' | '\') out+="\\$c" ;;
      *) out+="$c" ;;
    esac
  done
  printf '%s' "$out"
}

matches_glob() { # <glob> <путь>
  local re; re=$(glob_to_regex "$1")
  [[ "$2" =~ ^${re}$ ]]
}

MODULES=()
for rule in "$RULES_DIR"/*.md "$RULES_DIR"/*/*.md; do
  [[ -f "$rule" ]] || continue

  # frontmatter до второго ---
  fm=$(awk 'NR==1 && $0!="---"{exit} NR>1 && $0=="---"{exit} NR>1' "$rule" 2>/dev/null)
  [[ -n "$fm" ]] || continue

  # Правило без paths грузится всегда — напоминать про него незачем
  printf '%s' "$fm" | grep -q '^paths:' || continue

  hit=0
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    if matches_glob "$p" "$REL"; then hit=1; break; fi
  done < <(printf '%s\n' "$fm" | sed -n '/^paths:/,/^[a-z_]*:/p' \
             | sed -n 's/^[[:space:]]*-[[:space:]]*//p' | tr -d '"'"'")

  [[ $hit -eq 1 ]] || continue

  # Имя модуля — каталог симлинка (std-web-css), для правил проекта — сам файл
  d=$(basename "$(dirname "$rule")")
  if [[ "$d" == "rules" ]]; then
    MODULES+=("правило проекта $(basename "$rule" .md)")
  else
    MODULES+=("$d/$(basename "$rule" .md)")
  fi
done

[[ ${#MODULES[@]} -eq 0 ]] && exit 0

# Список без повторов и в стабильном порядке.
#
# Разделитель ставится отдельным шагом: `paste -sd', '` берёт символы списка
# по очереди и выдаёт то запятую, то пробел — список выглядит побитым.
LIST=$(printf '%s\n' "${MODULES[@]}" | sort -u | paste -sd, - | sed 's/,/, /g')

mkdir -p "$(dirname "$SEEN")" 2>/dev/null
printf '%s\n' "$REL" >> "$SEEN" 2>/dev/null

CTX="Файл $REL подпадает под правила: $LIST. Сверь с ними написанное — целиком файл, а не только новые строки. Несоответствия в границах своей правки исправь сразу; если файл расходится с правилами шире правки, назови расхождения человеку и спроси, чинить ли сейчас — молча переписывать чужой код не нужно."

printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "$(json_escape "$CTX")"
exit 0
