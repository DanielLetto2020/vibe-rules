#!/usr/bin/env bash
# std-setup.sh — вся настройка проекта одной командой.
#
# Заменяет последовательность link → profile → gauntlet:init → doctor.
# Каждая дополнительная команда на старте — это место, где внедрение
# останавливается: человек сделал первый шаг, отвлёкся и не вернулся.
#
#   std-setup.sh                определить всё и настроить
#   std-setup.sh --sync         перечитать проект и доустановить недостающее
#   std-setup.sh --profile team явно задать профиль
#   std-setup.sh --dry-run      показать, что будет сделано, ничего не меняя
#   std-setup.sh --no-install   не ставить плагины, только правила и конфиг
#   std-setup.sh --scope project  привязать плагины к проекту, а не к машине
set -uo pipefail
export LC_NUMERIC=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
PROFILES="$HERE/../profiles/profiles.json"
CFG_DIR="$PROJECT_DIR/.claude"
CFG="$CFG_DIR/gauntlet.json"

FORCE_PROFILE=""; DRY=0; NO_INSTALL=0; SYNC=0
# user    — плагины на машине, во всех проектах
# project — в .claude/settings.json проекта: получат все, кто его склонирует
# local   — только в этом проекте и только у тебя
SCOPE="user"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)    FORCE_PROFILE="${2:-}"; shift 2 ;;
    --dry-run)    DRY=1; shift ;;
    --no-install) NO_INSTALL=1; shift ;;
    --sync)       SYNC=1; shift ;;
    --scope)      SCOPE="${2:-user}"; shift 2 ;;
    *) shift ;;
  esac
done

MARKETPLACE_NAME="${VIBE_RULES_MARKETPLACE:-vibe-rules}"
# Путь переопределяем: иначе тест зависел бы от того, что установлено
# на конкретной машине, и был бы то зелёным, то красным.
INSTALLED_DB="${VIBE_RULES_INSTALLED_DB:-$HOME/.claude/plugins/installed_plugins.json}"
STANDARDS_HOME=$(bash "$HERE/std-link.sh" --home 2>/dev/null || true)

b()   { printf '\033[1m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }
ylw() { printf '\033[33m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*"; }

# ── 1. Профиль ────────────────────────────────────────────────────────────────
b "▸ 1/5  Состояние проекта"
FACTS=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$HERE/std-profile.sh" --json 2>/dev/null)
if [[ -z "$FACTS" ]]; then
  red "  не удалось собрать факты о проекте"; exit 1
fi

# При --sync профиль берётся из конфигурации проекта: его мог задать человек,
# и повторный запуск не должен молча вернуть автоопределённый.
EXISTING_PROFILE=""
[[ -f "$CFG" ]] && EXISTING_PROFILE=$(jq -r '.profile // empty' "$CFG" 2>/dev/null)
if [[ $SYNC -eq 1 && -n "$EXISTING_PROFILE" && -z "$FORCE_PROFILE" ]]; then
  PROFILE="$EXISTING_PROFILE"
else
  PROFILE="${FORCE_PROFILE:-$(jq -r '.profile' <<<"$FACTS")}"
fi
WHY=$(jq -r '.why' <<<"$FACTS")
jq -r '.facts | "  коммитов: \(.commits)   авторов: \(.activeAuthors)   тесты: \(.testFiles)/\(.sourceFiles) (\(.testRatio))   CI: \(if .hasCi then "есть" else "нет" end)"' <<<"$FACTS"

if [[ -n "$FORCE_PROFILE" ]]; then
  printf '  профиль: \033[1m%s\033[0m (задан вручную)\n' "$PROFILE"
elif [[ $SYNC -eq 1 && -n "$EXISTING_PROFILE" ]]; then
  printf '  профиль: \033[1m%s\033[0m (из конфигурации проекта)\n' "$PROFILE"
else
  printf '  профиль: \033[1m%s\033[0m — %s\n' "$PROFILE" "$WHY"
fi

if ! jq -e --arg p "$PROFILE" '.profiles[$p]' "$PROFILES" >/dev/null 2>&1; then
  red "  неизвестный профиль '$PROFILE'"
  echo "  доступны: $(jq -r '.profiles | keys | join(", ")' "$PROFILES")"
  exit 1
fi
P=$(jq -c --arg p "$PROFILE" '.profiles[$p]' "$PROFILES")

# ── 2. Плагины ────────────────────────────────────────────────────────────────
# Модуль, состоящий только из правил, ставить не нужно: правила приезжают
# симлинками. Установка требуется там, где есть хуки, скиллы, команды или
# агенты — их Claude Code берёт только у установленного плагина.
echo; b "▸ 2/5  Плагины"
case "$SCOPE" in
  project) echo "  область: проект — попадёт в .claude/settings.json и достанется всей команде" ;;
  local)   echo "  область: только этот проект и только ты" ;;
  *)       echo "  область: машина — во всех твоих проектах" ;;
esac

module_needs_plugin() { # <slug>
  local d="$STANDARDS_HOME/plugins/std-$1"
  [[ -f "$d/hooks/hooks.json" ]] && return 0
  local sub
  for sub in skills commands agents workflows; do
    [[ -d "$d/$sub" ]] && [[ -n "$(ls -A "$d/$sub" 2>/dev/null)" ]] && return 0
  done
  return 1
}

plugin_installed() { # <slug>
  [[ -f "$INSTALLED_DB" ]] || return 1
  jq -e --arg k "std-$1@$MARKETPLACE_NAME" '.plugins | has($k)' "$INSTALLED_DB" >/dev/null 2>&1
}

DETECTED=()
if [[ -n "$STANDARDS_HOME" ]]; then
  mapfile -t DETECTED < <(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$HERE/std-link.sh" --detect 2>/dev/null \
                          | sed 's/^ *//;s/^std-//')
fi

TO_INSTALL=(); ALREADY=(); RULES_ONLY=()
for m in "${DETECTED[@]}"; do
  [[ -z "$m" ]] && continue
  if module_needs_plugin "$m"; then
    if plugin_installed "$m"; then ALREADY+=("$m"); else TO_INSTALL+=("$m"); fi
  else
    RULES_ONLY+=("$m")
  fi
done

if [[ ${#ALREADY[@]} -gt 0 ]]; then
  printf '  уже установлены: %s\n' "${ALREADY[*]}"
fi
if [[ ${#RULES_ONLY[@]} -gt 0 ]]; then
  printf '  только правила (установка не нужна): %s\n' "${RULES_ONLY[*]}"
fi

INSTALL_FAILED=0
if [[ ${#TO_INSTALL[@]} -eq 0 ]]; then
  [[ ${#ALREADY[@]} -gt 0 ]] && grn "  доустанавливать нечего"
elif [[ $DRY -eq 1 ]]; then
  ylw "  (dry-run) установил бы: ${TO_INSTALL[*]}"
elif [[ $NO_INSTALL -eq 1 ]]; then
  ylw "  требуют установки, но --no-install: ${TO_INSTALL[*]}"
else
  for m in "${TO_INSTALL[@]}"; do
    printf '  ставлю std-%s… ' "$m"
    if claude plugin install "std-$m@$MARKETPLACE_NAME" --scope "$SCOPE" >/dev/null 2>&1; then
      grn "готово"
    else
      red "не удалось"; INSTALL_FAILED=1
    fi
  done
fi

# При scope=project записываем настройки в сам проект. Тогда коллега,
# склонировавший репозиторий, получит предложение поставить всё нужное при первом
# открытии — вручную ставить ничего не нужно.
write_project_settings() {
  local settings="$CFG_DIR/settings.json"
  local source_json
  source_json=$(jq -r --arg n "$MARKETPLACE_NAME" \
    'if .[$n].source.source == "github" then {source:"github", repo:.[$n].source.repo}
     else {source:"github", repo:"DanielLetto2020/vibe-rules"} end' \
    "$HOME/.claude/plugins/known_marketplaces.json" 2>/dev/null) || source_json='{"source":"github","repo":"DanielLetto2020/vibe-rules"}'

  local enabled='{}'
  local m
  for m in "${ALREADY[@]}" "${TO_INSTALL[@]}"; do
    [[ -z "$m" ]] && continue
    enabled=$(jq --arg k "std-$m@$MARKETPLACE_NAME" '. + {($k): true}' <<<"$enabled")
  done

  mkdir -p "$CFG_DIR"
  local new
  new=$(jq -n --arg n "$MARKETPLACE_NAME" --argjson src "$source_json" --argjson en "$enabled" \
    '{extraKnownMarketplaces: {($n): {source: $src}}, enabledPlugins: $en}')
  if [[ -f "$settings" ]]; then
    new=$(jq -s '.[0] * .[1]' <<<"$new"$'\n'"$(cat "$settings")")
  fi
  printf '%s\n' "$(jq . <<<"$new")" > "$settings"
  grn "  записан .claude/settings.json — коллеге ставить руками ничего не нужно"
}

# ── 3. Правила стека ──────────────────────────────────────────────────────────
echo; b "▸ 3/5  Правила стека"
if [[ $DRY -eq 1 ]]; then
  ylw "  (dry-run) была бы выполнена линковка модулей по стеку"
else
  CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$HERE/std-link.sh" --auto 2>&1 \
    | grep -E '^\s+\+|^\s+!' | sed 's/^ */  /' || true
fi

# ── 3. Гейты ──────────────────────────────────────────────────────────────────
echo; b "▸ 4/5  Гейты качества"

have() { [[ -e "$PROJECT_DIR/$1" ]]; }

# Каталог со спецификациями. Имя не универсально: behat и pytest-bdd кладут
# в features/, Cucumber в JS — часто в tests/features. Найденный путь пишется
# в конфиг, чтобы гейт не искал заново.
FEATURES_DIR=""
has_features() {
  [[ -n "$FEATURES_DIR" ]] && return 0
  local d
  for d in features tests/features spec/features src/test/resources/features; do
    if [[ -d "$PROJECT_DIR/$d" ]] && \
       [[ -n "$(find "$PROJECT_DIR/$d" -name '*.feature' -print -quit 2>/dev/null)" ]]; then
      FEATURES_DIR="$d"; return 0
    fi
  done
  return 1
}

gate_cmd() { # <имя гейта> -> команда или пусто
  case "$1" in
    style)
      have artisan && { echo './vendor/bin/pint --test'; return; }
      have composer.json && { echo './vendor/bin/php-cs-fixer fix --dry-run --diff'; return; }
      have package.json && { echo 'npm run lint --if-present'; return; }
      have pyproject.toml && { echo 'ruff check .'; return; } ;;
    types)
      # Psalm и PHPStan сосуществуют: если настроены оба, гоняем оба
      if have psalm.xml || have psalm.xml.dist; then
        have phpstan.neon && { echo './vendor/bin/psalm --no-progress && ./vendor/bin/phpstan analyse --no-progress'; return; }
        echo './vendor/bin/psalm --no-progress'; return
      fi
      have composer.json && { echo './vendor/bin/phpstan analyse --no-progress'; return; }
      have tsconfig.json && { echo 'npx --no-install tsc --noEmit'; return; }
      have pyproject.toml && { echo 'mypy .'; return; } ;;
    test)
      # Codeception проверяется до PHPUnit: он его надстройка, и запускать
      # надо именно его, иначе приёмочные наборы не выполнятся
      have codeception.yml && { echo './vendor/bin/codecept run'; return; }
      have codeception.dist.yml && { echo './vendor/bin/codecept run'; return; }
      have artisan && { echo 'php artisan test'; return; }
      have composer.json && { echo './vendor/bin/phpunit'; return; }
      have package.json && { echo 'npm test --if-present'; return; }
      have pyproject.toml && { echo 'pytest -q'; return; } ;;
    security)
      have composer.lock && { echo 'composer audit'; return; }
      have package-lock.json && { echo 'npm audit --audit-level=high'; return; } ;;
    spec-mutation)
      # Мутация данных спецификации: имеет смысл только там, где сценарии есть
      # и тесты из них порождаются. Команда прогона берётся из гейта test.
      if has_features; then
        local tcmd; tcmd=$(gate_cmd test)
        # STD_GAUNTLET_ROOT остаётся переменной: путь модуля содержит версию
        # и меняется при обновлении, его подставляет gauntlet.sh. А каталог
        # спецификаций подставляется значением — он свойство проекта.
        [[ -n "$tcmd" ]] && { echo "python3 \"\$STD_GAUNTLET_ROOT/scripts/gherkin-mutate.py\" --features $FEATURES_DIR --run '$tcmd'"; return; }
      fi ;;
    mutation)
      have artisan && { echo './vendor/bin/infection --threads=max --min-msi=$MSI --no-progress'; return; }
      have composer.json && { echo './vendor/bin/infection --threads=max --min-msi=$MSI --no-progress'; return; }
      have package.json && { echo 'npx --no-install stryker run'; return; }
      have pyproject.toml && { echo 'mutmut run'; return; } ;;
  esac
}

GATES_JSON='{}'; MISSING=()
PROFILE_GATES=$(jq -r '.gates[]' <<<"$P")
# Спецификации в проекте есть — добавляем гейт мутации данных, даже если
# профиль его не перечисляет: без него Gherkin остаётся украшением, а связь
# тестов с требованием никем не проверяется.
if has_features && [[ "$PROFILE_GATES" != *spec-mutation* ]]; then
  PROFILE_GATES="$PROFILE_GATES"$'\n'"spec-mutation"
fi
for g in $PROFILE_GATES; do
  c=$(gate_cmd "$g")
  if [[ -n "$c" ]]; then
    GATES_JSON=$(jq --arg k "$g" --arg v "$c" '. + {($k): $v}' <<<"$GATES_JSON")
    printf '  \033[32m✓\033[0m %-9s %s\n' "$g" "$c"
  else
    MISSING+=("$g")
    printf '  \033[33m–\033[0m %-9s инструмент не найден\n' "$g"
  fi
done

MUT_ON=$(jq -r '.mutation.enabled' <<<"$P")
MUT_JSON='{"enabled": false}'
if [[ "$MUT_ON" == "true" ]]; then
  c=$(gate_cmd mutation)
  MODE=$(jq -r '.mutation.mode' <<<"$P")
  if [[ -n "$c" ]] && jq -e '.facts.hasMutation' <<<"$FACTS" >/dev/null; then
    GATES_JSON=$(jq --arg v "$c" '. + {mutation: $v}' <<<"$GATES_JSON")
    printf '  \033[32m✓\033[0m %-9s %s\n' "mutation" "$c"
  else
    printf '  \033[33m–\033[0m %-9s не установлено — главный пробел, см. итог\n' "mutation"
  fi
  MUT_JSON=$(jq -c '{enabled: true, mode: .mutation.mode,
                     floor: (.mutation.floor // 0),
                     threshold: (.mutation.threshold // null),
                     changedOnly: (.mutation.changedOnly // false)}' <<<"$P")
fi

# ── 4. Конфигурация ───────────────────────────────────────────────────────────
echo; b "▸ 5/5  Конфигурация"
NEW_CFG=$(jq -n \
  --arg profile "$PROFILE" \
  --argjson gates "$GATES_JSON" \
  --argjson mutation "$MUT_JSON" \
  --argjson rbc "$(jq '.requireBeforeCommit' <<<"$P")" \
  --arg guardTests "$(jq -r '.guardTests' <<<"$P")" \
  --argjson specFirst "$(jq '.specFirst' <<<"$P")" \
  '{profile: $profile, gates: $gates, mutation: $mutation,
    requireBeforeCommit: $rbc, guardTests: $guardTests, specFirst: $specFirst}')

if [[ $DRY -eq 1 ]]; then
  ylw "  (dry-run) конфигурация не записана:"
  jq . <<<"$NEW_CFG" | sed 's/^/    /'
else
  mkdir -p "$CFG_DIR"
  if [[ -f "$CFG" ]]; then
    # Ручные правки важнее автогенерации: сохраняем то, что человек уже задал
    NEW_CFG=$(jq -s '.[0] * .[1]' <<<"$NEW_CFG"$'\n'"$(cat "$CFG")")
    ylw "  существующий gauntlet.json сохранён, значения слиты"
  fi
  printf '%s\n' "$(jq . <<<"$NEW_CFG")" > "$CFG"
  grn "  записан .claude/gauntlet.json"

  [[ "$SCOPE" != "user" ]] && write_project_settings

  # Приоритет правил объявляется явно: общие модули и правила проекта имеют
  # одинаковый вес, и при противоречии выбор был бы произвольным.
  CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$HERE/std-rule.sh" precedence 2>&1 \
    | grep -E 'создан|уже есть' | sed 's/^ */  /' || true
fi

# ── Итог ──────────────────────────────────────────────────────────────────────
echo; b "════ ГОТОВО ════"
# Без fold: он считает байты, а не символы, и рвёт кириллицу вдвое раньше нужного
jq -r --arg p "$PROFILE" '.profiles[$p] | "Профиль \($p) — \(.title).\n\(.when)\n\n\(.rationale)"' "$PROFILES" \
  | sed 's/^/  /'

echo
if [[ ${#MISSING[@]} -gt 0 ]]; then
  ylw "  Не настроено: ${MISSING[*]}"
  echo "  Профиль их требует — гейты будут неполными, пока инструменты не появятся."
fi
if [[ "$MUT_ON" == "true" ]] && ! jq -e '.facts.hasMutation' <<<"$FACTS" >/dev/null; then
  echo
  ylw "  Мутационное тестирование не установлено."
  echo "  Это единственная проверка, которая проверяет сами тесты. Без неё"
  echo "  покрытие остаётся числом, которое ничего не гарантирует."
  echo "  Готовые конфиги: plugins/std-gauntlet/configs/"
fi
echo
if [[ ${#TO_INSTALL[@]} -gt 0 && $DRY -eq 0 && $NO_INSTALL -eq 0 && $INSTALL_FAILED -eq 0 ]]; then
  ylw "  Установлены новые плагины — выполни /reload-plugins,"
  echo "  иначе их хуки и команды не появятся в текущей сессии."
  echo
fi
echo "  Дальше: /std-gauntlet:run --fast  — убедиться, что гейты запускаются"
