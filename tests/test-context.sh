#!/usr/bin/env bash
# test-context.sh — проверяет, что правила РЕАЛЬНО попадают в контекст.
#
# Все остальные тесты проверяют наши файлы. Этот проверяет саму механику
# Claude Code: что path-scoped правило загружается при чтении подходящего
# файла и НЕ загружается при чтении неподходящего.
#
# Метод: одноразовый проект в /tmp + хук InstructionsLoaded, который ведёт
# журнал фактических загрузок. Тест не зависит от установки плагина —
# хук прописывается напрямую в settings.json временного проекта.
#
# Запускает модель (стоит токенов), поэтому вынесен из run.sh.
#   tests/test-context.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRACE_SCRIPT="$ROOT/plugins/std-core/scripts/rules-trace.sh"
PASS=0; FAIL=0
ok()  { printf '  \033[32mOK\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n     %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

command -v claude >/dev/null || { echo "claude не найден в PATH"; exit 1; }

PROJ=$(mktemp -d /tmp/std-ctx-XXXXXX)
trap 'rm -rf "$PROJ"' EXIT
echo "Тестовый проект: $PROJ"

# --- фикстуры: файлы под разные paths: ---------------------------------------
mkdir -p "$PROJ/app/Http/Controllers" "$PROJ/app/Models" "$PROJ/components" "$PROJ/.claude"
cat > "$PROJ/app/Http/Controllers/OrderController.php" <<'PHP'
<?php
namespace App\Http\Controllers;

class OrderController
{
    public function store()
    {
        return response()->json(['ok' => true]);
    }
}
PHP
cat > "$PROJ/components/Cart.vue" <<'VUE'
<script setup lang="ts">
const items = []
</script>
<template><div>{{ items.length }}</div></template>
VUE

# --- подключаем правила симлинком (как это делает std-link.sh) ---------------
mkdir -p "$PROJ/.claude/rules"
ln -s "$ROOT/plugins/std-php-laravel/rules" "$PROJ/.claude/rules/std-php-laravel"
ln -s "$ROOT/plugins/std-js-vue3/rules"     "$PROJ/.claude/rules/std-js-vue3"

# --- журнал загрузок ----------------------------------------------------------
TRACE="$PROJ/trace.jsonl"
cat > "$PROJ/.claude/settings.json" <<EOF
{
  "hooks": {
    "InstructionsLoaded": [
      { "hooks": [ { "type": "command", "command": "$TRACE_SCRIPT" } ] }
    ]
  }
}
EOF

echo "CLAUDE.md проекта" > "$PROJ/CLAUDE.md"

run_probe() { # <промпт>
  ( cd "$PROJ" && STD_TRACE_FILE="$TRACE" CLAUDE_PROJECT_DIR="$PROJ" \
      claude -p "$1" --model claude-haiku-4-5-20251001 >/dev/null 2>&1 )
}

loaded() { # <подстрока пути> -> 0 если есть в журнале
  [[ -f "$TRACE" ]] && grep -q "$1" "$TRACE"
}

echo
echo "== Проба 1: чтение PHP-файла из app/Http =="
: > "$TRACE"
run_probe "Прочитай файл app/Http/Controllers/OrderController.php и опиши в одном предложении, что он делает."

if loaded "10-http.md"; then
  ok "правило std-php-laravel/10-http.md загружено при чтении app/Http/**"
else
  bad "правило 10-http.md НЕ загрузилось" "$( [[ -f $TRACE ]] && wc -l < "$TRACE" || echo 0) записей в журнале; проверь paths: и что хук сработал"
fi

if loaded "10-components.md"; then
  bad "лишняя загрузка: vue-правило пришло на PHP-файле" "paths: слишком широкие — контекст тратится впустую"
else
  ok "vue-правило не загрузилось на PHP-файле (paths: изолируют корректно)"
fi

echo
echo "== Проба 2: чтение .vue файла =="
: > "$TRACE"
run_probe "Прочитай файл components/Cart.vue и скажи, какой в нём используется синтаксис."

if loaded "10-components.md"; then
  ok "правило std-js-vue3/10-components.md загружено при чтении **/*.vue"
else
  bad "правило 10-components.md НЕ загрузилось" "проверь glob '**/*.vue'"
fi

echo
if [[ -f "$TRACE" ]]; then
  echo "Последние записи журнала:"
  tail -5 "$TRACE" | jq -c '{file, reason}' 2>/dev/null | sed 's/^/  /'
fi

echo
printf 'Пройдено: \033[32m%d\033[0m   Провалено: \033[31m%d\033[0m\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
