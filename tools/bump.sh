#!/usr/bin/env bash
# bump.sh — поднять версию всех модулей перед публикацией.
#
# Зачем: Claude Code доставляет обновление плагина только когда меняется его
# version. Забытый бамп выглядит у пользователя как «обновление не работает»:
# команда отрабатывает, а изменения не приезжают.
#
# Версия одна на весь набор: модули публикуются вместе, и разные версии
# у соседних модулей только запутывают, что у кого установлено.
#
#   tools/bump.sh          patch: 0.4.1 -> 0.4.2
#   tools/bump.sh minor    0.4.1 -> 0.5.0
#   tools/bump.sh 1.0.0    явная версия
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MP="$ROOT/.claude-plugin/marketplace.json"

CURRENT=$(jq -r '.metadata.version // "0.0.0"' "$MP")
IFS='.' read -r MA MI PA <<<"$CURRENT"

case "${1:-patch}" in
  patch) NEW="$MA.$MI.$((PA+1))" ;;
  minor) NEW="$MA.$((MI+1)).0" ;;
  major) NEW="$((MA+1)).0.0" ;;
  *)     NEW="$1" ;;
esac

[[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "неверная версия: $NEW" >&2; exit 2; }

for f in "$ROOT"/plugins/*/.claude-plugin/plugin.json; do
  tmp=$(mktemp)
  jq --arg v "$NEW" '.version = $v' "$f" > "$tmp" && mv "$tmp" "$f"
done

tmp=$(mktemp)
jq --arg v "$NEW" '.metadata.version = $v | .plugins |= map(.version = $v)' "$MP" > "$tmp" && mv "$tmp" "$MP"

echo "$CURRENT -> $NEW  (модулей: $(ls -d "$ROOT"/plugins/*/ | wc -l))"
echo "Пользователи получат обновление командой /plugin update после пуша."
