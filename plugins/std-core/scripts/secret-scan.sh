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
FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
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
