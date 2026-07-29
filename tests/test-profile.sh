#!/usr/bin/env bash
# test-profile.sh — тесты профилей, детектора состояния проекта и храповика.
#
# Профиль определяется по фактам из git и файловой системы, поэтому проверяется
# так же: собираем игрушечный репозиторий с нужной историей и смотрим вывод.
set -uo pipefail
export LC_NUMERIC=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROF="$ROOT/plugins/std-core/scripts/std-profile.sh"
SETUP="$ROOT/plugins/std-core/scripts/std-setup.sh"
RATCHET="$ROOT/plugins/std-gauntlet/scripts/ratchet.sh"
GUARD="$ROOT/plugins/std-core/scripts/guard-tests.sh"
PASS=0; FAIL=0
ok()  { printf '  \033[32mOK\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n     ожидали: %s\n     получили: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# repo <каталог> <число коммитов> <число авторов> <число тестовых файлов>
#
# История создаётся пустыми коммитами: файловые операции на каждой итерации
# делают подготовку сотен коммитов заметно медленнее, а для определения
# профиля важно только их количество и авторы.
repo() {
  local d="$1" commits="$2" authors="$3" tests="$4"
  mkdir -p "$d/src" "$d/tests"
  ( cd "$d" || exit 1
    git init -q 2>/dev/null
    local i
    for ((i=1; i<=tests; i++)); do echo "<?php // test $i" > "tests/Case${i}Test.php"; done
    for ((i=1; i<=5; i++)); do echo "<?php // src $i" > "src/File$i.php"; done
    # add -A обязателен: commit -a видит только уже отслеживаемые файлы
    git add -A >/dev/null 2>&1
    git -c user.email="dev1@x" -c user.name="dev1" commit -qm "c1" >/dev/null 2>&1
    local n
    for ((i=2; i<=commits; i++)); do
      n=$(( (i % authors) + 1 ))
      git -c user.email="dev$n@x" -c user.name="dev$n" \
          commit -q --allow-empty -m "c$i" >/dev/null 2>&1
    done ) >/dev/null 2>&1

  # Подготовка должна быть проверяемой: без этого «профиль определился не так»
  # выглядит как ошибка детектора, хотя история просто не создалась
  local got
  got=$(git -C "$d" rev-list --count HEAD 2>/dev/null || echo 0)
  if [[ "$got" != "$commits" ]]; then
    bad "подготовка репозитория $(basename "$d")" "$commits коммитов" "$got"
    return 1
  fi
}

profile_of() { CLAUDE_PROJECT_DIR="$1" bash "$PROF" --json 2>/dev/null | jq -r '.profile'; }

echo "== определение профиля по состоянию проекта =="

repo "$TMP/proto" 5 1 0
got=$(profile_of "$TMP/proto")
[[ "$got" == "prototype" ]] && ok "мало коммитов, нет тестов -> prototype" || bad "prototype" prototype "$got"

repo "$TMP/legacy" 250 2 0
got=$(profile_of "$TMP/legacy")
[[ "$got" == "legacy" ]] && ok "много коммитов без тестов -> legacy" || bad "legacy" legacy "$got"

# Строгость по числу авторов не угадывается. Раньше один автор давал solo,
# а двое — team; на живом проекте это включало требование спеки и прогона
# гейтов там, где гейтов нет. Требование без проверки за ним обесценивает
# остальные, поэтому планка поднимается только явным --profile.
repo "$TMP/solo" 40 1 6
got=$(profile_of "$TMP/solo")
[[ "$got" == "prototype" ]] && ok "один автор с тестами -> prototype, а не solo" || bad "один автор" prototype "$got"

repo "$TMP/team" 40 3 6
got=$(profile_of "$TMP/team")
[[ "$got" == "prototype" ]] && ok "несколько авторов -> prototype, а не team" || bad "несколько авторов" prototype "$got"

for d in proto solo team legacy; do
  got=$(profile_of "$TMP/$d")
  [[ "$got" == "prototype" || "$got" == "legacy" ]] \
    || bad "автовыбор ограничен двумя профилями" "prototype или legacy" "$got"
done
ok "автоматически выбираются только prototype и legacy"

# Профили, которые нельзя проверить на живом проекте, в наборе не держим
PROFILES_JSON="$ROOT/plugins/std-core/profiles/profiles.json"
if jq -e '.profiles | has("corporate") or has("regulated")' "$PROFILES_JSON" >/dev/null 2>&1; then
  bad "набор профилей" "без corporate и regulated" "$(jq -r '.profiles|keys|join(", ")' "$PROFILES_JSON")"
else
  ok "в наборе только проверяемые профили"
fi

# Регрессия: один человек, коммитящий с двух адресов, считался двумя авторами.
# На профиль это больше не влияет, но факт печатается человеку и должен быть верным.
S1="$TMP/two-mails"; mkdir -p "$S1/src"
( cd "$S1" && git init -q 2>/dev/null
  echo "x" > src/a.php && git add -A >/dev/null 2>&1
  git -c user.email=me@home -c user.name="Один Человек" commit -qm c1 >/dev/null 2>&1
  echo "y" >> src/a.php && git add -A >/dev/null 2>&1
  git -c user.email=me@work -c user.name="Один Человек" commit -qm c2 >/dev/null 2>&1
  for i in $(seq 3 20); do
    echo "$i" >> src/a.php && git add -A >/dev/null 2>&1
    git -c user.email=me@work -c user.name="Один Человек" commit -qm "c$i" >/dev/null 2>&1
  done ) >/dev/null 2>&1
mkdir -p "$S1/tests"; echo '<?php' > "$S1/tests/ATest.php"
got=$(CLAUDE_PROJECT_DIR="$S1" bash "$PROF" --json 2>/dev/null | jq -r '.facts.activeAuthors')
[[ "$got" == "1" ]] && ok "два адреса одного человека — это один автор" || bad "два адреса" 1 "$got"

echo "== факты о проекте =="
F=$(CLAUDE_PROJECT_DIR="$TMP/team" bash "$PROF" --json 2>/dev/null)
[[ "$(jq -r '.facts.activeAuthors' <<<"$F")" == "3" ]] && ok "авторы посчитаны верно" \
  || bad "авторы" 3 "$(jq -r '.facts.activeAuthors' <<<"$F")"
jq -e '.facts.testRatio | tonumber' <<<"$F" >/dev/null 2>&1 \
  && ok "доля тестов — число с точкой (локаль не влияет)" \
  || bad "доля тестов" "число" "$(jq -r '.facts.testRatio' <<<"$F")"

echo "== храповик =="
R="$TMP/ratchet"; mkdir -p "$R/.claude"
echo '{"mutation":{"floor":0}}' > "$R/.claude/gauntlet.json"
rc() { CLAUDE_PROJECT_DIR="$R" bash "$RATCHET" check "$1" >/dev/null 2>&1; echo $?; }

[[ "$(rc 20)" == "0" ]] && ok "старт с нуля: любое значение принимается" || bad "старт" 0 "$(rc 20)"
[[ "$(rc 45)" == "0" ]] && ok "рост поднимает планку"                     || bad "рост" 0 "$(rc 45)"
[[ "$(rc 44)" == "0" ]] && ok "колебание в пределах допуска проходит"      || bad "допуск" 0 "$(rc 44)"
[[ "$(rc 30)" == "1" ]] && ok "падение ниже планки валит гейт"             || bad "падение" 1 "$(rc 30)"
[[ "$(CLAUDE_PROJECT_DIR=$R bash "$RATCHET" show | grep -c 'планка: 45')" == "1" ]] \
  && ok "планка сохраняется между прогонами" || bad "планка" "45" "другое"

CLAUDE_PROJECT_DIR="$R" bash "$RATCHET" reset 10 >/dev/null 2>&1
[[ "$(rc 12)" == "0" ]] && ok "ручной сброс планки работает" || bad "сброс" 0 "$(rc 12)"

echo "== профиль управляет строгостью замка тестов =="
G="$TMP/guard"; mkdir -p "$G/.claude/tests"
echo '<?php' > "$G/.claude/tests/ExistingTest.php"
guard_decision() { # <профиль> -> решение
  printf '{"guardTests": "%s"}' "$1" > "$G/.claude/gauntlet.json"
  jq -n --arg p "$G/.claude/tests/ExistingTest.php" '{tool_name:"Edit",tool_input:{file_path:$p}}' \
    | CLAUDE_PROJECT_DIR="$G" bash "$GUARD" 2>/dev/null \
    | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null
}
d=$(guard_decision off);  d=${d:-allow}
[[ "$d" == "allow" ]] && ok "прототип: правка теста не мешает работе" || bad "off" allow "$d"
[[ "$(guard_decision ask)"  == "ask"  ]] && ok "команда: правка теста эскалируется"  || bad "ask" ask "$(guard_decision ask)"
[[ "$(guard_decision deny)" == "deny" ]] && ok "повышенные требования: правка запрещена" || bad "deny" deny "$(guard_decision deny)"

echo "== единая команда настройки =="
S="$TMP/setup"; mkdir -p "$S"
( cd "$S" && echo '{"require":{"laravel/framework":"^11.0"}}' > composer.json && git init -q 2>/dev/null
  git -c user.email=a@x -c user.name=a add -A 2>/dev/null
  git -c user.email=a@x -c user.name=a commit -qm init 2>/dev/null )
OUT=$(VIBE_RULES_HOME="$ROOT" CLAUDE_PROJECT_DIR="$S" bash "$SETUP" --dry-run 2>&1)
grep -q 'профиль:' <<<"$OUT" && ok "setup --dry-run сообщает профиль"       || bad "dry-run профиль" "строка с профилем" "нет"
[[ ! -f "$S/.claude/gauntlet.json" ]] && ok "--dry-run ничего не записывает" || bad "--dry-run" "файла нет" "файл создан"

VIBE_RULES_HOME="$ROOT" CLAUDE_PROJECT_DIR="$S" bash "$SETUP" >/dev/null 2>&1
if [[ -f "$S/.claude/gauntlet.json" ]] && jq -e '.profile and .gates and .mutation' "$S/.claude/gauntlet.json" >/dev/null 2>&1; then
  ok "setup записывает корректный gauntlet.json"
else
  bad "setup" "валидный gauntlet.json" "нет или неполный"
fi

# Ручные правки не должны затираться повторным запуском
jq '.gates.test = "МОЯ КОМАНДА"' "$S/.claude/gauntlet.json" > "$S/.claude/tmp" && mv "$S/.claude/tmp" "$S/.claude/gauntlet.json"
VIBE_RULES_HOME="$ROOT" CLAUDE_PROJECT_DIR="$S" bash "$SETUP" >/dev/null 2>&1
[[ "$(jq -r '.gates.test' "$S/.claude/gauntlet.json")" == "МОЯ КОМАНДА" ]] \
  && ok "повторный setup сохраняет ручные правки" \
  || bad "слияние конфигов" "МОЯ КОМАНДА" "$(jq -r '.gates.test' "$S/.claude/gauntlet.json")"

echo "== автоустановка плагинов и пересинхронизация =="

# Модуль из одних правил ставить не нужно — он приезжает симлинком.
# Установка требуется там, где есть хуки, скиллы или команды.
A="$TMP/autoinstall"; mkdir -p "$A"
( cd "$A" && printf '<!doctype html><html lang=ru><body>x</body></html>' > index.html
  printf 'body{color:red}' > style.css
  git init -q 2>/dev/null; git add -A >/dev/null 2>&1
  git -c user.email=a@x -c user.name=a commit -qm init >/dev/null 2>&1 ) >/dev/null 2>&1

# Подменяем базу установленных плагинов на пустую: результат не должен
# зависеть от того, что стоит на машине, где идут тесты
echo '{"version":2,"plugins":{}}' > "$TMP/empty-plugins.json"
OUT=$(VIBE_RULES_HOME="$ROOT" VIBE_RULES_INSTALLED_DB="$TMP/empty-plugins.json" \
      CLAUDE_PROJECT_DIR="$A" bash "$SETUP" --dry-run 2>&1 | sed 's/\x1b\[[0-9;]*m//g')

grep -q 'установил бы' <<<"$OUT" \
  && ok "setup сообщает, какие плагины поставит" \
  || bad "автоустановка" "строка «установил бы»" "нет"

grep -q 'core' <<<"$(grep 'установил бы' <<<"$OUT")" \
  && ok "модули с хуками попадают в установку" \
  || bad "модули с хуками" "core в списке" "нет"

grep -qE 'только правила.*web-html' <<<"$OUT" \
  && ok "модули из одних правил в установку не попадают" \
  || bad "модули-правила" "web-html среди «только правила»" "нет"

grep -q 'установил бы.*web-html' <<<"$OUT" \
  && bad "модуль правил не должен ставиться" "web-html вне установки" "он в списке установки" \
  || ok "web-html не ставится как плагин"

# Полный набор для этого проекта — все модули с хуками, а не только ядро:
# std-web-design приезжает вместе со стилями и тоже несёт хук, поэтому без него
# «доустанавливать нечего» не наступит.
echo '{"version":2,"plugins":{"std-core@vibe-rules":[{"scope":"user"}],"std-gauntlet@vibe-rules":[{"scope":"user"}],"std-web-design@vibe-rules":[{"scope":"user"}]}}' > "$TMP/full-plugins.json"
OUTF=$(VIBE_RULES_HOME="$ROOT" VIBE_RULES_INSTALLED_DB="$TMP/full-plugins.json" \
       CLAUDE_PROJECT_DIR="$A" bash "$SETUP" --dry-run 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
grep -q 'доустанавливать нечего' <<<"$OUTF" \
  && ok "уже установленные плагины не ставятся повторно" \
  || bad "повторная установка" "«доустанавливать нечего»" "нет"

# --sync берёт профиль из конфигурации, а не определяет заново
S2="$TMP/syncproj"; mkdir -p "$S2/.claude"
( cd "$S2" && echo '{"require":{"laravel/framework":"^11.0"}}' > composer.json
  git init -q 2>/dev/null; git add -A >/dev/null 2>&1
  git -c user.email=a@x -c user.name=a commit -qm init >/dev/null 2>&1 ) >/dev/null 2>&1
printf '{"profile": "team", "gates": {}}' > "$S2/.claude/gauntlet.json"

OUT2=$(VIBE_RULES_HOME="$ROOT" VIBE_RULES_INSTALLED_DB="$TMP/empty-plugins.json" \
       CLAUDE_PROJECT_DIR="$S2" bash "$SETUP" --sync --dry-run 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
# Ищем именно строку выбора: слово team встречается и в подсказке «--profile solo|team»
grep -q 'профиль: team' <<<"$OUT2" \
  && ok "--sync сохраняет профиль, заданный человеком" \
  || bad "--sync профиль" "профиль: team" "переопределён автоопределением"

OUT3=$(VIBE_RULES_HOME="$ROOT" VIBE_RULES_INSTALLED_DB="$TMP/empty-plugins.json" \
       CLAUDE_PROJECT_DIR="$S2" bash "$SETUP" --dry-run 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
grep -q 'профиль: team' <<<"$OUT3" \
  && bad "setup без --sync определяет заново" "не team" "team" \
  || ok "setup без --sync определяет профиль заново"

# Явное указание строгости должно работать: автовыбор её больше не даёт
OUT4=$(VIBE_RULES_HOME="$ROOT" VIBE_RULES_INSTALLED_DB="$TMP/empty-plugins.json" \
       CLAUDE_PROJECT_DIR="$S" bash "$SETUP" --profile solo --dry-run 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
grep -q 'профиль: solo' <<<"$OUT4" \
  && ok "--profile поднимает планку явно" || bad "--profile solo" "профиль: solo" "не применился"

echo "== требования профиля доходят до модели =="
SC0="$TMP/ctx"; mkdir -p "$SC0/.claude/rules"
ln -sfn "$ROOT/plugins/std-core/rules" "$SC0/.claude/rules/std-core"
ctx() { printf '{}' | CLAUDE_PROJECT_DIR="$SC0" bash "$ROOT/plugins/std-core/scripts/session-check.sh" 2>/dev/null \
        | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null; }

echo '{"profile":"prototype","specFirst":false,"requireBeforeCommit":false}' > "$SC0/.claude/gauntlet.json"
[[ -z "$(ctx)" ]] && ok "прототип: лишнего в контекст не добавляется" || bad "prototype" "пусто" "$(ctx)"

echo '{"profile":"solo","specFirst":true,"requireBeforeCommit":true}' > "$SC0/.claude/gauntlet.json"
grep -q 'критерий приёмки' <<<"$(ctx)" \
  && ok "specFirst доносится до модели, а не только до скриптов" \
  || bad "specFirst" "требование спеки в контексте" "нет"
grep -q 'std-gauntlet:run' <<<"$(ctx)" \
  && ok "требование гейтов перед коммитом попадает в контекст" || bad "requireBeforeCommit" "есть" "нет"

echo '{"profile":"legacy","specFirst":false,"requireBeforeCommit":false}' > "$SC0/.claude/gauntlet.json"
grep -q 'эталон' <<<"$(ctx)" \
  && ok "легаси: сначала зафиксировать поведение" || bad "legacy" "упоминание эталона" "нет"

rm -f "$SC0/.claude/gauntlet.json"
[[ -z "$(ctx)" ]] && ok "без конфигурации проекта хук молчит" || bad "без конфига" "пусто" "$(ctx)"

echo "== область установки =="

SC="$TMP/scoped"; mkdir -p "$SC"
( cd "$SC" && printf '<!doctype html><html lang=ru><body>x</body></html>' > index.html
  git init -q 2>/dev/null; git add -A >/dev/null 2>&1
  git -c user.email=a@x -c user.name=a commit -qm init >/dev/null 2>&1 ) >/dev/null 2>&1

VIBE_RULES_HOME="$ROOT" VIBE_RULES_INSTALLED_DB="$TMP/empty-plugins.json" \
  CLAUDE_PROJECT_DIR="$SC" bash "$SETUP" --scope project --no-install --profile prototype >/dev/null 2>&1

SET="$SC/.claude/settings.json"
[[ -f "$SET" ]] && ok "scope=project пишет .claude/settings.json" || bad "settings.json" "файла нет"

jq -e '.extraKnownMarketplaces["vibe-rules"]' "$SET" >/dev/null 2>&1 \
  && ok "маркетплейс объявлен в настройках проекта" || bad "маркетплейс" "нет в settings.json"

# Локальный путь в проектный файл попадать не должен: у коллеги его не будет
[[ "$(jq -r '.extraKnownMarketplaces["vibe-rules"].source.source' "$SET")" == "github" ]] \
  && ok "источник записан как github, а не путь на диске" \
  || bad "источник" "$(jq -r '.extraKnownMarketplaces["vibe-rules"].source.source' "$SET")"

jq -e '.enabledPlugins | has("std-core@vibe-rules")' "$SET" >/dev/null 2>&1 \
  && ok "нужные плагины перечислены для автоустановки" || bad "enabledPlugins" "пусто"

# scope=user не должен трогать файлы проекта
SU="$TMP/userscope"; mkdir -p "$SU"
( cd "$SU" && printf '<!doctype html><html lang=ru><body>x</body></html>' > index.html
  git init -q 2>/dev/null; git add -A >/dev/null 2>&1
  git -c user.email=a@x -c user.name=a commit -qm init >/dev/null 2>&1 ) >/dev/null 2>&1
VIBE_RULES_HOME="$ROOT" VIBE_RULES_INSTALLED_DB="$TMP/empty-plugins.json" \
  CLAUDE_PROJECT_DIR="$SU" bash "$SETUP" --no-install --profile prototype >/dev/null 2>&1
[[ ! -f "$SU/.claude/settings.json" ]] \
  && ok "scope=user не пишет настройки в проект" || bad "scope=user" "settings.json создан"

# Существующие настройки проекта не затираются
printf '{"env":{"MY_VAR":"1"}}' > "$SC/.claude/settings.json"
VIBE_RULES_HOME="$ROOT" VIBE_RULES_INSTALLED_DB="$TMP/empty-plugins.json" \
  CLAUDE_PROJECT_DIR="$SC" bash "$SETUP" --scope project --no-install --profile prototype >/dev/null 2>&1
jq -e '.env.MY_VAR == "1"' "$SET" >/dev/null 2>&1 \
  && ok "чужие настройки проекта сохраняются" || bad "слияние настроек" "MY_VAR потерян"

echo
printf 'Пройдено: \033[32m%d\033[0m   Провалено: \033[31m%d\033[0m\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
