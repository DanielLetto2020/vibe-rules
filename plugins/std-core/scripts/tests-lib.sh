#!/usr/bin/env bash
# shellcheck disable=SC2034  # STD_TEST_* читают подключившие этот файл скрипты
# tests-lib.sh — что считается тестом и насколько строго его охранять.
# Подключается через source из guard-tests.sh (Write/Edit) и guard-bash.sh
# (sed -i, >, cp, rm по файлу теста). Сам ничего не решает.
#
# Отдельный файл по той же причине, что и secret-lib.sh: точек две, и пока
# маски жили только в guard-tests, правка теста через `sed -i` шла мимо —
# тот же короткий путь, ради которого замок заведён, только другим
# инструментом.

# Маски сверяются с путём внутри проекта, а не с абсолютным (иначе проект,
# лежащий в …/tests/…, целиком считался бы тестом).
STD_TEST_DEFAULT_RE='(^|/)(tests?|spec|specs|__tests__|Feature|Unit)/|Test\.php$|(^|/)test_[^/]*\.py$|_test\.(py|go)$|\.(spec|test)\.(ts|tsx|js|jsx|mjs|cjs|mts|cts)$|\.cy\.(ts|js)$|_spec\.rb$'

_std_test_cfg() { # <файл> <ключ>
  [[ -f "$1" ]] || return 0
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$2" '.[$k] // empty' "$1" 2>/dev/null; return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys
try:
    v = json.load(open(sys.argv[1])).get(sys.argv[2], "")
    print("" if v is None else (v if isinstance(v, str) else json.dumps(v)), end="")
except Exception:
    pass' "$1" "$2" 2>/dev/null
  fi
  return 0
}

# Политика проекта: STD_TEST_MODE (off|ask|deny) и STD_TEST_RE.
# Код 1 — проект не подключён к стандартам, охранять нечего.
std_test_policy() { # <корень проекта>
  local d="$1" v
  STD_TEST_MODE=ask; STD_TEST_RE=$STD_TEST_DEFAULT_RE
  [[ -f "$d/.claude/gauntlet.json" ]] || compgen -G "$d/.claude/rules/std-*" >/dev/null 2>&1 || return 1
  # Строгость задаётся профилем, отдельный файл переопределяет профиль
  v=$(_std_test_cfg "$d/.claude/gauntlet.json" guardTests); [[ -n "$v" ]] && STD_TEST_MODE=$v
  v=$(_std_test_cfg "$d/.claude/std-guard.json" mode);      [[ -n "$v" ]] && STD_TEST_MODE=$v
  v=$(_std_test_cfg "$d/.claude/std-guard.json" protectedRegex); [[ -n "$v" ]] && STD_TEST_RE=$v
  return 0
}
