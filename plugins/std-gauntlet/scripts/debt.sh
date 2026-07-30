#!/usr/bin/env bash
# debt.sh — храповик долга: сколько в проекте мест, не соответствующих
# стандарту. Улучшать не обязательно, ухудшать нельзя.
#
# Зачем отдельно от правил. Правило «тронул файл — приведи к стандарту» есть
# в baseline, и хук после записи называет подходящие модули. Но у этого нет
# измерения: неизвестно, движется проект к стандарту или от него. Правило
# без числа соблюдается ровно до первой спешки, и заметить это нельзя.
#
# Почему не ratchet.sh. Там метрика растёт (mutation score), здесь падает;
# там проценты, здесь штуки; и главное — другая реакция на провал. Мутационный
# храповик говорит «усиль тесты», этот — «приведи файл к правилам или объясни,
# почему нельзя». Общая обёртка сделала бы оба сообщения одинаково бесполезными.
#
#   debt.sh count           посчитать нарушения и напечатать число
#   debt.sh check           посчитать, сравнить с планкой, обновить при улучшении
#   debt.sh show            планка, лучшее достигнутое, история
#   debt.sh reset <число>   установить планку вручную (смена линтера или конфига)
#
# Состояние: .claude/.debt.json — локальное, в git не идёт: планка отражает
# прогон на конкретной машине с конкретными версиями инструментов.
set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
STATE="$PROJECT_DIR/.claude/.debt.json"
CFG="$PROJECT_DIR/.claude/gauntlet.json"

# --- std:jq-guard — гейт без разбора состояния чинят, а не проходят -----------
if ! command -v jq >/dev/null 2>&1; then
  echo "храповик долга не может прочитать состояние: на машине нет jq." >&2
  echo "Поставь jq (apt install jq / brew install jq) — без него планка не проверяется." >&2
  exit 2
fi

have() { [[ -e "$PROJECT_DIR/$1" ]]; }

# Команда подсчёта. Требование к ней одно: печатать по строке на нарушение
# в формате «путь:строка: …» — так делают phpstan --error-format=raw,
# eslint -f unix, ruff --output-format=concise и mypy. Считаются именно
# такие строки, а не весь вывод: заголовки и сводки инструментов иначе
# попали бы в долг и меняли бы его при обновлении версии.
debt_command() {
  local c=""
  if [[ -f "$CFG" ]]; then
    c=$(jq -r 'if has("debt") then (.debt.command // "") else "" end' "$CFG" 2>/dev/null)
  fi
  if [[ -n "$c" && "$c" != "null" ]]; then printf '%s' "$c"; return 0; fi

  if have vendor/bin/phpstan; then
    printf '%s' './vendor/bin/phpstan analyse --error-format=raw --no-progress'
  elif have package.json && have node_modules/.bin/eslint; then
    printf '%s' './node_modules/.bin/eslint . -f unix'
  elif have pyproject.toml || have requirements.txt; then
    printf '%s' 'ruff check . --output-format=concise'
  else
    return 1
  fi
}

count_debt() {
  local cmd out
  cmd=$(debt_command) || return 2
  out=$( cd "$PROJECT_DIR" && eval "$cmd" 2>/dev/null )
  # grep -c без совпадений возвращает 1 и печатает 0 — читаем вывод, а не код.
  printf '%s\n' "$out" | grep -cE '^[^[:space:]]+:[0-9]+' 2>/dev/null || true
}

read_num() { # <ключ> <значение по умолчанию>
  [[ -f "$STATE" ]] || { printf '%s' "$2"; return 0; }
  local v; v=$(jq -r --arg k "$1" 'if has($k) then .[$k] else empty end' "$STATE" 2>/dev/null)
  [[ -z "$v" || "$v" == "null" ]] && v="$2"
  printf '%s' "$v"
}

write_state() { # <потолок> <лучшее> <текущее> <заметка>
  local tmp; tmp=$(mktemp)
  local ts; ts=$(date -u +%Y-%m-%dT%H:%MZ)
  if [[ -f "$STATE" ]]; then
    jq --argjson c "$1" --argjson b "$2" --argjson v "$3" --arg n "$4" --arg ts "$ts" \
      '.ceiling=$c | .best=$b | .history += [{ts:$ts, value:$v, note:$n}] | .history |= .[-50:]' \
      "$STATE" > "$tmp"
  else
    mkdir -p "$(dirname "$STATE")"
    jq -n --argjson c "$1" --argjson b "$2" --argjson v "$3" --arg n "$4" --arg ts "$ts" \
      '{ceiling:$c, best:$b, history:[{ts:$ts, value:$v, note:$n}]}' > "$tmp"
  fi
  mv "$tmp" "$STATE"
}

case "${1:-check}" in
  count)
    n=$(count_debt) || { echo "нечем считать долг: не найден ни phpstan, ни eslint, ни ruff" >&2; exit 2; }
    echo "$n"
    exit 0 ;;

  show)
    if [[ -f "$STATE" ]]; then
      jq -r '"планка (не выше): \(.ceiling)\nлучшее достигнутое: \(.best)\nистория:",
             (.history[-10:][] | "  \(.ts)  \(.value)")' "$STATE"
    else
      echo "храповик долга ещё не запускался"
      echo "команда подсчёта: $(debt_command || echo 'не определена')"
    fi
    exit 0 ;;

  reset)
    NEW="${2:-}"
    [[ -z "$NEW" ]] && { echo "укажи число: debt.sh reset 120"; exit 2; }
    write_state "$NEW" "$NEW" "$NEW" "установлено вручную"
    echo "планка долга установлена: $NEW"
    exit 0 ;;

  check) ;;
  *) echo "использование: debt.sh check | count | show | reset <число>"; exit 2 ;;
esac

CURRENT=$(count_debt)
rc=$?
if [[ $rc -ne 0 ]]; then
  # Молча пропустить нельзя: «нечем измерить» выглядело бы как «долга нет».
  echo "долг не измерен: не найден инструмент подсчёта (phpstan, eslint или ruff)."
  echo "Укажи команду явно: .claude/gauntlet.json → \"debt\": { \"command\": \"…\" }"
  echo "Команда должна печатать по строке на нарушение в виде «путь:строка: …»."
  exit 0
fi

# Первый прогон фиксирует то, что есть: планка — это факт, а не пожелание.
if [[ ! -f "$STATE" ]]; then
  write_state "$CURRENT" "$CURRENT" "$CURRENT" "первый прогон, планка зафиксирована"
  printf '\033[32mДОЛГ: %s — планка зафиксирована\033[0m\n' "$CURRENT"
  echo "Дальше её можно только опускать: каждый тронутый файл, приведённый"
  echo "к правилам, снижает число, и новая планка становится обязательной."
  exit 0
fi

CEILING=$(read_num ceiling "$CURRENT")
BEST=$(read_num best "$CURRENT")

if (( CURRENT > CEILING )); then
  write_state "$CEILING" "$BEST" "$CURRENT" "рост долга"
  printf '\033[31mДОЛГ: %s — выше планки %s (стало на %s больше)\033[0m\n' \
    "$CURRENT" "$CEILING" "$(( CURRENT - CEILING ))"
  echo
  echo "Планка — это лучшее состояние, которого проект уже достигал. Рост"
  echo "означает, что новый код внесён не по правилам: старое несоответствие"
  echo "терпимо, новое — нет."
  echo
  echo "Что делать:"
  echo "  1. Посмотреть, какие нарушения добавились: $(debt_command)"
  echo "  2. Починить их в своём коде — это дешевле, чем в чужом."
  echo "  3. Если рост объективен (новый строгий конфиг, обновлённый линтер) —"
  echo "     это решение человека: debt.sh reset $CURRENT"
  exit 1
fi

if (( CURRENT < BEST )); then
  write_state "$CURRENT" "$CURRENT" "$CURRENT" "новый минимум, планка опущена"
  printf '\033[32mДОЛГ: %s — новый минимум, планка опущена с %s\033[0m\n' "$CURRENT" "$CEILING"
else
  write_state "$CEILING" "$BEST" "$CURRENT" "в пределах планки"
  printf '\033[32mДОЛГ: %s — планка %s удержана\033[0m\n' "$CURRENT" "$CEILING"
fi
exit 0
