#!/usr/bin/env bash
# run.sh — полный прогон проверок репозитория стандартов.
# Ставится в CI на каждый PR. Ни один шаг не требует запуска модели.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Чего не хватает — говорим одной строкой в начале, а не сорока «command not
# found» вперемешку с FAIL посреди прогона. «Нечем проверять» и «проверки
# провалились» — разные новости, и чинят их по-разному.
. "$ROOT/tests/require.sh"; require_tools jq git python3
RC=0
hdr() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }

hdr "1/19 Страж приватных данных"
python3 "$ROOT/tests/no-private-data.py" || RC=1

hdr "2/19 Права на исполнение скриптов"
noexec=0
while IFS= read -r s; do
  [[ -x "$s" ]] || { printf '  не исполняемый: %s\n' "${s#$ROOT/}"; noexec=1; }
done < <(find "$ROOT/plugins" "$ROOT/tests" -name '*.sh' -type f)
[[ $noexec -eq 0 ]] && echo "  ok" || { echo "  почини: chmod +x"; RC=1; }

hdr "3/19 Статический анализ shell-скриптов"
# Замки — это shell, а в shell ошибка часто выглядит как работающий код:
# неэкранированная переменная, маска там, где ждали строку, cd без проверки.
# Порог — warning: стилистику не навязываем, дефекты не пропускаем.
# Отключение отдельной проверки — только комментарием у строки с причиной.
if command -v shellcheck >/dev/null 2>&1; then
  mapfile -t sh_files < <(find "$ROOT/plugins" "$ROOT/tests" "$ROOT/tools" \
                                "$ROOT/templates" -name '*.sh' -type f | sort)
  sh_files+=("$ROOT"/.githooks/*)
  if shellcheck -S warning -x "${sh_files[@]}"; then
    echo "  ok    файлов: ${#sh_files[@]}"
  else
    RC=1
  fi
else
  # Как и на шаге 19: пропуск называем вслух, чтобы он не выглядел пройденным.
  # В CI shellcheck ставится закреплённой версией, там шаг не пропускается.
  echo "  shellcheck не найден в PATH — шаг пропущен"
  echo "  поставь: pip install shellcheck-py  |  apt install shellcheck  |  brew install shellcheck"
fi

hdr "4/19 Структура модулей и frontmatter"
python3 "$ROOT/tests/lint-modules.py" || RC=1

hdr "5/19 Замки (unit-тесты хуков)"
bash "$ROOT/tests/test-hooks.sh" || RC=1

hdr "6/19 Утечка секретов: чтение, команда, запись, коммит"
bash "$ROOT/tests/test-secrets.sh" || RC=1

hdr "7/19 Обходы замков, ложные срабатывания, известные границы"
python3 "$ROOT/tests/test-hook-corpus.py" || RC=1

hdr "8/19 Фаззинг разбора команд"
python3 "$ROOT/tests/fuzz-guard-bash.py" || RC=1

hdr "9/19 Автодетект стека и целостность связей"
bash "$ROOT/tests/test-link.sh" || RC=1

hdr "10/19 Профили, храповик, единая настройка"
bash "$ROOT/tests/test-profile.sh" || RC=1

hdr "11/19 Храповик долга соответствия"
bash "$ROOT/tests/test-debt.sh" || RC=1

hdr "12/19 Покрытие изменённых строк"
bash "$ROOT/tests/test-diff-coverage.sh" || RC=1

hdr "13/19 Строй проверок и замок на коммит"
bash "$ROOT/tests/test-gauntlet.sh" || RC=1

hdr "14/19 Политика стека"
bash "$ROOT/tests/test-policy.sh" || RC=1

hdr "15/19 Правила уровня проекта"
bash "$ROOT/tests/test-rule.sh" || RC=1

hdr "16/19 Мутация данных спецификации"
bash "$ROOT/tests/test-gherkin-mutate.sh" || RC=1

hdr "17/19 Публикация"
bash "$ROOT/tests/test-publish.sh" || RC=1

hdr "18/19 Согласованность документации"
python3 "$ROOT/tests/test-docs-sync.py" || RC=1

hdr "19/19 Валидация манифестов средствами Claude Code"
if command -v claude >/dev/null 2>&1; then
  for p in "$ROOT"/plugins/*/; do
    out=$(claude plugin validate "$p" --strict 2>&1)
    if [[ $? -eq 0 ]]; then
      printf '  ok    %s\n' "$(basename "$p")"
    else
      printf '  FAIL  %s\n%s\n' "$(basename "$p")" "$(sed 's/^/        /' <<<"$out")"
      RC=1
    fi
  done
else
  # Молча пропускать нельзя: раньше это выглядело как пройденная проверка,
  # и красный манифест уезжал в публикацию. Структуру манифестов покрывает
  # шаг 3, здесь — только то, что умеет сам CLI.
  echo "  claude не найден в PATH — шаг пропущен"
  echo "  структура манифестов при этом проверена на шаге 3"
fi

echo
if [[ $RC -eq 0 ]]; then
  printf '\033[32mВСЁ ЗЕЛЁНОЕ\033[0m\n'
else
  printf '\033[31mЕСТЬ ОШИБКИ\033[0m — репозиторий не готов к публикации\n'
fi
exit $RC
