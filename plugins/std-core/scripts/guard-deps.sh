#!/usr/bin/env bash
# guard-deps.sh — PreToolUse: прямая правка файлов зависимостей.
#
# guard-bash.sh перехватывает `composer require` и `npm install`. Но зависимость
# можно добавить и в обход — дописав строку в composer.json или package.json.
# Этот замок закрывает обходной путь.
#
# Почему это важнее, чем кажется: вредоносный пакет проходит все тесты, весь
# статический анализ и всё мутационное тестирование идеально. Это единственный
# вектор, который система автопроверок не закрывает в принципе.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/bash-min.sh"; std_bash_min pre "${BASH_SOURCE[0]}"   # до чтения stdin
INPUT=$(cat)

# std:hooks-off — человек отключил замки в этом проекте (.claude/std-hooks-off).
# Этот хук молчит целиком; правила остаются и грузятся как раньше. Запреты
# на необратимое маркер не снимает — они живут в guard-bash.sh и работают
# всегда. Что замки выключены, напоминает session-check.sh: единственный хук,
# которого маркер не глушит.
[[ -f "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/std-hooks-off" ]] && exit 0

# --- std:jq-guard — отсутствие разборщика не открывает ворота ------------------
json_escape() {
  local s="$1"; s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
  printf '%s' "$s"
}
emit() { # <deny|ask> <причина>
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' \
    "$1" "$(json_escape "$2")"
  exit 0
}
read_field() { # <поле в tool_input>
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$INPUT" | jq -r --arg f "$1" '.tool_input[$f] // empty' 2>/dev/null; return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$INPUT" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("tool_input", {}).get(sys.argv[1], "") or "", end="")
except Exception:
    pass' "$1" 2>/dev/null; return 0
  fi
  return 1
}

# Проект подключён к стандартам? Признак — конфигурация гейтов или слинкованные
# правила. Плагин ставится на машину и виден во всех проектах, но вмешиваться
# он должен только там, где стандарты приняли: иначе первый же чужой проект
# встречает вопросы, которых человек не просил, и замки отключают целиком.
project_uses_standards() {
  local d="${CLAUDE_PROJECT_DIR:-$PWD}"
  [[ -f "$d/.claude/gauntlet.json" ]] && return 0
  compgen -G "$d/.claude/rules/std-*" >/dev/null 2>&1 && return 0
  return 1
}

project_uses_standards || exit 0

if ! FILE=$(read_field file_path); then
  emit ask "Замок на зависимости не может прочитать запрос: нет ни jq, ни python3. Вредоносный пакет проходит все тесты идеально, поэтому молча пропустить правку нельзя — подтверди сам или поставь jq."
fi
[[ -z "$FILE" ]] && exit 0

base=$(basename "$FILE")
case "$base" in
  composer.json|package.json) KIND=json ;;
  requirements*.txt|constraints*.txt) KIND=req ;;
  pyproject.toml|Cargo.toml) KIND=toml ;;
  go.mod) KIND=gomod ;;
  *) exit 0 ;;
esac

# Новый файл — это создание проекта, а не подмена зависимости
[[ -e "$FILE" ]] || exit 0

NEW=$(read_field new_string); [[ -z "$NEW" ]] && NEW=$(read_field content)
# MultiEdit несёт правки массивом: без него текст пуст, а пустой текст —
# это не «ничего не добавлено», а «не смогли прочитать».
if [[ -z "$NEW" ]] && command -v jq >/dev/null 2>&1; then
  NEW=$(printf '%s' "$INPUT" | jq -r '[.tool_input.edits[]?.new_string // empty] | join("\n")' 2>/dev/null)
fi
if [[ -z "$NEW" ]]; then
  # Edit с пустой заменой — удаление строк: пакет из манифеста убирают,
  # а не подменяют. Всё остальное без текста — не проверено, значит вопрос.
  [[ "$(read_field old_string)" != "" ]] && exit 0
  emit ask "Правка зависимостей в $base, текст которой замок не смог прочитать. Проверь её сам: имя пакета, источник, число загрузок."
fi

# Похоже ли добавленное на зависимость. Раньше признаком было «значение
# начинается с цифры или ^~><=*», и это работало только для JSON: пять
# манифестов из шести не проверялись никогда, а в JSON проходили "latest",
# "github:user/repo", "git+https://…", "npm:другой-пакет@1", file: и link: —
# ровно те формы, которыми пакет подменяют.
Q="[\"']"
adds_dependency() {
  case "$KIND" in
    json)
      # Версия или источник пакета в значении
      # Построчно: метаданные (version, homepage) исключаются только своей
      # строкой, иначе поднятая версия рядом с новым пакетом пропускала бы его.
      printf '%s\n' "$NEW" \
        | grep -E "${Q}[a-z0-9@._/-]+${Q}[[:space:]]*:[[:space:]]*${Q}([\^~>=<0-9*]|latest|next|github:|gitlab:|bitbucket:|git\+|git:|https?:|file:|link:|npm:|[a-z0-9._-]+/[a-z0-9._-]+(#|${Q}))" \
        | grep -vE "^[[:space:]]*${Q}(name|version|description|homepage|url|main|module|types|license|author|funding|node|npm|php)${Q}[[:space:]]*:" \
        | grep -q . && return 0
      printf '%s' "$NEW" | grep -qE "${Q}[a-z0-9@._/-]+${Q}[[:space:]]*:[[:space:]]*${Q}([\^~>=<0-9*]|latest|github:|git\+|https?:|file:|link:|npm:)" \
        && printf '%s' "$NEW" | grep -qE "${Q}(dependencies|devDependencies|optionalDependencies|peerDependencies|require|require-dev)${Q}" \
        && return 0
      # Скрипты установки исполняются при npm install на каждой машине,
      # а источник пакетов composer подменяет их все разом.
      printf '%s' "$NEW" | grep -qE "${Q}(preinstall|install|postinstall|prepare)${Q}[[:space:]]*:" && return 0
      printf '%s' "$NEW" | grep -qE "${Q}repositories${Q}[[:space:]]*:|${Q}type${Q}[[:space:]]*:[[:space:]]*${Q}(vcs|git|path|artifact|package)${Q}" && return 0
      ;;
    req)
      # Любая значимая строка — зависимость: имя, git+, путь, индекс пакетов
      printf '%s\n' "$NEW" | grep -qvE '^[[:space:]]*(#|$)' && return 0
      ;;
    toml)
      # PEP 508 в массиве: "requests>=2", "evil @ git+…", "pkg"
      printf '%s' "$NEW" | grep -qE "^[[:space:]]*${Q}[A-Za-z0-9._-]+(\[[^]]*\])?[[:space:]]*([<>=!~]=?|@|;|${Q})" && return 0
      # Таблица Poetry/Cargo: имя = "версия" | { … }
      printf '%s' "$NEW" | grep -E "^[[:space:]]*[A-Za-z0-9._-]+[[:space:]]*=[[:space:]]*(${Q}[\^~<>=*0-9]|\{)" \
        | grep -qvE '^[[:space:]]*(version|edition|rust-version|requires-python|python|line-length|target-version)[[:space:]]*=' && return 0
      printf '%s' "$NEW" | grep -qE '(^|[[:space:]])(git|path|registry|index-url|extra-index-url)[[:space:]]*=' && return 0
      ;;
    gomod)
      printf '%s' "$NEW" | grep -qE '(^|[[:space:]])(require|replace)([[:space:]]|$)|^[[:space:]]*[a-z0-9.-]+\.[a-z]+/[^[:space:]]+[[:space:]]+v[0-9]' && return 0
      ;;
  esac
  return 1
}

adds_dependency || exit 0

emit ask "Правка зависимостей в $base. Пакет проходит любые тесты и линтеры идеально — этот риск автопроверками не закрывается. Проверь имя пакета (опечатка в имени популярного пакета — типовая атака), его источник и число загрузок."
