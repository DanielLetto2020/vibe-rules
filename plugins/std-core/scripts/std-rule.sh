#!/usr/bin/env bash
# std-rule.sh — правила уровня проекта: свои стандарты, которые не уходят
# в общий репозиторий.
#
# Зачем: общие модули покрывают технологию, но у каждого проекта есть своё —
# договорённости, ловушки, отступления от общего правила с причиной. Раньше
# это некуда было положить: дописывать в общий репозиторий нельзя (сломает
# другим), а CLAUDE.md грузится в каждую сессию целиком.
#
# Правило проекта живёт в .claude/rules/<имя>.md, коммитится вместе с кодом,
# грузится по путям файлов — как и общие. Отличается только источником.
#
#   std-rule.sh new <имя> [шаблон]   создать правило
#   std-rule.sh list                 показать правила проекта и общие модули
#   std-rule.sh precedence           создать файл приоритета правил
#   std-rule.sh override <модуль>    отключить общий модуль в этом проекте
set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
RULES_DIR="$PROJECT_DIR/.claude/rules"
PRECEDENCE="$RULES_DIR/00-precedence.md"

b()   { printf '\033[1m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }
ylw() { printf '\033[33m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*"; }

today() { date -u +%Y-%m-%d; }

# ── Файл приоритета ───────────────────────────────────────────────────────────
# Claude Code загружает все правила с одинаковым весом: автоматического
# «проектное побеждает общее» нет. При противоречии модель выберет одно
# произвольно, и никто не узнает какое. Поэтому иерархия объявляется явно.
write_precedence() {
  mkdir -p "$RULES_DIR"
  if [[ -f "$PRECEDENCE" ]]; then
    ylw "  файл приоритета уже есть: .claude/rules/00-precedence.md"
    return 0
  fi
  cat > "$PRECEDENCE" <<EOF
---
owner: "@project"
enforcement: prose
since: "$(today)"
---

# Приоритет правил в этом проекте

Правила приходят из двух источников: общие модули стандартов
(\`.claude/rules/std-*\`, симлинки на общий репозиторий) и правила этого
проекта (остальные файлы в \`.claude/rules/\`, они в git).

**При противоречии действует правило проекта.** Общие модули описывают, как
принято обычно; проект знает свои обстоятельства.

**Заметив противоречие, скажи о нём.** Не выбирай молча: расхождение означает
либо что общее правило пора уточнять, либо что отступление в проекте больше
не нужно. Оба случая требуют решения человека, а не тихого выбора одного
из двух.

Отступления от общих правил записываются здесь, ниже, вместе с причиной.
Отступление без причины через полгода неотличимо от недосмотра.

## Отступления

<!--
Пример:

### Валидация в контроллерах, а не в FormRequest
Модуль: std-php-laravel, правило 10-http.
Причина: легаси-модуль биллинга не переведён на FormRequest, перевод
запланирован на Q4. Новый код — по общему правилу.
-->

Пока нет.
EOF
  grn "  создан .claude/rules/00-precedence.md"
  echo "  Он коммитится: приоритет должен быть одинаковым у всей команды."
}

# ── Создание правила ──────────────────────────────────────────────────────────
new_rule() {
  local name="${1:-}" kind="${2:-general}"
  [[ -z "$name" ]] && { red "укажи имя: std-rule.sh new api-conventions"; exit 2; }

  # Нормализуем имя: без пробелов, без расширения, без префикса std-
  name="${name%.md}"; name="${name#std-}"
  name=$(printf '%s' "$name" | tr ' _' '--' | tr -cd 'a-zA-Z0-9-')
  [[ -z "$name" ]] && { red "имя должно содержать латиницу или цифры"; exit 2; }

  local file="$RULES_DIR/$name.md"
  if [[ -e "$file" ]]; then
    red "  правило уже существует: .claude/rules/$name.md"
    exit 1
  fi
  mkdir -p "$RULES_DIR"

  local paths_hint
  case "$kind" in
    backend)  paths_hint='  - "app/**/*.php"' ;;
    frontend) paths_hint='  - "src/**/*.{ts,vue}"' ;;
    infra)    paths_hint='  - "deploy/**"' ;;
    tests)    paths_hint='  - "tests/**"' ;;
    always)   paths_hint='' ;;
    *)        paths_hint='  - "путь/**/*.расширение"' ;;
  esac

  {
    echo "---"
    if [[ -n "$paths_hint" ]]; then
      echo "# Без paths правило грузится в КАЖДУЮ сессию и расходует контекст,"
      echo "# даже когда оно ни при чём. Указывай пути всегда, кроме случая,"
      echo "# когда правило действительно касается любого файла."
      echo "paths:"
      echo "$paths_hint"
    else
      echo "# Правило без paths грузится всегда. Держи его коротким."
    fi
    echo "owner: \"@\"                 # кто в проекте отвечает за это правило"
    echo "enforcement: prose        # hook | lint | test | review | prose"
    echo "since: \"$(today)\""
    echo "---"
    echo
    echo "# Заголовок: о чём правило"
    echo
    echo "<!--"
    echo "Правило заводится по факту, а не впрок: агент ошибся одинаково второй"
    echo "раз, ревью поймало то, что он должен был знать, или ты второй раз"
    echo "печатаешь ту же поправку в чат."
    echo
    echo "Проверь себя: это можно проверить машиной? Если да — место правилу"
    echo "в конфиге линтера или в хуке, а не в тексте. Текст — просьба,"
    echo "проверка — гарантия."
    echo "-->"
    echo
    echo "- Пункт формулируется проверяемо: «валидация только в FormRequest»,"
    echo "  а не «валидируй данные аккуратно»."
    echo "- Причину пиши там, где она неочевидна: почему в этом проекте так."
    echo "- До 15 пунктов: длинные правила соблюдаются хуже коротких."
  } > "$file"

  grn "  создан .claude/rules/$name.md"
  echo
  echo "  Дальше:"
  echo "    1. заполни paths, owner и сами пункты"
  echo "    2. закоммить — правило проекта живёт в git, в отличие от std-* ссылок"
  echo "    3. проверь загрузку: открой подходящий файл и выполни /context"
  [[ -f "$PRECEDENCE" ]] || {
    echo
    ylw "  Файла приоритета нет. Создай: /std-core:rule precedence"
    echo "  Без него при противоречии с общим правилом модель выберет любое."
  }
}

# ── Отступление от общего модуля ──────────────────────────────────────────────
override_module() {
  local mod="${1:-}"
  [[ -z "$mod" ]] && { red "укажи модуль: std-rule.sh override php-laravel"; exit 2; }
  mod="${mod#std-}"

  local link="$RULES_DIR/std-$mod"
  [[ -L "$link" ]] || { red "  модуль std-$mod в этом проекте не подключён"; exit 1; }

  write_precedence
  cat >> "$PRECEDENCE" <<EOF

### Модуль std-$mod отключён в этом проекте

Причина: ЗАПОЛНИ — без неё через полгода отступление неотличимо от недосмотра.
Дата: $(today)
EOF

  rm "$link"
  grn "  модуль std-$mod отвязан от проекта"
  echo "  Причина записана в 00-precedence.md — заполни её."
  echo "  Вернуть обратно: /std-core:sync"
}

# ── Список ────────────────────────────────────────────────────────────────────
list_rules() {
  b "Правила этого проекта (в git):"
  local found=0
  shopt -s nullglob
  for f in "$RULES_DIR"/*.md; do
    [[ -L "$f" ]] && continue
    local paths owner
    # Берём только строки-элементы списка после paths: и до следующего ключа,
    # иначе в вывод попадает значение owner со следующей строки
    paths=$(awk '/^paths:/{f=1;next} /^[a-z_]+:/{f=0} f&&/^[[:space:]]*-/{print}' "$f" 2>/dev/null \
            | grep -oE '"[^"]+"' | head -2 | tr '\n' ' ')
    owner=$(grep -oE '^owner:.*' "$f" 2>/dev/null | cut -d'"' -f2)
    printf '  %-28s %s %s\n' "$(basename "$f")" "${owner:-—}" "${paths:-«грузится всегда»}"
    found=1
  done
  shopt -u nullglob
  [[ $found -eq 0 ]] && echo "  нет — создать: /std-core:rule new <имя>"

  echo
  b "Общие модули (симлинки, в git не идут):"
  found=0
  shopt -s nullglob
  for l in "$RULES_DIR"/std-*; do
    [[ -L "$l" ]] || continue
    local state; [[ -d "$l" ]] && state="ok" || state="БИТАЯ ССЫЛКА"
    printf '  %-28s %s\n' "$(basename "$l")" "$state"
    found=1
  done
  shopt -u nullglob
  [[ $found -eq 0 ]] && echo "  нет — подключить: /std-core:setup"

  echo
  if [[ -f "$PRECEDENCE" ]]; then
    grn "Приоритет объявлен: 00-precedence.md"
  else
    ylw "Файла приоритета нет — при противоречии выбор произволен."
    echo "Создать: /std-core:rule precedence"
  fi
}

case "${1:-}" in
  new)        shift; new_rule "$@" ;;
  precedence) write_precedence ;;
  override)   shift; override_module "$@" ;;
  list|"")    list_rules ;;
  *)          red "неизвестная команда: $1"
              echo "  new <имя> [backend|frontend|infra|tests|always]"
              echo "  list | precedence | override <модуль>"; exit 2 ;;
esac
