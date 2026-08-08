#!/usr/bin/env bash
# std-setup.sh — настройка и пересинхронизация проекта одной командой.
#
# Заменяет последовательность link → profile → gauntlet:init → doctor.
# Каждая дополнительная команда на старте — это место, где внедрение
# останавливается: человек сделал первый шаг, отвлёкся и не вернулся.
#
# Команда идемпотентна: первый запуск настраивает, повторный — перечитывает
# проект и доустанавливает появившееся, сохраняя профиль и ручные правки.
# Отдельной команды синхронизации нет намеренно — помнить, чем «настроить»
# отличается от «досинхронизировать», не должно быть обязанностью человека.
#
#   std-setup.sh                настроить или досинхронизировать
#   std-setup.sh --profile team явно задать профиль
#   std-setup.sh --fresh        определить профиль заново, забыв записанный
#   std-setup.sh --remove       отключить проект от стандартов
#   std-setup.sh --dry-run      показать, что будет сделано, ничего не меняя
#   std-setup.sh --no-install   не ставить плагины, только правила и конфиг
#   std-setup.sh --scope project  привязать плагины к проекту, а не к машине
#   std-setup.sh --no-hooks     подключить одни правила: замки в этом проекте молчат
#   std-setup.sh --hooks        вернуть замки
set -uo pipefail
export LC_NUMERIC=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
PROFILES="$HERE/../profiles/profiles.json"
CFG_DIR="$PROJECT_DIR/.claude"
CFG="$CFG_DIR/gauntlet.json"
# Маркер отключённых замков. Файл, а не ключ в конфигурации: состояние «проверок
# нет» должно быть видно в git status и в списке файлов проекта, не открывая
# JSON. Читают его сами хуки — по одной строке в каждом, чтобы выключение
# не зависело от того, установлен ли std-core и жив ли его конфиг.
MARKER="$CFG_DIR/std-hooks-off"

# SYNC=1 по умолчанию: если проект уже настроен, его профиль сохраняется.
# Переопределить — --fresh или явный --profile.
FORCE_PROFILE=""; DRY=0; NO_INSTALL=0; SYNC=1; REMOVE=0
# HOOKS: 1 включить, 0 выключить, пусто — не трогать текущее состояние.
# Третье значение обязательно: без него повторный запуск команды молча
# возвращал бы замки тому, кто их снял неделю назад и об этом не помнит.
HOOKS=""
# user    — плагины на машине, во всех проектах
# project — в .claude/settings.json проекта: получат все, кто его склонирует
# local   — только в этом проекте и только у тебя
SCOPE="user"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)    FORCE_PROFILE="${2:-}"; shift 2 ;;
    --dry-run)    DRY=1; shift ;;
    --no-install) NO_INSTALL=1; shift ;;
    --fresh)      SYNC=0; shift ;;
    --remove)     REMOVE=1; shift ;;
    # Принимается ради установок, где команда записана в скриптах: раньше
    # пересинхронизация требовала явного флага, теперь это поведение по умолчанию.
    --sync)       SYNC=1; shift ;;
    --scope)      SCOPE="${2:-user}"; shift 2 ;;
    --no-hooks)   HOOKS=0; shift ;;
    --hooks)      HOOKS=1; shift ;;
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

# ── Отключение проекта от стандартов ──────────────────────────────────────────
# Живёт здесь, а не отдельной командой: подключение и отключение — одно решение,
# принятое в разные стороны, и искать для второго другое имя незачем.
#
# Убирается только то, что создали стандарты. Правила проекта, чужие настройки
# и история решений остаются: удалять чужое при отключении никто не просил.
if [[ $REMOVE -eq 1 ]]; then
  b "▸ Отключение проекта от стандартов"
  if [[ $DRY -eq 1 ]]; then
    ylw "  (dry-run) отвязал бы правила, убрал gauntlet.json и записи маркетплейса"
    exit 0
  fi

  bash "$HERE/std-link.sh" --unlink 2>/dev/null || true

  for f in "$CFG" "$MARKER" "$CFG_DIR/.ratchet.json" "$CFG_DIR/.debt.json" "$CFG_DIR/.gauntlet-pass" "$CFG_DIR/.std-trace.jsonl"; do
    [[ -e "$f" ]] && { rm -f "$f"; grn "  - удалён $(basename "$f")"; }
  done

  SETTINGS="$CFG_DIR/settings.json"
  if [[ -f "$SETTINGS" ]] && command -v jq >/dev/null 2>&1; then
    upd=$(jq --arg m "$MARKETPLACE_NAME" --arg suf "@$MARKETPLACE_NAME" '
      if has("extraKnownMarketplaces") then .extraKnownMarketplaces |= del(.[$m]) else . end
      | if (.extraKnownMarketplaces // {}) == {} then del(.extraKnownMarketplaces) else . end
      | if has("enabledPlugins")
          then .enabledPlugins |= with_entries(select(.key | endswith($suf) | not))
          else . end
      | if (.enabledPlugins // {}) == {} then del(.enabledPlugins) else . end
    ' "$SETTINGS" 2>/dev/null)
    if [[ -n "$upd" ]]; then
      if [[ "$upd" == "{}" ]]; then
        rm -f "$SETTINGS"; grn "  - удалён settings.json (в нём не было ничего своего)"
      else
        printf '%s\n' "$upd" > "$SETTINGS"; grn "  - из settings.json убраны записи стандартов"
      fi
    fi
  fi

  rmdir "$CFG_DIR/rules" 2>/dev/null && grn "  - удалён пустой .claude/rules"
  rmdir "$CFG_DIR" 2>/dev/null && grn "  - удалён пустой .claude"

  echo
  grn "════ ПРОЕКТ ОТКЛЮЧЁН ════"
  echo "Правила проекта и чужие настройки не тронуты."
  echo "Плагины остались на машине — они нужны другим проектам."
  echo "Подключить обратно: /std-core:setup --scope project"
  exit 0
fi

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

    # ...но не важнее того, что человек только что попросил. Слияние кладёт
    # старый файл поверх нового, поэтому записанный профиль перебивал явный
    # --profile: скрипт печатал «профиль prototype», а в файл писал прежний
    # solo. Смена профиля на любом уже настроенном проекте молча не срабатывала.
    #
    # Аргумент и --fresh возвращают параметры профиля обратно. Гейты при этом
    # остаются ручными: их правят под проект, а не под уровень строгости.
    if [[ -n "$FORCE_PROFILE" || $SYNC -eq 0 ]]; then
      NEW_CFG=$(jq \
        --arg profile "$PROFILE" \
        --argjson mutation "$MUT_JSON" \
        --argjson rbc "$(jq '.requireBeforeCommit' <<<"$P")" \
        --arg guardTests "$(jq -r '.guardTests' <<<"$P")" \
        --argjson specFirst "$(jq '.specFirst' <<<"$P")" \
        '.profile = $profile
         | .mutation = $mutation
         | .requireBeforeCommit = $rbc
         | .guardTests = $guardTests
         | .specFirst = $specFirst' <<<"$NEW_CFG")
      ylw "  профиль задан явно — его параметры применены поверх прежних"
    fi
  fi
  printf '%s\n' "$(jq . <<<"$NEW_CFG")" > "$CFG"
  grn "  записан .claude/gauntlet.json"

  [[ "$SCOPE" != "user" ]] && write_project_settings

  # Приоритет правил объявляется явно: общие модули и правила проекта имеют
  # одинаковый вес, и при противоречии выбор был бы произвольным.
  CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$HERE/std-rule.sh" precedence 2>&1 \
    | grep -E 'создан|уже есть' | sed 's/^ */  /' || true
fi

# ── Замки ─────────────────────────────────────────────────────────────────────
# Правила и замки разъединяются здесь. Обычно это одно целое — текст говорит,
# что делать, хук проверяет, что сделано именно так. Но в личном проекте вопрос
# на каждую команду стоит дороже, чем закрываемый им риск, и человек начинает
# искать, как выключить всё. Найденное решение обычно оказывается грубее нужного
# (disableAllHooks гасит и чужие хуки) и незаметнее (переменная окружения
# не видна никому, кроме того, кто её поставил). Поэтому выключатель здесь
# свой: один файл, видимый в git, и напоминание на старте каждой сессии.
#
# Что остаётся при выключенных замках: правила в .claude/rules, команды, скиллы,
# гейты (/std-gauntlet:run запускается вручную и от хуков не зависит).
# Что пропадает: все проверки в момент действия — разрушающие команды, правка
# тестов, секреты при чтении, записи и коммите, подсказки по соседним файлам.
if [[ -n "$HOOKS" ]]; then
  echo; b "▸ Замки"
  if [[ "$HOOKS" == "0" ]]; then
    if [[ $DRY -eq 1 ]]; then
      ylw "  (dry-run) создал бы $MARKER — замки бы замолчали"
    else
      mkdir -p "$CFG_DIR"
      cat > "$MARKER" <<EOF
# Замки стандартов в этом проекте выключены — $(date +%F).
#
# Правила (.claude/rules/std-*) действуют: модель их читает и им следует.
# Проверки не выполняются ни одна: разрушающие команды, правка существующих
# тестов, секреты при чтении, записи и коммите. Соблюдение правил держится
# на внимании человека, как до появления хуков.
#
# Гейты это не затрагивает: /std-gauntlet:run запускается руками и работает.
#
# Вернуть проверки: /std-core:setup --hooks (или просто удалить этот файл).
EOF
      grn "  создан .claude/std-hooks-off — замки молчат, правила остаются"
      echo "  Файл виден в git. Если решение личное, а не командное, добавь его в .gitignore."
    fi
  else
    if [[ $DRY -eq 1 ]]; then
      ylw "  (dry-run) удалил бы $MARKER — замки бы заработали"
    elif [[ -f "$MARKER" ]]; then
      rm -f "$MARKER"; grn "  удалён .claude/std-hooks-off — замки снова работают"
    else
      grn "  замки и так работают"
    fi
  fi
  # Перезагрузка плагинов не нужна: маркер читают сами скрипты хуков, при каждом
  # вызове. Это стоит сказать вслух — иначе человек ждёт /reload-plugins и решает,
  # что команда не сработала.
  [[ $DRY -eq 0 ]] && echo "  Действует сразу, в текущей сессии: перезагружать плагины не нужно."
fi

# ── Итог ──────────────────────────────────────────────────────────────────────
echo; b "════ ГОТОВО ════"
# Без fold: он считает байты, а не символы, и рвёт кириллицу вдвое раньше нужного
jq -r --arg p "$PROFILE" '.profiles[$p] | "Профиль \($p) — \(.title).\n\(.when)\n\n\(.rationale)"' "$PROFILES" \
  | sed 's/^/  /'

echo
# Состояние замков называется на каждом запуске, а не только когда его меняли:
# профиль строгости при выключенных замках описывает намерение, а не то,
# что происходит на самом деле, и разница между этим должна быть видна.
if [[ -f "$MARKER" && $DRY -eq 0 ]]; then
  ylw "  Замки выключены (.claude/std-hooks-off): проверок в момент действия нет."
  echo "  Профиль выше описывает планку качества, но держать её теперь некому,"
  echo "  кроме тебя. Вернуть проверки: /std-core:setup --hooks"
  echo
fi
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
