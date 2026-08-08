#!/usr/bin/env bash
# session-check.sh — SessionStart: самодиагностика подключения стандартов.
#
# Симлинк на правила ломается в двух случаях: репозиторий стандартов переехал
# или проект склонировали на другую машину. Молчаливо сломанное правило хуже
# отсутствующего — все думают, что оно работает. Хук замечает это на старте.
set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
RULES_DIR="$PROJECT_DIR/.claude/rules"

# Проект не подключён к стандартам — это нормально, молчим
[[ -d "$RULES_DIR" ]] || exit 0

json_escape() {
  local s="$1"; s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

# --- std:jq-guard — о поломке защиты человек узнаёт на старте сессии -----------
# Раньше при отсутствии jq этот хук просто выходил, а замки в это время молча
# ничего не проверяли. Теперь отсутствие разборщика — первое, что видно в сессии:
# сообщение печатается без jq, иначе предупреждать было бы нечем.
if ! command -v jq >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
  MSG="Ни jq, ни python3 не найдены. Замки не могут разобрать запросы и блокируют команды вместо тихого пропуска. Поставь jq: apt install jq / brew install jq / dnf install jq"
  printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' \
    "$(json_escape "$MSG")" \
    "$(json_escape "ВНИМАНИЕ: $MSG До установки считай, что автоматических проверок в этом проекте нет.")"
  exit 0
fi

broken=() ok=()
shopt -s nullglob
for l in "$RULES_DIR"/std-*; do
  if [[ -L "$l" && ! -d "$l" ]]; then
    broken+=("$(basename "$l")")
  elif [[ -d "$l" ]]; then
    ok+=("$(basename "$l")")
  fi
done
shopt -u nullglob

if [[ ${#broken[@]} -gt 0 ]]; then
  msg="Битые ссылки на стандарты: ${broken[*]}. Правила НЕ загружены. Почини: /std-core:update"
  printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' \
    "$(json_escape "$msg")" \
    "$(json_escape "ВНИМАНИЕ: $msg До починки не считай, что стандарты проекта тебе известны.")"
  exit 0
fi

NOTES=()

# --- Замки выключены ----------------------------------------------------------
# Этот хук единственный, кого маркер не глушит, и причина ровно одна: выключение
# должно оставаться видимым. Выключенная защита, о которой никто не напоминает,
# перестаёт быть решением и становится состоянием — «на время» превращается
# в «навсегда» за одну неделю. Поэтому цена называется на старте каждой сессии.
if [[ -f "$PROJECT_DIR/.claude/std-hooks-off" ]]; then
  NOTES+=("Вопросы замков в этом проекте выключены (.claude/std-hooks-off). Запреты на необратимое работают: удаление образов и томов, rm -rf по системным путям, drop и truncate, mkfs, force-push будут заблокированы, и обходить их не пытайся. Не проверяется остальное: правка существующих тестов, секреты при записи и в коммите, новые зависимости, соответствие соседним файлам. Это ровно те правила, которые теперь держатся на тебе, — соблюдай их сам, подтверждения об этом не будет. Вернуть проверки: /std-core:setup --hooks")
  HOOKS_WARN="Вопросы замков выключены (.claude/std-hooks-off). Запреты на удаляющее работают, но правка тестов, секреты при записи и в коммите и новые зависимости не проверяются. Вернуть: /std-core:setup --hooks"
fi

# --- Незакрытые секреты -------------------------------------------------------
# Проверяется один раз за сессию и именно здесь: замок на коммит скажет об этом
# в тот момент, когда работа уже сделана и человек торопится, а `git add .`
# случается раньше и без вопросов. Дешевле узнать на старте.
. "$(dirname "${BASH_SOURCE[0]}")/secret-lib.sh"

if git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  tracked=() exposed=()
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    secret_path_kind "$f" >/dev/null || continue
    if git -C "$PROJECT_DIR" ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
      tracked+=("$f")
    else
      exposed+=("$f")
    fi
  done < <(git -C "$PROJECT_DIR" ls-files -co --exclude-standard 2>/dev/null | head -500)

  if [[ ${#tracked[@]} -gt 0 ]]; then
    NOTES+=("В git уже отслеживаются файлы с доступами: ${tracked[*]}. Они в истории репозитория — удаление файла этого не отменяет. Скажи человеку, что нужно: убрать из индекса (git rm --cached), закрыть в .gitignore и ротировать значения.")
    SECRET_WARN="Секреты в git: ${tracked[*]} — файлы отслеживаются, значит уже в истории. Нужна ротация, а не удаление файла."
  fi
  if [[ ${#exposed[@]} -gt 0 ]]; then
    NOTES+=("Файлы с доступами не закрыты в .gitignore: ${exposed[*]}. Первый же 'git add .' увезёт их в историю. Предложи человеку добавить их в .gitignore.")
    SECRET_WARN="${SECRET_WARN:+$SECRET_WARN }Не в .gitignore: ${exposed[*]} — уедут при первом 'git add .'."
  fi
fi

# Требования профиля доносим до модели явно. Раньше они жили только
# в .claude/gauntlet.json, который читают скрипты, но не модель: настройка
# specFirst стояла, а поведение не менялось — и выглядело это как «правило
# не работает», хотя правило до модели просто не доезжало.
CFG="$PROJECT_DIR/.claude/gauntlet.json"

# Читаем тем же способом, что и замки: где есть jq — им, иначе python3.
# Одинаковое чтение важнее краткости: иначе на машине без jq замок считает
# профиль так, а подсказка модели — иначе, и расхождение никак не видно.
read_cfg() { # <ключ>
  [[ -f "$CFG" ]] || return 0
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$1" 'if has($k) then .[$k] else "" end' "$CFG" 2>/dev/null; return 0
  fi
  python3 -c 'import json,sys
try:
    v = json.load(open(sys.argv[1])).get(sys.argv[2], "")
    print("" if v == "" else json.dumps(v).strip(chr(34)), end="")
except Exception:
    pass' "$CFG" "$1" 2>/dev/null
}

[[ "$(read_cfg specFirst)" == "true" ]] \
  && NOTES+=("Прежде чем писать код новой функциональности, сформулируй критерий приёмки на человеческом языке, перечисли несчастливые пути и получи подтверждение. Тест, написанный после реализации, проверяет то, что получилось, а не то, что требовалось.")

[[ "$(read_cfg requireBeforeCommit)" == "true" ]] \
  && NOTES+=("Перед коммитом должны быть пройдены гейты проекта: /std-gauntlet:run.")

[[ "$(read_cfg profile)" == "legacy" ]] \
  && NOTES+=("Профиль проекта — legacy: спецификации нет, поведение известно частично. Прежде чем менять непокрытый тестами код, зафиксируй текущее поведение как эталон.")

[[ ${#NOTES[@]} -eq 0 ]] && exit 0

PROFILE=$(read_cfg profile); [[ -z "$PROFILE" ]] && PROFILE="не задан"
CTX="Профиль стандартов в этом проекте: $PROFILE."
for n in "${NOTES[@]}"; do CTX+=" $n"; done

# Про секреты и про выключенные замки человек должен узнать сам, а не через
# модель: эти решения принимает он (ротировать, переписать историю, вернуть
# проверки), и принимать их надо до того, как сессия начнёт что-то коммитить.
WARN="${HOOKS_WARN:-}"
[[ -n "${SECRET_WARN:-}" ]] && WARN="${WARN:+$WARN }$SECRET_WARN"
if [[ -n "$WARN" ]]; then
  printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' \
    "$(json_escape "$WARN")" "$(json_escape "$CTX")"
  exit 0
fi

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$(json_escape "$CTX")"
exit 0
