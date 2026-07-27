#!/usr/bin/env bash
# gauntlet.sh — прогон всех гейтов проекта одной командой.
#
# Смысл: пока «проверить работу» означает «вспомнить пять команд», проверка
# делается выборочно и по настроению. Одна команда с общим вердиктом —
# то, что делает отказ от чтения кода возможным.
#
# Настройка проекта: .claude/gauntlet.json (создаётся /std-gauntlet:init).
# Без него используются разумные дефолты по признакам стека.
#
#   gauntlet.sh              все гейты
#   gauntlet.sh --fast       без мутационного (для итераций в процессе работы)
#   gauntlet.sh --only lint  один гейт
#   gauntlet.sh --list       что будет запущено
set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
CFG="$PROJECT_DIR/.claude/gauntlet.json"
# Команды гейтов могут ссылаться на скрипты модуля — например мутация данных
# спецификации. Путь подставляется здесь, чтобы в конфигурации проекта его
# не хардкодили: при обновлении плагина он меняется.
export STD_GAUNTLET_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="full"; ONLY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fast) MODE="fast"; shift ;;
    --only) ONLY="${2:-}"; shift 2 ;;
    --list) MODE="list"; shift ;;
    *) shift ;;
  esac
done

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
red()  { printf '\033[31m%s\033[0m\n' "$*"; }
ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }

have() { [[ -e "$PROJECT_DIR/$1" ]]; }

# Мутация КОДА (infection, stryker, mutmut) — к ней применяется храповик
# и ограничение изменёнными файлами. Мутация ДАННЫХ спецификации живёт
# по другому правилу: выживший мутант там означает, что тест не связан
# с требованием, и послаблений на этот счёт не бывает.
is_code_mutation() { [[ "$1" == *mutation* && "$1" != spec-* ]]; }

# --- Дефолты по стеку ---------------------------------------------------------
# Порядок гейтов не случаен: дешёвые и быстрые идут первыми, чтобы очевидная
# ошибка обнаружилась за секунды, а не после десятиминутной мутации.
default_gates() {
  if have artisan; then
    echo "style|./vendor/bin/pint --test"
    echo "types|./vendor/bin/phpstan analyse --no-progress"
    echo "test|php artisan test"
    echo "mutation|./vendor/bin/infection --threads=max --min-msi=\$MSI --no-progress"
  elif have composer.json; then
    echo "style|./vendor/bin/php-cs-fixer fix --dry-run --diff"
    echo "types|./vendor/bin/phpstan analyse --no-progress"
    echo "test|./vendor/bin/phpunit"
    echo "mutation|./vendor/bin/infection --threads=max --min-msi=\$MSI --no-progress"
  fi
  if have package.json; then
    echo "js-lint|npm run lint --if-present"
    echo "js-types|npx --no-install tsc --noEmit"
    echo "js-test|npm test --if-present"
    echo "js-mutation|npx --no-install stryker run"
  fi
  if have pyproject.toml || have requirements.txt; then
    echo "py-lint|ruff check ."
    echo "py-types|mypy ."
    echo "py-test|pytest -q"
    echo "py-mutation|mutmut run --no-progress"
  fi
}

# --- Гейты из конфига проекта, если он есть -----------------------------------
read_gates() {
  if [[ -f "$CFG" ]] && command -v jq >/dev/null 2>&1; then
    jq -r '.gates | to_entries[] | "\(.key)|\(.value)"' "$CFG" 2>/dev/null && return 0
  fi
  default_gates
}

# --- Режим мутационного гейта -------------------------------------------------
# absolute — фиксированный порог. Годится там, где качество уже высокое.
# ratchet  — планка равна лучшему достигнутому: улучшать не обязательно,
#            ухудшать нельзя. Единственный режим, работающий на легаси, где
#            любой достижимый абсолютный порог бесполезен, а полезный —
#            недостижим и потому будет отключён.
MUT_MODE="absolute"; MSI=70; MUT_CHANGED_ONLY="false"
if [[ -f "$CFG" ]] && command -v jq >/dev/null 2>&1; then
  m=$(jq -r '.mutation.mode // "absolute"' "$CFG" 2>/dev/null); [[ -n "$m" && "$m" != "null" ]] && MUT_MODE="$m"
  t=$(jq -r '.mutation.threshold // .mutation.minMsi // empty' "$CFG" 2>/dev/null); [[ -n "$t" && "$t" != "null" ]] && MSI="$t"
  c=$(jq -r '.mutation.changedOnly // false' "$CFG" 2>/dev/null); [[ "$c" == "true" ]] && MUT_CHANGED_ONLY="true"
fi
if [[ "$MUT_MODE" == "ratchet" ]]; then
  # При храповике инструмент не должен падать по своему порогу: решение
  # принимает ratchet.sh, сравнивая с планкой проекта.
  MSI=0
fi
export MSI

mapfile -t GATES < <(read_gates)

if [[ ${#GATES[@]} -eq 0 ]]; then
  ylw "Гейты не определены: стек не распознан и нет .claude/gauntlet.json"
  echo "Создай конфиг: /std-gauntlet:init"
  exit 1
fi

if [[ "$MODE" == "list" ]]; then
  bold "Гейты проекта (порог мутации: ${MSI}%):"
  for g in "${GATES[@]}"; do printf '  %-12s %s\n' "${g%%|*}" "${g#*|}"; done
  exit 0
fi

# --- Прогон -------------------------------------------------------------------
declare -a NAMES STATUS
FAILED=0
LOGDIR=$(mktemp -d)
trap 'rm -rf "$LOGDIR"' EXIT

for g in "${GATES[@]}"; do
  name="${g%%|*}"; cmd="${g#*|}"
  [[ -n "$ONLY" && "$name" != "$ONLY" ]] && continue
  if [[ "$MODE" == "fast" && "$name" == *mutation* ]]; then
    NAMES+=("$name"); STATUS+=("пропущен"); continue
  fi

  printf '\n'; bold "▸ $name"
  cmd_expanded=$(eval "echo \"$cmd\"")

  # На большом проекте полный мутационный прогон идёт часами. Ограничение
  # изменёнными файлами превращает его в проверку, которую реально запускают.
  if is_code_mutation "$name" && [[ "$MUT_CHANGED_ONLY" == "true" ]]; then
    case "$cmd_expanded" in
      *infection*) cmd_expanded="$cmd_expanded --git-diff-filter=AM" ;;
      *stryker*)   cmd_expanded="$cmd_expanded --since" ;;
    esac
  fi

  ( cd "$PROJECT_DIR" && eval "$cmd_expanded" ) > "$LOGDIR/$name.log" 2>&1
  rc=$?

  # --- Храповик вместо порога инструмента -------------------------------------
  if is_code_mutation "$name" && [[ "$MUT_MODE" == "ratchet" ]]; then
    # Формат вывода различается: Infection печатает «MSI: 63%»,
    # Stryker — «Mutation score: 63.45%», mutmut — свою сводку.
    score=$(grep -oiE '(mutation score indicator \(msi\)|mutation score|msi)[^0-9]{0,12}[0-9]+([.,][0-9]+)?' \
              "$LOGDIR/$name.log" 2>/dev/null | grep -oE '[0-9]+([.,][0-9]+)?' | tail -1)
    if [[ -n "$score" ]]; then
      score=${score%%[.,]*}
      if CLAUDE_PROJECT_DIR="$PROJECT_DIR" "$(dirname "${BASH_SOURCE[0]}")/ratchet.sh" check "$score" 2>&1 | sed 's/^/  /'; then
        rc=0
      else
        rc=1
      fi
    else
      ylw "  не удалось извлечь mutation score из вывода — храповик пропущен"
      ylw "  задай mutation.mode = absolute либо проверь формат отчёта"
    fi
  fi

  if [[ $rc -eq 0 ]]; then
    grn "  пройден"; NAMES+=("$name"); STATUS+=("ок")
  else
    red "  ПРОВАЛЕН (код $rc)"
    tail -25 "$LOGDIR/$name.log" | sed 's/^/    /'
    NAMES+=("$name"); STATUS+=("ПРОВАЛ"); FAILED=1
  fi
done

# --- Вердикт ------------------------------------------------------------------
echo; bold "════ ИТОГ ════"
for i in "${!NAMES[@]}"; do
  case "${STATUS[$i]}" in
    ок)       printf '  \033[32m✓\033[0m %-14s\n' "${NAMES[$i]}" ;;
    ПРОВАЛ)   printf '  \033[31m✗\033[0m %-14s\n' "${NAMES[$i]}" ;;
    *)        printf '  \033[33m–\033[0m %-14s (%s)\n' "${NAMES[$i]}" "${STATUS[$i]}" ;;
  esac
done

echo
if [[ $FAILED -eq 0 ]]; then
  # Отметка успеха: по ней guard-commit.sh понимает, что гейты прогонялись
  # ПОСЛЕ последней правки кода, а не когда-то раньше.
  if [[ "$MODE" == "full" && -z "$ONLY" ]]; then
    mkdir -p "$PROJECT_DIR/.claude"
    date -u +%s > "$PROJECT_DIR/.claude/.gauntlet-pass"
  fi
  grn "ВСЕ ГЕЙТЫ ПРОЙДЕНЫ"
  cat <<'EOF'

Это НЕ означает, что изменения можно не смотреть. Гейты не покрывают:
  миграции и схему БД · изменения API-контрактов · новые зависимости
  деньги, права доступа, персональные данные · манифесты k8s и playbook'и
  производительность, гонки, стоимость эксплуатации
EOF
  exit 0
else
  red "ЕСТЬ ПРОВАЛЕННЫЕ ГЕЙТЫ — работа не сделана"
  exit 1
fi
