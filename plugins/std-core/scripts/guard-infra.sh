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
FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[[ -z "$FILE" ]] && exit 0

ask() {
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
  exit 0
}

base=$(basename "$FILE")

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
