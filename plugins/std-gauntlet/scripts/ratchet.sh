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
# Состояние: .claude/.ratchet.json (в git не идёт — у каждого свой прогон).
set -uo pipefail
export LC_NUMERIC=C

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
STATE="$PROJECT_DIR/.claude/.ratchet.json"
CFG="$PROJECT_DIR/.claude/gauntlet.json"

# Допуск: мутационный прогон недетерминирован из-за таймаутов и параллельности,
# и колебание в пару пунктов не должно валить сборку.
TOLERANCE=2

read_floor() {
  if [[ -f "$STATE" ]]; then
    jq -r '.floor // 0' "$STATE" 2>/dev/null
  elif [[ -f "$CFG" ]]; then
    jq -r '.mutation.floor // 0' "$CFG" 2>/dev/null
  else
    echo 0
  fi
}

case "${1:-}" in
  show)
    if [[ -f "$STATE" ]]; then
      jq -r '"планка: \(.floor)%\nлучшее:  \(.best)%\nистория:",
             (.history[-10:][] | "  \(.ts)  \(.value)%")' "$STATE"
    else
      echo "храповик ещё не запускался (планка из конфига: $(read_floor)%)"
    fi
    exit 0 ;;

  reset)
    NEW="${2:-}"
    [[ -z "$NEW" ]] && { echo "укажи значение: ratchet.sh reset 45"; exit 2; }
    mkdir -p "$(dirname "$STATE")"
    jq -n --argjson f "$NEW" --arg ts "$(date -u +%Y-%m-%dT%H:%MZ)" \
      '{floor:$f, best:$f, history:[{ts:$ts, value:$f, note:"установлено вручную"}]}' > "$STATE"
    echo "планка установлена: ${NEW}%"
    exit 0 ;;

  check) ;;
  *) echo "использование: ratchet.sh check <значение> | show | reset <значение>"; exit 2 ;;
esac

CURRENT="${2:-}"
[[ -z "$CURRENT" ]] && { echo "нужно текущее значение: ratchet.sh check 63"; exit 2; }

FLOOR=$(read_floor)
BEST=$( [[ -f "$STATE" ]] && jq -r '.best // 0' "$STATE" || echo "$FLOOR" )
TS=$(date -u +%Y-%m-%dT%H:%MZ)
mkdir -p "$(dirname "$STATE")"

append_history() { # <значение> <заметка>
  local tmp
  tmp=$(mktemp)
  if [[ -f "$STATE" ]]; then
    jq --argjson v "$1" --arg n "$2" --arg ts "$TS" --argjson f "$NEW_FLOOR" --argjson b "$NEW_BEST" \
      '.floor=$f | .best=$b | .history += [{ts:$ts, value:$v, note:$n}] | .history |= .[-50:]' "$STATE" > "$tmp"
  else
    jq -n --argjson v "$1" --arg n "$2" --arg ts "$TS" --argjson f "$NEW_FLOOR" --argjson b "$NEW_BEST" \
      '{floor:$f, best:$b, history:[{ts:$ts, value:$v, note:$n}]}' > "$tmp"
  fi
  mv "$tmp" "$STATE"
}

MIN_ALLOWED=$(( FLOOR - TOLERANCE ))
[[ $MIN_ALLOWED -lt 0 ]] && MIN_ALLOWED=0

if (( CURRENT < MIN_ALLOWED )); then
  NEW_FLOOR=$FLOOR; NEW_BEST=$BEST
  append_history "$CURRENT" "падение ниже планки"
  printf '\033[31mХРАПОВИК: %s%% ниже планки %s%%\033[0m\n' "$CURRENT" "$FLOOR"
  echo
  echo "Планка — это лучшее, чего проект уже достигал. Опускаться ниже нельзя:"
  echo "значит новый код проверен хуже, чем существующий."
  echo
  echo "Что делать: разобрать выживших мутантов и усилить ассерты (скилл"
  echo "mutation-harden). Понижать планку — только осознанным решением человека:"
  echo "  ratchet.sh reset <значение>"
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
