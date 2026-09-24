#!/usr/bin/env bash
# bash-min.sh — замки написаны для bash 4.4+; на старом bash они не должны
# молча пропускать всё подряд. Подключается через source первой строкой хука,
# ДО чтения stdin: при перезапуске вход должен остаться непрочитанным.
#
# Почему это отдельная проверка, а не «пишем на bash 3.2». В macOS по умолчанию
# /bin/bash 3.2 (2007 год), и `#!/usr/bin/env bash` берёт его, если Homebrew
# bash не стоит раньше в PATH. На нём `mapfile`, `declare -A` и `${x,,}` дают
# ошибку выполнения, а не синтаксиса: скрипт продолжает работу с пустыми
# данными. guard-bash разбивал команду на ноль сегментов и не находил в ней
# ничего опасного — то есть пропускал всё, и снаружи это выглядело как работа.
#
# Порядок: сначала ищем bash новее и перезапускаемся под ним — у большинства
# он есть, просто не первый в PATH. Нет — решение, а не тишина:
#   pre      — PreToolUse: вопрос человеку с объяснением;
#   post     — PostToolUse с проверкой безопасности: код 2 и сообщение;
#   advisory — подсказки: тихий выход, о проблеме скажет старт сессии;
#   session  — SessionStart: предупреждение в контекст один раз.

# Версия для тестов подменяется переменной: собрать bash 3.2 на машине CI
# дороже, чем проверить ветку решения. После перезапуска подмена не действует,
# иначе дочерний процесс снова счёл бы себя старым.
_std_bash_version() {
  if [[ -z "${STD_BASH_REEXEC:-}" && -n "${STD_TEST_BASH_VERSION:-}" ]]; then
    printf '%s' "$STD_TEST_BASH_VERSION"
  else
    printf '%s.%s' "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"
  fi
}

_std_bash_ok() { # <версия вида 4.4>
  local maj=${1%%.*} min=${1#*.}
  min=${min%%.*}
  [ "$maj" -gt 4 ] 2>/dev/null && return 0
  [ "$maj" -eq 4 ] 2>/dev/null && [ "$min" -ge 4 ] 2>/dev/null && return 0
  return 1
}

# Путь к bash 4.4+ из известных мест установки или пусто.
std_bash_newer() {
  local b
  for b in ${STD_BASH_CANDIDATES-/opt/homebrew/bin/bash /usr/local/bin/bash /opt/local/bin/bash /run/current-system/sw/bin/bash /nix/var/nix/profiles/default/bin/bash}; do
    [ -x "$b" ] || continue
    "$b" -c '[ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 4 ]; }' 2>/dev/null || continue
    printf '%s' "$b"; return 0
  done
  return 1
}

STD_BASH_WHY=""

std_bash_min() { # <pre|post|advisory|session> <путь к скрипту> [аргументы]
  local mode="$1" self="$2" have b
  shift 2
  have=$(_std_bash_version)
  _std_bash_ok "$have" && return 0

  if [ -z "${STD_BASH_REEXEC:-}" ] && b=$(std_bash_newer); then
    # Сессии достаточно знать, что замки найдут новый bash сами.
    [ "$mode" = "session" ] && return 0
    STD_BASH_REEXEC=1 exec "$b" "$self" ${1+"$@"}   # ${1+…}: в bash 3.2 с set -u пустой "$@" — ошибка
  fi

  STD_BASH_WHY="Замки стандартов требуют bash 4.4 или новее, а запущен bash $have (в macOS он стоит по умолчанию). На нём проверки не работают, а выглядят работающими. Поставь новый bash: brew install bash — перезапуск Claude Code не нужен, замки найдут его сами."
  local why="$STD_BASH_WHY"
  case "$mode" in
    pre)
      why=${why//\\/\\\\}; why=${why//\"/\\\"}
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s До тех пор каждое действие подтверждается вручную."}}\n' "$why"
      exit 0 ;;
    post)
      printf '%s\n' "$why" >&2
      exit 2 ;;
    session)
      return 1 ;;
    *)
      exit 0 ;;
  esac
}
