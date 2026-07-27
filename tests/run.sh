#!/usr/bin/env bash
# run.sh — полный прогон проверок репозитория стандартов.
# Ставится в CI на каждый PR. Ни один шаг не требует запуска модели.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RC=0
hdr() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }

hdr "1/11 Страж приватных данных"
python3 "$ROOT/tests/no-private-data.py" || RC=1

hdr "2/11 Права на исполнение скриптов"
missing=0
while IFS= read -r s; do
  [[ -x "$s" ]] || { printf '  не исполняемый: %s\n' "${s#$ROOT/}"; missing=1; }
done < <(find "$ROOT/plugins" "$ROOT/tests" -name '*.sh' -type f)
[[ $missing -eq 0 ]] && echo "  ok" || { echo "  почини: chmod +x"; RC=1; }

hdr "3/11 Структура модулей и frontmatter"
python3 "$ROOT/tests/lint-modules.py" || RC=1

hdr "4/11 Замки (unit-тесты хуков)"
bash "$ROOT/tests/test-hooks.sh" || RC=1

hdr "5/11 Автодетект стека и целостность связей"
bash "$ROOT/tests/test-link.sh" || RC=1

hdr "6/11 Профили, храповик, единая настройка"
bash "$ROOT/tests/test-profile.sh" || RC=1

hdr "7/11 Политика стека"
bash "$ROOT/tests/test-policy.sh" || RC=1

hdr "8/11 Правила уровня проекта"
bash "$ROOT/tests/test-rule.sh" || RC=1

hdr "9/11 Мутация данных спецификации"
bash "$ROOT/tests/test-gherkin-mutate.sh" || RC=1

hdr "10/11 Публикация"
bash "$ROOT/tests/test-publish.sh" || RC=1

hdr "11/11 Валидация манифестов средствами Claude Code"
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
