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
# Код 3, а не 2: двойку печатает сам Python на опечатке в пути к скрипту
# и на ошибке аргументов, и такой сбой выглядел как «нет отчёта» — гейт
# показывал «не проверено» и не падал.
got=$(rc_of)
[[ "$got" == "3" ]] && ok "без отчёта гейт не зеленеет, а сообщает (код 3)" || bad "нет отчёта" 3 "$got"
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
[[ "$got" == "3" ]] && ok "отчёт с DTD отвергается, а не разбирается" || bad "DTD" 3 "$got"
rm -f "$P/coverage.xml"

got=$(python3 "$DC" --project "$P" --min 2>/dev/null; echo $?)
[[ "$got" == "2" ]] && ok "ошибка запуска — код 2, отличимый от «не проверено»" || bad "argparse" 2 "$got"

# --- Отдельные репозитории под каждую находку аудита -------------------------
# Общий $P выше живёт одной историей; дальше каждому случаю нужен свой git
# с нужной формой: без коммитов, с подпроектом, с неглубоким клоном.
mkrepo() { # <каталог>
  mkdir -p "$1"
  git -C "$1" init -q 2>/dev/null
  git -C "$1" config user.email t@t; git -C "$1" config user.name t
}
commit_all() { git -C "$1" add -A >/dev/null 2>&1; git -C "$1" commit -qm c >/dev/null 2>&1; }
dc()    { local d="$1"; shift; python3 "$DC" --project "$d" "$@" 2>&1; }
dc_rc() { local d="$1"; shift; python3 "$DC" --project "$d" "$@" >/dev/null 2>&1; echo $?; }
# clover <файл> <имя в отчёте> <попаданий на строку 1> [<на строку 2> …]
clover() {
  local f="$1" name="$2" n=0; shift 2
  { echo '<?xml version="1.0"?><coverage><project>'
    printf '<file name="%s">\n' "$name"
    for h in "$@"; do n=$((n+1)); printf '<line num="%d" type="stmt" count="%s"/>\n' "$n" "$h"; done
    echo '</file></project></coverage>'; } > "$f"
}

echo "== изменения в индексе тоже изменения =="
# Без основной ветки сравнение шло «индекс против диска»: после git add
# новый файл исчезал из виду, и гейт отвечал «проверять нечего».
A="$TMP/staged"; mkrepo "$A"; printf 'x\n' > "$A/README.md"; commit_all "$A"
mkdir -p "$A/src"; printf 'n1\nn2\nn3\nn4\n' > "$A/src/New.php"
clover "$A/coverage.xml" src/New.php 1 1 0 0
git -C "$A" add src/New.php
got=$(dc "$A" --min 80)
grep -q "2/4 = 50%" <<<"$got" && ok "добавленное в индекс считается изменённым" || bad "git add" "2/4 = 50%" "$got"

B="$TMP/nohead"; mkrepo "$B"; printf 'a = 1\nb = 2\n' > "$B/app.py"; git -C "$B" add app.py
printf 'SF:app.py\nDA:1,0\nDA:2,0\nend_of_record\n' > "$B/lcov.info"
got=$(dc_rc "$B" --min 80)
[[ "$got" == "1" ]] && ok "репозиторий без единого коммита проверяется" || bad "нет HEAD" 1 "$got"

echo "== файла нет в отчёте — это не «покрыт» =="
# Модуль, который не импортирует ни один тест, coverage.py в отчёт не пишет
# вовсе. Раньше такой файл молча пропускался, и новый непокрытый код давал
# «нет исполняемых строк — проверять нечего».
C="$TMP/unimported"; mkrepo "$C"; mkdir -p "$C/src/pkg"
printf 'a = 1\nb = 2\nc = 3\n' > "$C/src/pkg/old.py"; commit_all "$C"
printf 'def f():\n    return 1\n\n# комментарий\n' > "$C/src/pkg/new.py"
cat > "$C/coverage.xml" <<EOF
<?xml version="1.0" ?>
<coverage version="7.6"><sources><source>$C/src</source></sources>
<packages><package name="pkg"><classes>
<class name="old.py" filename="pkg/old.py"><lines>
<line number="1" hits="1"/><line number="2" hits="1"/><line number="3" hits="1"/>
</lines></class></classes></package></packages></coverage>
EOF
got=$(dc "$C" --min 80); rc=$(dc_rc "$C" --min 80)
[[ "$rc" == "1" ]] && ok "файл вне отчёта рядом с измеренными — строки непокрыты" || bad "нет в отчёте" 1 "$rc: $got"
grep -q "0/2 = 0%" <<<"$got" && ok "считаются только строки кода, не пустые и не комментарии" \
  || bad "строки вне отчёта" "0/2 = 0%" "$got"
grep -q "src/pkg/new.py" <<<"$got" && ok "файл вне отчёта назван" || bad "список" "src/pkg/new.py" "$got"

# Исключение — решение, записанное в конфигурации, а не молчаливый пропуск
mkdir -p "$C/.claude"
printf '{ "diffCoverage": { "exclude": ["src/pkg/new.py"] } }' > "$C/.claude/gauntlet.json"
got=$(dc_rc "$C" --min 80)
[[ "$got" == "0" ]] && ok "явное исключение в gauntlet.json действует" || bad "exclude" 0 "$got"
rm -rf "$C/.claude"

echo "== корни <source> у Cobertura =="
# src-раскладка: coverage.py пишет pkg/old.py относительно source, git видит
# src/pkg/old.py. Ни один путь не совпадал, и гейт проходил всегда.
rm -f "$C/src/pkg/new.py"
printf 'a = 1\nb = 2\nc = 3\nd = 4\ne = 5\nf = 6\n' > "$C/src/pkg/old.py"
cat > "$C/coverage.xml" <<EOF
<?xml version="1.0" ?>
<coverage version="7.6"><sources><source>$C/src</source></sources>
<packages><package name="pkg"><classes>
<class name="old.py" filename="pkg/old.py"><lines>
<line number="1" hits="1"/><line number="2" hits="1"/><line number="3" hits="1"/>
<line number="4" hits="1"/><line number="5" hits="0"/><line number="6" hits="0"/>
</lines></class></classes></package></packages></coverage>
EOF
got=$(dc "$C" --min 80)
grep -q "1/3 = 33%" <<<"$got" && ok "путь склеивается с корнем из <source>" || bad "source" "1/3 = 33%" "$got"
sed -i "s|<source>$C/src</source>|<source>/ci/build/src</source>|" "$C/coverage.xml"
got=$(dc "$C" --min 80)
grep -q "1/3 = 33%" <<<"$got" && ok "корень из чужого контейнера находится по хвосту" || bad "чужой source" "1/3 = 33%" "$got"

echo "== подпроект в монорепозитории =="
# git отдаёт пути от корня репозитория (api/src/m.py), отчёт подпроекта —
# от его каталога (src/m.py). Раньше не совпадало ничего, и гейт проходил.
M="$TMP/mono"; mkrepo "$M"; mkdir -p "$M/api/src" "$M/web"
printf 'a = 1\n' > "$M/api/src/m.py"; printf 'x\n' > "$M/web/w.py"; commit_all "$M"
printf 'a = 1\ndef f():\n    return 2\n' > "$M/api/src/m.py"
printf 'x\ny\n' > "$M/web/w.py"
cat > "$M/api/coverage.xml" <<'EOF'
<?xml version="1.0"?><coverage><packages><package><classes>
<class filename="src/m.py"><lines><line number="1" hits="1"/><line number="2" hits="0"/><line number="3" hits="0"/></lines></class>
</classes></package></packages></coverage>
EOF
got=$(dc "$M/api" --min 80)
grep -q "0/2 = 0%" <<<"$got" && ok "пути подпроекта сопоставляются с отчётом" || bad "монорепо" "0/2 = 0%" "$got"
grep -q "web/w.py" <<<"$got" && bad "монорепо: чужой подпроект" "не упоминается" "$got" \
  || ok "правки соседнего подпроекта в знаменатель не идут"
sed -i 's|filename="src/m.py"|filename="api/src/m.py"|' "$M/api/coverage.xml"
got=$(dc "$M/api" --min 80)
grep -q "0/2 = 0%" <<<"$got" && ok "отчёт с путями от корня репозитория тоже" || bad "монорепо от корня" "0/2 = 0%" "$got"

echo "== одинаковые имена в разных каталогах =="
# Суффиксное сравнение сопоставляло app.py с /ci/build/sub/app.py — покрытым,
# хотя в отчёте был и свой /ci/build/app.py, непокрытый.
K="$TMP/collide"; mkrepo "$K"; mkdir -p "$K/sub"
printf 'a = 1\n' > "$K/app.py"; printf 'a = 1\n' > "$K/sub/app.py"; commit_all "$K"
printf 'a = 1\nb = 2\nc = 3\n' > "$K/app.py"
cat > "$K/clover.xml" <<'EOF'
<?xml version="1.0"?><coverage><project>
<file name="/ci/build/sub/app.py"><line num="2" type="stmt" count="5"/><line num="3" type="stmt" count="5"/></file>
<file name="/ci/build/app.py"><line num="2" type="stmt" count="0"/><line num="3" type="stmt" count="0"/></file>
</project></coverage>
EOF
got=$(dc "$K" --min 80)
grep -q "0/2 = 0%" <<<"$got" && ok "файл сопоставлен со своим, а не с однофамильцем" || bad "коллизия" "0/2 = 0%" "$got"

echo "== пути не латиницей и чужие настройки git =="
# core.quotepath заключал путь в кавычки с восьмеричными кодами, diff.noprefix
# убирал b/ — в обоих случаях файл выпадал, и гейт говорил «нечего проверять».
U="$TMP/unicode"; mkrepo "$U"; mkdir -p "$U/src"
printf 'a\n' > "$U/src/Заказ.php"; commit_all "$U"
printf 'a\nb\nc\n' > "$U/src/Заказ.php"; printf 'x\ny\n' > "$U/src/Счёт.php"
git -C "$U" config core.quotepath true; git -C "$U" config diff.noprefix true
cat > "$U/coverage.xml" <<'EOF'
<?xml version="1.0"?><coverage><project>
<file name="src/Заказ.php"><line num="2" type="stmt" count="0"/><line num="3" type="stmt" count="0"/></file>
<file name="src/Счёт.php"><line num="1" type="stmt" count="0"/><line num="2" type="stmt" count="0"/></file>
</project></coverage>
EOF
got=$(dc "$U" --min 80)
grep -q "0/4 = 0%" <<<"$got" && ok "кириллица в пути и diff.noprefix не выключают гейт" || bad "не латиница" "0/4 = 0%" "$got"

echo "== тесты, конфиги и чужие каталоги в знаменатель не идут =="
# Обратная сторона строгости: тестов и миграций в отчёте о покрытии не бывает,
# и засчитывать их строки непокрытыми — значит валить каждую задачу с тестом.
T="$TMP/scope"; mkrepo "$T"; mkdir -p "$T/src" "$T/tests" "$T/database"
printf 'a = 1\nb = 2\nc = 3\n' > "$T/src/a.py"; commit_all "$T"
printf 'a = 1\nb = 2\nc = 3\nd = 4\ne = 5\n' > "$T/src/a.py"
printf 'def test_a():\n    assert 1\n' > "$T/tests/test_a.py"
printf 'x = 1\ny = 2\n' > "$T/database/m1.py"
printf 'export default {}\n' > "$T/vite.config.ts"
cat > "$T/coverage.xml" <<'EOF'
<?xml version="1.0"?><coverage><project><file name="src/a.py">
<line num="1" type="stmt" count="1"/><line num="2" type="stmt" count="1"/><line num="3" type="stmt" count="1"/>
<line num="4" type="stmt" count="1"/><line num="5" type="stmt" count="1"/>
</file></project></coverage>
EOF
got=$(dc "$T" --min 80); rc=$(dc_rc "$T" --min 80)
[[ "$rc" == "0" ]] && grep -q "2/2 = 100%" <<<"$got" \
  && ok "тесты, конфиг сборки и каталог вне отчёта не засчитаны непокрытыми" || bad "область" "2/2 = 100%, код 0" "$rc: $got"
grep -q "database/m1.py" <<<"$got" && ok "файлы вне области отчёта названы вслух" || bad "вне области" "database/m1.py" "$got"

echo "== отчёт не про этот проект =="
X="$TMP/foreign"; mkrepo "$X"; mkdir -p "$X/src"
printf 'a = 1\n' > "$X/src/x.py"; commit_all "$X"; printf 'a = 1\nb = 2\n' > "$X/src/x.py"
clover "$X/coverage.xml" other/y.py 1 1
got=$(dc_rc "$X" --min 80)
[[ "$got" == "3" ]] && ok "пути отчёта не сопоставились — «не проверено», а не «нечего»" || bad "чужой отчёт" 3 "$got"

echo "== неглубокий клон: общего предка нет =="
# actions/checkout по умолчанию клонирует на глубину 1. Общего предка с main
# не находилось, гейт тихо переходил на незакоммиченную работу, а её в CI нет.
O="$TMP/origin"; mkrepo "$O"; git -C "$O" checkout -q -b main 2>/dev/null
printf 'a = 1\n' > "$O/a.py"; commit_all "$O"; printf 'a = 1\nb = 2\n' > "$O/a.py"; commit_all "$O"
git -C "$O" checkout -q -b feat; printf 'a = 1\nb = 2\nc = 3\n' > "$O/a.py"; commit_all "$O"
SH="$TMP/shallow"
git clone -q --depth 1 --no-single-branch "file://$O" "$SH" 2>/dev/null
clover "$SH/coverage.xml" a.py 1 1 1
got=$(dc "$SH"); rc=$(dc_rc "$SH")
[[ "$rc" == "3" ]] && ok "без общего предка — «не проверено», а не пустой зелёный" || bad "неглубокий клон" 3 "$rc: $got"
grep -q "fetch-depth" <<<"$got" && ok "подсказано, как починить (fetch-depth: 0)" || bad "подсказка" "fetch-depth" "$got"
got=$(dc_rc "$SH" --base nonexistent-ref)
[[ "$got" == "3" ]] && ok "указанная, но несуществующая база — «не проверено»" || bad "нет базы" 3 "$got"
# Сборка PR: забрана одна ветка, основной в клоне нет вовсе
SH1="$TMP/shallow-single"
git clone -q --depth 1 --single-branch --branch feat "file://$O" "$SH1" 2>/dev/null
clover "$SH1/coverage.xml" a.py 1 1 1
got=$(dc_rc "$SH1")
[[ "$got" == "3" ]] && ok "неглубокий клон одной ветки — тоже «не проверено»" || bad "одна ветка" 3 "$got"

echo
printf 'Пройдено: \033[32m%d\033[0m   Провалено: \033[31m%d\033[0m\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
