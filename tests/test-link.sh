#!/usr/bin/env bash
# test-link.sh — тесты автодетекта стека и линковки правил.
#
# Первый кейс этого файла появился из настоящего бага: grep со списком, где
# часть файлов не существует, возвращает код 2, и под set -o pipefail это
# выглядело как «postgres не найден». Молчаливо не подключённый модуль —
# ровно тот класс ошибок, ради которого здесь вообще есть тесты.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LINK="$ROOT/plugins/std-core/scripts/std-link.sh"
PASS=0; FAIL=0
ok()  { printf '  \033[32mOK\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n     ожидали: %s\n     получили: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# linked <проект> -> отсортированный список подключённых модулей одной строкой
linked() {
  local p="$1"
  find "$p/.claude/rules" -maxdepth 1 -name 'std-*' -printf '%f\n' 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//'
}

case_detect() { # <описание> <подготовка-проекта> <ожидаемый список>
  local desc="$1" setup="$2" want="$3"
  local p="$TMP/p$RANDOM"; mkdir -p "$p"
  ( cd "$p" && eval "$setup" )
  VIBE_RULES_HOME="$ROOT" CLAUDE_PROJECT_DIR="$p" bash "$LINK" --auto >/dev/null 2>&1
  local got; got=$(linked "$p")
  [[ "$got" == "$want" ]] && ok "$desc" || bad "$desc" "$want" "$got"
}

echo "== автодетект стека =="
# std-core и std-gauntlet подключаются всегда: базовые правила и конвейер
# проверок нужны любому проекту независимо от стека.

case_detect "Laravel + Postgres" \
  'echo "{\"require\":{\"laravel/framework\":\"^11.0\"}}" > composer.json; echo "DB_CONNECTION=pgsql" > .env.example' \
  "std-core std-gauntlet std-php-base std-php-laravel std-sql-postgres"

case_detect "голый PHP без фреймворка — правила языка всё равно есть" \
  'mkdir -p src; printf "<?php\nclass A {}\n" > src/A.php' \
  "std-core std-gauntlet std-php-base"

case_detect "Yii 2" \
  'echo "{\"require\":{\"yiisoft/yii2\":\"^2.0\"}}" > composer.json' \
  "std-core std-gauntlet std-php-base std-php-yii2"

case_detect "Vue 3 без Nuxt" \
  'echo "{\"dependencies\":{\"vue\":\"^3.4\"}}" > package.json' \
  "std-core std-gauntlet std-js-base std-js-vue3"

case_detect "Nuxt поглощает Vue — двух модулей быть не должно" \
  'echo "{\"dependencies\":{\"nuxt\":\"^3.14\",\"vue\":\"^3.5\"}}" > package.json' \
  "std-core std-gauntlet std-js-base std-js-nuxt"

case_detect "Playwright" \
  'echo "{\"devDependencies\":{\"@playwright/test\":\"^1.49\"}}" > package.json' \
  "std-core std-gauntlet std-js-base std-js-playwright"

case_detect "FastAPI + Redis" \
  'printf "[project]\ndependencies = [\"fastapi\", \"redis\"]\n" > pyproject.toml' \
  "std-cache-redis std-core std-gauntlet std-py-base std-py-fastapi"

case_detect "Python-парсер" \
  'printf "[project]\ndependencies = [\"httpx\", \"beautifulsoup4\"]\n" > pyproject.toml' \
  "std-core std-gauntlet std-py-base std-py-parsers"

case_detect "SQLite" \
  'echo "DB_CONNECTION=sqlite" > .env.example' \
  "std-core std-gauntlet std-sql-sqlite"

case_detect "RabbitMQ + Kafka в compose" \
  'printf "services:\n  mq:\n    image: rabbitmq:3\n  kafka:\n    image: redpanda\n" > docker-compose.yml' \
  "std-core std-gauntlet std-msg-kafka std-msg-rabbitmq std-ops-containers"

case_detect "compose в подкаталоге тоже находится" \
  'mkdir -p deploy; printf "services:\n  app:\n    build: .\n" > deploy/docker-compose.yml' \
  "std-core std-gauntlet std-ops-containers"

case_detect "манифесты Kubernetes" \
  'mkdir -p k8s; printf "apiVersion: apps/v1\nkind: Deployment\n" > k8s/app.yaml' \
  "std-core std-gauntlet std-ops-k8s"

case_detect "Ansible" \
  'printf -- "- hosts: all\n  become: true\n" > playbook.yml' \
  "std-core std-gauntlet std-ops-ansible"

# Регрессия: `xargs -r` при пустом вводе возвращает 0, из-за чего «yaml-файлов
# нет» было неотличимо от «нашлось совпадение», и в Python-проект подключались
# правила Kubernetes и Ansible.
case_detect "проект без yaml не получает k8s и ansible" \
  'printf "[project]\ndependencies = [\"fastapi\"]\n" > pyproject.toml' \
  "std-core std-gauntlet std-py-base std-py-fastapi"

case_detect "пустой проект — только базовые правила" \
  'touch README.md' \
  "std-core std-gauntlet"

echo "== целостность связей =="

P="$TMP/check"; mkdir -p "$P"
( cd "$P" && echo '{"require":{"laravel/framework":"^11.0"}}' > composer.json )
VIBE_RULES_HOME="$ROOT" CLAUDE_PROJECT_DIR="$P" bash "$LINK" --auto >/dev/null 2>&1

VIBE_RULES_HOME="$ROOT" CLAUDE_PROJECT_DIR="$P" bash "$LINK" --check >/dev/null 2>&1 \
  && ok "--check на живых ссылках возвращает успех" \
  || bad "--check на живых ссылках" "код 0" "ненулевой код"

grep -qxF '.claude/rules/std-*' "$P/.gitignore" \
  && ok "симлинки добавлены в .gitignore (в git им нельзя: путь абсолютный)" \
  || bad ".gitignore" "строка .claude/rules/std-*" "её нет"

ln -sfn /nonexistent/path "$P/.claude/rules/std-broken"
VIBE_RULES_HOME="$ROOT" CLAUDE_PROJECT_DIR="$P" bash "$LINK" --check >/dev/null 2>&1 \
  && bad "--check ловит битую ссылку" "ненулевой код" "код 0" \
  || ok "--check ловит битую ссылку"

OUT=$(printf '{"hook_event_name":"SessionStart"}' | CLAUDE_PROJECT_DIR="$P" \
        bash "$ROOT/plugins/std-core/scripts/session-check.sh" 2>/dev/null)
printf '%s' "$OUT" | jq -e '.systemMessage | test("std-broken")' >/dev/null 2>&1 \
  && ok "SessionStart предупреждает о битой ссылке" \
  || bad "SessionStart предупреждает о битой ссылке" "systemMessage со std-broken" "${OUT:-пусто}"

rm "$P/.claude/rules/std-broken"
VIBE_RULES_HOME="$ROOT" CLAUDE_PROJECT_DIR="$P" bash "$LINK" --unlink >/dev/null 2>&1
[[ -z "$(linked "$P")" ]] && ok "--unlink убирает все ссылки" || bad "--unlink" "пусто" "$(linked "$P")"

echo
printf 'Пройдено: \033[32m%d\033[0m   Провалено: \033[31m%d\033[0m\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
