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
# Отказ читает агент. Готовая команда сброса в нём читалась как следующий
# шаг, и планку опускали, не спросив. Теперь сказано, чьё это решение.
grep -q "спроси человека" <<<"$out" && ok "в отказе сказано, что понижать планку решает человек" \
  || bad "текст отказа" "«спроси человека»" "$out"
grep -q "debt.sh reset" <<<"$out" && bad "текст отказа" "без готовой команды сброса" "$out" \
  || ok "команда сброса агенту как следующий шаг не предлагается"
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

echo "== сломанный подсчёт — это не «долга нет» =="
# Инструмент упал (ESLint 9 без форматтера unix, ruff не установлен) — раньше
# его код возврата не читали, пустой вывод давал «ДОЛГ: 0», и первая же
# поломка навсегда опускала планку до нуля.
C2="$TMP/crash"; mkdir -p "$C2/.claude"
printf '{ "debt": { "command": "echo src/a.php:1: x; exit 2" } }' > "$C2/.claude/gauntlet.json"
out=$(CLAUDE_PROJECT_DIR="$C2" bash "$DEBT" check 2>&1); got=$?
[[ "$got" == "2" ]] && ok "упавший инструмент — «не измерено» (код 2)" || bad "падение инструмента" 2 "$got: $out"
[[ ! -f "$C2/.claude/.debt.json" ]] && ok "упавший прогон планку не фиксирует" \
  || bad "состояние после падения" "нет файла" "$(cat "$C2/.claude/.debt.json")"
printf '{ "debt": { "command": "no-such-linter-xyz check ." } }' > "$C2/.claude/gauntlet.json"
got=$(CLAUDE_PROJECT_DIR="$C2" bash "$DEBT" count >/dev/null 2>&1; echo $?)
[[ "$got" == "2" ]] && ok "не установленный инструмент — тоже «не измерено»" || bad "нет инструмента" 2 "$got"
# Код 1 у линтеров — «нарушения найдены», это нормальный подсчёт
printf '{ "debt": { "command": "cat violations.txt; exit 1" } }' > "$C2/.claude/gauntlet.json"
printf 'a.php:1: x\nb.php:2: y\n' > "$C2/violations.txt"
got=$(CLAUDE_PROJECT_DIR="$C2" bash "$DEBT" count 2>/dev/null)
[[ "$got" == "2" ]] && ok "код 1 у линтера — нарушения найдены, счёт идёт" || bad "код 1" 2 "$got"

echo "== пути с пробелом =="
# eslint и phpstan печатают абсолютные пути; каталог с пробелом выпадал
# из подсчёта целиком, и тот же проект давал 0 вместо 3.
SP="$TMP/es proj"; mkdir -p "$SP/.claude"
printf '{ "debt": { "command": "cat v.txt" } }' > "$SP/.claude/gauntlet.json"
for i in 1 2 3; do printf '%s/src/a%d.js:%d:5: ошибка [Error/semi]\n' "$SP" "$i" "$i"; done > "$SP/v.txt"
got=$(CLAUDE_PROJECT_DIR="$SP" bash "$DEBT" count 2>/dev/null)
[[ "$got" == "3" ]] && ok "путь с пробелом считается" || bad "пробел в пути" 3 "$got"

echo "== ESLint 9: форматтера unix больше нет =="
ES="$TMP/eslint9"; mkdir -p "$ES/.claude" "$ES/node_modules/.bin"; echo '{}' > "$ES/package.json"
cat > "$ES/node_modules/.bin/eslint" <<'SH'
#!/usr/bin/env bash
# Заглушка ESLint 9: unix убран из ядра, json на месте.
case " $* " in
  *" -f unix "*) echo "The unix formatter is no longer part of core ESLint." >&2; exit 2 ;;
  *" -f json "*) printf '[{"filePath":"/p/a.js","messages":[{"line":1,"message":"x"},{"line":4,"message":"y"}]},'
                 printf '{"filePath":"/p/b.js","messages":[{"line":2,"message":"z"}]}]\n'; exit 1 ;;
esac
exit 2
SH
chmod +x "$ES/node_modules/.bin/eslint"
got=$(CLAUDE_PROJECT_DIR="$ES" bash "$DEBT" count 2>/dev/null)
[[ "$got" == "3" ]] && ok "долг по ESLint считается через JSON-вывод" || bad "eslint 9" 3 "$got"

echo "== испорченное состояние не выключает проверку =="
# Раньше пустой или битый .debt.json читался как «планки нет»: любой долг
# проходил, а состояние так и оставалось пустым навсегда.
BR="$TMP/broken"; mkdir -p "$BR/.claude"
printf '{ "debt": { "command": "cat v.txt" } }' > "$BR/.claude/gauntlet.json"
printf 'a.php:1: x\n' > "$BR/v.txt"
CLAUDE_PROJECT_DIR="$BR" bash "$DEBT" check >/dev/null 2>&1
out=$(CLAUDE_PROJECT_DIR="$BR" bash "$DEBT" reset 1O 2>&1); got=$?
[[ "$got" == "2" ]] && ok "reset с нечислом отвергается" || bad "reset 1O" 2 "$got: $out"
got=$(jq -r '.ceiling' "$BR/.claude/.debt.json" 2>/dev/null)
[[ "$got" == "1" ]] && ok "после отвергнутого reset планка цела" || bad "планка после reset 1O" 1 "${got:-<пусто>}"
: > "$BR/.claude/.debt.json"
for i in $(seq 1 500); do printf 'a.php:%d: x\n' "$i"; done > "$BR/v.txt"
got=$(CLAUDE_PROJECT_DIR="$BR" bash "$DEBT" check >/dev/null 2>&1; echo $?)
[[ "$got" == "2" ]] && ok "пустое состояние — отказ, а не «планка удержана»" || bad "пустое состояние" 2 "$got"
echo '{"ceiling":"много"}' > "$BR/.claude/.debt.json"
got=$(CLAUDE_PROJECT_DIR="$BR" bash "$DEBT" check >/dev/null 2>&1; echo $?)
[[ "$got" == "2" ]] && ok "нечисловая планка — отказ" || bad "битая планка" 2 "$got"
CLAUDE_PROJECT_DIR="$BR" bash "$DEBT" reset 499 >/dev/null 2>&1
got=$(CLAUDE_PROJECT_DIR="$BR" bash "$DEBT" check >/dev/null 2>&1; echo $?)
[[ "$got" == "1" ]] && ok "reset человека чинит состояние, и проверка снова работает" || bad "после починки" 1 "$got"

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
