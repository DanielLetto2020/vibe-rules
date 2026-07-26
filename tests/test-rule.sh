#!/usr/bin/env bash
# test-rule.sh — тесты правил уровня проекта.
#
# Правило проекта коммитится вместе с кодом и не уходит в общий репозиторий.
# Проверяется именно это разделение: свои правила — обычные файлы в git,
# общие модули — симлинки, которые в git попадать не должны.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RULE="$ROOT/plugins/std-core/scripts/std-rule.sh"
PASS=0; FAIL=0
ok()  { printf '  \033[32mOK\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n     %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
P="$TMP/proj"; mkdir -p "$P/.claude/rules"
ln -s "$ROOT/plugins/std-php-laravel/rules" "$P/.claude/rules/std-php-laravel"
r() { CLAUDE_PROJECT_DIR="$P" bash "$RULE" "$@" 2>&1; }

echo "== создание правила проекта =="

r new api-conventions backend >/dev/null
F="$P/.claude/rules/api-conventions.md"
[[ -f "$F" ]] && ok "правило создано" || bad "создание" "файла нет"

grep -q '^paths:' "$F" && ok "во frontmatter есть paths" || bad "paths" "нет"
grep -q '^owner:' "$F" && ok "во frontmatter есть owner" || bad "owner" "нет"
grep -q '^enforcement:' "$F" && ok "во frontmatter есть enforcement" || bad "enforcement" "нет"
grep -q 'app/\*\*/\*.php' "$F" && ok "шаблон backend подставил пути" || bad "шаблон" "путей нет"

# Имя не должно превращаться в симлинк-подобное: префикс std- зарезервирован
r new std-my-rule >/dev/null
[[ -f "$P/.claude/rules/my-rule.md" ]] \
  && ok "префикс std- отбрасывается, чтобы не путать с общими модулями" \
  || bad "префикс" "файл my-rule.md не создан"

OUT=$(r new api-conventions)
grep -q 'уже существует' <<<"$OUT" && ok "повторное создание не затирает файл" || bad "перезапись" "файл перезаписан"

echo "== приоритет =="
r precedence >/dev/null
PREC="$P/.claude/rules/00-precedence.md"
[[ -f "$PREC" ]] && ok "файл приоритета создан" || bad "precedence" "файла нет"
grep -q 'действует правило проекта' "$PREC" \
  && ok "приоритет объявлен явно" || bad "приоритет" "формулировки нет"
grep -q 'скажи о нём' "$PREC" \
  && ok "требует сообщать о противоречии, а не выбирать молча" \
  || bad "сообщать о конфликте" "требования нет"

OUT=$(r precedence)
grep -q 'уже есть' <<<"$OUT" && ok "повторный вызов не затирает отступления" || bad "precedence" "перезаписан"

echo "== отступление от общего модуля =="
r override php-laravel >/dev/null
[[ ! -e "$P/.claude/rules/std-php-laravel" ]] \
  && ok "модуль отвязан от проекта" || bad "override" "симлинк остался"
grep -q 'std-php-laravel отключён' "$PREC" \
  && ok "отступление записано в файл приоритета" || bad "запись" "нет"
grep -q 'ЗАПОЛНИ' "$PREC" \
  && ok "причина помечена как обязательная к заполнению" || bad "причина" "нет метки"

OUT=$(r override no-such-module)
grep -q 'не подключён' <<<"$OUT" && ok "отключение неподключённого модуля не молчит" || bad "override" "молча прошло"

echo "== список =="
OUT=$(r list)
grep -q 'api-conventions.md' <<<"$OUT" && ok "правила проекта показаны" || bad "список" "правил нет"
grep -qE 'api-conventions\.md.*app' <<<"$OUT" \
  && ok "пути правила разобраны без захвата соседних полей" \
  || bad "разбор paths" "$(grep 'api-conventions' <<<"$OUT")"

echo "== разделение источников =="
# Ключевое: правило проекта — обычный файл (идёт в git),
# общий модуль — симлинк (в git не идёт)
[[ -f "$F" && ! -L "$F" ]] \
  && ok "правило проекта — обычный файл, попадёт в git" \
  || bad "тип файла" "это симлинк"

ln -s "$ROOT/plugins/std-web-css/rules" "$P/.claude/rules/std-web-css"
[[ -L "$P/.claude/rules/std-web-css" ]] \
  && ok "общий модуль — симлинк, в git не попадёт" \
  || bad "тип модуля" "это обычный файл"

echo
printf 'Пройдено: \033[32m%d\033[0m   Провалено: \033[31m%d\033[0m\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
