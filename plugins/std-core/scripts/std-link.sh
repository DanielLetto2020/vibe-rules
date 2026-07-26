#!/usr/bin/env bash
# std-link.sh — связывает правила модулей стандартов с проектом.
#
# Зачем: плагины Claude Code раздают skills/commands/hooks, но НЕ раздают
# .claude/rules/. При этом только rules умеют path-scoped загрузку (paths:).
# Поэтому правила линкуются симлинком на репозиторий стандартов.
#
# Путь резолвится динамически, а не хардкодится:
#   1) $VIBE_RULES_HOME, если задан;
#   2) installLocation из ~/.claude/plugins/known_marketplaces.json;
#   3) ошибка с инструкцией.
# Так связь переживает /plugin update и переезд между машинами.
#
# Использование:
#   std-link.sh --auto              определить стек по файлам проекта и слинковать
#   std-link.sh php-laravel sql-postgres
#   std-link.sh --check             только проверить (ничего не меняет), для CI
#   std-link.sh --detect            показать, что подключилось бы, не меняя проект
#   std-link.sh --unlink            убрать все симлинки стандартов
set -uo pipefail

MARKETPLACE_NAME="${VIBE_RULES_MARKETPLACE:-vibe-rules}"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
RULES_DIR="$PROJECT_DIR/.claude/rules"
LINK_PREFIX="std-"

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }

# --- 1. Где лежит репозиторий стандартов -------------------------------------
resolve_standards_home() {
  if [[ -n "${VIBE_RULES_HOME:-}" && -d "$VIBE_RULES_HOME/plugins" ]]; then
    echo "$VIBE_RULES_HOME"; return 0
  fi
  local known="$HOME/.claude/plugins/known_marketplaces.json"
  if [[ -f "$known" ]] && command -v jq >/dev/null 2>&1; then
    local loc
    loc=$(jq -r --arg n "$MARKETPLACE_NAME" '.[$n].installLocation // empty' "$known" 2>/dev/null)
    if [[ -n "$loc" && -d "$loc/plugins" ]]; then
      echo "$loc"; return 0
    fi
  fi
  return 1
}

# --- 2. Автодетект стека по файлам проекта -----------------------------------

# Ищет регулярку в перечисленных файлах проекта. Файлы перебираются по одному:
# grep со списком, где часть путей не существует, возвращает код 2, и при
# set -o pipefail это неотличимо от «не найдено» — так уже терялся модуль.
has_in() { # <регулярка> <файл>...
  local re="$1"; shift
  local f
  for f in "$@"; do
    [[ -f "$PROJECT_DIR/$f" ]] && grep -qiE "$re" "$PROJECT_DIR/$f" 2>/dev/null && return 0
  done
  return 1
}

# Ищет регулярку в любом файле по маске, не глубже 3 уровней.
# Проверяем непустой список найденного, а не код возврата пайплайна:
# `xargs -r` при пустом вводе ничего не запускает и возвращает 0, из-за чего
# «файлов вообще нет» было неотличимо от «нашлось совпадение» — так в проект
# на Python подключались правила Kubernetes и Ansible.
# Глубина 5, а не 3: контроллеры в PHP-проектах лежат в app/Http/Controllers/,
# то есть на четвёртом уровне, и при меньшей глубине не находились.
has_tree() { # <регулярка> <маска-имени> [подкаталог]
  local re="$1" name="$2" sub="${3:-.}" found
  [[ -d "$PROJECT_DIR/$sub" ]] || return 1
  found=$(find "$PROJECT_DIR/$sub" -maxdepth 5 \
            \( -path '*/node_modules' -o -path '*/vendor' -o -path '*/.git' \
               -o -path '*/.venv' -o -path '*/dist' -o -path '*/build' \) -prune -o \
            -name "$name" -type f -print0 2>/dev/null \
          | xargs -0 -r grep -liE "$re" 2>/dev/null | head -1)
  [[ -n "$found" ]]
}

ENV_FILES=(.env.example .env .env.dist docker-compose.yml docker-compose.yaml compose.yaml compose.yml)

detect_modules() {
  local mods=("core" "gauntlet")   # база и конвейер проверок нужны всегда

  # --- PHP ---
  # Язык и фреймворк — разные модули: PHP не всегда Laravel, и правила
  # уровня языка нужны в любом случае. Фреймворковый модуль добавляется
  # сверх базового, а не вместо него.
  if [[ -f "$PROJECT_DIR/composer.json" ]] || has_tree '<\?php' '*.php' .; then
    mods+=("php-base")
    has_in '"laravel/framework"' composer.json && mods+=("php-laravel")
    has_in '"yiisoft/yii2"'      composer.json && mods+=("php-yii2")
  fi

  # --- Веб-разметка и стили ---
  # Ищем по файлам, а не по package.json: лендинг, виджет или статический сайт
  # часто вообще не имеют сборки, и по манифесту их не видно.
  has_tree '<' '*.html' . && mods+=("web-html")
  if find "$PROJECT_DIR" -maxdepth 3 \
       \( -path '*/node_modules' -o -path '*/vendor' -o -path '*/.git' -o -path '*/dist' \) -prune -o \
       \( -name '*.css' -o -name '*.scss' -o -name '*.sass' -o -name '*.less' \) \
       -type f -print -quit 2>/dev/null | grep -q .; then
    mods+=("web-css")
  fi

  # --- JS/TS: Nuxt поглощает Vue, отдельный модуль Vue тогда не нужен ---
  if [[ -f "$PROJECT_DIR/package.json" ]] \
     || has_tree 'function|const |=>' '*.js' . ; then
    mods+=("js-base")
    if has_in '"nuxt"' package.json || [[ -f "$PROJECT_DIR/nuxt.config.ts" || -f "$PROJECT_DIR/nuxt.config.js" ]]; then
      mods+=("js-nuxt")
    elif has_in '"vue"' package.json; then
      mods+=("js-vue3")
    fi
    if has_in '@playwright/test' package.json || [[ -f "$PROJECT_DIR/playwright.config.ts" || -f "$PROJECT_DIR/playwright.config.js" ]]; then
      mods+=("js-playwright")
    fi
  fi

  # TypeScript — отдельный модуль от js-base: система типов не нужна проекту
  # на чистом JavaScript, а проверять её там не на чем.
  if [[ -f "$PROJECT_DIR/tsconfig.json" ]] \
     || find "$PROJECT_DIR" -maxdepth 3 \
          \( -path '*/node_modules' -o -path '*/.git' -o -path '*/dist' \) -prune -o \
          \( -name '*.ts' -o -name '*.tsx' \) ! -name '*.d.ts' \
          -type f -print -quit 2>/dev/null | grep -q .; then
    mods+=("js-typescript")
    # Проект может быть на TypeScript без package.json — тогда базовые
    # правила языка тоже нужны, а выше их не добавили
    printf '%s\n' "${mods[@]}" | grep -qx 'js-base' || mods+=("js-base")
  fi

  # --- Python ---
  if [[ -f "$PROJECT_DIR/pyproject.toml" || -f "$PROJECT_DIR/requirements.txt" ]] \
     || has_tree 'import |def ' '*.py' .; then
    mods+=("py-base")
    if has_in 'fastapi' pyproject.toml requirements.txt; then
      mods+=("py-fastapi")
    fi
    if has_in 'scrapy|beautifulsoup|bs4|selectolax|lxml|httpx|aiohttp|requests' pyproject.toml requirements.txt; then
      mods+=("py-parsers")
    fi
  fi

  # --- Базы данных ---
  has_in 'postgres|pgsql|psycopg' "${ENV_FILES[@]}" composer.json pyproject.toml requirements.txt package.json \
    && mods+=("sql-postgres")
  has_in 'sqlite' "${ENV_FILES[@]}" composer.json pyproject.toml requirements.txt package.json \
    && mods+=("sql-sqlite")

  # --- Очереди и кэш ---
  has_in 'rabbitmq|amqp' "${ENV_FILES[@]}" composer.json pyproject.toml requirements.txt package.json \
    && mods+=("msg-rabbitmq")
  has_in 'kafka|redpanda' "${ENV_FILES[@]}" composer.json pyproject.toml requirements.txt package.json \
    && mods+=("msg-kafka")
  has_in 'redis|valkey' "${ENV_FILES[@]}" composer.json pyproject.toml requirements.txt package.json \
    && mods+=("cache-redis")

  # --- Контейнеры ---
  # Ищем не только в корне: compose-файлы часто лежат в docker/, compose/, deploy/
  if [[ -f "$PROJECT_DIR/Dockerfile" || -f "$PROJECT_DIR/Containerfile" ]] \
     || find "$PROJECT_DIR" -maxdepth 3 \
          \( -path '*/node_modules' -o -path '*/vendor' -o -path '*/.git' \) -prune -o \
          \( -name 'Dockerfile*' -o -name 'Containerfile*' \
             -o -name '*compose*.y*ml' \) \
          -type f -print -quit 2>/dev/null | grep -q .; then
    mods+=("ops-containers")
  fi

  # --- Kubernetes: манифест узнаётся по паре apiVersion+kind, а не по имени файла ---
  local d
  for d in k8s kubernetes deploy deployment manifests chart charts helm .; do
    if has_tree 'apiVersion:' '*.y*ml' "$d" && has_tree '^kind:' '*.y*ml' "$d"; then
      mods+=("ops-k8s"); break
    fi
  done
  [[ -f "$PROJECT_DIR/Chart.yaml" ]] && mods+=("ops-k8s")

  # --- Ansible ---
  if [[ -f "$PROJECT_DIR/ansible.cfg" || -f "$PROJECT_DIR/playbook.yml" \
     || -f "$PROJECT_DIR/site.yml" || -d "$PROJECT_DIR/roles" || -d "$PROJECT_DIR/ansible" ]]; then
    mods+=("ops-ansible")
  elif has_tree 'hosts:|become:|ansible\.builtin' '*.y*ml' .; then
    mods+=("ops-ansible")
  fi

  # --- Универсальные модули, зависящие не от стека, а от устройства проекта ---

  # HTTP API: есть контроллеры, роуты или схема OpenAPI
  if has_tree 'Controller|Route|router' '*.php' . \
     || has_tree 'openapi|swagger' '*.y*ml' . \
     || [[ -d "$PROJECT_DIR/routes" ]]; then
    mods+=("api-http")
  fi

  # Межсервисное взаимодействие: в конфигурации фигурируют внешние сервисы
  has_in 'API_URL|_SERVICE_URL|_HOST=|BASE_URI|GATEWAY' "${ENV_FILES[@]}" \
    && mods+=("arch-services")

  # Наблюдаемость нужна всему, что где-то развёрнуто
  printf '%s\n' "${mods[@]}" | grep -qE 'ops-k8s|ops-containers' \
    && mods+=("ops-observability")

  # Подход к предметной области — там, где домен выделен явно
  local dd
  for dd in Domain domain src/Domain app/Domain Entity entities; do
    [[ -d "$PROJECT_DIR/$dd" ]] && { mods+=("arch-approach"); break; }
  done

  # Политика подключается только если она в проекте объявлена: механизм есть
  # у всех, содержимое задаёт организация
  [[ -f "$PROJECT_DIR/.claude/policy.json" ]] && mods+=("policy")

  printf '%s\n' "${mods[@]:-}" | grep -v '^$' | sort -u
}

# --- 3. Гигиена .gitignore ----------------------------------------------------
# Симлинки содержат абсолютный путь конкретной машины. В git они попасть не должны:
# у коллеги путь другой, и правило молча перестанет грузиться.
ensure_gitignore() {
  local gi="$PROJECT_DIR/.gitignore"
  local line=".claude/rules/${LINK_PREFIX}*"
  [[ -f "$gi" ]] || touch "$gi"
  grep -qxF "$line" "$gi" || {
    printf '\n# Симлинки на общие стандарты (у каждого свой абсолютный путь)\n%s\n' "$line" >> "$gi"
    grn "  + .gitignore: добавлен $line"
  }
}

# --- 4. Основные операции -----------------------------------------------------
do_unlink() {
  local n=0
  shopt -s nullglob
  for l in "$RULES_DIR/${LINK_PREFIX}"*; do
    [[ -L "$l" ]] && { rm "$l"; grn "  - отвязан $(basename "$l")"; n=$((n+1)); }
  done
  shopt -u nullglob
  [[ $n -eq 0 ]] && ylw "  нечего отвязывать"
  return 0
}

do_check() {
  local rc=0 n=0
  shopt -s nullglob
  for l in "$RULES_DIR/${LINK_PREFIX}"*; do
    n=$((n+1))
    if [[ -d "$l" ]]; then
      grn "  ok   $(basename "$l") -> $(readlink "$l")"
    else
      red  "  БИТ  $(basename "$l") -> $(readlink "$l" 2>/dev/null || echo '?')"
      rc=1
    fi
  done
  shopt -u nullglob
  [[ $n -eq 0 ]] && { ylw "  правила стандартов не подключены (запусти: std-link.sh --auto)"; rc=1; }
  return $rc
}

main() {
  local mode="link" modules=()
  case "${1:-}" in
    --home)   mode="home" ;;
    --detect) mode="detect" ;;
    --check)  mode="check" ;;
    --unlink) mode="unlink" ;;
    --auto)   mode="link"; mapfile -t modules < <(detect_modules) ;;
    "")       red "Укажи модули или --auto. Пример: std-link.sh --auto"; exit 2 ;;
    *)        modules=("$@") ;;
  esac

  # Путь репозитория — для скриптов, которым он нужен (std-setup.sh)
  if [[ "$mode" == "home" ]]; then
    resolve_standards_home || exit 1
    exit 0
  fi

  # Сухой прогон: только показать результат детекта. Каталог правил не
  # создаётся — команда безопасна для чужого проекта, который ещё не решили
  # подключать.
  if [[ "$mode" == "detect" ]]; then
    local m
    for m in $(detect_modules); do printf '  %s\n' "std-$m"; done
    exit 0
  fi

  mkdir -p "$RULES_DIR"
  [[ "$mode" == "unlink" ]] && { do_unlink; exit 0; }
  [[ "$mode" == "check"  ]] && { do_check;  exit $?; }

  local home
  if ! home=$(resolve_standards_home); then
    red "Не найден репозиторий стандартов '$MARKETPLACE_NAME'."
    echo "Варианты:"
    echo "  1) /plugin marketplace add <путь-или-репо>   (и повтори)"
    echo "  2) export VIBE_RULES_HOME=/путь/к/vibe-rules"
    exit 1
  fi
  echo "Репозиторий стандартов: $home"

  if [[ ${#modules[@]} -eq 0 ]]; then
    ylw "Стек не определён автоматически. Укажи модули явно, например: std-link.sh php-laravel"
    exit 1
  fi

  local failed=0
  for m in "${modules[@]}"; do
    [[ -z "$m" ]] && continue
    m="${m#std-}"                               # принимаем и 'php-laravel', и 'std-php-laravel'
    local src="$home/plugins/std-$m/rules"
    local dst="$RULES_DIR/${LINK_PREFIX}$m"
    if [[ ! -d "$src" ]]; then
      red "  ! модуля std-$m нет в репозитории ($src)"; failed=1; continue
    fi
    [[ -L "$dst" ]] && rm "$dst"
    if [[ -e "$dst" ]]; then
      red "  ! $dst существует и это не симлинк — пропускаю"; failed=1; continue
    fi
    ln -s "$src" "$dst" && grn "  + std-$m -> $src"
  done

  ensure_gitignore
  echo
  echo "Готово. Проверь загрузку: запусти сессию в проекте и выполни /context"
  exit $failed
}

main "$@"
