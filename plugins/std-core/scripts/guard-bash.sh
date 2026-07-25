#!/usr/bin/env bash
# guard-bash.sh — PreToolUse-замок на Bash.
#
# Принцип: то, что можно проверить машиной, не должно жить в тексте правил.
# Текст — просьба (модель может забыть), хук — гарантия (выполняется всегда).
#
# Вход:  JSON на stdin (tool_name, tool_input.command)
# Выход: exit 0 + JSON с permissionDecision: deny | ask | (пусто = обычный поток)
set -uo pipefail

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[[ -z "$CMD" ]] && exit 0

deny() {
  jq -n --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

ask() {
  jq -n --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "ask",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

# --- 1. Контейнеры: удаление образов/томов/кэша ------------------------------
# Потеря build-кэша и томов необратима и стоит часов пересборки.
if printf '%s' "$CMD" | grep -Eq '(^|[;&|[:space:]])(podman|docker|buildah)[[:space:]]+((container|image|volume|network|system)[[:space:]]+)?(rm|rmi|prune)'; then
  deny "Удаление контейнеров/образов/томов/кэша запрещено политикой. Сначала покажи занятое место и спроси разрешение на конкретную команду."
fi
if printf '%s' "$CMD" | grep -Eq '(podman|docker)([[:space:]]+compose|-compose)[[:space:]]+down[[:space:]].*(-v|--volumes)'; then
  deny "'compose down -v' удаляет тома вместе с данными. Используй 'down' без -v."
fi

# --- 2. Git: необратимое и обход проверок ------------------------------------
if printf '%s' "$CMD" | grep -Eq 'git[[:space:]]+push[[:space:]].*(--force([[:space:]]|$)|-f([[:space:]]|$))' \
   && ! printf '%s' "$CMD" | grep -q 'force-with-lease'; then
  deny "force-push перезаписывает чужую историю. Используй --force-with-lease."
fi
if printf '%s' "$CMD" | grep -Eq '(git[[:space:]]+(commit|push).*--no-verify|-n[[:space:]]+-m)'; then
  deny "--no-verify отключает pre-commit проверки — ровно тот слой, ради которого код не читают глазами."
fi
if printf '%s' "$CMD" | grep -Eq 'git[[:space:]]+reset[[:space:]]+--hard'; then
  ask "git reset --hard уничтожит незакоммиченные изменения. Подтверди."
fi

# --- 3. База данных: разрушающие операции ------------------------------------
if printf '%s' "$CMD" | grep -Eqi 'migrate:fresh|migrate:reset|db:wipe|drop[[:space:]]+database|truncate[[:space:]]+table'; then
  deny "Разрушающая операция с БД. Если она действительно нужна — выполни вручную, осознанно."
fi

# --- 4. Файловая система ------------------------------------------------------
if printf '%s' "$CMD" | grep -Eq 'rm[[:space:]]+(-[a-zA-Z]*[rf][a-zA-Z]*[[:space:]]+)+(/|~|\$HOME)([[:space:]]|$)'; then
  deny "Рекурсивное удаление от корня или из домашней директории."
fi

# --- 5. Новые зависимости: не запрет, а обязательная пара глаз ---------------
# Пакет проходит любые тесты идеально. Это единственный вектор, который
# система автопроверок не закрывает в принципе.
if printf '%s' "$CMD" | grep -Eq '(composer[[:space:]]+require|npm[[:space:]]+i(nstall)?[[:space:]]+[a-z@]|yarn[[:space:]]+add|pnpm[[:space:]]+add|pip[[:space:]]+install[[:space:]]+[a-z])'; then
  ask "Добавляется новая зависимость. Подтверди пакет и его источник — тесты этот риск не покрывают."
fi

exit 0
