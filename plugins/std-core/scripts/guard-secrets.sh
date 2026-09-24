#!/usr/bin/env bash
# guard-secrets.sh — PreToolUse: чтение файла, который целиком является секретом.
#
# Закрывает дыру, которую не видит ни один линтер и не ловил ни один замок:
# прочитанный секрет попадает в контекст модели. Дальше он уезжает провайдеру,
# остаётся в истории сессии на диске и может всплыть где угодно — в примере
# кода, в фикстуре теста, в сообщении коммита. Момент утечки — не запись,
# а именно чтение, и после него отменить уже нечего.
#
# Решение — ask, а не deny. Прочитать .env иногда действительно нужно, и замок,
# который это запрещает совсем, отключают вместе со всеми остальными. Вопрос
# называет цену и предлагает способ обойтись без значений.
#
# Вход:  JSON на stdin (tool_name, tool_input.file_path | .path)
# Выход: exit 0 + JSON с permissionDecision: ask | (пусто = обычный поток)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/bash-min.sh"; std_bash_min pre "${BASH_SOURCE[0]}"   # до чтения stdin
INPUT=$(cat)

# std:hooks-off — человек отключил замки в этом проекте (.claude/std-hooks-off).
# Этот хук молчит целиком; правила остаются и грузятся как раньше. Запреты
# на необратимое маркер не снимает — они живут в guard-bash.sh и работают
# всегда. Что замки выключены, напоминает session-check.sh: единственный хук,
# которого маркер не глушит.
[[ -f "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/std-hooks-off" ]] && exit 0
. "$(dirname "${BASH_SOURCE[0]}")/secret-lib.sh"

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

# --- std:jq-guard — молчаливый пропуск здесь равен выключенной проверке -------
read_input() { # -> две строки: путь, маска Grep
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$INPUT" | jq -r '(.tool_input.file_path // .tool_input.path // ""),
                                  (.tool_input.glob // "")' 2>/dev/null
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$INPUT" | python3 -c 'import json,sys
try:
    t = json.load(sys.stdin).get("tool_input", {})
    print(t.get("file_path") or t.get("path") or "")
    print(t.get("glob") or "")
except Exception:
    pass' 2>/dev/null
    return 0
  fi
  return 1
}

# Маска Grep раскрывается в имена файлов, а не задаёт путь, и проверять
# её по пути бессмысленно. При этом маска перекрывает .gitignore: Grep
# с glob ".env*" печатал строки из игнорируемого .env, пока замок смотрел
# только на path. Поэтому маска сверяется с образцами имён секретов:
# совпала хоть с одним — это чтение секрета, как и Read.
SECRET_SAMPLES=(.env .env.local .env.production prod.env id_rsa id_ed25519
  server.pem server.key cert.p12 .npmrc .pypirc .netrc .git-credentials .pgpass
  auth.json credentials.json prod.tfvars terraform.tfstate secrets.yaml kubeconfig)

# Одна пара фигурных скобок раскрывается вручную, без eval: маска приходит
# от модели, и исполнять её нельзя ни в каком виде.
expand_braces() { # <маска> -> варианты по строке
  local g="$1" pre body post alt
  if [[ "$g" =~ ^([^{]*)\{([^{}]*)\}(.*)$ ]]; then
    pre=${BASH_REMATCH[1]}; body=${BASH_REMATCH[2]}; post=${BASH_REMATCH[3]}
    local IFS=,
    for alt in $body; do expand_braces "$pre$alt$post"; done
  else
    printf '%s\n' "$g"
  fi
}

# Совпадение маски с образцом говорит о намерении, а не о факте: под «*.json»
# попадает и auth.json, но спрашивать о каждом поиске по JSON — значит
# приучить нажимать «да» не читая. Поэтому, если каталог поиска есть на диске,
# решает факт: нашёлся под маской файл-секрет — вопрос, нет — поиск свободен.
# Образцы остаются запасным путём, когда смотреть не на что.
glob_secret_kind() { # <маска Grep> <каталог поиска> -> вид секрета, код 0; иначе 1
  local root="$2" part name sample kind f
  local -a parts
  # Claude Code делит маску по пробелам и запятым вне скобок; делим так же.
  # read -a, а не for по $(...): иначе «*» раскрылась бы в файлы каталога.
  read -ra parts <<< "$(printf '%s' "$1" | sed -E ':a; s/(\{[^{},]*),([^{}]*\})/\1\x01\2/; ta; s/,/ /g')"
  for part in "${parts[@]}"; do
    part=${part//$'\x01'/,}
    [[ "$part" == \!* ]] && continue          # исключение ничего не добавляет
    while IFS= read -r name; do
      name=${name##*/}
      # Маска без единой буквы («*», «**/*») — это «все файлы», а не запрос
      # секрета. Спрашивать о ней — значит спрашивать о любом поиске.
      [[ "$name" =~ [A-Za-z0-9] ]] || continue
      if [[ -d "$root" ]]; then
        while IFS= read -r -d '' f; do
          kind=$(secret_path_kind "$f") && { printf '%s' "$kind"; return 0; }
        done < <(find "$root" -maxdepth 8 \( -name .git -o -name node_modules -o -name vendor \) -prune \
                   -o -type f -name "$name" -print0 2>/dev/null)
        continue
      fi
      kind=$(secret_path_kind "$name") && { printf '%s' "$kind"; return 0; }
      for sample in "${SECRET_SAMPLES[@]}"; do
        # shellcheck disable=SC2053  # правая часть — маска, так и задумано
        if [[ "$sample" == $name ]]; then
          secret_path_kind "$sample"; return 0
        fi
      done
    done < <(expand_braces "$part")
  done
  return 1
}

if ! RAW=$(read_input); then
  emit ask "Проверка на чтение секретов не работает: нет ни jq, ни python3. Подтверди осознанно, что этот файл не содержит ключей, или поставь jq."
fi
{ IFS= read -r FILE; IFS= read -r GLOB; } <<< "$RAW"

ROOT_DIR="${FILE:-${CLAUDE_PROJECT_DIR:-$PWD}}"
if [[ -n "$GLOB" ]] && KIND=$(glob_secret_kind "$GLOB" "$ROOT_DIR"); then
  emit ask "Маска поиска '$GLOB' захватывает файлы вида «$KIND». Маска Grep перекрывает .gitignore, поэтому найденные строки со значениями попадут в контекст модели: уедут провайдеру и останутся в истории сессии. Отменить это после чтения нельзя.

Если нужны только имена переменных — возьми их без значений:
  grep -oE '^[A-Za-z_][A-Za-z0-9_]*' .env
Если ищешь по коду — исключи секреты из маски или сузь её до исходников."
fi

[[ -z "$FILE" ]] && exit 0

# Ссылка проверяется по цели: app.conf -> .env читает тот же .env.
KIND=$(secret_path_kind "$FILE") \
  || { REAL=$(realpath -m -- "$FILE" 2>/dev/null) && [[ "$REAL" != "$FILE" ]] \
       && KIND=$(secret_path_kind "$REAL"); } \
  || exit 0

emit ask "$FILE — $KIND. Прочитанное попадёт в контекст модели: уедет провайдеру, останется в истории сессии на диске и может всплыть в коде, тесте или сообщении коммита. Отменить это после чтения нельзя.

Если нужны только имена переменных, а не значения — возьми их безопасно:
  grep -oE '^[A-Za-z_][A-Za-z0-9_]*' \"$FILE\"
Если нужна структура — читай образец рядом (.env.example).
Значения читай, только если задача без них не решается."
