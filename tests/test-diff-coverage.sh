#!/usr/bin/env bash
# test-diff-coverage.sh — покрытие изменённых строк.
#
# Главное свойство: гейт смотрит только на строки этой работы. Проверяется
# и обратное — что «отчёта нет» не выглядит как «покрытие в порядке»: гейт,
# который молча зеленеет без данных, вреднее отсутствующего.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/require.sh"; require_tools git python3
DC="$ROOT/plugins/std-gauntlet/scripts/diff-coverage.py"
PASS=0; FAIL=0

ok()  { printf '  \033[32mOK\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n     ожидали: %s, получили: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
P="$TMP/проект"; mkdir -p "$P/src"
git -C "$P" init -q 2>/dev/null
git -C "$P" config user.email t@t; git -C "$P" config user.name t

printf 'line1\nline2\nline3\n' > "$P/src/Old.php"
git -C "$P" add -A; git -C "$P" commit -qm init 2>/dev/null

run() { python3 "$DC" --project "$P" "$@" 2>&1; }
rc_of() { python3 "$DC" --project "$P" "$@" >/dev/null 2>&1; echo $?; }

echo "== нечего мерить =="
got=$(rc_of)
[[ "$got" == "0" ]] && ok "без изменений гейт проходит" || bad "нет изменений" 0 "$got"

# Правка документации в знаменатель не идёт: иначе гейт краснеет от README
# и его снимают целиком.
printf '# документация\n' > "$P/README.md"
got=$(run)
grep -q "нет" <<<"$got" && ok "правка не-исходников проверять нечего" || bad "README" "нет строк" "$got"

echo "== отчёта нет — это не «покрытие в порядке» =="
printf 'new1\nnew2\nnew3\nnew4\n' > "$P/src/New.php"
got=$(rc_of)
[[ "$got" == "2" ]] && ok "без отчёта гейт не зеленеет, а сообщает" || bad "нет отчёта" 2 "$got"
got=$(run)
grep -q "НЕ проверено" <<<"$got" && ok "сказано, что проверка не выполнена" \
  || bad "текст" "«НЕ проверено»" "$got"

echo "== clover: покрытые и непокрытые строки =="
cat > "$P/coverage.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<coverage generated="1">
  <project timestamp="1">
    <file name="src/New.php">
      <line num="1" type="stmt" count="3"/>
      <line num="2" type="stmt" count="1"/>
      <line num="3" type="stmt" count="0"/>
      <line num="4" type="stmt" count="0"/>
    </file>
  </project>
</coverage>
EOF
got=$(run --min 80)
grep -q "2/4 = 50%" <<<"$got" && ok "считаются только изменённые исполняемые строки" \
  || bad "подсчёт" "2/4 = 50%" "$got"
got=$(rc_of --min 80)
[[ "$got" == "1" ]] && ok "ниже порога — провал" || bad "порог 80" 1 "$got"
got=$(rc_of --min 50)
[[ "$got" == "0" ]] && ok "на пороге — проход" || bad "порог 50" 0 "$got"

got=$(run --min 80)
grep -q "src/New.php:3" <<<"$got" && ok "непокрытые строки названы поимённо" \
  || bad "список" "src/New.php:3" "$got"

echo "== чужие строки в знаменатель не попадают =="
# Строки, которые в этой работе не менялись, покрывать не обязаны: иначе
# первая же правка в старом файле требует покрыть его целиком.
cat > "$P/coverage.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<coverage><project><file name="src/New.php">
  <line num="1" type="stmt" count="1"/>
  <line num="2" type="stmt" count="1"/>
  <line num="3" type="stmt" count="1"/>
  <line num="4" type="stmt" count="1"/>
  <line num="90" type="stmt" count="0"/>
  <line num="91" type="stmt" count="0"/>
</file></project></coverage>
EOF
got=$(run --min 100)
grep -q "4/4 = 100%" <<<"$got" && ok "непокрытые строки вне правки не учитываются" \
  || bad "чужие строки" "4/4 = 100%" "$got"

echo "== lcov: тот же ответ на другом формате =="
rm -f "$P/coverage.xml"
mkdir -p "$P/coverage"
cat > "$P/coverage/lcov.info" <<'EOF'
SF:src/New.php
DA:1,1
DA:2,0
DA:3,0
DA:4,0
end_of_record
EOF
got=$(run --min 80)
grep -q "1/4 = 25%" <<<"$got" && ok "lcov разбирается наравне с clover" \
  || bad "lcov" "1/4 = 25%" "$got"

echo "== порог берётся из конфигурации проекта =="
rm -rf "$P/coverage"
cat > "$P/coverage.xml" <<'EOF'
<?xml version="1.0"?>
<coverage><project><file name="src/New.php">
  <line num="1" type="stmt" count="1"/>
  <line num="2" type="stmt" count="0"/>
  <line num="3" type="stmt" count="0"/>
  <line num="4" type="stmt" count="0"/>
</file></project></coverage>
EOF
mkdir -p "$P/.claude"
printf '{ "diffCoverage": { "min": 20 } }' > "$P/.claude/gauntlet.json"
got=$(rc_of)
[[ "$got" == "0" ]] && ok "порог из gauntlet.json применяется" || bad "конфиг" 0 "$got"
printf '{ "diffCoverage": { "min": 90 } }' > "$P/.claude/gauntlet.json"
got=$(rc_of)
[[ "$got" == "1" ]] && ok "поднятый в конфиге порог тоже действует" || bad "конфиг 90" 1 "$got"
got=$(rc_of --min 10)
[[ "$got" == "0" ]] && ok "аргумент команды важнее конфигурации" || bad "приоритет" 0 "$got"
rm -f "$P/.claude/gauntlet.json"

echo "== подменённый отчёт не разбирается =="
rm -rf "$P/coverage"
cat > "$P/coverage.xml" <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE coverage [ <!ENTITY a "aaaaaaaaaa"> ]>
<coverage><project><file name="src/New.php">
  <line num="1" type="stmt" count="1"/>
</file></project></coverage>
EOF
got=$(rc_of --min 80)
[[ "$got" == "2" ]] && ok "отчёт с DTD отвергается, а не разбирается" || bad "DTD" 2 "$got"

echo
printf 'Пройдено: \033[32m%d\033[0m   Провалено: \033[31m%d\033[0m\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
