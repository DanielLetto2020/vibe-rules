#!/usr/bin/env bash
# test-hooks.sh — unit-тесты замков.
#
# Хук — это чистая функция: JSON на входе, решение на выходе. Значит он
# тестируется полностью детерминированно, без запуска модели и без токенов.
# Это и есть ответ на «как убедиться, что правила работают, не лazя в код».
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$ROOT/plugins/std-core/scripts"
PASS=0; FAIL=0

ok()   { printf '  \033[32mOK\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n     ожидали: %s, получили: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); }

# decision <script> <json> -> allow|deny|ask|error
decision() {
  local script="$1" input="$2" out rc
  out=$(printf '%s' "$input" | "$script" 2>/dev/null); rc=$?
  if [[ $rc -eq 2 ]]; then echo "error"; return; fi
  local d
  d=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
  echo "${d:-allow}"
}

bash_case() { # <описание> <команда> <ожидаемое>
  local desc="$1" cmd="$2" want="$3"
  local json; json=$(jq -n --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')
  local got; got=$(decision "$SCRIPTS/guard-bash.sh" "$json")
  [[ "$got" == "$want" ]] && ok "$desc" || bad "$desc" "$want" "$got"
}

echo "== guard-bash: контейнеры =="
bash_case "podman rmi блокируется"                 'podman rmi old-image'                    deny
bash_case "docker system prune блокируется"        'docker system prune -af'                 deny
bash_case "podman volume rm блокируется"           'podman volume rm pgdata'                 deny
bash_case "buildah rm --all блокируется"           'buildah rm --all'                        deny
bash_case "compose down -v блокируется"            'podman compose down -v'                  deny
bash_case "podman ps разрешён"                     'podman ps -a'                            allow
bash_case "docker logs разрешён"                   'docker logs api --tail 50'               allow
bash_case "compose down без -v разрешён"           'podman compose down'                     allow

echo "== guard-bash: git =="
bash_case "force-push блокируется"                 'git push --force origin main'            deny
bash_case "force-with-lease разрешён"              'git push --force-with-lease origin feat' allow
bash_case "--no-verify блокируется"                'git commit --no-verify -m "wip"'         deny
bash_case "reset --hard требует подтверждения"     'git reset --hard origin/main'            ask
bash_case "обычный commit разрешён"                'git commit -m "fix: taxes"'              allow

echo "== guard-bash: БД и ФС =="
bash_case "migrate:fresh блокируется"              'php artisan migrate:fresh --seed'        deny
bash_case "db:wipe блокируется"                    'php artisan db:wipe'                     deny
bash_case "DROP DATABASE блокируется"              'psql -c "DROP DATABASE prod"'            deny
bash_case "rm -rf / блокируется"                   'rm -rf /'                                deny
bash_case "rm -rf в подпапке разрешён"             'rm -rf ./build/cache'                    allow
bash_case "обычная миграция разрешена"             'php artisan migrate'                     allow

echo "== guard-bash: зависимости =="
bash_case "composer require спрашивает"            'composer require guzzlehttp/guzzle'      ask
bash_case "npm install пакета спрашивает"          'npm install lodash'                      ask
bash_case "npm install без пакета разрешён"        'npm install'                             allow
bash_case "запуск тестов разрешён"                 'php artisan test'                        allow

echo "== guard-tests: защита надзорного слоя =="
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/tests/Feature" "$TMP/app"
echo "<?php" > "$TMP/tests/Feature/OrderTest.php"
echo "<?php" > "$TMP/app/Order.php"

write_case() { # <описание> <файл> <ожидаемое>
  local desc="$1" f="$2" want="$3"
  local json; json=$(jq -n --arg p "$f" '{tool_name:"Edit",tool_input:{file_path:$p}}')
  local got; got=$(decision "$SCRIPTS/guard-tests.sh" "$json")
  [[ "$got" == "$want" ]] && ok "$desc" || bad "$desc" "$want" "$got"
}

write_case "правка существующего теста -> ask"  "$TMP/tests/Feature/OrderTest.php"      ask
write_case "создание нового теста -> allow"     "$TMP/tests/Feature/NewTest.php"        allow
write_case "правка обычного кода -> allow"      "$TMP/app/Order.php"                    allow
write_case "правка .spec.ts -> ask"             "$(touch "$TMP/cart.spec.ts"; echo "$TMP/cart.spec.ts")" ask

echo "== guard-infra: то, что тестами не откатишь =="
mkdir -p "$TMP/k8s" "$TMP/ansible" "$TMP/database/migrations" "$TMP/.github/workflows"
touch "$TMP/k8s/deployment.yaml" "$TMP/ansible/playbook.yml" "$TMP/Dockerfile" \
      "$TMP/.github/workflows/ci.yml" "$TMP/database/migrations/2024_create_orders.php" "$TMP/.env"

infra_case() { # <описание> <файл> <ожидаемое>
  local desc="$1" f="$2" want="$3"
  local json; json=$(jq -n --arg p "$f" '{tool_name:"Edit",tool_input:{file_path:$p}}')
  local got; got=$(decision "$SCRIPTS/guard-infra.sh" "$json")
  [[ "$got" == "$want" ]] && ok "$desc" || bad "$desc" "$want" "$got"
}

infra_case "манифест k8s"                "$TMP/k8s/deployment.yaml"                    ask
infra_case "playbook ansible"            "$TMP/ansible/playbook.yml"                   ask
infra_case "Dockerfile"                  "$TMP/Dockerfile"                             ask
infra_case "workflow CI"                 "$TMP/.github/workflows/ci.yml"               ask
infra_case "файл окружения"              "$TMP/.env"                                   ask
infra_case "правка существующей миграции" "$TMP/database/migrations/2024_create_orders.php" ask
infra_case "новая миграция разрешена"    "$TMP/database/migrations/2026_add_index.php" allow
infra_case "обычный код разрешён"        "$TMP/app/Order.php"                          allow

echo "== guard-deps: обход через прямую правку файла зависимостей =="
printf '{"require":{"php":"^8.3"}}' > "$TMP/composer.json"
printf '{"dependencies":{"vue":"^3.5"}}' > "$TMP/package.json"

deps_case() { # <описание> <файл> <новое-содержимое> <ожидаемое>
  local desc="$1" f="$2" new="$3" want="$4"
  local json; json=$(jq -n --arg p "$f" --arg n "$new" '{tool_name:"Edit",tool_input:{file_path:$p,new_string:$n}}')
  local got; got=$(decision "$SCRIPTS/guard-deps.sh" "$json")
  [[ "$got" == "$want" ]] && ok "$desc" || bad "$desc" "$want" "$got"
}

deps_case "новый пакет в composer.json"  "$TMP/composer.json" '"guzzlehttp/guzzle": "^7.8"'  ask
deps_case "новый пакет в package.json"   "$TMP/package.json"  '"lodash": "^4.17.21"'         ask
deps_case "правка скриптов не трогает"   "$TMP/package.json"  '"scripts": { "dev": "vite" }' allow
deps_case "обычный файл не трогает"      "$TMP/app/Order.php" 'class Order {}'               allow

echo "== guard-commit: коммит без прогона гейтов =="
GT="$ROOT/plugins/std-gauntlet/scripts/guard-commit.sh"
GP=$(mktemp -d); mkdir -p "$GP/.claude" "$GP/app"

commit_case() { # <описание> <команда> <ожидаемое>
  local desc="$1" cmd="$2" want="$3"
  local json; json=$(jq -n --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')
  local out rc got
  out=$(printf '%s' "$json" | CLAUDE_PROJECT_DIR="$GP" "$GT" 2>/dev/null)
  got=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null)
  # Пустой stdout означает «решения нет» — обычный поток разрешений
  [[ "$got" == "$want" || ( -z "$got" && "$want" == "allow" ) ]] && ok "$desc" || bad "$desc" "$want" "${got:-<пусто>}"
}

echo 'class A {}' > "$GP/app/A.php"
commit_case "гейты никогда не прогонялись" 'git commit -m "feat: x"'  ask

# Отметка успешного прогона свежее исходников
date -u +%s > "$GP/.claude/.gauntlet-pass"
commit_case "гейты пройдены после правок"  'git commit -m "feat: x"'  allow

# Правка кода после прогона делает результат устаревшим
sleep 1; echo 'class B {}' > "$GP/app/B.php"
commit_case "код изменён после прогона"    'git commit -m "feat: y"'  ask
commit_case "не-коммит не трогаем"         'git status'               allow

printf '{"requireBeforeCommit": false}' > "$GP/.claude/gauntlet.json"
commit_case "проект отключил требование"   'git commit -m "feat: z"'  allow
rm -rf "$GP"

echo "== secret-scan =="
secret_case() { # <описание> <содержимое> <ожидаемое: error|allow>
  local desc="$1" content="$2" want="$3"
  local f="$TMP/config_$RANDOM.php"
  printf '%s\n' "$content" > "$f"
  local json; json=$(jq -n --arg p "$f" '{tool_name:"Write",tool_input:{file_path:$p}}')
  local got; got=$(decision "$SCRIPTS/secret-scan.sh" "$json")
  [[ "$got" == "$want" ]] && ok "$desc" || bad "$desc" "$want" "$got"
}

secret_case "жёстко зашитый пароль ловится"   "\$db_password = 'SuperSecret123';"          error
secret_case "AWS-ключ ловится"                "AKIAIOSFODNN7EXAMPLE"                       error
secret_case "приватный ключ ловится"          "-----BEGIN RSA PRIVATE KEY-----"            error
secret_case "чтение из env не ловится"        "\$pass = getenv('DB_PASSWORD');"            allow
secret_case "плейсхолдер не ловится"          "\$pass = env('DB_PASS', '');"               allow

echo
printf 'Пройдено: \033[32m%d\033[0m   Провалено: \033[31m%d\033[0m\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
