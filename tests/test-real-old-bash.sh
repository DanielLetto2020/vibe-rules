#!/usr/bin/env bash
# test-real-old-bash.sh — замки под настоящим bash 3.2, а не под подменой версии.
#
# test-hooks.sh проверяет ветку решения, подменяя версию переменной. Этого мало:
# подмена не покажет, что верх скрипта вообще разбирается старым bash и что
# перезапуск под новым действительно происходит. На macOS /bin/bash — 3.2,
# и CI гоняет этот файл там. Где старого bash нет, шаг называет себя
# пропущенным, а не пройденным.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/require.sh"; require_tools jq
SCRIPTS="$ROOT/plugins/std-core/scripts"
OLD="${OLD_BASH:-/bin/bash}"
PASS=0; FAIL=0
ok()  { printf '  \033[32mOK\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n     ожидали: %s, получили: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); }

ver=$("$OLD" -c 'echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"' 2>/dev/null)
maj=${ver%%.*}; min=${ver#*.}
if [[ -z "$ver" ]] || (( maj > 4 || (maj == 4 && min >= 4) )); then
  echo "  старого bash нет ($OLD — ${ver:-не найден}) — шаг пропущен"
  exit 0
fi
echo "  $OLD — bash $ver"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
DANGER=$(jq -n '{tool_name:"Bash",tool_input:{command:"rm -rf /etc"}}')
decide() { jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null; }

got=$(printf '%s' "$DANGER" | STD_BASH_CANDIDATES="" CLAUDE_PROJECT_DIR="$TMP" "$OLD" "$SCRIPTS/guard-bash.sh" | decide)
[[ "$got" == "ask" ]] && ok "без нового bash — вопрос, а не пропуск" || bad "guard-bash на bash $ver" ask "$got"

for h in guard-secrets guard-tests guard-infra guard-deps precommit-secrets; do
  got=$(printf '{}' | STD_BASH_CANDIDATES="" CLAUDE_PROJECT_DIR="$TMP" "$OLD" "$SCRIPTS/$h.sh" | decide)
  [[ "$got" == "ask" ]] && ok "$h спрашивает" || bad "$h на bash $ver" ask "$got"
done

# Перезапуск: если новый bash стоит в известном месте (Homebrew), замок
# работает в полную силу, хотя запущен старым.
. "$SCRIPTS/bash-min.sh"
if newer=$(std_bash_newer); then
  got=$(printf '%s' "$DANGER" | CLAUDE_PROJECT_DIR="$TMP" "$OLD" "$SCRIPTS/guard-bash.sh" | decide)
  [[ "$got" == "deny" ]] && ok "перезапуск под $newer — запрет работает" || bad "перезапуск под $newer" deny "$got"
else
  echo "  нового bash в известных местах нет — проверка перезапуска пропущена"
fi

echo
printf 'Пройдено: \033[32m%d\033[0m   Провалено: \033[31m%d\033[0m\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
