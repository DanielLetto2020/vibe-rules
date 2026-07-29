#!/usr/bin/env bash
# secret-scan.sh — PostToolUse: ищет секреты в только что записанном файле.
#
# Тесты, типизация и линтеры этот класс проблем не ловят в принципе:
# захардкоженный ключ не мешает коду работать. Поэтому — отдельный слой.
#
# Не блокирует запись (файл уже создан), но возвращает Claude текст ошибки,
# чтобы он немедленно исправил, и показывает предупреждение человеку.
set -uo pipefail

INPUT=$(cat)

# --- std:jq-guard — «не проверено» должно быть слышно -------------------------
# Молчаливый выход здесь означал бы, что записанный файл никто не смотрел,
# а выглядело бы это как пройденная проверка.
read_field() { # <поле в tool_input>
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$INPUT" | jq -r --arg f "$1" '.tool_input[$f] // empty' 2>/dev/null; return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$INPUT" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("tool_input", {}).get(sys.argv[1], "") or "", end="")
except Exception:
    pass' "$1" 2>/dev/null; return 0
  fi
  return 1
}

if ! FILE=$(read_field file_path); then
  printf '%s\n' "Файл записан, но на секреты не проверен: на машине нет ни jq, ни python3. Поставь jq — до тех пор этот слой защиты не работает." >&2
  exit 2
fi
[[ -z "$FILE" || ! -f "$FILE" ]] && exit 0

case "$FILE" in
  *.env.example|*.md|*/tests/*|*lock.json|*.lock) exit 0 ;;
esac

HITS=$(grep -nEi \
  -e '(aws_secret_access_key|aws_access_key_id)[[:space:]]*[:=]' \
  -e 'AKIA[0-9A-Z]{16}' \
  -e '(sk-ant-|ghp_|gho_|github_pat_|xox[baprs]-)[A-Za-z0-9_-]{10,}' \
  -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' \
  -e '(password|passwd|secret|api_?key|token)[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"'{$]{8,}["'"'"']' \
  "$FILE" 2>/dev/null | head -5)

[[ -z "$HITS" ]] && exit 0

MSG="Похоже на секрет в открытом виде в $FILE:
$HITS

Вынеси значение в переменную окружения и добавь плейсхолдер в .env.example."

printf '%s\n' "$MSG" >&2
exit 2
