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
#   gauntlet.sh                  все гейты
#   gauntlet.sh --fast           без мутационного (для итераций в процессе работы)
#   gauntlet.sh --only lint      один гейт — или семейство: js-lint, py-lint…
#   gauntlet.sh --only mutation  вся мутация кода, как бы гейты ни назывались
#   gauntlet.sh --list           что будет запущено
#
# Коды: 0 — пройдено; 1 — есть проваленные гейты или гейты не определены;
# 2 — прогон не проводился: неверный аргумент, нет гейта с таким именем,
# конфигурация есть, а прочитать её нечем.
set -uo pipefail

# bash 4.4+. На bash 3.2 (по умолчанию в macOS) mapfile — ошибка выполнения:
# список гейтов оказывался пустым, и строй мог объявить «пройдено», ничего
# не проверив. Модуль ставится отдельно от std-core, поэтому проверка своя,
# та же по смыслу, что bash-min.sh: найти новый bash и перезапуститься,
# иначе остановиться с кодом 2 — «прогон не проводился».
_have="${STD_TEST_BASH_VERSION:-${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}}"
[ -n "${STD_BASH_REEXEC:-}" ] && _have="${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"
_maj=${_have%%.*}; _min=${_have#*.}; _min=${_min%%.*}
if [ "$_maj" -lt 4 ] || { [ "$_maj" -eq 4 ] && [ "$_min" -lt 4 ]; }; then
  if [ -z "${STD_BASH_REEXEC:-}" ]; then
    for _b in ${STD_BASH_CANDIDATES-/opt/homebrew/bin/bash /usr/local/bin/bash /opt/local/bin/bash /run/current-system/sw/bin/bash /nix/var/nix/profiles/default/bin/bash}; do
      [ -x "$_b" ] || continue
      "$_b" -c '[ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 4 ]; }' 2>/dev/null || continue
      # shellcheck disable=SC2093  # exec в цикле: следующий кандидат — только если этот не запустился
      STD_BASH_REEXEC=1 exec "$_b" "${BASH_SOURCE[0]}" ${1+"$@"}
    done
  fi
  echo "gauntlet.sh требует bash 4.4 или новее, а запущен bash $_have. Прогон не проводился. Поставь: brew install bash" >&2
  exit 2
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
CFG="$PROJECT_DIR/.claude/gauntlet.json"
MARK="$PROJECT_DIR/.claude/.gauntlet-pass"
# Команды гейтов могут ссылаться на скрипты модуля — например мутация данных
# спецификации. Путь подставляется здесь, чтобы в конфигурации проекта его
# не хардкодили: при обновлении плагина он меняется.
STD_GAUNTLET_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export STD_GAUNTLET_ROOT
SCRIPTS="$STD_GAUNTLET_ROOT/scripts"
MODE="full"; ONLY=""

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
red()  { printf '\033[31m%s\033[0m\n' "$*"; }
ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }
usage() { echo "использование: gauntlet.sh [--fast | --only <гейт> | --list]"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fast) MODE="fast"; shift ;;
    --list) MODE="list"; shift ;;
    # Без имени прогон раньше зависал: shift 2 при одном аргументе не сдвигает
    # ничего, и цикл крутился вечно.
    --only)
      if [[ -z "${2:-}" || "$2" == --* ]]; then
        echo "--only: не указано имя гейта" >&2; usage >&2; exit 2
      fi
      ONLY="$2"; shift 2 ;;
    --only=?*) ONLY="${1#--only=}"; shift ;;
    # Неизвестный аргумент раньше молча пропускался: опечатка в --fast давала
    # полный прогон, опечатка в --only — прогон вообще без гейтов.
    *) echo "неизвестный аргумент: $1" >&2; usage >&2; exit 2 ;;
  esac
done

have() { [[ -e "$PROJECT_DIR/$1" ]]; }

# --- Конфигурация читается или прогон не проводится ---------------------------
# Без jq .claude/gauntlet.json раньше молча не читался, и шли гейты по
# умолчанию: настроенные security и e2e не запускались, а прогон зеленел
# и ставил отметку для коммита. Прогон не тех проверок хуже отсутствия
# прогона — он выглядит как проверка.
if [[ -f "$CFG" ]]; then
  if ! command -v jq >/dev/null 2>&1; then
    red "конфигурация гейтов есть (.claude/gauntlet.json), а прочитать её нечем: на машине нет jq."
    echo "Гейты по умолчанию вместо настроенных — прогон не тех проверок; он не проводится."
    echo "Поставь jq (apt install jq / brew install jq)."
    exit 2
  fi
  if ! jq -e 'type == "object"' "$CFG" >/dev/null 2>&1; then
    red ".claude/gauntlet.json не разбирается как JSON-объект — прогон не проводится."
    exit 2
  fi
fi

# Мутация КОДА (infection, stryker, mutmut) — к ней применяется храповик
# и ограничение изменёнными файлами. Мутация ДАННЫХ спецификации живёт
# по другому правилу: выживший мутант там означает, что тест не связан
# с требованием, и послаблений на этот счёт не бывает.
#
# Узнаётся не только по имени. Гейт «infection» с $MSI в команде при храповике
# получал выключенный порог (MSI=0) и в храповик не шёл — не проверялось
# ничего, и 10% при планке 70 проходили.
is_code_mutation() { # <имя> <команда>
  [[ "$1" == spec-* ]] && return 1
  [[ "$1" == *mutation* ]] && return 0
  # shellcheck disable=SC2016  # ищем буквальный текст $MSI в команде
  [[ "$2" == *'$MSI'* || "$2" == *'${MSI}'* ]] && return 0
  grep -qE '(^|[^[:alnum:]_-])(infection|stryker|mutmut)([^[:alnum:]_-]|$)' <<<"$2"
}

# --- Дефолты по стеку ---------------------------------------------------------
# Порядок гейтов не случаен: дешёвые и быстрые идут первыми, чтобы очевидная
# ошибка обнаружилась за секунды, а не после десятиминутной мутации.
#
# Гейт `debt` намеренно повторяет прогон анализатора, уже сделанный в `types`,
# и это не расточительство, а разные вопросы. `types` спрашивает «ошибок ноль?»
# — на существующем проекте ответ «нет», гейт красный всегда и его отключают
# в первый день. `debt` спрашивает «ошибок не больше, чем было?» — на этот
# вопрос проект может отвечать «да» с самого начала, и планка опускается
# по мере того, как тронутые файлы приводятся к правилам.
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
  # Покрытие изменённых строк. Ставится там, где вообще есть тесты: отчёта
  # может ещё не быть, и это не повод не иметь гейта — при отсутствии отчёта
  # он честно скажет «не проверено» (код 3), а прогон от этого не покраснеет.
  if have composer.json || have package.json || have pyproject.toml || have requirements.txt; then
    echo "diff-coverage|python3 \"\$STD_GAUNTLET_ROOT\"/scripts/diff-coverage.py"
  fi
  # Долг считается там, где есть чем считать. Скрипт сам разберётся, каким
  # инструментом, и промолчит, если ни одного нет, — гейт «нечем измерить»
  # не должен валить прогон, но и молчать о себе тоже не должен.
  if have vendor/bin/phpstan || have node_modules/.bin/eslint \
     || have pyproject.toml || have requirements.txt; then
    echo "debt|\"\$STD_GAUNTLET_ROOT\"/scripts/debt.sh check"
  fi
}

# --- Гейты из конфига проекта, если он есть -----------------------------------
# Раздел gates заменяет дефолты целиком: порядок и состав — решение проекта.
# /std-core:setup поэтому записывает туда и diff-coverage с debt.
read_gates() {
  if [[ -f "$CFG" ]] && jq -e 'has("gates")' "$CFG" >/dev/null 2>&1; then
    jq -r '.gates | to_entries[] | select(.value | type == "string") | "\(.key)|\(.value)"' "$CFG"
    return
  fi
  default_gates
}

# --- Режим мутационного гейта -------------------------------------------------
# absolute — фиксированный порог. Годится там, где качество уже высокое.
# ratchet  — планка равна лучшему достигнутому: улучшать не обязательно,
#            ухудшать нельзя. Единственный режим, работающий на легаси, где
#            любой достижимый абсолютный порог бесполезен, а полезный —
#            недостижим и потому будет отключён.
MUT_ENABLED="true"; MUT_MODE="absolute"; MSI=70; MUT_CHANGED_ONLY="false"
if [[ -f "$CFG" ]]; then
  # enabled: false раньше не читался вовсе: после смены профиля на prototype
  # мутационный гейт оставался в gates и продолжал запускаться.
  [[ "$(jq -r '.mutation.enabled' "$CFG" 2>/dev/null)" == "false" ]] && MUT_ENABLED="false"
  m=$(jq -r '.mutation.mode // "absolute"' "$CFG" 2>/dev/null); [[ -n "$m" && "$m" != "null" ]] && MUT_MODE="$m"
  t=$(jq -r '.mutation.threshold // .mutation.minMsi // empty' "$CFG" 2>/dev/null); [[ -n "$t" && "$t" != "null" ]] && MSI="$t"
  c=$(jq -r '.mutation.changedOnly // false' "$CFG" 2>/dev/null); [[ "$c" == "true" ]] && MUT_CHANGED_ONLY="true"
fi
case "$MUT_MODE" in
  absolute|ratchet) ;;
  # Опечатка в режиме раньше тихо давала absolute с порогом 70
  *) red "mutation.mode: неизвестный режим «$MUT_MODE» — ожидается absolute или ratchet"; exit 2 ;;
esac
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

# --- --only: гейт или семейство -------------------------------------------------
# Раньше неизвестное имя не совпадало ни с одним гейтом, не запускалось ничего,
# и печаталось «ВСЕ ГЕЙТЫ ПРОЙДЕНЫ». Скилл mutation-harden при этом звал
# --only mutation, а гейты по умолчанию называются js-mutation и py-mutation.
if [[ -n "$ONLY" ]]; then
  SELECTED=()
  for g in "${GATES[@]}"; do [[ "${g%%|*}" == "$ONLY" ]] && SELECTED+=("$g"); done
  if [[ ${#SELECTED[@]} -eq 0 ]]; then
    for g in "${GATES[@]}"; do
      n="${g%%|*}"
      if [[ "$ONLY" == "mutation" ]]; then
        is_code_mutation "$n" "${g#*|}" && SELECTED+=("$g")
      elif [[ "$n" == *-"$ONLY" ]]; then
        SELECTED+=("$g")
      fi
    done
  fi
  if [[ ${#SELECTED[@]} -eq 0 ]]; then
    red "нет гейта «$ONLY»"
    printf 'Есть: '; for g in "${GATES[@]}"; do printf '%s ' "${g%%|*}"; done; echo
    exit 2
  fi
  GATES=("${SELECTED[@]}")
fi

if [[ "$MODE" == "list" ]]; then
  bold "Гейты проекта (порог мутации: ${MSI}%, режим: $MUT_MODE):"
  for g in "${GATES[@]}"; do
    note=""
    if is_code_mutation "${g%%|*}" "${g#*|}"; then
      [[ "$MUT_ENABLED" == "false" ]] && note="  [выключен: mutation.enabled = false]"
      [[ "$MUT_ENABLED" == "true" && "$MUT_MODE" == "ratchet" ]] && note="  [храповик]"
    fi
    printf '  %-12s %s%s\n' "${g%%|*}" "${g#*|}" "$note"
  done
  exit 0
fi

# --- Отпечаток рабочего дерева --------------------------------------------------
# По отметке успешного прогона guard-commit.sh решает, проверено ли то, что
# уходит в коммит. Отпечаток снимается ДО прогона: проверено то, что лежало
# на диске в начале. Раньше отметка ставилась в конце, и правка, сделанная
# во время долгого фонового прогона, считалась проверенной.
fingerprint() { CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$SCRIPTS/worktree-fingerprint.sh" "$@" 2>/dev/null; }

WRITE_MARK=0; FP_START=""; FP_RC=0
if [[ "$MODE" == "full" && -z "$ONLY" ]]; then
  WRITE_MARK=1
  # Прогон, который провалится или не дойдёт до конца, не должен оставить
  # в силе отметку прошлого успеха.
  rm -f "$MARK"
  FP_START=$(fingerprint); FP_RC=$?
fi

write_mark() {
  local end p tracked=() artifacts=() ex=()
  mkdir -p "$PROJECT_DIR/.claude"
  if [[ $FP_RC -eq 3 ]]; then
    # Не git: снять отпечаток не из чего. Отметка — время, как раньше;
    # guard-commit сравнит с ним время изменения файлов.
    date -u +%s > "$MARK"
    return 0
  fi
  if [[ $FP_RC -ne 0 || -z "$FP_START" ]]; then
    ylw "  отпечаток рабочего дерева не снят (ошибка git) — отметка для коммита не поставлена"
    return 1
  fi
  end=$(fingerprint) || { ylw "  отпечаток рабочего дерева не снят — отметка для коммита не поставлена"; return 1; }
  if [[ "$end" != "$FP_START" ]]; then
    while IFS= read -r -d '' p; do
      if [[ -n "$(git -C "$PROJECT_DIR" ls-files -- ":(top,literal)$p" 2>/dev/null)" ]] \
         || git -C "$PROJECT_DIR" cat-file -e "HEAD:$p" 2>/dev/null; then
        tracked+=("$p")
      else
        artifacts+=("$p")
      fi
    done < <(git -C "$PROJECT_DIR" diff-tree -r -z --name-only --no-renames "$FP_START" "$end" 2>/dev/null)
    if (( ${#tracked[@]} )); then
      ylw "  за время прогона изменились отслеживаемые файлы: ${tracked[*]:0:5}"
      ylw "  проверено не то, что лежит на диске сейчас, — отметка для коммита не поставлена;"
      ylw "  прогони ещё раз, когда правки закончатся"
      return 1
    fi
    # Неотслеживаемые файлы, которые изменил сам прогон (отчёты покрытия,
    # логи мутаций), в отпечаток не входят: иначе он устаревал бы в момент
    # окончания прогона. Но и молчать о них нельзя — их место в .gitignore.
    for p in ${artifacts[@]+"${artifacts[@]}"}; do
      [[ "$p" == *$'\n'* ]] || ex+=(--exclude "$p")
    done
    end=$(fingerprint ${ex[@]+"${ex[@]}"}) || return 1
    ylw "  прогон записал неотслеживаемые файлы: ${artifacts[*]:0:5}"
    echo "  в сверку перед коммитом они не входят; отчётам и логам место в .gitignore"
  fi
  {
    echo "# Отметка успешного прогона гейтов: пишет gauntlet.sh, сверяет guard-commit.sh."
    echo "time $(date -u +%s)"
    echo "fingerprint $end"
    for p in ${artifacts[@]+"${artifacts[@]}"}; do
      [[ "$p" == *$'\n'* ]] || printf 'exclude %s\n' "$p"
    done
  } > "$MARK.tmp" && mv "$MARK.tmp" "$MARK"
}

# --- Mutation score из вывода инструмента ---------------------------------------
# Порядок разбора важен:
#   Infection — «Mutation Score Indicator (MSI): 40%». Ниже идут «Mutation Code
#     Coverage» и «Covered Code MSI»; последняя обычно выше MSI, и раньше
#     храповик брал именно её — последнее число рядом со словом msi;
#   Stryker — строка «All files | 15.38 | …» итоговой таблицы, первая колонка —
#     счёт по всем мутантам. Строки «Final mutation score …» без порога break
#     нет вовсе, и раньше число не находилось;
#   mutmut — сводка из эмодзи: 🎉 убиты, ⏰ таймаут (тоже убиты), 🤔 и 🙁
#     выжили, 🫥 без тестов, 🔇 пропущены (в счёт не идут);
#   остальное — «mutation score: 63.45%».
ESC=$'\033'
emoji_count() { # <строка> <эмодзи>
  local n; n=$(grep -oE "$2[[:space:]]*[0-9]+" <<<"$1" | grep -oE '[0-9]+$' | tail -1)
  printf '%s' "${n:-0}"
}
mutation_score() { # <лог> → целая часть или пусто
  local text s line k t q sv nt total
  text=$(sed "s/${ESC}\[[0-9;]*[A-Za-z]//g" "$1" | tr '\r' '\n')
  s=$(grep -aoiE 'mutation score indicator[^0-9]{0,16}[0-9]+([.,][0-9]+)?' <<<"$text" | tail -1 | grep -oE '[0-9]+([.,][0-9]+)?$')
  if [[ -z "$s" ]]; then
    s=$(grep -aE '^[[:space:]]*All files[[:space:]]*\|' <<<"$text" | tail -1 \
        | awk -F'|' '{ gsub(/[[:space:]]/, "", $2); print $2 }' | grep -oE '^[0-9]+([.,][0-9]+)?$')
  fi
  if [[ -z "$s" ]]; then
    line=$(grep -a '🎉' <<<"$text" | grep -a '🙁' | tail -1)
    if [[ -n "$line" ]]; then
      k=$(emoji_count "$line" '🎉'); t=$(emoji_count "$line" '⏰'); q=$(emoji_count "$line" '🤔')
      sv=$(emoji_count "$line" '🙁'); nt=$(emoji_count "$line" '🫥')
      total=$(( k + t + q + sv + nt ))
      (( total > 0 )) && s=$(( (k + t) * 100 / total ))
    fi
  fi
  if [[ -z "$s" ]]; then
    s=$(grep -aoiE 'mutation score( of)?[^0-9]{0,16}[0-9]+([.,][0-9]+)?' <<<"$text" | tail -1 | grep -oE '[0-9]+([.,][0-9]+)?$')
  fi
  [[ -n "$s" ]] && printf '%s' "${s%%[.,]*}"
}

# --- Прогон -------------------------------------------------------------------
declare -a NAMES STATUS
FAILED=0
LOGDIR=$(mktemp -d)
trap 'rm -rf "$LOGDIR"' EXIT

i=0
for g in "${GATES[@]}"; do
  name="${g%%|*}"; cmd="${g#*|}"; i=$((i + 1)); log="$LOGDIR/$i.log"
  code_mut=0; is_code_mutation "$name" "$cmd" && code_mut=1

  if [[ $code_mut -eq 1 && "$MUT_ENABLED" == "false" ]]; then
    NAMES+=("$name"); STATUS+=("выключен"); continue
  fi
  if [[ "$MODE" == "fast" && ( $code_mut -eq 1 || "$name" == *mutation* ) ]]; then
    NAMES+=("$name"); STATUS+=("пропущен"); continue
  fi

  printf '\n'; bold "▸ $name"

  # На большом проекте полный мутационный прогон идёт часами. Ограничение
  # изменёнными файлами превращает его в проверку, которую реально запускают.
  # У Stryker флага --since нет (прогон падал с «unknown option»):
  # инкрементальный режим пересчитывает только затронутых мутантов.
  if [[ $code_mut -eq 1 && "$MUT_CHANGED_ONLY" == "true" ]]; then
    case "$cmd" in
      *infection*) cmd="$cmd --git-diff-filter=AM" ;;
      *stryker*)   cmd="$cmd --incremental" ;;
    esac
  fi

  # Один eval, в каталоге проекта. Раньше команду сначала раскрывали через
  # eval "echo …", и тот снимал кавычки: путь модуля с пробелом ломал гейты
  # debt и diff-coverage. $MSI и $STD_GAUNTLET_ROOT экспортированы.
  ( cd "$PROJECT_DIR" && eval "$cmd" ) > "$log" 2>&1
  rc=$?

  # --- Храповик вместо порога инструмента -------------------------------------
  if [[ $code_mut -eq 1 && "$MUT_MODE" == "ratchet" ]]; then
    score=$(mutation_score "$log")
    if [[ -n "$score" ]]; then
      if CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$SCRIPTS/ratchet.sh" check "$score" 2>&1 | sed 's/^/  /'; then
        rc=0
      else
        rc=1
      fi
    else
      # При храповике порог самого инструмента выключен (MSI=0). Без числа
      # не проверено ничего — раньше здесь печаталось «храповик пропущен»,
      # и гейт проходил с любым результатом.
      red "  не удалось извлечь mutation score из вывода — гейт не пройден"
      echo "  При храповике порог инструмента выключен, и без числа не проверено ничего."
      echo "  Посмотри, дошёл ли инструмент до отчёта (вывод ниже), либо задай"
      echo "  mutation.mode = absolute — тогда решает порог самого инструмента."
      rc=1
    fi
  fi

  # Код 3 у гейта покрытия означает «мерить нечем»: отчёта нет, тесты гоняли
  # без него, в неглубоком клоне нет общего предка. Это не провал работы, но
  # и не успех — прогон продолжается, а в итоге стоит «не проверено».
  # Молчаливое «пройден» здесь было бы худшим вариантом: гейт есть, зелёный,
  # а покрытие никто не считал.
  #
  # Именно 3, а не 2: двойку печатает сам Python — на опечатке в пути
  # к скрипту, на ошибке аргументов. Раньше такой сбой читался как «нет
  # отчёта», и сломанный гейт не валил прогон.
  if [[ ( "$name" == "diff-coverage" || "$cmd" == *diff-coverage.py* ) && $rc -eq 3 ]]; then
    ylw "  не проверено"
    sed -n '1,6p' "$log" | sed 's/^/    /'
    NAMES+=("$name"); STATUS+=("не проверено"); continue
  fi

  if [[ $rc -eq 0 ]]; then
    grn "  пройден"; NAMES+=("$name"); STATUS+=("ок")
  else
    red "  ПРОВАЛЕН (код $rc)"
    tail -25 "$log" | sed 's/^/    /'
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
  if [[ $WRITE_MARK -eq 1 ]]; then
    write_mark
    grn "ВСЕ ГЕЙТЫ ПРОЙДЕНЫ"
  else
    # Неполный прогон отметку для коммита не ставит — и говорит об этом,
    # чтобы «пройдено» по одному гейту не читалось как «можно коммитить».
    grn "ВЫБРАННЫЕ ГЕЙТЫ ПРОЙДЕНЫ"
    echo "Это не полный прогон: отметка для коммита не ставится."
  fi
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
