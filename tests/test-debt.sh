#!/usr/bin/env bash
# test-debt.sh — храповик долга: несоответствие стандарту можно не чинить,
# но нельзя наращивать.
#
# Проверяется главное свойство и его края: первый прогон фиксирует факт, рост
# валит гейт, снижение опускает планку навсегда, а отсутствие инструмента
# подсчёта не выглядит как «долга нет».
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/require.sh"; require_tools jq
DEBT="$ROOT/plugins/std-gauntlet/scripts/debt.sh"
PASS=0; FAIL=0

ok()  { printf '  \033[32mOK\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n     ожидали: %s, получили: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
P="$TMP/проект"; mkdir -p "$P/.claude"

# Подсчёт подменяем на чтение файла: тест про храповик, а не про линтер.
# Формат тот же, что у phpstan --error-format=raw и eslint -f unix.
cat > "$P/.claude/gauntlet.json" <<'EOF'
{ "debt": { "command": "cat violations.txt" } }
EOF

set_violations() { # <сколько>
  : > "$P/violations.txt"
  for ((i = 0; i < $1; i++)); do
    printf 'src/File%d.php:%d: не соответствует правилу\n' "$i" "$((i + 1))" >> "$P/violations.txt"
  done
}

run() { CLAUDE_PROJECT_DIR="$P" bash "$DEBT" "$@" 2>&1; }
rc_of() { CLAUDE_PROJECT_DIR="$P" bash "$DEBT" "$@" >/dev/null 2>&1; echo $?; }

echo "== счёт нарушений =="
set_violations 12
got=$(run count)
[[ "$got" == "12" ]] && ok "считаются строки вида путь:строка" || bad "count" 12 "$got"

# Сводки и заголовки инструментов долгом не считаются: иначе число менялось бы
# при обновлении версии линтера, а не при изменении кода.
printf '\n[ERROR] Found 12 errors\nSummary: 12 problems\n' >> "$P/violations.txt"
got=$(run count)
[[ "$got" == "12" ]] && ok "сводка инструмента в долг не попадает" || bad "count со сводкой" 12 "$got"

echo "== первый прогон фиксирует факт =="
got=$(rc_of check)
[[ "$got" == "0" ]] && ok "первый прогон проходит" || bad "первый check" 0 "$got"
[[ -f "$P/.claude/.debt.json" ]] && ok "состояние создано" || bad "состояние" "файл" "нет файла"
got=$(jq -r '.ceiling' "$P/.claude/.debt.json")
[[ "$got" == "12" ]] && ok "планка равна фактическому долгу" || bad "планка" 12 "$got"

echo "== ухудшать нельзя =="
set_violations 15
got=$(rc_of check)
[[ "$got" == "1" ]] && ok "рост долга валит гейт" || bad "рост" 1 "$got"
out=$(run check)
grep -q "reset" <<<"$out" && ok "в отказе назван способ решения человеком" \
  || bad "текст отказа" "упоминание reset" "$out"
got=$(jq -r '.ceiling' "$P/.claude/.debt.json")
[[ "$got" == "12" ]] && ok "планка при провале не поднимается" || bad "планка после роста" 12 "$got"

echo "== улучшение опускает планку навсегда =="
set_violations 9
got=$(rc_of check)
[[ "$got" == "0" ]] && ok "снижение проходит" || bad "снижение" 0 "$got"
got=$(jq -r '.ceiling' "$P/.claude/.debt.json")
[[ "$got" == "9" ]] && ok "планка опущена до нового минимума" || bad "новая планка" 9 "$got"

set_violations 11
got=$(rc_of check)
[[ "$got" == "1" ]] && ok "возврат к прежнему уровню больше не проходит" || bad "откат" 1 "$got"

set_violations 9
got=$(rc_of check)
[[ "$got" == "0" ]] && ok "удержание планки проходит" || bad "удержание" 0 "$got"

echo "== ручное решение человека =="
run reset 30 >/dev/null
got=$(jq -r '.ceiling' "$P/.claude/.debt.json")
[[ "$got" == "30" ]] && ok "reset поднимает планку осознанно" || bad "reset" 30 "$got"
set_violations 25
got=$(rc_of check)
[[ "$got" == "0" ]] && ok "после reset прежний долг проходит" || bad "после reset" 0 "$got"

echo "== нечем измерить — это не «долга нет» =="
BARE="$TMP/пустой"; mkdir -p "$BARE/.claude"
out=$(CLAUDE_PROJECT_DIR="$BARE" bash "$DEBT" check 2>&1); got=$?
[[ "$got" == "0" ]] && ok "без инструмента прогон не валится" || bad "без инструмента" 0 "$got"
grep -q "не измерен" <<<"$out" && ok "но об этом сказано вслух" \
  || bad "сообщение" "«долг не измерен»" "$out"

echo "== без jq храповик падает, а не соглашается =="
NOJQ="$TMP/bare-path"; mkdir -p "$NOJQ"
for b in bash cat grep sed awk date mktemp mv printf; do
  p=$(command -v "$b" 2>/dev/null) && ln -sf "$p" "$NOJQ/$b"
done
PATH="$NOJQ" CLAUDE_PROJECT_DIR="$P" bash "$DEBT" check >/dev/null 2>&1
got=$?
[[ "$got" == "2" ]] && ok "без jq — отказ с кодом 2" || bad "без jq" 2 "$got"

echo
printf 'Пройдено: \033[32m%d\033[0m   Провалено: \033[31m%d\033[0m\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
