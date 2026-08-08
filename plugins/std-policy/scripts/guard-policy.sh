#!/usr/bin/env bash
# guard-policy.sh — PreToolUse: проверка изменений против политики стека.
#
# Превращает регламент организации из документа в проверку. Документ говорит
# «используем такие-то технологии таких-то версий»; без механизма это
# соблюдается настолько, насколько помнят.
#
# Политика: .claude/policy.json (образец — configs/policy.example.json).
# Нет файла — замок молчит: проекты без политики не должны страдать.
#
# Проверяется:
#   нестабильные версии зависимостей (alpha, beta, rc, dev)
#   пакеты из списка запрещённых
#   минимальные версии рантайма
#   крупные бинарники в git вместо объектного хранилища
#   отладчик в образе для продуктивной среды
set -uo pipefail

INPUT=$(cat)

# std:hooks-off — человек отключил замки в этом проекте (.claude/std-hooks-off).
# Этот хук молчит целиком; правила остаются и грузятся как раньше. Запреты
# на необратимое маркер не снимает — они живут в guard-bash.sh и работают
# всегда. Что замки выключены, напоминает session-check.sh: единственный хук,
# которого маркер не глушит.
[[ -f "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/std-hooks-off" ]] && exit 0
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
POLICY="$PROJECT_DIR/.claude/policy.json"

[[ -f "$POLICY" ]] || exit 0

# --- std:jq-guard — политика без разбора не соблюдается ------------------------
# Проверки политики построены на разборе JSON целиком: запрещённые пакеты,
# минимальные версии, лимиты. Свести их к чтению без jq нельзя, а тихо выйти —
# значит объявить регламент соблюдённым, не проверив ни одного пункта. Поэтому
# при наличии политики и отсутствии jq решение принимает человек.
if ! command -v jq >/dev/null 2>&1; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' \
    "В проекте есть .claude/policy.json, но jq на машине нет — проверить изменение против политики нечем. Подтверди правку сам или поставь jq."
  exit 0
fi

# Проект вне политики — подрядчик «под ключ» либо согласованное отклонение.
# Замки безопасности при этом продолжают работать: их отключает не политика.
if [[ "$(jq -r 'if .exempt then (.exempt.enabled // false) else false end' "$POLICY" 2>/dev/null)" == "true" ]]; then
  exit 0
fi

FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
NEW=$(printf '%s' "$INPUT" | jq -r '.tool_input.new_string // .tool_input.content // empty' 2>/dev/null)
[[ -z "$FILE" ]] && exit 0

base=$(basename "$FILE")

deny() {
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}
ask() {
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
  exit 0
}

# ── 1. Зависимости ────────────────────────────────────────────────────────────
case "$base" in
  composer.json|package.json|pyproject.toml|requirements.txt)
    [[ -z "$NEW" ]] && exit 0

    # Нестабильные версии: воспроизводимость сборки важнее свежести
    if [[ "$(jq -r 'if .stability then (.stability.denyPrerelease // false) else false end' "$POLICY")" == "true" ]]; then
      if printf '%s' "$NEW" | grep -qiE '["'"'"'~^>= ]*[0-9][^"'"'"']*-(alpha|beta|rc|dev|preview|snapshot)'; then
        deny "Политика запрещает нестабильные версии зависимостей (alpha, beta, rc, dev). Сборка с ними невоспроизводима: вчера собиралось, сегодня нет, и никто не менял код. Возьми стабильный релиз."
      fi
      if printf '%s' "$NEW" | grep -qiE '"(dev-master|dev-main|dev-develop)"'; then
        deny "Политика запрещает зависимости от ветки разработки: содержимое меняется без изменения версии."
      fi
    fi

    # Явно запрещённые пакеты — с причиной из политики
    while IFS=$'\t' read -r pkg reason; do
      [[ -z "$pkg" ]] && continue
      if printf '%s' "$NEW" | grep -qF "$pkg"; then
        deny "Пакет '$pkg' не используется в этой организации: $reason"
      fi
    done < <(jq -r 'if .deniedPackages then (.deniedPackages | to_entries[] | "\(.key)\t\(.value)") else empty end' "$POLICY" 2>/dev/null)

    # Минимальные версии рантайма
    while IFS=$'\t' read -r rt minv; do
      [[ -z "$rt" || "$rt" == "_comment" ]] && continue
      case "$rt" in
        php)  req=$(printf '%s' "$NEW" | grep -oE '"php"\s*:\s*"[^"]+"' | grep -oE '[0-9]+\.[0-9]+' | head -1) ;;
        node) req=$(printf '%s' "$NEW" | grep -oE '"node"\s*:\s*"[^"]+"' | grep -oE '[0-9]+' | head -1) ;;
        *)    req="" ;;
      esac
      [[ -z "$req" ]] && continue
      # Сравниваем как версии, а не как строки: 8.10 больше 8.9
      if [[ "$(printf '%s\n%s\n' "$minv" "$req" | sort -V | head -1)" != "$minv" ]]; then
        deny "Политика требует $rt не ниже $minv, в изменении указано $req."
      fi
    done < <(jq -r 'if .runtime then (.runtime | to_entries[] | "\(.key)\t\(.value)") else empty end' "$POLICY" 2>/dev/null)
    exit 0 ;;
esac

# ── 2. Отладчик в продуктивном образе ─────────────────────────────────────────
if [[ "$base" == "Dockerfile" || "$base" == "Containerfile" ]] \
   || printf '%s' "$base" | grep -qE '^(Dockerfile|Containerfile)\.'; then
  if [[ "$(jq -r 'if .debugger then (.debugger.deniedInProd // false) else false end' "$POLICY")" == "true" ]] \
     && printf '%s' "$NEW" | grep -qiE '(xdebug|pydevd|debugpy|--inspect)'; then
    ask "В образ добавляется отладчик. Политика требует, чтобы он был настроен для разработки, но отсутствовал в продуктивном образе — проверь, что это стадия сборки для разработки, а не финальная."
  fi
fi

# ── 3. Крупные бинарники в git ────────────────────────────────────────────────
MAXKB=$(jq -r 'if .staticAssets then (.staticAssets.maxBinaryKb // empty) else empty end' "$POLICY" 2>/dev/null)
if [[ -n "$MAXKB" && "$MAXKB" != "null" ]]; then
  while IFS= read -r pat; do
    [[ -z "$pat" ]] && continue
    # Приводим glob политики к сравнению по префиксу пути
    prefix="${pat%%\**}"
    rel="${FILE#$PROJECT_DIR/}"
    if [[ -n "$prefix" && "$rel" == "$prefix"* ]]; then
      ask "Путь '$rel' предназначен для статических ресурсов. Политика требует хранить их в объектном хранилище, а не в git: репозиторий с бинарниками невозможно быстро клонировать, а историю уже не почистить."
    fi
  done < <(jq -r 'if .staticAssets then (.staticAssets.denyPaths // [])[] else empty end' "$POLICY" 2>/dev/null)

  if printf '%s' "$base" | grep -qiE '\.(png|jpe?g|gif|webp|mp4|mov|zip|tar|gz|pdf|psd|ai|woff2?|ttf)$'; then
    SIZE_KB=0
    [[ -n "$NEW" ]] && SIZE_KB=$(( ${#NEW} / 1024 ))
    if (( SIZE_KB > MAXKB )); then
      ask "Бинарный файл ~${SIZE_KB} КБ превышает лимит политики ${MAXKB} КБ. Статические ресурсы хранятся в объектном хранилище."
    fi
  fi
fi

exit 0
