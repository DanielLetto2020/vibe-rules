#!/usr/bin/env bash
# guard-infra.sh — PreToolUse: правки инфраструктуры и всего, что нельзя откатить тестом.
#
# Тесты проверяют поведение приложения. Они не видят, что реплик стало 0,
# что секрет попал в манифест, что миграция удаляет колонку, что playbook
# получил новый хост. Цена ошибки здесь измеряется не багом, а простоем.
#
# Поэтому: не запрет, а обязательная пара человеческих глаз (ask).
# Запрет остановил бы работу; эскалация оставляет решение человеку.
set -uo pipefail

INPUT=$(cat)

# std:hooks-off — человек отключил замки в этом проекте (.claude/std-hooks-off).
# Правила при этом остаются и грузятся как раньше: стандарт возвращается
# к тексту без проверки. Что замки выключены, напоминает session-check.sh —
# единственный хук, которого маркер не глушит.
[[ -f "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/std-hooks-off" ]] && exit 0

# --- std:jq-guard — решение печатается своими силами --------------------------
# Отсутствие jq раньше означало пустое поле и тихий выход, то есть выключенный
# замок без единого признака поломки.
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
  emit ask "Замок на инфраструктуру не может прочитать запрос: нет ни jq, ни python3. Правка не пропускается молча — подтверди её сам или поставь jq."
fi
[[ -z "$FILE" ]] && exit 0

ask() { emit ask "$1"; }

base=$(basename "$FILE")
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
REL="${FILE#"$PROJECT_DIR"/}"

# --- 0. Сам механизм проверок --------------------------------------------------
# Периметр обязан охранять собственные ворота. Правка настроек хуков, списка
# разрешений или скрипта замка отключает всё остальное разом — и делает это
# тише, чем любое изменение в коде: тесты останутся зелёными, потому что
# проверять станет некому.
if printf '%s' "$REL" | grep -qE '(^|/)\.claude/std-hooks-off$'; then
  ask "Этот файл выключает все замки стандартов разом и до самого своего удаления. Выключать их можно, но это решение человека и принимается оно один раз явно — командой /std-core:setup --no-hooks, а не правкой файла по ходу задачи."
fi
if printf '%s' "$REL" | grep -qE '(^|/)\.claude/settings(\.local)?\.json$'; then
  ask "Правка $REL меняет настройки хуков и разрешений — тот слой, которым проверяется всё остальное. Ослабление здесь не видно ни в одном тесте. Прочитай диff глазами."
fi
if printf '%s' "$REL" | grep -qE '(^|/)\.claude/(gauntlet|std-guard|policy)\.json$'; then
  ask "Правка $REL меняет строгость проверок проекта (гейты, замки, политику). Понижение планки должно быть решением человека, а не побочным эффектом задачи."
fi
if printf '%s' "$REL" | grep -qE '(^|/)\.claude/rules/'; then
  ask "Правка правил проекта ($base). Это то, чем описан здешний стандарт: изменение действует на все будущие сессии."
fi
if printf '%s' "$REL" | grep -qE '(^|/)\.githooks/|(^|/)\.git/hooks/'; then
  ask "Правка git-хука ($base). Он выполняется при каждом коммите и push — ошибка здесь отключает проверки молча."
fi
if printf '%s' "$REL" | grep -qE '(^|/)(hooks\.json)$|(^|/)scripts/(guard|secret|session|rules)-[a-z-]+\.sh$'; then
  ask "Правка самого механизма проверок ($base). Замок, который правит собственный замок, — это не проверка. Подтверди осознанно."
fi

# --- 1. Миграции БД ------------------------------------------------------------
# Откат кода занимает минуту, откат удалённых данных не занимает ничего.
if printf '%s' "$FILE" | grep -qE '(migrations?|migrate)/.*\.(php|py|sql|js|ts)$'; then
  # Новый файл миграции — нормальный ход работы. Правка уже применённой — нет.
  if [[ -e "$FILE" ]]; then
    ask "Правка существующей миграции ($base). Если она уже применена где-то кроме твоей машины, изменение файла не изменит состояние тех баз — нужна новая миграция. Подтверди."
  fi
  exit 0
fi

# --- 2. Kubernetes и Helm ------------------------------------------------------
if printf '%s' "$FILE" | grep -qE '(^|/)(k8s|kubernetes|manifests|charts?|helm|deploy(ment)?)/.*\.ya?ml$' \
   || [[ "$base" == "Chart.yaml" || "$base" == "values.yaml" ]]; then
  ask "Правка манифеста Kubernetes ($base). Тесты приложения не покрывают реплики, лимиты, probe'ы и секреты — ошибка здесь роняет прод целиком. Прочитай диff глазами."
fi

# --- 3. Ansible ----------------------------------------------------------------
if printf '%s' "$FILE" | grep -qE '(^|/)(ansible|playbooks?|roles)/.*\.ya?ml$' \
   || [[ "$base" == "playbook.yml" || "$base" == "site.yml" || "$base" == "hosts" || "$base" == "inventory" ]]; then
  ask "Правка Ansible ($base). Playbook выполняется на живых машинах и обычно необратим. Проверь inventory и идемпотентность задач."
fi

# --- 4. CI/CD — слой, который охраняет все остальные ---------------------------
if printf '%s' "$FILE" | grep -qE '(\.github/workflows/|\.gitlab-ci\.yml|Jenkinsfile|\.circleci/)'; then
  ask "Правка конфигурации CI ($base). Это тот слой, которым проверяется всё остальное: ослабив его, система перестаёт ловить ошибки молча."
fi

# --- 5. Контейнеры и compose ---------------------------------------------------
if [[ "$base" == "Dockerfile" || "$base" == "Containerfile" ]] \
   || printf '%s' "$base" | grep -qE '^(docker-)?compose\.ya?ml$'; then
  ask "Правка $base. Проверь: не появился ли образ с плавающим тегом latest, не пробрасываются ли секреты аргументами сборки, не запускается ли процесс от root."
fi

# --- 6. Прод-конфиги и секреты -------------------------------------------------
if printf '%s' "$base" | grep -qE '^\.env(\.(prod|production|stage|staging))?$'; then
  ask "Правка файла окружения ($base). Реальные значения в git попадать не должны — только в .env.example и только плейсхолдерами."
fi

exit 0
