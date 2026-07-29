#!/usr/bin/env bash
# std-update.sh — обновить стандарты: каталог, плагины, связи проекта.
#
# Обновление состоит из трёх шагов, и пропуск любого выглядит как «обновление
# не работает»: каталог маркетплейса, сами плагины, симлинки правил в проекте.
# Руками эту цепочку забывают на втором шаге — поэтому она собрана в команду.
#
#   std-update.sh              обновить всё
#   std-update.sh --dry-run    показать, что будет сделано
#   std-update.sh --check      только сравнить версии, ничего не менять
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
MARKETPLACE="${VIBE_RULES_MARKETPLACE:-vibe-rules}"

# Путь к CLI переопределяется для тестов: иначе проверка обновления зависела бы
# от того, что установлено на машине, где идут тесты.
CLI="${VIBE_RULES_CLI:-claude}"

DRY=0; CHECK=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --check)   CHECK=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) shift ;;
  esac
done

b()   { printf '\033[1m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }
ylw() { printf '\033[33m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*"; }

command -v "$CLI" >/dev/null 2>&1 || {
  red "не найден CLI '$CLI' — обновить плагины нечем"
  echo "  Обнови вручную: /plugin marketplace update $MARKETPLACE"
  exit 1
}
command -v jq >/dev/null 2>&1 || { red "нужен jq"; exit 1; }

installed_ids() { # id всех установленных плагинов нашего маркетплейса
  "$CLI" plugin list --json 2>/dev/null \
    | jq -r --arg m "@$MARKETPLACE" '.[]? | select(.id | endswith($m)) | .id' 2>/dev/null
}

version_of() { # <id> -> версия или пусто
  "$CLI" plugin list --json 2>/dev/null \
    | jq -r --arg i "$1" '.[]? | select(.id == $i) | .version // empty' 2>/dev/null
}

IDS=$(installed_ids)
if [[ -z "$IDS" ]]; then
  ylw "плагины маркетплейса '$MARKETPLACE' не установлены"
  echo "  Поставить и настроить проект: /std-core:setup --scope project"
  exit 0
fi

b "▸ 1/3  Каталог маркетплейса"
if [[ $DRY -eq 1 || $CHECK -eq 1 ]]; then
  ylw "  (без изменений) обновил бы каталог '$MARKETPLACE'"
else
  if "$CLI" plugin marketplace update "$MARKETPLACE" >/dev/null 2>&1; then
    grn "  каталог обновлён"
  else
    red "  не удалось обновить каталог '$MARKETPLACE'"
    echo "  Проверь, что он подключён: /plugin marketplace list"
    exit 1
  fi
fi

b "▸ 2/3  Плагины"
COUNT=0; CHANGED=0
while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  COUNT=$((COUNT + 1))
  before=$(version_of "$id")
  if [[ $DRY -eq 1 || $CHECK -eq 1 ]]; then
    printf '  %-32s %s\n' "$id" "${before:-?}"
    continue
  fi
  if "$CLI" plugin update "$id" >/dev/null 2>&1; then
    after=$(version_of "$id")
    if [[ "$before" != "$after" ]]; then
      CHANGED=$((CHANGED + 1))
      printf '  %-32s %s -> \033[32m%s\033[0m\n' "$id" "${before:-?}" "${after:-?}"
    else
      printf '  %-32s %s (без изменений)\n' "$id" "${before:-?}"
    fi
  else
    printf '  %-32s \033[31mошибка обновления\033[0m\n' "$id"
  fi
done <<< "$IDS"

[[ $DRY -eq 1 || $CHECK -eq 1 ]] && { ylw "  (без изменений) обновил бы перечисленное: $COUNT шт."; }

b "▸ 3/3  Связи проекта"
if [[ -d "$PROJECT_DIR/.claude/rules" ]]; then
  if [[ $DRY -eq 1 || $CHECK -eq 1 ]]; then
    ylw "  (без изменений) проверил бы симлинки правил"
  else
    # Симлинки содержат путь установки, а он меняется при обновлении:
    # без перелинковки правила молча перестают загружаться.
    bash "$HERE/std-link.sh" --check >/dev/null 2>&1 \
      && grn "  симлинки правил целы" \
      || { bash "$HERE/std-link.sh" --auto >/dev/null 2>&1 \
             && grn "  симлинки правил перепривязаны" \
             || ylw "  симлинки не удалось перепривязать — проверь /std-core:doctor"; }
  fi
else
  ylw "  проект не подключён к стандартам — /std-core:setup --scope project"
fi

echo
if [[ $DRY -eq 1 || $CHECK -eq 1 ]]; then
  ylw "Ничего не изменено. Выполнить: /std-core:update"
  exit 0
fi

if [[ $CHANGED -gt 0 ]]; then
  grn "════ ОБНОВЛЕНО: $CHANGED из $COUNT ════"
  echo
  echo "Дальше:"
  echo "  1. Перезапусти сессию — обновление плагинов применяется только после этого."
  echo "  2. /std-core:setup — доустановит модули, появившиеся в стеке."
else
  grn "════ УЖЕ АКТУАЛЬНО: $COUNT плагинов ════"
fi
exit 0
