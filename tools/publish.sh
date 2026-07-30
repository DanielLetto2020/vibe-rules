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
# Проверяются оба прогона — локальный и тот, что идёт на GitHub. Раньше
# проверялся только локальный, и версия 0.9.4 уехала в релиз при красном CI:
# на машине автора шаг проходил, в чужой среде — нет. Релиз с красным CI
# снаружи читается как «здесь не проверяют», и это дороже задержки в пару минут.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
REPO="${VIBE_RULES_REPO:-DanielLetto2020/vibe-rules}"

b()   { printf '\033[1m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*"; }
ylw() { printf '\033[33m%s\033[0m\n' "$*"; }

# Разбор в любом порядке. Раньше --dry-run распознавался только первым
# аргументом: переданный после заголовка, он молча игнорировался, и «покажи,
# что будет» публиковало по-настоящему. Неизвестный аргумент теперь тоже
# ошибка — скрипт, который пушит наружу, не имеет права молча пропускать
# то, чего не понял.
DRY=0; BUMP=""; TITLE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '9,12p' "$0"; exit 0 ;;
    --*)       red "неизвестный аргумент: $1"; exit 2 ;;
    *)
      if [[ -z "$BUMP" ]]; then BUMP="$1"
      elif [[ -z "$TITLE" ]]; then TITLE="$1"
      else red "лишний аргумент: $1"; exit 2
      fi ;;
  esac
  shift
done
BUMP="${BUMP:-patch}"

case "$BUMP" in
  patch|minor|major|[0-9]*.[0-9]*.[0-9]*) ;;
  *) red "непонятный вид версии: $BUMP"
     echo "ожидается patch, minor, major или точная версия вида 1.2.3"; exit 2 ;;
esac

# Ожидание прогона на GitHub для конкретного коммита.
#
# Возвращает: 0 — зелёный, 1 — красный, 2 — не дождались или спросить нечем.
# Опрос, а не единичная проверка: прогон стартует не мгновенно, и «прогонов нет»
# в первые секунды означает «ещё не начался», а не «всё хорошо».
wait_ci() { # <sha>
  local sha="$1" waited=0 limit="${CI_WAIT_LIMIT:-600}" step=15 resp status concl
  command -v ghapi >/dev/null 2>&1 || return 2
  while ((waited < limit)); do
    resp=$(ghapi GET "/repos/$REPO/actions/runs?head_sha=$sha&per_page=1" 2>/dev/null)
    status=$(jq -r '.workflow_runs[0].status // empty' <<<"$resp" 2>/dev/null)
    concl=$(jq -r '.workflow_runs[0].conclusion // empty' <<<"$resp" 2>/dev/null)
    if [[ "$status" == "completed" ]]; then
      [[ "$concl" == "success" ]] && return 0
      return 1
    fi
    [[ -n "$status" ]] && printf '\r  прогон идёт (%s), ждём %s с' "$status" "$waited"
    sleep "$step"; waited=$((waited + step))
  done
  printf '\r'
  return 2
}

# ── 1. Проверки ───────────────────────────────────────────────────────────────
b "▸ 1/6  Проверки"

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
# Предсказуемое имя в /tmp — чужой симлинк с тем же именем перенаправит запись
TESTLOG=$(mktemp)
trap 'rm -f "$TESTLOG"' EXIT
if ! bash tests/run.sh >"$TESTLOG" 2>&1; then
  red "  прогон красный — публикация отменена"
  tail -25 "$TESTLOG" | sed 's/^/    /'
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

# ── 2. Код наружу ─────────────────────────────────────────────────────────────
# Сначала уезжает код, потом проверяется, потом двигается версия. Обратный
# порядок оставлял main с новым номером версии и без релиза, если прогон падал:
# состояние, из которого непонятно, что вообще выпущено.
echo; b "▸ 2/6  Публикация кода"
OLD=$(jq -r '.metadata.version' .claude-plugin/marketplace.json)
# Этот пуш заведомо без бампа: версия двигается после зелёного прогона.
# pre-push об этом знает по переменной и пропускает только такой случай —
# ручной пуш без поднятой версии он по-прежнему останавливает.
export VIBE_PUBLISH=1
if [[ $DRY -eq 0 ]]; then
  if ! git push origin main 2>&1 | tail -1 | sed 's/^/  /'; then
    red "  пуш не прошёл"; exit 1
  fi
  grn "  код опубликован"
else
  ylw "  (dry-run) пуш не выполнялся"
fi

# ── 3. Прогон на стороне GitHub ───────────────────────────────────────────────
# Локальный прогон говорит только о машине автора. Разница сред — обычное дело:
# другая версия git, другая локаль, отсутствующая программа.
echo; b "▸ 3/6  Прогон на GitHub"
if [[ $DRY -eq 0 ]]; then
  SHA=$(git rev-parse HEAD)
  wait_ci "$SHA"; CI=$?
  case $CI in
    0) grn "  прогон зелёный" ;;
    1) red "  прогон красный — версия не поднята, релиза нет"
       echo "  Смотри: https://github.com/$REPO/actions"
       echo "  Почини, закоммить и запусти публикацию заново."
       exit 1 ;;
    2) red "  результат прогона получить не удалось (нет ghapi или превышено ожидание)"
       echo "  Версия не поднята намеренно: выпускать, не зная состояния проверок, —"
       echo "  это ровно та ошибка, из-за которой 0.9.4 вышла с красным CI."
       echo "  Проверь https://github.com/$REPO/actions и повтори."
       exit 1 ;;
  esac
else
  ylw "  (dry-run) прогон не проверялся"
fi

# ── 4. Версия ─────────────────────────────────────────────────────────────────
echo; b "▸ 4/6  Версия"
if [[ $DRY -eq 1 ]]; then
  ylw "  (dry-run) текущая $OLD, бамп: $BUMP"
  NEW="(не изменено)"
else
  bash tools/bump.sh "$BUMP" | head -1 | sed 's/^/  /'
  NEW=$(jq -r '.metadata.version' .claude-plugin/marketplace.json)
fi

# ── 5. Что вошло ──────────────────────────────────────────────────────────────
echo; b "▸ 5/6  Изменения с прошлого релиза"
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

# ── 6. Бамп наружу и релиз ────────────────────────────────────────────────────
echo; b "▸ 6/6  Релиз v$NEW"
git add -A
git -c user.email=i@m-letto.ru -c user.name=Letto commit -qm "version $NEW" 2>/dev/null || true
if ! git push origin main 2>&1 | tail -1 | sed 's/^/  /'; then
  red "  пуш версии не прошёл"; exit 1
fi

# Описание на русском, как и вся документация репозитория. Раньше оно было
# двуязычным ради внешней аудитории; репозиторий делается для себя, и вторая
# половина текста только удваивала работу при каждом релизе.
BODY="${TITLE:+$TITLE

}## Что изменилось

$CHANGES

Полный список: https://github.com/$REPO/compare/$LAST_TAG...v$NEW

---

Обновить установленное:

\`\`\`
/plugin marketplace update vibe-rules
/plugin update
\`\`\`

Впервые здесь? Начните с [START.md](https://github.com/$REPO/blob/main/docs/START.md)
— что это такое, простыми словами."

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
