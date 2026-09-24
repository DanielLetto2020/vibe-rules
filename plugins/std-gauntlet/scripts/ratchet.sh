#!/usr/bin/env bash
# ratchet.sh — храповик качества: улучшать не обязательно, ухудшать нельзя.
#
# Проблема абсолютного порога: на существующем проекте фактический mutation
# score обычно 20–40%. Порог 70% недостижим сегодня, поэтому его отключают
# в первый же день — и проверки нет вообще. Порог 20% бесполезен: он не мешает
# добавлять непроверенный код.
#
# Храповик решает это иначе. Планка равна лучшему достигнутому результату
# (минус небольшой допуск на шум). Каждая задача, поднявшая качество, поднимает
# планку. Откатиться назад нельзя.
#
#   ratchet.sh check <текущее значение>   сравнить с планкой, обновить при росте
#   ratchet.sh show                       показать историю
#   ratchet.sh reset <значение>           установить планку вручную
#
# Коды возврата: 0 — планка удержана или поднята; 1 — падение ниже планки;
# 2 — проверить нельзя: неверный аргумент, повреждённое состояние, нет jq.
#
# Состояние: .claude/.ratchet.json (в git не идёт — у каждого свой прогон).
set -uo pipefail
export LC_NUMERIC=C

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
STATE="$PROJECT_DIR/.claude/.ratchet.json"
CFG="$PROJECT_DIR/.claude/gauntlet.json"

# Допуск: мутационный прогон недетерминирован из-за таймаутов и параллельности,
# и колебание в пару пунктов не должно валить сборку.
TOLERANCE=2

# --- std:jq-guard — гейт без разбора состояния не проходят, а чинят -----------
# Без jq чтение планки давало пустую строку, а пустая строка в сравнении
# читалась как «планка нулевая»: мутационный гейт молча пропускал любой
# результат. Гейт, который нельзя выполнить, обязан падать, а не соглашаться.
if ! command -v jq >/dev/null 2>&1; then
  echo "храповик не может прочитать состояние: на машине нет jq." >&2
  echo "Поставь jq (apt install jq / brew install jq) — без него планка качества не проверяется." >&2
  exit 2
fi

# Состояние читается целиком или не читается вовсе. Раньше битый файл давал
# пустую строку, та читалась как планка 0 — и любой результат проходил,
# а запись поверх битого файла снова давала пустой файл, навсегда.
state_ok() {
  jq -e 'type == "object"
         and (.floor | type) == "number" and (.best | type) == "number"
         and .floor >= 0 and .best >= 0' "$STATE" >/dev/null 2>&1
}

state_broken() {
  echo "состояние храповика повреждено: ${STATE#"$PROJECT_DIR"/}"
  echo "Без него планку не с чем сравнить, а считать её нулевой значило бы"
  echo "пропускать любой результат. Восстановить планку — решение человека:"
  echo "остановись и скажи ему. Сам файл состояния не правь и не удаляй."
  exit 2
}

# Планка — целое число. Дробная стартовая планка в конфиге (45.5) раньше
# роняла арифметику bash, и гейт падал на любом результате.
read_floor() {
  if [[ -f "$STATE" ]]; then
    jq -r '.floor | floor' "$STATE"
  elif [[ -f "$CFG" ]]; then
    jq -r '(.mutation.floor // 0) | if type == "number" then floor else error("не число") end' "$CFG" 2>/dev/null
  else
    echo 0
  fi
}

# Результат прогона: целое, с точкой или запятой — дробная часть отбрасывается.
to_int() { # <значение> → целое или код 1
  [[ "$1" =~ ^[0-9]+([.,][0-9]+)?$ ]] || return 1
  local v="${1%%[.,]*}"
  printf '%s' "$((10#$v))"
}

write_state() { # <jq-выражение> <аргументы jq…> — атомарная запись
  local tmp rc
  mkdir -p "$(dirname "$STATE")"
  # Временный файл рядом с состоянием: mv в пределах каталога атомарен,
  # и прерванная запись не оставляет полупустой файл.
  tmp=$(mktemp "$STATE.XXXXXX") || return 1
  if [[ -f "$STATE" ]] && state_ok; then
    jq "$@" "$STATE" > "$tmp"; rc=$?
  else
    jq -n "$@" > "$tmp"; rc=$?
  fi
  if [[ $rc -ne 0 || ! -s "$tmp" ]]; then
    rm -f "$tmp"
    echo "не удалось записать состояние храповика: $STATE" >&2
    return 1
  fi
  mv "$tmp" "$STATE"
}

TS=$(date -u +%Y-%m-%dT%H:%MZ)

case "${1:-}" in
  show)
    if [[ -f "$STATE" ]]; then
      state_ok || state_broken
      jq -r '"планка: \(.floor)%\nлучшее:  \(.best)%\nистория:",
             ((.history // [])[-10:][] | "  \(.ts)  \(.value)%  \(.note // "")")' "$STATE"
    else
      f=$(read_floor) || { echo "стартовая планка в конфиге — не число: .mutation.floor"; exit 2; }
      echo "храповик ещё не запускался (планка из конфига: ${f}%)"
    fi
    exit 0 ;;

  reset)
    NEW="${2:-}"
    [[ -z "$NEW" ]] && { echo "укажи значение: ratchet.sh reset 45"; exit 2; }
    # Проверка до записи: раньше «reset 70%» ронял jq, файл состояния
    # оставался пустым, а команда печатала «планка установлена».
    if [[ ! "$NEW" =~ ^[0-9]+$ ]] || (( 10#$NEW > 100 )); then
      echo "укажи целое число от 0 до 100: ratchet.sh reset 45 (получено: «${NEW}»)"
      exit 2
    fi
    NEW=$((10#$NEW))
    # История не стирается: сброс — одна из записей в ней. Иначе после него
    # не восстановить, как качество менялось до решения человека.
    write_state --argjson f "$NEW" --arg ts "$TS" \
      'if . == null then {} else . end
       | .floor=$f | .best=$f
       | .history = ((.history // []) + [{ts:$ts, value:$f, note:"установлено вручную"}])
       | .history |= .[-50:]' || exit 2
    echo "планка установлена: ${NEW}%"
    exit 0 ;;

  check) ;;
  *) echo "использование: ratchet.sh check <значение> | show | reset <значение>"; exit 2 ;;
esac

[[ -n "${2:-}" ]] || { echo "нужно текущее значение: ratchet.sh check 63"; exit 2; }
CURRENT=$(to_int "$2") || { echo "результат мутационного прогона — не число: «$2»"; exit 2; }

[[ -f "$STATE" ]] && { state_ok || state_broken; }
FLOOR=$(read_floor) || { echo "стартовая планка в конфиге — не число: .mutation.floor"; exit 2; }
[[ "$FLOOR" =~ ^[0-9]+$ ]] || { echo "стартовая планка в конфиге — не число: «$FLOOR»"; exit 2; }
if [[ -f "$STATE" ]]; then
  BEST=$(jq -r '.best | floor' "$STATE")
else
  BEST=$FLOOR
fi

append_history() { # <значение> <заметка>
  write_state --argjson v "$1" --arg n "$2" --arg ts "$TS" \
    --argjson f "$NEW_FLOOR" --argjson b "$NEW_BEST" \
    'if . == null then {} else . end
     | .floor=$f | .best=$b
     | .history = ((.history // []) + [{ts:$ts, value:$v, note:$n}])
     | .history |= .[-50:]' || exit 2
}

MIN_ALLOWED=$(( FLOOR - TOLERANCE ))
(( MIN_ALLOWED < 0 )) && MIN_ALLOWED=0

if (( CURRENT < MIN_ALLOWED )); then
  NEW_FLOOR=$FLOOR; NEW_BEST=$BEST
  append_history "$CURRENT" "падение ниже планки"
  printf '\033[31mХРАПОВИК: %s%% ниже планки %s%%\033[0m\n' "$CURRENT" "$FLOOR"
  echo
  echo "Планка — это лучшее, чего проект уже достигал. Опускаться ниже нельзя:"
  echo "значит новый код проверен хуже, чем существующий."
  echo
  echo "Что делать: разобрать выживших мутантов и усилить ассерты (скилл"
  echo "mutation-harden). Если планку и правда нужно понизить (удалён хорошо"
  echo "покрытый модуль), это решение человека: остановись и спроси человека."
  echo "Сам планку не сбрасывай и файл состояния не трогай."
  exit 1
fi

if (( CURRENT > BEST )); then
  NEW_FLOOR=$CURRENT; NEW_BEST=$CURRENT
  append_history "$CURRENT" "новый максимум, планка поднята"
  printf '\033[32mХРАПОВИК: %s%% — новый максимум, планка поднята с %s%%\033[0m\n' "$CURRENT" "$FLOOR"
else
  NEW_FLOOR=$FLOOR; NEW_BEST=$BEST
  append_history "$CURRENT" "в пределах планки"
  printf '\033[32mХРАПОВИК: %s%% — планка %s%% удержана\033[0m\n' "$CURRENT" "$FLOOR"
fi
exit 0
