#!/usr/bin/env bash
# run.sh — полный прогон проверок репозитория стандартов.
# Ставится в CI на каждый PR. Ни один шаг не требует запуска модели.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RC=0
hdr() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }

hdr "1/9 Страж приватных данных"
python3 "$ROOT/tests/no-private-data.py" || RC=1

hdr "2/9 Права на исполнение скриптов"
missing=0
while IFS= read -r s; do
  [[ -x "$s" ]] || { printf '  не исполняемый: %s\n' "${s#$ROOT/}"; missing=1; }
done < <(find "$ROOT/plugins" "$ROOT/tests" -name '*.sh' -type f)
[[ $missing -eq 0 ]] && echo "  ok" || { echo "  почини: chmod +x"; RC=1; }

hdr "3/9 Структура модулей и frontmatter"
python3 "$ROOT/tests/lint-modules.py" || RC=1

hdr "4/9 Замки (unit-тесты хуков)"
bash "$ROOT/tests/test-hooks.sh" || RC=1

hdr "5/9 Автодетект стека и целостность связей"
bash "$ROOT/tests/test-link.sh" || RC=1

hdr "6/9 Профили, храповик, единая настройка"
bash "$ROOT/tests/test-profile.sh" || RC=1

hdr "7/9 Политика стека"
bash "$ROOT/tests/test-policy.sh" || RC=1

hdr "8/9 Правила уровня проекта"
bash "$ROOT/tests/test-rule.sh" || RC=1

hdr "9/9 Валидация манифестов средствами Claude Code"
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
  echo "  пропущено: claude не найден в PATH"
fi

echo
if [[ $RC -eq 0 ]]; then
  printf '\033[32mВСЁ ЗЕЛЁНОЕ\033[0m\n'
else
  printf '\033[31mЕСТЬ ОШИБКИ\033[0m — репозиторий не готов к публикации\n'
fi
exit $RC
