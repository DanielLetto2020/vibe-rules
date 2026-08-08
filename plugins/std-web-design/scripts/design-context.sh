#!/usr/bin/env bash
# design-context.sh — PostToolUse: оформление, уже принятое в этом проекте.
#
# Правило «придерживайся существующего дизайна» прозой не работает: чтобы ему
# следовать, надо знать, какой дизайн существует, а это знание разбросано по
# файлам стилей и не попадает в контекст само. Агент верстает по своему
# усмотрению не из упрямства — он просто не видел палитры.
#
# Поэтому хук собирает факты из кода: переменные оформления, шрифты, радиусы,
# конфигурацию Tailwind — и отдаёт их списком. Дальше правило std-web-design
# требует брать значения оттуда.
#
# Если ничего не нашлось, проект верстается с нуля — и тогда напоминание
# обратное: сначала токены и направление, потом разметка. Это единственный
# момент, когда оформление выбирают; дальше его только соблюдают.
#
# Отключить: export STD_DESIGN=0
set -uo pipefail

[[ "${STD_DESIGN:-1}" == "0" ]] && exit 0

INPUT=$(cat)

# std:hooks-off — человек отключил замки в этом проекте (.claude/std-hooks-off).
# Этот хук молчит целиком; правила остаются и грузятся как раньше. Запреты
# на необратимое маркер не снимает — они живут в guard-bash.sh и работают
# всегда. Что замки выключены, напоминает session-check.sh: единственный хук,
# которого маркер не глушит.
[[ -f "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/std-hooks-off" ]] && exit 0

# Разбор входа как в замках: jq, иначе python3. Хук не защищает, а подсказывает,
# поэтому при отсутствии обоих он молчит — о поломке скажет session-check.
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
  *.css|*.scss|*.sass|*.less|*.vue|*.html|*.htm|*.blade.php|*.twig|*.jsx|*.tsx) ;;
  *) exit 0 ;;
esac

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
[[ -d "$PROJECT_DIR/.claude/rules" ]] || exit 0

# Один раз за сессию: палитра не меняется от файла к файлу, а повтор на каждую
# правку — шум, который отключают вместе с проверкой.
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
STAMP="${TMPDIR:-/tmp}/std-design-${SESSION}"
[[ -f "$STAMP" ]] && exit 0

sources() { # файлы, где обычно живёт оформление
  find "$PROJECT_DIR" -maxdepth 4 \
    \( -path '*/node_modules' -o -path '*/vendor' -o -path '*/.git' \
       -o -path '*/dist' -o -path '*/build' -o -path '*/.nuxt' \) -prune -o \
    \( -name '*.css' -o -name '*.scss' -o -name '*.sass' -o -name '*.less' \
       -o -name '*.vue' -o -name 'tailwind.config.*' \) -type f -print 2>/dev/null | head -200
}

FILES=$(sources)
[[ -z "$FILES" ]] && FILES=""

collect() { # <регулярное выражение> <сколько> — уникальные совпадения строкой
  [[ -z "$FILES" ]] && return 0
  printf '%s\n' "$FILES" | tr '\n' '\0' \
    | xargs -0 grep -hoE "$1" 2>/dev/null \
    | sed 's/[[:space:]]\+/ /g; s/ *!important//; s/^ *//; s/ *$//' \
    | sort -u | head -"$2" | paste -sd, - | sed 's/,/, /g'
}

# Переменные оформления: и собственные (--brand), и заданные препроцессором
TOKENS=$(collect '(--|\$)[a-z][a-z0-9-]*(color|colour|bg|background|brand|accent|primary|secondary|text|surface|border|shadow|radius|space|gap|font)[a-z0-9-]*' 20)
COLORS=$(collect '#[0-9a-fA-F]{3,8}\b|(rgb|hsl|oklch|lab)a?\([^)]{3,40}\)' 10)

# Из объявления шрифта берём только первое семейство: запасные варианты
# одинаковы почти везде и в списке лишь мешают увидеть выбранный шрифт.
FONTS=$(collect 'font-family:[^;}]{3,80}' 12)
FONTS=$(printf '%s' "$FONTS" | tr ',' '\n' | sed -n 's/^ *font-family: *//p' \
        | tr -d '"'"'" | sed 's/^ *//; s/ *$//' | grep -v '^inherit$' \
        | sort -u | head -4 | paste -sd, - | sed 's/,/, /g')

RADII=$(collect 'border-radius: *[^;}]{1,24}' 5)

# `grep -c` при нуле совпадений возвращает 1, и `|| echo 0` дописывает второй
# ноль к уже напечатанному — сравнение потом падает на «0\n0».
HAS_TAILWIND=0
printf '%s\n' "$FILES" | grep -q 'tailwind\.config' && HAS_TAILWIND=1

NOTES=()
[[ -n "$TOKENS" ]] && NOTES+=("переменные оформления: $TOKENS")
[[ -n "$COLORS" ]] && NOTES+=("цвета: $COLORS")
[[ -n "$FONTS" ]]  && NOTES+=("шрифты: $FONTS")
[[ -n "$RADII" ]]  && NOTES+=("скругления: $RADII")
[[ "$HAS_TAILWIND" -eq 1 ]] && NOTES+=("настройка Tailwind в проекте есть — значения берутся из неё")

mkdir -p "$(dirname "$STAMP")" 2>/dev/null
: > "$STAMP" 2>/dev/null

if [[ ${#NOTES[@]} -eq 0 ]]; then
  CTX="В проекте не найдено ни переменных оформления, ни заданных шрифтов и скруглений — вёрстка начинается с нуля. Прежде чем верстать: сформулируй направление одной фразой и заведи токены (палитра, шкала размеров, шкала отступов, радиусы), дальше бери значения только из них. Оформление по умолчанию — фиолетово-синий градиент, Inter, три карточки с тенью, эмодзи вместо иконок — это не стиль, а отсутствие решения; подробности в правиле std-web-design/20-from-scratch."
else
  JOINED=$(printf '%s; ' "${NOTES[@]}")
  CTX="Оформление, уже принятое в проекте — ${JOINED%; }. Бери значения отсюда, а не подбирай новые: разнобой вредит интерфейсу сильнее, чем скучное решение. Нужного значения действительно нет — добавь его в общий набор токенов и скажи об этом человеку, а не вписывай по месту."
fi

printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "$(json_escape "$CTX")"
exit 0
