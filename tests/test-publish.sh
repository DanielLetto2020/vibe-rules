#!/usr/bin/env bash
# test-publish.sh — тесты публикации.
#
# Публикация — единственное действие, которое видно снаружи и которое нельзя
# отменить. До этих тестов скрипт был не покрыт, и в нём одновременно жили два
# дефекта: --dry-run распознавался только первым аргументом (переданный после
# заголовка, он молча публиковал по-настоящему), а описание релиза выходило
# одноязычным вопреки стандарту.
#
# Ничего наружу не уходит: клон локальный, remote — bare-репозиторий рядом,
# ghapi подменён заглушкой, которая записывает переданное тело в файл.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  \033[32mOK\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n     %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

command -v jq >/dev/null 2>&1 || { echo "  jq не найден — тесты пропущены"; exit 0; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# ── Изолированный стенд ───────────────────────────────────────────────────────
git init -q --bare "$TMP/remote.git"
git clone -q "$ROOT" "$TMP/work" 2>/dev/null || { echo "  клон не удался"; exit 0; }
cd "$TMP/work" || exit 1
git remote set-url origin "$TMP/remote.git"
git config user.email "test@example.invalid"
git config user.name "test"
git push -q origin HEAD:main 2>/dev/null

# Клон содержит только закоммиченное, а проверять надо рабочую копию:
# иначе тест зеленеет на старом скрипте и правку никто не проверяет
cp "$ROOT/tools/publish.sh" tools/publish.sh

# Прогон настоящих тестов занял бы минуты и проверяет не то, что здесь важно
cat > tests/run.sh <<'EOF'
#!/usr/bin/env bash
echo "ВСЁ ЗЕЛЁНОЕ"; exit 0
EOF
chmod +x tests/run.sh

# Заглушка ghapi: записывает тело релиза и отвечает как настоящий
mkdir -p "$TMP/bin"
cat > "$TMP/bin/ghapi" <<EOF
#!/usr/bin/env bash
printf '%s' "\${3:-}" > "$TMP/release-body.json"
echo '{"html_url":"https://example.invalid/releases/tag/test"}'
EOF
chmod +x "$TMP/bin/ghapi"
export PATH="$TMP/bin:$PATH"

git add -A >/dev/null 2>&1
git commit -q -m "Стенд для тестов публикации" 2>/dev/null

BEFORE=$(git rev-parse HEAD)
P="bash $TMP/work/tools/publish.sh"

echo "== разбор аргументов =="
# Главный дефект: флаг после заголовка молча игнорировался, и «покажи, что
# будет» публиковало по-настоящему
OUT=$($P minor "Заголовок" --dry-run 2>&1)
grep -q 'dry-run' <<<"$OUT" \
  && ok "--dry-run распознаётся после заголовка" \
  || bad "--dry-run третьим аргументом" "флаг проигнорирован"

[[ "$(git rev-parse HEAD)" == "$BEFORE" ]] \
  && ok "при --dry-run коммит не создаётся" \
  || bad "--dry-run изменил историю" "HEAD сдвинулся"

[[ ! -f "$TMP/release-body.json" ]] \
  && ok "при --dry-run релиз не создаётся" \
  || bad "--dry-run создал релиз" "ghapi был вызван"

$P --неизвестный >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "неизвестный аргумент — отказ, а не молчание" \
               || bad "неизвестный аргумент" "код не 2"

$P бред >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "непонятный вид версии — отказ" || bad "вид версии" "код не 2"

$P minor "Заголовок" лишнее >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "лишний аргумент — отказ" || bad "лишний аргумент" "код не 2"

echo "== грязное дерево =="
echo "мусор" > untracked-change.txt
git add untracked-change.txt
$P patch >/dev/null 2>&1
[[ $? -eq 1 ]] \
  && ok "публикация при незакоммиченных правках отменяется" \
  || bad "грязное дерево" "код не 1"
git reset -q HEAD untracked-change.txt; rm -f untracked-change.txt

echo "== настоящая публикация в изолированный стенд =="
OLD_V=$(jq -r '.metadata.version' .claude-plugin/marketplace.json)
OUT=$($P minor "Проверка выпуска" 2>&1)
NEW_V=$(jq -r '.metadata.version' .claude-plugin/marketplace.json)

[[ "$NEW_V" != "$OLD_V" ]] && ok "версия поднята: $OLD_V -> $NEW_V" \
                           || bad "бамп версии" "версия не изменилась"

# minor обязан обнулить патч: 0.7.3 -> 0.8.0, а не 0.8.3
[[ "$NEW_V" == *".0" ]] && ok "minor обнуляет патч-компоненту" \
                        || bad "семантика minor" "получилось $NEW_V"

# Единая версия у всех модулей: разнобой означает, что часть обновится,
# а часть нет, и понять это снаружи невозможно
MODS=$(jq -r '.plugins[].version // empty' .claude-plugin/marketplace.json | sort -u | wc -l)
[[ "$MODS" -le 1 ]] && ok "версия у модулей единая" \
                    || bad "версии модулей" "разных значений: $MODS"

[[ -f "$TMP/release-body.json" ]] && ok "релиз создан" || bad "релиз" "ghapi не вызван"

echo "== описание релиза =="
BODY=$(jq -r '.body' < "$TMP/release-body.json" 2>/dev/null)
grep -q 'По-русски' <<<"$BODY" && ok "русская часть на месте" \
                               || bad "двуязычность" "нет русской части"
grep -qi 'English' <<<"$BODY" && ok "английская часть на месте" \
                              || bad "двуязычность" "нет английской части"
grep -q 'START.md' <<<"$BODY" && grep -q 'START.ru.md' <<<"$BODY" \
  && ok "ссылки на оба стартовых документа" \
  || bad "ссылки" "стартовый документ только на одном языке"
grep -q 'Проверка выпуска' <<<"$BODY" \
  && ok "заголовок выпуска попал в описание" || bad "заголовок" "его нет"
grep -q 'Стенд для тестов публикации' <<<"$BODY" \
  && ok "список изменений собран из истории" || bad "список изменений" "пуст"

# Соавторство агента не указывается нигде — ни в коммитах, ни в описании
grep -qiE 'co-authored|claude|anthropic' <<<"$BODY" \
  && bad "следы агента" "упоминание в описании релиза" \
  || ok "в описании релиза нет упоминаний агента"
git log -3 --format='%an%n%b' | grep -qiE 'co-authored|claude|anthropic' \
  && bad "следы агента" "упоминание в коммитах" \
  || ok "в коммитах публикации нет упоминаний агента"

echo "== запись ушла в remote =="
git -C "$TMP/remote.git" rev-parse main >/dev/null 2>&1 \
  && ok "ветка опубликована в remote" || bad "push" "в remote ветки нет"

echo
printf 'Пройдено: \033[32m%d\033[0m   Провалено: \033[31m%d\033[0m\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
