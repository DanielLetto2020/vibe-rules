#!/usr/bin/env bash
# test-hooks.sh — unit-тесты замков.
#
# Хук — это чистая функция: JSON на входе, решение на выходе. Значит он
# тестируется полностью детерминированно, без запуска модели и без токенов.
# Это и есть ответ на «как убедиться, что правила работают, не лazя в код».
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/require.sh"; require_tools jq git python3
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
# Замки методологии срабатывают только в проектах, подключённых к стандартам.
# Тестовый каталог помечаем подключённым, иначе они молчат и проверяется не то.
mkdir -p "$TMP/.claude"; echo '{"guardTests":"ask"}' > "$TMP/.claude/gauntlet.json"
export CLAUDE_PROJECT_DIR="$TMP"
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

# Периметр обязан охранять собственные ворота: правка настроек хуков или самого
# скрипта замка отключает всё остальное разом, и ни один тест этого не заметит —
# проверять станет некому, а зелёный прогон останется зелёным.
mkdir -p "$TMP/.githooks" "$TMP/.claude/rules"
touch "$TMP/.claude/settings.json" "$TMP/.githooks/pre-push" \
      "$TMP/.claude/rules/50-project.md" "$TMP/.claude/policy.json"
infra_case "настройки хуков и разрешений" "$TMP/.claude/settings.json"      ask
infra_case "конфигурация гейтов"          "$TMP/.claude/gauntlet.json"      ask
infra_case "политика стека"               "$TMP/.claude/policy.json"        ask
infra_case "правило уровня проекта"       "$TMP/.claude/rules/50-project.md" ask
infra_case "git-хук"                      "$TMP/.githooks/pre-push"         ask

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
echo '{}' > "$GP/.claude/gauntlet.json"

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

echo "== плагин стоит на машине, но чужие проекты не трогает =="
# Замки методологии применяются там, где стандарты приняли. Иначе первый же
# посторонний проект встречает вопросы, которых человек не просил, и замки
# отключают целиком. Защита от необратимого работает везде.
NOSTD="$TMP/чужой"; mkdir -p "$NOSTD/tests"
echo '<?php' > "$NOSTD/tests/ATest.php"; touch "$NOSTD/Dockerfile"

silent() { # <скрипт> <json> -> 0 если замок промолчал
  local out
  out=$(printf '%s' "$2" | CLAUDE_PROJECT_DIR="$NOSTD" bash "$1" 2>/dev/null)
  [[ -z "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)" ]]
}

silent "$ROOT/plugins/std-gauntlet/scripts/guard-commit.sh" \
       "$(jq -n '{tool_name:"Bash",tool_input:{command:"git commit -m x"}}')" \
  && ok "коммит в чужом проекте не спрашивают" || bad "guard-commit в чужом" "молчание" "решение"

silent "$ROOT/plugins/std-core/scripts/guard-tests.sh" \
       "$(jq -n --arg p "$NOSTD/tests/ATest.php" '{tool_name:"Edit",tool_input:{file_path:$p}}')" \
  && ok "правку теста в чужом проекте не блокируют" || bad "guard-tests в чужом" "молчание" "решение"

silent "$ROOT/plugins/std-core/scripts/guard-infra.sh" \
       "$(jq -n --arg p "$NOSTD/Dockerfile" '{tool_name:"Edit",tool_input:{file_path:$p}}')" \
  && ok "правку Dockerfile в чужом проекте не трогают" || bad "guard-infra в чужом" "молчание" "решение"

# А необратимое блокируется независимо от того, знает ли проект о стандартах
OUT=$(jq -n '{tool_name:"Bash",tool_input:{command:"podman volume rm data"}}' \
      | CLAUDE_PROJECT_DIR="$NOSTD" bash "$SCRIPTS/guard-bash.sh" 2>/dev/null \
      | jq -r '.hookSpecificOutput.permissionDecision // "allow"')
[[ "$OUT" == "deny" ]] && ok "удаление тома блокируется и в чужом проекте" \
  || bad "guard-bash в чужом" deny "$OUT"

# Признак подключённого проекта — конфигурация или слинкованные правила
mkdir -p "$NOSTD/.claude"; echo '{"guardTests":"ask"}' > "$NOSTD/.claude/gauntlet.json"
OUT=$(jq -n --arg p "$NOSTD/tests/ATest.php" '{tool_name:"Edit",tool_input:{file_path:$p}}' \
      | CLAUDE_PROJECT_DIR="$NOSTD" bash "$SCRIPTS/guard-tests.sh" 2>/dev/null \
      | jq -r '.hookSpecificOutput.permissionDecision // "allow"')
[[ "$OUT" == "ask" ]] && ok "в подключённом проекте замок снова работает" \
  || bad "guard-tests в подключённом" ask "$OUT"

echo "== rules-recheck: какие правила действуют на правленый файл =="
# Хук называет модули, чьи paths совпали с путём файла. Проверяем и совпадение,
# и молчание там, где правил нет: ложное срабатывание на каждый файл — это шум,
# а шум отключают вместе с проверкой.
RC="$TMP/recheck"; mkdir -p "$RC/.claude/rules" "$RC/pages" "$RC/src"
for m in std-web-html std-web-css std-js-base std-js-typescript std-js-vue3 std-js-nuxt; do
  ln -sfn "$ROOT/plugins/$m/rules" "$RC/.claude/rules/$m"
done

recheck() { # <относительный путь> -> список модулей (или пусто)
  local rel="$1"
  mkdir -p "$RC/$(dirname "$rel")"; touch "$RC/$rel"
  # session_id уникален на вызов: напоминание выдаётся раз на файл за сессию,
  # и без этого второй кейс подряд получил бы молчание
  jq -n --arg p "$RC/$rel" --arg s "s$RANDOM" \
     '{session_id:$s,tool_name:"Write",tool_input:{file_path:$p}}' \
    | CLAUDE_PROJECT_DIR="$RC" TMPDIR="$TMP" bash "$SCRIPTS/rules-recheck.sh" 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext // ""'
}

got=$(recheck "index.html")
grep -q 'std-web-html/10-markup' <<<"$got" \
  && ok "html: правила разметки названы" || bad "html" "std-web-html" "$got"

# Регрессия: `{js,mjs,cjs}` не раскрывается сопоставлением bash, и модуль
# языка молчал бы на обычном .js-файле
got=$(recheck "src/util.js")
grep -q 'std-js-base/10-language' <<<"$got" \
  && ok "перечисление в фигурных скобках раскрывается" || bad "{js,mjs}" "std-js-base" "$got"

# Регрессия: `**/pages/**/*.vue` должен совпадать и с pages/index.vue —
# `**` внутри пути не эквивалентен одной звёздочке, а ведущий `**/` обязан
# оставаться необязательным: иначе правило перестанет видеть код в корне
got=$(recheck "pages/index.vue")
grep -q 'std-js-nuxt/10-nuxt' <<<"$got" \
  && ok "** внутри пути совпадает с нулём каталогов" || bad "pages/**" "std-js-nuxt" "$got"

# SFC — это разметка, стили и логика в одном файле: должны сойтись все слои.
# Проверяется по тому же $got, что и кейс выше, — не перезаписывать его между ними
for m in std-web-html std-web-css std-js-vue3 std-js-typescript; do
  grep -q "$m" <<<"$got" || bad "SFC: $m не назван" "$m" "$got"
done
ok "для .vue названы разметка, стили, компоненты и типы"

# Регрессия: приложение живёт в подкаталоге чаще, чем кажется. Маски без
# ведущего `**/` делали мёртвой треть модулей — правило молча не грузилось,
# и выглядело это как «файлов такого типа в проекте нет»
got=$(recheck "client-app/pages/index.vue")
grep -q 'std-js-nuxt/10-nuxt' <<<"$got" \
  && ok "приложение в подкаталоге: правила стека названы" \
  || bad "монорепа" "std-js-nuxt" "$got"

# Обратная сторона той же правки: маски достают до чужого и сгенерированного
# кода. Напоминание там — шум, а шум отключают вместе с проверкой
for junk in "node_modules/some-lib/pages/index.vue" "vendor/lib/src/util.js" \
            "dist/index.html" "client-app/node_modules/x/pages/a.vue"; do
  got=$(recheck "$junk")
  [[ -z "$got" ]] || bad "чужой код: $junk" "молчание" "$got"
done
ok "vendor, node_modules и сборка напоминаний не порождают"

got=$(recheck "notes.txt")
[[ -z "$got" ]] && ok "файл вне правил не порождает напоминания" || bad "txt" "молчание" "$got"

got=$(recheck ".claude/settings.json")
[[ -z "$got" ]] && ok "служебные файлы .claude не проверяются" || bad ".claude" "молчание" "$got"

# Второй раз тот же файл в той же сессии — молчание: повтор на каждый Edit
# превращается в шум
SID="repeat$RANDOM"
same() {
  jq -n --arg p "$RC/index.html" --arg s "$SID" \
     '{session_id:$s,tool_name:"Edit",tool_input:{file_path:$p}}' \
    | CLAUDE_PROJECT_DIR="$RC" TMPDIR="$TMP" bash "$SCRIPTS/rules-recheck.sh" 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext // ""'
}
first=$(same); second=$(same)
[[ -n "$first" && -z "$second" ]] \
  && ok "повторная правка того же файла молчит" || bad "повтор" "первый есть, второй пуст" "$first|$second"

# Чужой проект без слинкованных правил хук не трогает
got=$(jq -n --arg p "$NOSTD/tests/ATest.php" --arg s "x$RANDOM" \
        '{session_id:$s,tool_name:"Edit",tool_input:{file_path:$p}}' \
      | CLAUDE_PROJECT_DIR="$NOSTD" TMPDIR="$TMP" bash "$SCRIPTS/rules-recheck.sh" 2>/dev/null)
[[ -z "$got" ]] && ok "в проекте без правил хук молчит" || bad "чужой проект" "молчание" "$got"

# Выключатель
got=$(jq -n --arg p "$RC/src/app.ts" --arg s "off$RANDOM" \
        '{session_id:$s,tool_name:"Write",tool_input:{file_path:$p}}' \
      | STD_RECHECK=0 CLAUDE_PROJECT_DIR="$RC" TMPDIR="$TMP" bash "$SCRIPTS/rules-recheck.sh" 2>/dev/null)
[[ -z "$got" ]] && ok "STD_RECHECK=0 отключает напоминания" || bad "выключатель" "молчание" "$got"

echo "== design-context: оформление, принятое в проекте =="
# Правило «придерживайся существующего дизайна» бесполезно, пока агент не знает,
# какой дизайн существует. Хук достаёт факты из кода — проверяем оба исхода:
# нашлось оформление и не нашлось ничего.
DSG="$ROOT/plugins/std-web-design/scripts/design-context.sh"

design_ctx() { # <каталог проекта> <файл> -> текст напоминания
  jq -n --arg p "$1/$2" --arg s "dsg$RANDOM" \
     '{session_id:$s,tool_name:"Edit",tool_input:{file_path:$p}}' \
    | CLAUDE_PROJECT_DIR="$1" TMPDIR="$TMP" bash "$DSG" 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext // ""'
}

DP="$TMP/design"; mkdir -p "$DP/.claude/rules" "$DP/css"
cat > "$DP/css/main.css" <<'CSS'
:root { --brand-color: #0b7e53; --sys-radius: 10px; }
body { font-family: 'Montserrat', system-ui, sans-serif; }
.card { border-radius: 10px; background: #0b7e53; }
CSS
touch "$DP/index.html"

got=$(design_ctx "$DP" "index.html")
grep -q 'Montserrat' <<<"$got" && ok "шрифт проекта извлечён" || bad "шрифт" "Montserrat" "$got"
grep -q '#0b7e53' <<<"$got"    && ok "палитра проекта извлечена" || bad "цвет" "#0b7e53" "$got"
grep -q 'brand-color' <<<"$got" && ok "переменные оформления названы" || bad "токены" "--brand-color" "$got"

# Запасные шрифты одинаковы почти везде и в списке только мешают
grep -q 'system-ui' <<<"$got" && bad "запасные шрифты не нужны" "без system-ui" "$got" \
  || ok "из объявления шрифта берётся только первое семейство"

# Пустой проект: напоминание обратное — сначала токены, потом вёрстка
EP="$TMP/design-empty"; mkdir -p "$EP/.claude/rules"; touch "$EP/index.html"
got=$(design_ctx "$EP" "index.html")
grep -q 'с нуля' <<<"$got" && ok "пустой проект: сказано, что вёрстка с нуля" || bad "пустой" "с нуля" "$got"
# Без -i: приведение регистра кириллицы зависит от локали, и на машине с LANG=C
# проверка молча проходила бы мимо. В тексте хука слово строчными.
grep -q 'градиент' <<<"$got" && ok "названы приметы оформления по умолчанию" || bad "приметы" "градиент" "$got"

# Регрессия: `grep -c` при нуле совпадений возвращает 1, и `|| echo 0`
# дописывал второй ноль — сравнение падало с синтаксической ошибкой
err=$(jq -n --arg p "$EP/index.html" --arg s "e$RANDOM" \
        '{session_id:$s,tool_name:"Edit",tool_input:{file_path:$p}}' \
      | CLAUDE_PROJECT_DIR="$EP" TMPDIR="$TMP" bash "$DSG" 2>&1 >/dev/null)
[[ -z "$err" ]] && ok "хук отрабатывает без ошибок в stderr" || bad "stderr" "пусто" "$err"

# Не-вёрстка хук не трогает
got=$(design_ctx "$DP" "readme.md")
[[ -z "$got" ]] && ok "на файл не из вёрстки хук молчит" || bad "md" "молчание" "$got"

# Один раз за сессию: палитра не меняется от файла к файлу
SID="dsgrep$RANDOM"
one() {
  jq -n --arg p "$DP/index.html" --arg s "$SID" \
     '{session_id:$s,tool_name:"Edit",tool_input:{file_path:$p}}' \
    | CLAUDE_PROJECT_DIR="$DP" TMPDIR="$TMP" bash "$DSG" 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext // ""'
}
f=$(one); s=$(one)
[[ -n "$f" && -z "$s" ]] && ok "напоминание об оформлении выдаётся раз за сессию" \
  || bad "повтор" "первый есть, второй пуст" "$f|$s"

got=$(STD_DESIGN=0 design_ctx "$DP" "index.html")
[[ -z "$got" ]] && ok "STD_DESIGN=0 отключает напоминание" || bad "выключатель" "молчание" "$got"

echo "== отсутствие jq не открывает ворота =="
# Самая дорогая из найденных дыр: jq не объявлен зависимостью, а без него
# разбор входа давал пустую строку и тихий выход — все замки выключались,
# и снаружи это выглядело как «проверки пройдены». Проверяем оба случая:
# есть запасной разборщик (работаем как обычно) и нет никакого (не молчим).
sandbox_path() { # <каталог> <список программ> -> PATH только из них
  local dir="$1"; shift
  mkdir -p "$dir"
  local b p
  for b in "$@"; do p=$(command -v "$b" 2>/dev/null) && ln -sf "$p" "$dir/$b"; done
  printf '%s' "$dir"
}

BASE_TOOLS=(bash sh grep sed awk cat printf basename dirname find head tail tr sort
            uniq mktemp rm mkdir touch date stat ls env chmod paste comm wc cut expr id)
NOJQ=$(sandbox_path "$TMP/bin-nojq" "${BASE_TOOLS[@]}")
BARE=$(sandbox_path "$TMP/bin-bare" "${BASE_TOOLS[@]}")
# Ссылку на python3 берём по sys.executable, а не по `command -v`: на машинах
# с pyenv или asdf в PATH лежит обёртка, которая ищет свой менеджер версий
# в том же PATH и в песочнице не запускается. Тест проверял бы не то.
PY_REAL=$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null)
[[ -n "$PY_REAL" ]] && ln -sf "$PY_REAL" "$NOJQ/python3"

nojq_decision() { # <PATH> <скрипт> <json> -> решение
  local out d
  out=$(printf '%s' "$3" | PATH="$1" bash "$2" 2>/dev/null)
  # Пустой вывод — это «решения нет», то есть обычный поток разрешений.
  # jq на пустом входе вернул бы пустую строку, и «прошло» стало бы
  # неотличимо от «хук упал».
  d=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
  printf '%s' "${d:-allow}"
}

VOL=$(jq -n '{tool_name:"Bash",tool_input:{command:"podman volume rm data"}}')
SAFE=$(jq -n '{tool_name:"Bash",tool_input:{command:"podman ps -a"}}')

got=$(nojq_decision "$NOJQ" "$SCRIPTS/guard-bash.sh" "$VOL")
[[ "$got" == "deny" ]] && ok "без jq, но с python3 замок работает как обычно" \
  || bad "запасной разборщик" deny "$got"

got=$(nojq_decision "$NOJQ" "$SCRIPTS/guard-bash.sh" "$SAFE")
[[ "$got" == "allow" ]] && ok "без jq безобидная команда по-прежнему проходит" \
  || bad "запасной разборщик, безобидное" allow "$got"

got=$(nojq_decision "$BARE" "$SCRIPTS/guard-bash.sh" "$SAFE")
[[ "$got" == "deny" ]] && ok "без разборщика вовсе — отказ, а не тихий пропуск" \
  || bad "нет ни jq, ни python3" deny "$got"

out=$(printf '%s' "$SAFE" | PATH="$BARE" bash "$SCRIPTS/guard-bash.sh" 2>/dev/null)
grep -q 'jq' <<<"$out" && ok "в отказе сказано, чего не хватает" \
  || bad "текст отказа" "упоминание jq" "$out"

# Замки, работающие только в подключённых проектах, ведут себя так же
STDP="$TMP/подключённый"; mkdir -p "$STDP/.claude/rules/std-core" "$STDP/tests"
echo '{}' > "$STDP/.claude/gauntlet.json"; echo '<?php' > "$STDP/tests/BTest.php"
got=$(printf '%s' "$(jq -n --arg p "$STDP/tests/BTest.php" '{tool_name:"Edit",tool_input:{file_path:$p}}')" \
      | PATH="$BARE" CLAUDE_PROJECT_DIR="$STDP" bash "$SCRIPTS/guard-tests.sh" 2>/dev/null \
      | jq -r '.hookSpecificOutput.permissionDecision // "allow"')
[[ "$got" == "ask" ]] && ok "правка теста без разборщика эскалируется" \
  || bad "guard-tests без разборщика" ask "$got"

# Человек должен узнать о поломке в начале сессии, а не по факту пропущенной
# команды: сообщение печатается без jq, иначе предупреждать было бы нечем
out=$(printf '{}' | PATH="$BARE" CLAUDE_PROJECT_DIR="$STDP" bash "$SCRIPTS/session-check.sh" 2>/dev/null)
grep -q 'jq' <<<"$out" && ok "старт сессии сообщает, что защита не работает" \
  || bad "session-check без jq" "предупреждение" "${out:-<пусто>}"

# Мутационный гейт без jq обязан падать: пустая планка читалась как нулевая,
# и любой результат проходил
PATH="$BARE" bash "$ROOT/plugins/std-gauntlet/scripts/ratchet.sh" check 5 >/dev/null 2>&1
[[ $? -ne 0 ]] && ok "храповик без jq падает, а не пропускает" \
  || bad "ratchet без jq" "ненулевой код" "0"

echo
printf 'Пройдено: \033[32m%d\033[0m   Провалено: \033[31m%d\033[0m\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
