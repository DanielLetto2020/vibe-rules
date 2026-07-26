#!/usr/bin/env bash
# test-policy.sh — тесты замка политики стека.
#
# Политика превращает регламент организации из документа в проверку. Значит
# и проверяется она как код: JSON на вход, решение на выход.
#
# Отдельно проверяется, что политика НЕ отключает замки безопасности:
# профиль и политика двигают планку качества, но не открывают опасное.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GP="$ROOT/plugins/std-policy/scripts/guard-policy.sh"
GB="$ROOT/plugins/std-core/scripts/guard-bash.sh"
PASS=0; FAIL=0
ok()  { printf '  \033[32mOK\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n     ожидали: %s, получили: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
P="$TMP/proj"; mkdir -p "$P/.claude" "$P/public/upload" "$P/app"
touch "$P/composer.json" "$P/package.json" "$P/Dockerfile"

write_policy() { cat > "$P/.claude/policy.json"; }
write_policy <<'EOF'
{
  "runtime": { "php": "8.1", "node": "18" },
  "deniedPackages": { "example/legacy-client": "выведен из эксплуатации" },
  "stability": { "denyPrerelease": true },
  "staticAssets": { "maxBinaryKb": 512, "denyPaths": ["public/upload/**"] },
  "debugger": { "deniedInProd": true },
  "exempt": { "enabled": false }
}
EOF

decide() { # <файл> <новое содержимое> -> allow|deny|ask
  local out
  out=$(jq -n --arg p "$1" --arg n "$2" '{tool_name:"Edit",tool_input:{file_path:$p,new_string:$n}}' \
        | CLAUDE_PROJECT_DIR="$P" bash "$GP" 2>/dev/null)
  local d
  d=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
  echo "${d:-allow}"
}
c() { # <описание> <файл> <содержимое> <ожидаемое>
  local got; got=$(decide "$2" "$3")
  [[ "$got" == "$4" ]] && ok "$1" || bad "$1" "$4" "$got"
}

echo "== стабильность версий =="
c "стабильная версия проходит"      "$P/composer.json" '"guzzlehttp/guzzle": "^7.8"'    allow
c "alpha блокируется"               "$P/composer.json" '"a/b": "1.0.0-alpha3"'          deny
c "beta блокируется"                "$P/composer.json" '"a/b": "2.0.0-beta1"'           deny
c "rc блокируется"                  "$P/composer.json" '"a/b": "^3.0.0-rc2"'            deny
c "dev-ветка блокируется"           "$P/composer.json" '"a/b": "dev-master"'            deny
c "правка скриптов не трогается"    "$P/package.json"  '"scripts": {"dev": "vite"}'     allow

echo "== запрещённые пакеты и версии рантайма =="
c "запрещённый пакет блокируется"   "$P/composer.json" '"example/legacy-client": "^1.0"' deny
c "php ниже минимума блокируется"   "$P/composer.json" '"php": "^8.0"'                  deny
c "php на минимуме проходит"        "$P/composer.json" '"php": "^8.1"'                  allow
c "php выше минимума проходит"      "$P/composer.json" '"php": "^8.3"'                  allow
c "версии сравниваются как версии"  "$P/composer.json" '"php": "^8.10"'                 allow
c "node ниже минимума блокируется"  "$P/package.json"  '"node": ">=16"'                 deny

echo "== образ и статические ресурсы =="
c "отладчик в образе — к человеку"  "$P/Dockerfile" 'RUN pecl install xdebug'           ask
c "обычная сборка проходит"         "$P/Dockerfile" 'RUN composer install --no-dev'     allow
c "файл в каталоге статики"         "$P/public/upload/b.png" 'binary'                   ask
c "код вне политики не трогается"   "$P/app/Service.php" 'class Service {}'             allow

echo "== проект выведен из-под политики =="
write_policy <<'EOF'
{
  "stability": { "denyPrerelease": true },
  "runtime": { "php": "8.1" },
  "exempt": { "enabled": true, "reason": "разработан сторонним подрядчиком" }
}
EOF
c "политика не мешает: beta"        "$P/composer.json" '"a/b": "2.0.0-beta1"'           allow
c "политика не мешает: старый php"  "$P/composer.json" '"php": "^7.4"'                  allow

# Ключевая проверка: выход из-под политики не должен открывать опасное.
# Иначе флаг exempt стал бы способом обойти защиту целиком.
DANGER=$(jq -n '{tool_name:"Bash",tool_input:{command:"podman volume rm pgdata"}}' \
         | CLAUDE_PROJECT_DIR="$P" bash "$GB" 2>/dev/null \
         | jq -r '.hookSpecificOutput.permissionDecision // "allow"')
[[ "$DANGER" == "deny" ]] && ok "замки безопасности работают и при exempt" \
  || bad "замки безопасности при exempt" deny "$DANGER"

echo "== проект без политики =="
rm -f "$P/.claude/policy.json"
c "нет policy.json — замок молчит"  "$P/composer.json" '"a/b": "2.0.0-beta1"'           allow

echo
printf 'Пройдено: \033[32m%d\033[0m   Провалено: \033[31m%d\033[0m\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
