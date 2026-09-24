#!/usr/bin/env bash
# test-gauntlet.sh — строй проверок и замок на коммит.
#
# Проверяется вердикт целиком: прогон не зеленеет там, где проверка не
# состоялась — mutation score не прочитан, конфиг без jq не разобран, имя гейта
# с опечаткой, скрипт гейта не запустился. И отметка успешного прогона
# относится к тому содержимому, которое проверялось, а не ко времени
# последней записи файлов с «правильными» расширениями.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/require.sh"; require_tools jq git python3
GA="$ROOT/plugins/std-gauntlet/scripts/gauntlet.sh"
GC="$ROOT/plugins/std-gauntlet/scripts/guard-commit.sh"
PASS=0; FAIL=0
ok()  { printf '  \033[32mOK\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n     ожидали: %s\n     получили: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

ga()    { local d="$1"; shift; CLAUDE_PROJECT_DIR="$d" timeout 20 bash "$GA" "$@" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; }
ga_rc() { local d="$1"; shift; CLAUDE_PROJECT_DIR="$d" timeout 20 bash "$GA" "$@" >/dev/null 2>&1; echo $?; }
proj()  { mkdir -p "$1/.claude" "$1/bin"; printf '%s\n' "$2" > "$1/.claude/gauntlet.json"; }
tool()  { cat > "$1"; chmod +x "$1"; }   # заглушка инструмента из stdin

echo "== mutation score: берётся то самое число =="
# Infection печатает три метрики, и последней идёт Covered Code MSI — она
# выше MSI. Храповик брал последнюю и поднимал планку по чужому числу.
I="$TMP/infection"; proj "$I" '{"gates":{"mutation":"./bin/infection --min-msi=$MSI"},"mutation":{"mode":"ratchet","floor":70}}'
tool "$I/bin/infection" <<'SH'
#!/usr/bin/env bash
printf 'Metrics:\n         Mutation Score Indicator (MSI): 40%%\n'
printf '         Mutation Code Coverage: 50%%\n         Covered Code MSI: 80%%\n'
SH
out=$(ga "$I"); rc=$(ga_rc "$I")
[[ "$rc" == "1" ]] && grep -q "40% ниже планки 70%" <<<"$out" \
  && ok "Infection: MSI, а не Covered Code MSI" || bad "Infection" "код 1, «40% ниже планки 70%»" "$rc: $out"

# Stryker без порога break печатает только таблицу — раньше число не
# находилось, храповик пропускался, а гейт проходил.
ST="$TMP/stryker"; proj "$ST" '{"gates":{"js-mutation":"./bin/stryker run"},"mutation":{"mode":"ratchet","floor":60}}'
tool "$ST/bin/stryker" <<'SH'
#!/usr/bin/env bash
echo "$*" > "$(dirname "$0")/../stryker.args"
cat <<'OUT'
----------|------------------|----------|-----------|------------|----------|----------|
          | % Mutation score |          |           |            |          |          |
File      |  total | covered | # killed | # timeout | # survived | # no cov | # errors |
----------|--------|---------|----------|-----------|------------|----------|----------|
All files |  15.38 |   15.38 |        2 |         0 |         11 |        0 |        0 |
 math.js  |  15.38 |   15.38 |        2 |         0 |         11 |        0 |        0 |
----------|--------|---------|----------|-----------|------------|----------|----------|
OUT
SH
out=$(ga "$ST"); rc=$(ga_rc "$ST")
[[ "$rc" == "1" ]] && grep -q "15% ниже планки 60%" <<<"$out" \
  && ok "Stryker: число из таблицы, когда строки с порогом нет" || bad "Stryker таблица" "код 1, «15% ниже планки 60%»" "$rc: $out"

# Сводка mutmut — эмодзи: убитые, таймауты, подозрительные, выжившие
MM="$TMP/mutmut"; proj "$MM" '{"gates":{"py-mutation":"./bin/mutmut run"},"mutation":{"mode":"ratchet","floor":70}}'
tool "$MM/bin/mutmut" <<'SH'
#!/usr/bin/env bash
printf '2. Checking mutants\n'
printf '⠸ 50/100  🎉 5  ⏰ 0  🤔 0  🙁 45  🔇 0\r⠸ 100/100  🎉 10  ⏰ 0  🤔 0  🙁 90  🔇 0\n'
SH
out=$(ga "$MM"); rc=$(ga_rc "$MM")
[[ "$rc" == "1" ]] && grep -q "10% ниже планки 70%" <<<"$out" \
  && ok "mutmut: счёт по сводке из эмодзи" || bad "mutmut" "код 1, «10% ниже планки 70%»" "$rc: $out"

# Строка с порогом у Stryker и запятая в дробной части — прежнее поведение
SB="$TMP/stryker-break"; proj "$SB" '{"gates":{"mutation":"./bin/stryker run"},"mutation":{"mode":"ratchet","floor":60}}'
tool "$SB/bin/stryker" <<'SH'
#!/usr/bin/env bash
echo "Final mutation score 63,45 under breaking threshold 70, setting exit code to 1 (failure)."
exit 1
SH
out=$(ga "$SB"); rc=$(ga_rc "$SB")
[[ "$rc" == "0" ]] && grep -q "63%" <<<"$out" \
  && ok "строка с порогом и запятая по-прежнему читаются" || bad "Stryker break" "код 0, 63%" "$rc: $out"

# При храповике порог инструмента выключен (MSI=0). Непрочитанное число
# значит, что не проверено ничего, — гейт обязан упасть.
UN="$TMP/unparsed"; proj "$UN" '{"gates":{"mutation":"echo всё хорошо"},"mutation":{"mode":"ratchet","floor":70}}'
out=$(ga "$UN"); rc=$(ga_rc "$UN")
[[ "$rc" == "1" ]] && ok "непрочитанный mutation score при храповике — провал" || bad "не прочитано" 1 "$rc: $out"
grep -q "не удалось извлечь" <<<"$out" && ok "причина провала названа" || bad "текст" "«не удалось извлечь»" "$out"

# Гейт назван не по слову mutation, но берёт $MSI — порог ему выключили,
# значит храповик обязан его проверить.
IN="$TMP/infection-key"; proj "$IN" '{"gates":{"infection":"./bin/infection --min-msi=$MSI"},"mutation":{"mode":"ratchet","floor":70}}'
tool "$IN/bin/infection" <<'SH'
#!/usr/bin/env bash
echo "Mutation Score Indicator (MSI): 10%"
for a in "$@"; do case "$a" in --min-msi=*) min=${a#--min-msi=};; esac; done
[ "${min:-0}" -gt 10 ] && exit 1
exit 0
SH
rc=$(ga_rc "$IN")
[[ "$rc" == "1" ]] && ok "гейт с \$MSI под любым именем идёт через храповик" || bad "гейт infection" 1 "$rc"

echo "== настройки мутации =="
EN="$TMP/disabled"; proj "$EN" '{"gates":{"test":"true","mutation":"./bin/boom"},"mutation":{"enabled":false}}'
tool "$EN/bin/boom" <<'SH'
#!/usr/bin/env bash
exit 1
SH
out=$(ga "$EN"); rc=$(ga_rc "$EN")
[[ "$rc" == "0" ]] && grep -q "выключен" <<<"$out" \
  && ok "mutation.enabled: false выключает мутационный гейт" || bad "enabled false" "код 0, «выключен»" "$rc: $out"

# У Stryker нет флага --since: прогон падал с «unknown option». Инкрементальный
# режим пересчитывает только затронутых мутантов.
CO="$TMP/changed-only"; proj "$CO" '{"gates":{"js-mutation":"./bin/stryker run"},"mutation":{"mode":"ratchet","floor":0,"changedOnly":true}}'
cp "$ST/bin/stryker" "$CO/bin/stryker"
ga "$CO" >/dev/null
args=$(cat "$CO/stryker.args" 2>/dev/null)
[[ "$args" == *--incremental* && "$args" != *--since* ]] \
  && ok "changedOnly для Stryker — --incremental" || bad "changedOnly" "--incremental" "$args"

echo "== конфиг без jq не игнорируется =="
# Без jq .claude/gauntlet.json молча не читался, и шли гейты по умолчанию —
# настроенные security и e2e не запускались, а прогон зеленел.
NJ="$TMP/nojq"; proj "$NJ" '{"gates":{"security":"exit 1"}}'; echo '{}' > "$NJ/package.json"
BARE="$TMP/bare-bin"; mkdir -p "$BARE"
for b in bash env cat grep sed awk date mktemp mv rm mkdir dirname tail head tr printf sort git python3 timeout; do
  p=$(command -v "$b" 2>/dev/null) && ln -sf "$p" "$BARE/$b"
done
out=$(PATH="$BARE" CLAUDE_PROJECT_DIR="$NJ" bash "$GA" 2>&1); rc=$?
[[ "$rc" == "2" ]] && ok "конфиг есть, jq нет — отказ с кодом 2" || bad "без jq" 2 "$rc: $out"
grep -q "jq" <<<"$out" && ok "сказано, чего не хватает" || bad "текст без jq" "упоминание jq" "$out"

echo "== --only =="
OP="$TMP/only"; proj "$OP" '{"gates":{"test":"true","js-mutation":"./bin/stryker run"},"mutation":{"mode":"ratchet","floor":0}}'
cp "$ST/bin/stryker" "$OP/bin/stryker"
out=$(ga "$OP" --only tests); rc=$(ga_rc "$OP" --only tests)
[[ "$rc" == "2" ]] && ok "опечатка в имени гейта — ошибка, а не «все пройдены»" || bad "--only tests" 2 "$rc: $out"
rc=$(ga_rc "$OP" --only)
[[ "$rc" == "2" ]] && ok "--only без имени — ошибка, а не зависание" || bad "--only без имени" 2 "$rc"
out=$(ga "$OP" --only mutation)
grep -q "▸ js-mutation" <<<"$out" && ok "--only mutation запускает мутацию кода любого стека" \
  || bad "--only mutation" "запущен js-mutation" "$out"
rc=$(ga_rc "$OP" --onyl test)
[[ "$rc" == "2" ]] && ok "неизвестный аргумент — ошибка" || bad "--onyl" 2 "$rc"

echo "== гейт, который не запустился =="
# Путь модуля с пробелом: двойной eval снимал кавычки, и скрипт гейта не
# находился. А двойку от самого Python гейт покрытия читал как «нет отчёта».
PD="$TMP/plug dir"; mkdir -p "$PD"; cp -r "$ROOT/plugins/std-gauntlet" "$PD/"
SPP="$TMP/space"; proj "$SPP" '{"gates":{"debt":"\"$STD_GAUNTLET_ROOT\"/scripts/debt.sh check"},"debt":{"command":"cat v.txt"}}'
printf 'a.php:1: x\n' > "$SPP/v.txt"
rc=$(CLAUDE_PROJECT_DIR="$SPP" bash "$PD/std-gauntlet/scripts/gauntlet.sh" >/dev/null 2>&1; echo $?)
[[ "$rc" == "0" ]] && ok "путь модуля с пробелом не ломает гейты" || bad "пробел в пути модуля" 0 "$rc"
PE="$TMP/pyerr"; proj "$PE" '{"gates":{"diff-coverage":"python3 \"$STD_GAUNTLET_ROOT\"/scripts/no-such.py"}}'
out=$(ga "$PE"); rc=$(ga_rc "$PE")
[[ "$rc" == "1" ]] && grep -q "ПРОВАЛ" <<<"$out" \
  && ok "сбой запуска гейта покрытия — провал, а не «не проверено»" || bad "сбой python" "код 1" "$rc: $out"

echo "== замок на коммит: что считается коммитом =="
G="$TMP/repo"; mkdir -p "$G/src" "$G/tests" "$G/features"
git -C "$G" init -q 2>/dev/null; git -C "$G" config user.email t@t; git -C "$G" config user.name t
printf '<?php\n' > "$G/src/a.php"; printf '<?php\n' > "$G/src/b.php"
printf '<?php\n' > "$G/tests/CartTest.php"; printf 'Функция: x\n' > "$G/features/cart.feature"
echo '{}' > "$G/package.json"
proj "$G" '{"gates":{"test":"true"}}'
printf '.claude/.gauntlet-pass\n' > "$G/.gitignore"
git -C "$G" add -A; git -C "$G" commit -qm init

decision() { # <команда> -> allow|ask|deny
  local out
  out=$(jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' \
        | CLAUDE_PROJECT_DIR="$G" bash "$GC" 2>/dev/null)
  out=$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"$out" 2>/dev/null)
  echo "${out:-allow}"
}
pass_run() { CLAUDE_PROJECT_DIR="$G" bash "$GA" >/dev/null 2>&1; }

pass_run
[[ "$(decision 'git commit -m x')" == "allow" ]] && ok "после зелёного прогона коммит свободен" \
  || bad "чистый прогон" allow "$(decision 'git commit -m x')"

printf '<?php // правка\n' > "$G/src/a.php"
for c in 'git commit -m x' 'git -C . commit -m x' 'git -c user.name=x commit -m x' \
         'git --no-pager commit -m x' '/usr/bin/git commit -m x' 'bash -c "git commit -m x"' \
         'git -C "my dir" -c a.b=c commit' 'git merge feature' 'git cherry-pick abc123' \
         'git revert HEAD' 'git am fix.patch' 'git pull origin main' 'cd x && git  commit -am y'; do
  got=$(decision "$c")
  [[ "$got" == "ask" ]] && ok "устаревший прогон: $c" || bad "коммит не распознан: $c" ask "$got"
done
for c in 'git status' 'git log --grep commit' 'git commit-graph write' 'git merge --abort' \
         'git show HEAD' 'echo legit commit'; do
  got=$(decision "$c")
  [[ "$got" == "allow" ]] && ok "не коммит: $c" || bad "лишний вопрос: $c" allow "$got"
done

echo "== замок на коммит: что считается изменением =="
# Раньше смотрели mtime файлов семи расширений: .tsx, .rs, package.json,
# сценарии, удаление теста и переименование (mv сохраняет mtime) проходили.
stale_after() { # <описание> <команда правки>
  pass_run
  ( cd "$G" && eval "$2" )
  local got; got=$(decision 'git commit -m x')
  [[ "$got" == "ask" ]] && ok "после прогона: $1" || bad "изменение не замечено: $1" ask "$got"
  git -C "$G" checkout -q -- . 2>/dev/null; git -C "$G" clean -qfd -e .claude 2>/dev/null
}
stale_after "новый .tsx"             'printf "export const A = 1\n" > src/A.tsx'
stale_after "новый .rs"              'printf "fn main() {}\n" > src/main.rs'
stale_after "правка package.json"    'printf "{\"dependencies\":{\"x\":\"1\"}}\n" > package.json'
stale_after "правка сценария"        'printf "Функция: y\n" > features/cart.feature'
stale_after "удалён тест"            'rm tests/CartTest.php'
stale_after "переименование (mv)"    'mv src/b.php src/renamed.php'

# Индекс и коммиты содержимого не меняют: git add и частичный коммит после
# прогона не должны требовать нового прогона.
pass_run; printf '<?php // x\n' > "$G/src/a.php"; printf '<?php // y\n' > "$G/src/b.php"; pass_run
git -C "$G" add src/a.php
[[ "$(decision 'git commit -m x')" == "allow" ]] && ok "git add после прогона отметку не сбивает" \
  || bad "git add" allow "$(decision 'git commit -m x')"
git -C "$G" commit -qm a
[[ "$(decision 'git commit -am y')" == "allow" ]] && ok "частичный коммит отметку не сбивает" \
  || bad "частичный коммит" allow "$(decision 'git commit -am y')"
git -C "$G" commit -qam b

# Отметка без отпечатка — не отметка: её мог оставить touch
date -u +%s > "$G/.claude/.gauntlet-pass"
[[ "$(decision 'git commit -m x')" == "ask" ]] && ok "отметка без отпечатка не засчитывается" \
  || bad "старая отметка" ask "$(decision 'git commit -m x')"
: > "$G/.claude/.gauntlet-pass"
[[ "$(decision 'git commit -m x')" == "ask" ]] && ok "пустая отметка не засчитывается" \
  || bad "пустая отметка" ask "$(decision 'git commit -m x')"

echo "== отметка и время прогона =="
# Отметку ставили в конце прогона: правка, сделанная во время долгого
# фонового прогона, считалась проверенной.
RC_="$TMP/race"; mkdir -p "$RC_/src"
git -C "$RC_" init -q 2>/dev/null; git -C "$RC_" config user.email t@t; git -C "$RC_" config user.name t
printf '<?php\n' > "$RC_/src/a.php"
proj "$RC_" '{"gates":{"test":"printf \"<?php // поздняя правка\\n\" > src/a.php"}}'
git -C "$RC_" add -A; git -C "$RC_" commit -qm init
CLAUDE_PROJECT_DIR="$RC_" bash "$GA" >/dev/null 2>&1
got=$(jq -n '{tool_name:"Bash",tool_input:{command:"git commit -am x"}}' | CLAUDE_PROJECT_DIR="$RC_" bash "$GC" 2>/dev/null \
      | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
[[ "$got" == "ask" ]] && ok "правка во время прогона не считается проверенной" || bad "гонка" ask "${got:-allow}"

# Отчёты, которые пишет сам прогон, отметку не сбивают — иначе она устаревала
# бы в момент окончания прогона в каждом проекте без .gitignore на них.
AR="$TMP/artifacts"; mkdir -p "$AR/src"
git -C "$AR" init -q 2>/dev/null; git -C "$AR" config user.email t@t; git -C "$AR" config user.name t
printf '<?php\n' > "$AR/src/a.php"
proj "$AR" '{"gates":{"test":"date +%s%N > coverage.xml"}}'
git -C "$AR" add -A; git -C "$AR" commit -qm init
out=$(CLAUDE_PROJECT_DIR="$AR" bash "$GA" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
got=$(jq -n '{tool_name:"Bash",tool_input:{command:"git commit -am x"}}' | CLAUDE_PROJECT_DIR="$AR" bash "$GC" 2>/dev/null \
      | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
[[ -z "$got" ]] && ok "отчёт, записанный прогоном, отметку не сбивает" || bad "артефакт прогона" allow "$got"
grep -q "coverage.xml" <<<"$out" && ok "о неигнорируемом отчёте сказано вслух" || bad "текст об артефакте" "coverage.xml" "$out"
printf '<?php // x\n' > "$AR/src/a.php"
got=$(jq -n '{tool_name:"Bash",tool_input:{command:"git commit -am x"}}' | CLAUDE_PROJECT_DIR="$AR" bash "$GC" 2>/dev/null \
      | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
[[ "$got" == "ask" ]] && ok "а правка кода после него — сбивает" || bad "правка после артефакта" ask "${got:-allow}"

# Вне git отпечатка нет, остаётся время изменения. Удаление файла mtime не
# оставляет, но меняет время каталога — его и видно.
NG="$TMP/nogit"; mkdir -p "$NG/tests"; proj "$NG" '{"gates":{"test":"true"}}'
printf '<?php\n' > "$NG/tests/CartTest.php"
CLAUDE_PROJECT_DIR="$NG" bash "$GA" >/dev/null 2>&1
sleep 1; rm "$NG/tests/CartTest.php"
got=$(jq -n '{tool_name:"Bash",tool_input:{command:"git commit -m x"}}' | CLAUDE_PROJECT_DIR="$NG" bash "$GC" 2>/dev/null \
      | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
[[ "$got" == "ask" ]] && ok "вне git удаление файла после прогона тоже замечено" || bad "вне git: удаление" ask "${got:-allow}"

# Проваленный прогон не оставляет прежнюю отметку в силе
FL="$TMP/fails"; mkdir -p "$FL"; git -C "$FL" init -q 2>/dev/null
proj "$FL" '{"gates":{"test":"true"}}'
CLAUDE_PROJECT_DIR="$FL" bash "$GA" >/dev/null 2>&1
proj "$FL" '{"gates":{"test":"false"}}'
CLAUDE_PROJECT_DIR="$FL" bash "$GA" >/dev/null 2>&1
[[ ! -f "$FL/.claude/.gauntlet-pass" ]] && ok "проваленный прогон снимает прежнюю отметку" \
  || bad "отметка после провала" "нет файла" "осталась"

echo "== старый bash: не «пройдено», а «не проводился» =="
# На bash 3.2 mapfile — ошибка выполнения, список гейтов пуст. Версия
# подменяется переменной; настоящий 3.2 проверяет задание CI на macOS.
OB="$TMP/oldbash"; proj "$OB" '{"gates":{"test":"false"}}'
out=$(CLAUDE_PROJECT_DIR="$OB" STD_TEST_BASH_VERSION=3.2 STD_BASH_CANDIDATES="" bash "$GA" 2>&1); rc=$?
[[ "$rc" == "2" && "$out" == *"brew install bash"* && ! -f "$OB/.claude/.gauntlet-pass" ]] \
  && ok "bash 3.2 без нового рядом — код 2, отметки нет" || bad "gauntlet на bash 3.2" "код 2" "$rc: $out"
CLAUDE_PROJECT_DIR="$OB" STD_TEST_BASH_VERSION=3.2 STD_BASH_CANDIDATES="$(command -v bash)" bash "$GA" >/dev/null 2>&1; rc=$?
[[ "$rc" == "1" ]] && ok "bash 3.2 с новым рядом — перезапуск, красный гейт виден" \
  || bad "перезапуск gauntlet под новым bash" 1 "$rc"

echo
printf 'Пройдено: \033[32m%d\033[0m   Провалено: \033[31m%d\033[0m\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
