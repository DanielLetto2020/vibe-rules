#!/usr/bin/env bash
# std-profile.sh — определяет, в каком состоянии проект, и предлагает профиль.
#
# Зачем: одинаковая строгость для всех проектов не работает. На прототипе
# мутационный порог тормозит проверку гипотезы, на легаси он недостижим
# и будет отключён в первый день, а в команде мягкий режим означает, что
# стандартов нет.
#
# Определяется по фактам из репозитория, а не по вопросам пользователю:
#   сколько людей коммитит  -> команда или один
#   сколько коммитов и лет  -> новый, зрелый или легаси
#   есть ли тесты и сколько -> достижим ли порог качества
#
#   std-profile.sh           человекочитаемый отчёт
#   std-profile.sh --json    машинный вывод для std-setup.sh
set -uo pipefail

# Дробные числа должны печататься с точкой независимо от локали пользователя:
# при ru_RU awk выдаёт «0,00», и такое значение ломает и jq, и сравнения.
export LC_NUMERIC=C

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
cd "$PROJECT_DIR" 2>/dev/null || exit 1

JSON=0
[[ "${1:-}" == "--json" ]] && JSON=1

# --- Факты из git ------------------------------------------------------------
COMMITS=0; AUTHORS=0; AGE_DAYS=0; RECENT_AUTHORS=0
if git rev-parse --git-dir >/dev/null 2>&1; then
  COMMITS=$(git rev-list --count HEAD 2>/dev/null || echo 0)
  AUTHORS=$(git log --format='%ae' 2>/dev/null | sort -u | wc -l)
  # Активные за полгода важнее исторических: ушедший два года назад коллега
  # не делает проект командным сегодня
  RECENT_AUTHORS=$(git log --since='6 months ago' --format='%ae' 2>/dev/null | sort -u | wc -l)
  FIRST=$(git log --reverse --format='%at' 2>/dev/null | head -1)
  if [[ -n "$FIRST" ]]; then
    NOW=$(date +%s)
    AGE_DAYS=$(( (NOW - FIRST) / 86400 ))
  fi
fi
[[ "$RECENT_AUTHORS" -gt 0 ]] && EFFECTIVE_AUTHORS=$RECENT_AUTHORS || EFFECTIVE_AUTHORS=$AUTHORS

# --- Факты о тестах ----------------------------------------------------------
count_files() { # <маска>...
  local n=0 pat
  for pat in "$@"; do
    n=$(( n + $(find . \( -path ./node_modules -o -path ./vendor -o -path ./.git \
          -o -path ./.venv -o -path ./dist -o -path ./build \) -prune -o \
          -name "$pat" -type f -print 2>/dev/null | wc -l) ))
  done
  echo "$n"
}

PRUNE=( -path ./node_modules -o -path ./vendor -o -path ./.git
        -o -path ./.venv -o -path ./dist -o -path ./build )

# Тестом считается файл, подходящий по имени ИЛИ лежащий в тестовом каталоге.
# Только по именам мало: bash- и python-тесты часто называются иначе
# (test-hooks.sh, run.sh), и проект с полным набором проверок выглядел бы
# непокрытым.
BY_NAME=$(count_files '*Test.php' '*Spec.php' '*_test.py' 'test_*.py' \
                      '*.spec.ts' '*.spec.js' '*.test.ts' '*.test.js' '*_test.go')
BY_DIR=$(find . \( "${PRUNE[@]}" \) -prune -o \
           -type f \( -name '*.php' -o -name '*.py' -o -name '*.ts' -o -name '*.js' \
                   -o -name '*.go' -o -name '*.sh' \) \
           -regextype posix-extended \
           -regex '.*/(tests?|spec|specs|__tests__|e2e|features)/.*' -print 2>/dev/null | wc -l)
TEST_FILES=$(( BY_NAME > BY_DIR ? BY_NAME : BY_DIR ))

SRC_FILES=$(count_files '*.php' '*.py' '*.ts' '*.js' '*.vue' '*.go' '*.sh')
# Тестовые файлы попали в общий счёт исходников — вычитаем, иначе доля занижена
SRC_ONLY=$(( SRC_FILES - TEST_FILES ))
[[ $SRC_ONLY -lt 1 ]] && SRC_ONLY=1
RATIO=$(awk -v t="$TEST_FILES" -v s="$SRC_ONLY" 'BEGIN{printf "%.2f", t/s}')

HAS_CI=0
[[ -d .github/workflows || -f .gitlab-ci.yml || -f Jenkinsfile ]] && HAS_CI=1

HAS_MUTATION=0
grep -rslE 'infection|stryker|mutmut|cosmic-ray|pitest' \
  composer.json package.json pyproject.toml 2>/dev/null | grep -q . && HAS_MUTATION=1

# --- Выбор профиля -----------------------------------------------------------
# regulated автоматически не выбирается никогда: определить по коду, что проект
# работает с деньгами или медданными, надёжно нельзя, а ошибка дорога.
if [[ "$COMMITS" -lt 15 && "$TEST_FILES" -eq 0 ]]; then
  PROFILE="prototype"
  WHY="меньше 15 коммитов и ни одного теста — похоже на проверку гипотезы"
elif [[ "$COMMITS" -gt 200 ]] && awk -v r="$RATIO" 'BEGIN{exit !(r < 0.1)}'; then
  PROFILE="legacy"
  WHY="$COMMITS коммитов при доле тестов $RATIO — накопленный код без надзорного слоя"
elif [[ "$EFFECTIVE_AUTHORS" -gt 1 ]]; then
  PROFILE="team"
  WHY="$EFFECTIVE_AUTHORS автора за последние полгода — код читают те, кто его не писал"
else
  PROFILE="solo"
  WHY="один автор — второй пары глаз нет, надзорный слой важнее обычного"
fi

if [[ $JSON -eq 1 ]]; then
  jq -n \
    --arg profile "$PROFILE" --arg why "$WHY" \
    --argjson commits "$COMMITS" --argjson authors "$EFFECTIVE_AUTHORS" \
    --argjson allAuthors "$AUTHORS" --argjson ageDays "$AGE_DAYS" \
    --argjson testFiles "$TEST_FILES" --argjson srcFiles "$SRC_ONLY" \
    --arg ratio "$RATIO" --argjson hasCi "$HAS_CI" --argjson hasMutation "$HAS_MUTATION" \
    '{profile:$profile, why:$why, facts:{commits:$commits, activeAuthors:$authors,
      allAuthors:$allAuthors, ageDays:$ageDays, testFiles:$testFiles,
      sourceFiles:$srcFiles, testRatio:$ratio, hasCi:($hasCi==1), hasMutation:($hasMutation==1)}}'
  exit 0
fi

printf '\033[1mСостояние проекта\033[0m\n'
printf '  коммитов:        %s\n' "$COMMITS"
printf '  авторов активно: %s (всего за историю: %s)\n' "$EFFECTIVE_AUTHORS" "$AUTHORS"
printf '  возраст:         %s дней\n' "$AGE_DAYS"
printf '  тестов:          %s файлов на %s исходных (доля %s)\n' "$TEST_FILES" "$SRC_ONLY" "$RATIO"
printf '  CI:              %s\n' "$([[ $HAS_CI -eq 1 ]] && echo есть || echo нет)"
printf '  мутационное:     %s\n' "$([[ $HAS_MUTATION -eq 1 ]] && echo подключено || echo нет)"
printf '\n\033[1mПрофиль: %s\033[0m\n  %s\n' "$PROFILE" "$WHY"
