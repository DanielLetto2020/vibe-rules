#!/usr/bin/env bash
# publish.sh — выпустить версию: проверки, бамп, коммит, пуш, релиз.
#
# Зачем один скрипт вместо пяти команд: цепочка, где каждый шаг делается
# руками, теряет шаги. Релиз забывался дважды подряд, и на главной странице
# репозитория висела версия на пять релизов старше кода — снаружи это выглядит
# как заброшенный проект.
#
#   tools/publish.sh                     patch: 0.5.0 -> 0.5.1
#   tools/publish.sh minor "Заголовок"   0.5.0 -> 0.6.0
#   tools/publish.sh 1.0.0 "Заголовок"
#   tools/publish.sh --dry-run           показать, что будет сделано
#
# Публикация невозможна при красном прогоне: это не предупреждение, а условие.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
REPO="${VIBE_RULES_REPO:-DanielLetto2020/vibe-rules}"

b()   { printf '\033[1m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*"; }
ylw() { printf '\033[33m%s\033[0m\n' "$*"; }

DRY=0
[[ "${1:-}" == "--dry-run" ]] && { DRY=1; shift; }
BUMP="${1:-patch}"
TITLE="${2:-}"

# ── 1. Проверки ───────────────────────────────────────────────────────────────
b "▸ 1/5  Проверки"

# Правки должны быть закоммичены осмысленно ДО публикации: скрипт добавляет
# только бамп версии. Иначе всё уезжает одним коммитом «version X», и в описании
# релиза нечего показать — список изменений собирается из истории.
DIRTY=$(git status --porcelain | grep -v '^?? ' | head -5)
if [[ -n "$DIRTY" && $DRY -eq 0 ]]; then
  red "  есть незакоммиченные правки:"
  sed 's/^/    /' <<<"$DIRTY"
  echo
  echo "  Закоммить их осмысленно — они попадут в описание релиза."
  echo "  Скрипт добавляет только бамп версии поверх готовой истории."
  exit 1
fi
if ! bash tests/run.sh >/tmp/publish-tests.log 2>&1; then
  red "  прогон красный — публикация отменена"
  tail -25 /tmp/publish-tests.log | sed 's/^/    /'
  exit 1
fi
grn "  все тесты зелёные"

# Страж входит в общий прогон, но перед публикацией проверяем ещё и индекс:
# файл мог попасть в git и не попасть под шаблоны стража
git add -A >/dev/null 2>&1
for f in CLAUDE.md tests/.private-patterns .claude/settings.local.json; do
  if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
    red "  в индексе приватный файл: $f"; exit 1
  fi
done
if git ls-files | grep -q 'sandbox'; then
  red "  в индексе песочницы"; exit 1
fi
grn "  приватных файлов в индексе нет"

# ── 2. Версия ─────────────────────────────────────────────────────────────────
echo; b "▸ 2/5  Версия"
OLD=$(jq -r '.metadata.version' .claude-plugin/marketplace.json)
if [[ $DRY -eq 1 ]]; then
  ylw "  (dry-run) текущая $OLD, бамп: $BUMP"
  NEW="(не изменено)"
else
  bash tools/bump.sh "$BUMP" | head -1 | sed 's/^/  /'
  NEW=$(jq -r '.metadata.version' .claude-plugin/marketplace.json)
fi

# ── 3. Что вошло ──────────────────────────────────────────────────────────────
echo; b "▸ 3/5  Изменения с прошлого релиза"
git fetch --tags -q 2>/dev/null || true
LAST_TAG=$(git tag --sort=-v:refname | head -1)
if [[ -n "$LAST_TAG" ]]; then
  CHANGES=$(git log "$LAST_TAG..HEAD" --format='- %s' 2>/dev/null | grep -v '^- version ' || true)
else
  CHANGES=$(git log --format='- %s' -10)
fi
[[ -z "$CHANGES" ]] && CHANGES="- изменения без коммитов с прошлого релиза"
sed 's/^/  /' <<<"$CHANGES" | head -12

if [[ $DRY -eq 1 ]]; then
  echo; ylw "  (dry-run) остановка: коммит, пуш и релиз не выполнялись"
  exit 0
fi

# ── 4. Коммит и пуш ───────────────────────────────────────────────────────────
echo; b "▸ 4/5  Публикация кода"
git add -A
git -c user.email=i@m-letto.ru -c user.name=Letto commit -qm "version $NEW" 2>/dev/null || true
if ! git push origin main 2>&1 | tail -1 | sed 's/^/  /'; then
  red "  пуш не прошёл"; exit 1
fi
grn "  код опубликован"

# ── 5. Релиз ──────────────────────────────────────────────────────────────────
echo; b "▸ 5/5  Релиз v$NEW"
if ! command -v ghapi >/dev/null 2>&1; then
  ylw "  ghapi не найден — релиз не создан"
  echo "  Создай вручную: https://github.com/$REPO/releases/new?tag=v$NEW"
  exit 0
fi

BODY="${TITLE:+$TITLE

}## Что изменилось

$CHANGES

Полный список: https://github.com/$REPO/compare/$LAST_TAG...v$NEW

---

Обновиться:

\`\`\`
/plugin marketplace update vibe-rules
/plugin update
\`\`\`

Начать с основ: [START.ru.md](https://github.com/$REPO/blob/main/docs/START.ru.md)"

RESP=$(ghapi POST "/repos/$REPO/releases" "$(jq -n \
  --arg t "v$NEW" --arg n "v$NEW${TITLE:+ — $TITLE}" --arg b "$BODY" \
  '{tag_name:$t, target_commitish:"main", name:$n, body:$b, draft:false, prerelease:false}')")

if jq -e '.html_url' <<<"$RESP" >/dev/null 2>&1; then
  grn "  $(jq -r '.html_url' <<<"$RESP")"
  # Тег создан на стороне GitHub — подтягиваем, иначе pre-push будет сравнивать
  # с устаревшим локальным тегом и пропустит забытый бамп
  git fetch --tags -q 2>/dev/null || true
else
  red "  релиз не создан: $(jq -r '.message // "неизвестная ошибка"' <<<"$RESP")"
  exit 1
fi

echo; grn "════ ОПУБЛИКОВАНО: $OLD -> $NEW ════"
