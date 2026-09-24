#!/usr/bin/env bash
# guard-bash.sh — PreToolUse-замок на Bash.
#
# Принцип: то, что можно проверить машиной, не должно жить в тексте правил.
# Текст — просьба (модель может забыть), хук — проверка (выполняется всегда).
#
# Чего замок НЕ делает: он не песочница и не граница безопасности. Команду
# можно записать так, что разбор её не узнает — через файл скрипта, свою
# обёртку, чужой бинарник. Замок закрывает частые непреднамеренные разрушения,
# то есть забывчивость, а не намерение. Границы перечислены в README и держатся
# корпусом tests/hook-corpus.tsv: то, что мы не ловим, названо вслух.
#
# Вход:  JSON на stdin (tool_name, tool_input.command)
# Выход: exit 0 + JSON с permissionDecision: deny | ask | (пусто = обычный поток)
set -uo pipefail
# Раскрытие масок выключено намеренно. Аргументы разбираемой команды —
# это текст: `rm -rf /*` должен остаться строкой `/*`, а не превратиться
# в список каталогов корня, по которому правило уже ничего не узнает.
set -f

. "$(dirname "${BASH_SOURCE[0]}")/bash-min.sh"; std_bash_min pre "${BASH_SOURCE[0]}"   # до чтения stdin
INPUT=$(cat)

# std:hooks-off — человек отключил замки в этом проекте (.claude/std-hooks-off).
# Здесь это значит не «выйти», а «остаться только на необратимом». Мешают
# вопросы, а не запреты: запрет на удаление тома никого не тормозит, потому что
# удалять том никто и не собирался, — а вопрос про каждую вторую команду стоит
# рабочего времени каждый день. Поэтому маркер глушит вопросы и не трогает
# запреты: rm -rf по системному пути, удаление образов, томов и кэша, drop
# и truncate, mkfs, dd на устройство, force-push блокируются и здесь.
HOOKS_OFF=0
[[ -f "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/std-hooks-off" ]] && HOOKS_OFF=1

# Словарь секретов общий с остальными точками проверки: чтением файла, записью
# и коммитом. Пока он был у каждой свой, добавленный паттерн закрывал одну
# дорогу из четырёх.
. "$(dirname "${BASH_SOURCE[0]}")/secret-lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/tests-lib.sh"

# --- Вывод решения без внешних зависимостей ----------------------------------
# Раньше решение печатал jq. Получалось, что замок зависел от того же jq,
# без которого он и так не мог прочитать вход: одна отсутствующая программа
# выключала защиту дважды. Экранирование здесь простое и полное для наших
# строк: обратный слэш, кавычка, перевод строки, табуляция.
json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

emit() { # <deny|ask> <причина>
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' \
    "$1" "$(json_escape "$2")"
  exit 0
}

# Запрет выходит сразу: дальше разбирать незачем.
deny() { emit deny "$1"; }

# Два вида вопросов, и различие между ними — вся суть выключателя.
#
# ask_loss — про необратимую потерю того, что уже сделано: незакоммиченных
# правок, namespace вместе с томами, развёрнутого окружения. Таких команд
# за неделю единицы, и вопрос на них не мешает никому. Задаётся всегда,
# в том числе при выключенных замках: запретить их нельзя (они бывают нужны),
# а пропустить молча — значит потерять работу целиком.
#
# ask — всё остальное: новая зависимость, чтение файла с доступами, команда,
# которую замок не смог разобрать. Здесь вопрос стоит дешевле ошибки только
# до тех пор, пока его задают редко. Это и есть то, что выключается маркером.
#
# Вопрос не завершает разбор, а откладывается до конца. Раньше первый же
# вопрос печатался и выходил: `rm -rf ~/.cache/foo /var/lib/foo` получал
# вопрос про кэш, а запрет на /var/lib до проверки не доходил;
# `git reset --hard && git push --force` — то же самое. Запрет важнее
# вопроса, поэтому вопрос ждёт, пока будет проверено всё остальное.
PENDING=()
note_ask() {
  local m
  for m in "${PENDING[@]}"; do [[ "$m" == "$1" ]] && return 0; done
  PENDING+=("$1")
}
ask_loss() { note_ask "$1"; }
ask()      { ((HOOKS_OFF)) && return 0; note_ask "$1"; }

finish() {
  if ((${#PENDING[@]})); then
    local msg="${PENDING[0]}" i
    # Больше трёх причин не читают; первая уже требует решения
    for ((i = 1; i < ${#PENDING[@]} && i < 3; i++)); do msg+=$'\n\n'"${PENDING[i]}"; done
    emit ask "$msg"
  fi
  exit 0
}

# --- std:jq-guard — отсутствие разборщика JSON не должно открывать ворота ------
# Было: jq не найден -> пустая строка -> тихий exit 0 -> все замки выключены,
# и никто об этом не знает. Это ровно то, что репозиторий называет худшим
# случаем: молчаливо сломанная проверка. Теперь — отказ с объяснением.
#
# Код 2 — вход не разобрался как JSON. Раньше ошибку jq глотали, и битый
# вход выглядел как пустая команда: exit 0, решения нет.
read_command() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || return 2
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$INPUT" | PYTHONIOENCODING=utf-8 python3 -c 'import json,sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(2)
cmd = (data.get("tool_input") or {}).get("command", "") if isinstance(data, dict) else ""
print(cmd if isinstance(cmd, str) else json.dumps(cmd), end="")' 2>/dev/null
    return $?
  fi
  return 1
}

CMD=$(read_command); rc=$?
case $rc in
  0) ;;
  1) deny "Замки не работают: на машине нет ни jq, ни python3, а без них запрос не разобрать. Пока их нет, любая команда блокируется — иначе защита выключилась бы молча. Поставь jq в своём терминале (apt install jq / brew install jq / dnf install jq) и повтори." ;;
  # Не ask(): маркер глушит вопросы о том, что замок понял, а здесь он
  # не понял ничего — даже того, какую команду его просят пропустить.
  *) emit ask "Замок не смог прочитать запрос: на входе не JSON. Какая команда выполнится, отсюда не видно — прочитай её сам, прежде чем подтвердить." ;;
esac

[[ -z "$CMD" ]] && exit 0

# Дальше строка обрабатывается побайтно. В локали UTF-8 bash ищет по строке
# с многобайтными символами от её начала на каждом шаге, и heredoc на 3000
# строк кириллицы разбирался 5,5 секунды вместо 0,07. Всё, что ищут правила, —
# ASCII: имена команд, флаги, пути, SQL; байты кириллицы проходят насквозь.
export LC_ALL=C

# Служебные символы разборщика не должны приходить с командой: ими размечены
# его ответы, и команда с ними могла бы подделать разметку.
CMD=${CMD//[$'\x1c\x1d\x1e\x1f']/ }

PROJ=${CLAUDE_PROJECT_DIR:-$PWD}
while [[ ${#PROJ} -gt 1 && "$PROJ" == */ ]]; do PROJ=${PROJ%/}; done
HOME_DIR=${HOME:-/root}
while [[ ${#HOME_DIR} -gt 1 && "$HOME_DIR" == */ ]]; do HOME_DIR=${HOME_DIR%/}; done
# Текущий каталог для относительных путей. Меняется командой `cd` в той же
# строке: `cd / && rm -rf etc` — это rm -rf /etc, а не каталог проекта.
CWD=$PROJ
# Надзор за тестами: те же маски и строгость, что у guard-tests. Там Write
# и Edit, здесь — `sed -i`, `>`, `cp`, `rm` по файлу теста: тот же короткий
# путь «ослабить тест вместо кода», только другим инструментом.
TESTS_ON=0
if std_test_policy "$PROJ" && [[ "$STD_TEST_MODE" != off ]]; then TESTS_ON=1; fi

# --- Пределы разбора ----------------------------------------------------------
# Хук работает под таймаутом, и если разбор его превысит, команда выполнится
# без решения. Так и было: heredoc на 3000 строк с `rm -rf /etc` в конце
# разбирался дольше ста секунд. Сверх пределов команда проверяется грубо —
# по тексту целиком, только на запреты — и уходит человеку с вопросом:
# молча пропустить неразобранное нельзя.
MAXDEPTH=3      # вложенность bash -c / eval / $(...)
MAXSEGS=150     # команд в строке, на всех уровнях вместе
MAXTOK=400      # слов в одной команде
MAXINPUT=1000000
SEGCOUNT=0
TOO_BIG=""

US=$'\x1f'; NL_ENC=$'\x1e'; GS=$'\x1d'; FS=$'\x1c'

# --- Разбор командной строки --------------------------------------------------
# Проверять правилами всю строку целиком нельзя: тогда `echo "не запускай
# migrate:fresh"` блокируется наравне с самим migrate:fresh, а `bash -c "docker
# volume rm"` проходит, потому что опасное слово спрятано в аргументе. Поэтому
# строка сначала разбирается: сегменты, слова, перенаправления, heredoc,
# подстановки — и правила применяются только к тому, что действительно
# исполняется.
#
# Разборщик на awk, а не на bash, потому что посимвольный проход в bash
# квадратичен: `${s:i:1}` каждый раз ищет i-й символ от начала строки, и 80 КБ
# разбирались 14 секунд. awk проходит тот же текст за миллисекунды одним
# процессом, а awk есть везде, где есть bash.
#
# Ответ — записи по одной на строку, поля через \x1f:
#   S <разделитель>          начало сегмента; разделитель перед ним (; && || | & ( ) nl)
#   W <в кавычках 0|1> <текст>   слово; кавычки и экранирование сняты
#   R <оператор> <цель>      перенаправление (>, >>, <, <<<, &> ...)
#   H <сегмент> <разделитель в кавычках 0|1> <тело>   тело heredoc
#   C <вид> <текст>          тело $(...), `...`, <(...) — разбирается отдельно
# Переводы строк внутри полей закодированы \x1e.
read -r -d '' SCANNER <<'AWK'
BEGIN { US = sprintf("%c", 31); NLE = sprintf("%c", 30); NSEG = -1 }
{ LINES[NR] = $0 }
function setl() { if (L <= NLINES) { CL = LINES[L]; LN = length(CL) } else { CL = ""; LN = 0 } }
function ch(k,   p) {
  if (L > NLINES) return ""
  p = J + k
  if (p <= LN) return substr(CL, p, 1)
  if (p == LN + 1 && L < NLINES) return "\n"
  return ""
}
function adv(k) { J += k; while (L <= NLINES && J > LN + 1) { J -= LN + 1; L++; setl() } }
function enc(x) { gsub(/\n/, NLE, x); return x }
function add(t, q) { CUR = CUR t; INW = 1; if (q) CQ = 1 }
function flush(em) {
  if (!INW) return
  if (HDP) { NP++; PD[NP] = CUR; PS[NP] = HDS; PQ[NP] = CQ; PSEG[NP] = NSEG; PEM[NP] = em; HDP = 0 }
  else if (ROP != "") { if (em) printf "R%s%s%s%s\n", US, ROP, US, enc(CUR); ROP = "" }
  else if (em) printf "W%s%d%s%s\n", US, CQ, US, enc(CUR)
  CUR = ""; CQ = 0; INW = 0
}
function sep(em, kind) {
  flush(em); HDP = 0; ROP = ""
  if (em) { NSEG++; printf "S%s%s\n", US, kind }
}
function bodies(   p, body, t) {
  for (p = 1; p <= NP; p++) {
    body = ""
    while (L <= NLINES) {
      t = LINES[L]; L++
      if (PS[p]) sub(/^\t+/, "", t)
      if (t == PD[p]) break
      body = body t "\n"
    }
    if (PEM[p]) printf "H%s%d%s%d%s%s\n", US, PSEG[p], US, PQ[p], US, enc(body)
  }
  NP = 0; J = 1; setl()
}
function fdword() { return INW && !CQ && CUR ~ /^[0-9]+$/ }
function redir(em, op) { if (fdword()) { CUR = ""; INW = 0 } else flush(em); ROP = op }
function heredoc(em, strip) { if (fdword()) { CUR = ""; INW = 0 } else flush(em); HDP = 1; HDS = strip }
function extract(sL, sJ, eL, eJ,    t, i) {
  if (sL > NLINES) return ""
  if (eL > NLINES) { eL = NLINES; eJ = length(LINES[NLINES]) + 1 }
  if (sL == eL) return substr(LINES[sL], sJ, eJ - sJ)
  t = substr(LINES[sL], sJ)
  for (i = sL + 1; i < eL; i++) t = t "\n" LINES[i]
  return t "\n" substr(LINES[eL], 1, eJ - 1)
}
function nested(depth, em, kind,    sc, scq, si, sr, sh, sL, sJ, body) {
  sc = CUR; scq = CQ; si = INW; sr = ROP; sh = HDP
  CUR = ""; CQ = 0; INW = 0; ROP = ""; HDP = 0
  sL = L; sJ = J; CLOSED = 0
  scan(depth + 1, 0)
  # Незакрытая подстановка идёт до конца строки — последний символ не скобка
  body = extract(sL, sJ, L, CLOSED ? J - 1 : J)
  CLOSED = 0
  CUR = sc; CQ = scq; INW = si; ROP = sr; HDP = sh
  if (em) printf "C%s%s%s%s\n", US, kind, US, enc(body)
  add(kind "...)", 0)
}
function backtick(em,    c, c2, body) {
  body = ""
  while ((c = ch(0)) != "") {
    adv(1)
    if (c == "\\") { c2 = ch(0); if (c2 == "`" || c2 == "\\" || c2 == "$") { body = body c2; adv(1); continue } }
    if (c == "`") break
    body = body c
  }
  if (em) printf "C%s`%s%s\n", US, US, enc(body)
  add("$(...)", 0)
}
function sq(   c) { INW = 1; CQ = 1; while ((c = ch(0)) != "") { adv(1); if (c == "'") return; CUR = CUR c } }
function dq(depth, em,    c, c2) {
  INW = 1; CQ = 1
  while ((c = ch(0)) != "") {
    if (c == "\"") { adv(1); return }
    if (c == "\\") {
      c2 = ch(1)
      if (c2 == "\n") { adv(2); continue }
      if (c2 == "$" || c2 == "`" || c2 == "\"" || c2 == "\\") { CUR = CUR c2; adv(2); continue }
      CUR = CUR c; adv(1); continue
    }
    if (c == "$") { dollar(depth, em); continue }
    if (c == "`") { adv(1); backtick(em); continue }
    CUR = CUR c; adv(1)
  }
}
function dollar(depth, em,    c1, n, c, t) {
  c1 = ch(1)
  if (c1 == "(" && ch(2) == "(") {
    adv(3); n = 2; t = "$(("
    while ((c = ch(0)) != "") { adv(1); t = t c; if (c == "(") n++; else if (c == ")") { n--; if (n == 0) break } }
    add(t, 0); return
  }
  if (c1 == "(") { adv(2); nested(depth, em, "$("); return }
  if (c1 == "{") {
    adv(2); n = 1; t = "${"
    while ((c = ch(0)) != "") { adv(1); t = t c; if (c == "{") n++; else if (c == "}") { n--; if (n == 0) break } }
    add(t, 0); return
  }
  if (c1 == "'") {
    adv(2); INW = 1; CQ = 1
    while ((c = ch(0)) != "") {
      if (c == "\\") { CUR = CUR c ch(1); adv(2); continue }
      adv(1); if (c == "'") return
      CUR = CUR c
    }
    return
  }
  if (c1 == "\"") { adv(1); return }
  add("$", 0); adv(1)
}
function angle(depth, em, c,    c1, strip) {
  c1 = ch(1)
  if (c1 == "(") { flush(em); adv(2); nested(depth, em, c "("); return }
  if (c == "<") {
    if (c1 == "<") {
      if (ch(2) == "<") { adv(3); redir(em, "<<<"); return }
      adv(2); strip = 0
      if (ch(0) == "-") { adv(1); strip = 1 }
      heredoc(em, strip); return
    }
    if (c1 == "&") { adv(2); redir(em, "<&"); return }
    if (c1 == ">") { adv(2); redir(em, "<>"); return }
    adv(1); redir(em, "<"); return
  }
  if (c1 == ">") { adv(2); redir(em, ">>"); return }
  if (c1 == "&") { adv(2); redir(em, ">&"); return }
  if (c1 == "|") { adv(2); redir(em, ">|"); return }
  adv(1); redir(em, ">")
}
function scan(depth, em,    c, c2, paren) {
  paren = 0
  while ((c = ch(0)) != "") {
    if (c == "\\") {
      c2 = ch(1)
      if (c2 == "\n") { adv(2); continue }
      if (c2 == "") { adv(1); continue }
      add(c2, 1); adv(2); continue
    }
    if (c == "'") { adv(1); sq(); continue }
    if (c == "\"") { adv(1); dq(depth, em); continue }
    if (c == "`") { adv(1); backtick(em); continue }
    if (c == "$") { dollar(depth, em); continue }
    if (c == " " || c == "\t" || c == "\r") { flush(em); adv(1); continue }
    if (c == "#" && !INW) { J = LN + 1; continue }
    if (c == "\n") { flush(em); adv(1); if (NP) bodies(); sep(em, "nl"); continue }
    if (c == ";") { adv(ch(1) == ";" ? 2 : 1); sep(em, ";"); continue }
    if (c == "&") {
      c2 = ch(1)
      if (c2 == "&") { adv(2); sep(em, "&&"); continue }
      if (c2 == ">") { adv(2); if (ch(0) == ">") { adv(1); redir(em, "&>>") } else redir(em, "&>"); continue }
      adv(1); sep(em, "&"); continue
    }
    if (c == "|") {
      c2 = ch(1)
      if (c2 == "|") { adv(2); sep(em, "||"); continue }
      if (c2 == "&") { adv(2); sep(em, "|"); continue }
      adv(1); sep(em, "|"); continue
    }
    if (c == "<" || c == ">") { angle(depth, em, c); continue }
    if (c == "(") { adv(1); if (depth > 0) paren++; sep(em, "("); continue }
    if (c == ")") {
      if (depth > 0 && paren == 0) { flush(em); adv(1); CLOSED = 1; return }
      if (paren > 0) paren--
      adv(1); sep(em, ")"); continue
    }
    add(c, 0); adv(1)
  }
}
function dqbody(   c) {
  while ((c = ch(0)) != "") {
    if (c == "\\") { adv(2); continue }
    if (c == "$" && ch(1) == "(" && ch(2) != "(") { adv(2); nested(0, 1, "$("); continue }
    if (c == "`") { adv(1); backtick(1); continue }
    adv(1)
  }
}
END {
  NLINES = NR
  if (NLINES == 0) exit
  L = 1; J = 1; setl()
  if (mode == "dq") { dqbody(); exit }
  sep(1, "start")
  scan(0, 1)
  flush(1)
}
AWK

scan_text() { # <текст> [cmd|dq]
  printf '%s' "$1" | LC_ALL=C awk -v mode="${2:-cmd}" "$SCANNER"
}

# --- Слова сегмента -----------------------------------------------------------
# Подстановка присваиваний из той же строки: `D=docker; $D volume rm x`.
# Переменная из другой команды или из окружения так не раскрывается — это
# записано в известные границы, а не выдаётся за проверку.
AN=(); AV=()
remember() { # <имя> <значение>
  local i
  [[ -z "$2" ]] && return 0
  for ((i = 0; i < ${#AN[@]}; i++)); do
    [[ "${AN[i]}" == "$1" ]] && { AV[i]=$2; return 0; }
  done
  AN+=("$1"); AV+=("$2")
}

# $NAME заменяется, только если следом не идёт буква имени. Раньше замена была
# простой подстановкой строки, и `H=1; rm -rf $HOME` превращался в `rm -rf 1OME`
# — удаление домашнего каталога проходило как безобидное.
subst_word() { # <слово> -> SUBST
  local x="$1" i n v out rest pre
  for ((i = 0; i < ${#AN[@]}; i++)); do
    n=${AN[i]}; v=${AV[i]}
    [[ "$x" == *"\$"* ]] || break
    x=${x//"\${$n}"/"$v"}
    [[ "$x" == *"\$$n"* ]] || continue
    out=""; rest=$x
    while [[ "$rest" == *"\$$n"* ]]; do
      pre=${rest%%"\$$n"*}; rest=${rest#*"\$$n"}
      if [[ "$rest" == [A-Za-z0-9_]* ]]; then out+="$pre\$$n"; else out+="$pre$v"; fi
    done
    x="$out$rest"
  done
  SUBST=$x
}

seg_words() { # <первое слово> <за последним> -> sw, sq
  local i w q part
  sw=(); sq=()
  for ((i = $1; i < $2; i++)); do
    [[ "${W[i]}" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] && remember "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  done
  # for d in /etc /usr; do rm -rf $d — переменная цикла принимает все значения
  if (($2 - $1 >= 3)) && [[ "${W[$1]}" == for && "${W[$1+2]}" == in ]]; then
    local vals=""
    for ((i = $1 + 3; i < $2; i++)); do vals+="${W[i]} "; done
    remember "${W[$1+1]}" "${vals% }"
  fi
  for ((i = $1; i < $2; i++)); do
    w=${W[i]}; q=${WQ[i]}
    if ((${#AN[@]})) && [[ "$w" == *"\$"* ]]; then
      subst_word "$w"; w=$SUBST
      if ((q == 0)) && [[ "$w" == *[[:space:]]* ]]; then
        for part in $w; do sw+=("$part"); sq+=(0); done
        continue
      fi
    fi
    sw+=("$w"); sq+=("$q")
  done
}

# Пропуск опций обёртки. Буквы коротких опций со значением и длинные опции
# со значением — свои у каждой обёртки: `sudo -u postgres dropdb` без этого
# считался командой `-u`, и dropdb не проверялся вовсе.
skip_opts() { # <буквы со значением> <длинные со значением, ERE>
  local n=${#sw[@]} w
  while ((P < n)); do
    w=${sw[P]}
    case "$w" in
      --) ((P++)); return ;;
      -) ((P++)) ;;
      --*=*) ((P++)) ;;
      --*) ((P++)); [[ -n "$2" && "$w" =~ ^($2)$ ]] && ((P++)) ;;
      -[0-9]*) ((P++)) ;;
      -?*) ((P++)); [[ -n "$1" && "${w: -1}" == ["$1"] ]] && ((P++)) ;;
      *) return ;;
    esac
  done
}

# Снятие обёрток, за которыми стоит настоящая команда: sudo, env, timeout 30,
# nice, ведущие присваивания, ключевые слова. Без этого `sudo docker volume rm`
# считался бы командой sudo и не проверялся.
strip_prefix() { # sw -> P (первое слово команды), ENVPRINT, XARGS
  local n=${#sw[@]} w envp=0
  P=0; ENVPRINT=0; XARGS=0
  while ((P < n)); do
    w=${sw[P]}
    if [[ "$w" =~ ^[A-Za-z_][A-Za-z0-9_]*\+?= ]]; then ((P++)); continue; fi
    case "${w##*/}" in
      sudo|doas) ((P++)); skip_opts 'ugChpDrtTU' '--user|--group|--host|--prompt|--chdir|--role|--type|--other-user|--close-from|--command-timeout' ;;
      env)       ((P++)); envp=1; skip_opts 'uCS' '--unset|--chdir|--split-string' ;;
      nice)      ((P++)); skip_opts 'n' '--adjustment' ;;
      ionice)    ((P++)); skip_opts 'cnp' '--class|--classdata|--pid|--pgid|--uid' ;;
      timeout)   ((P++)); skip_opts 'sk' '--signal|--kill-after'; ((P < n)) && ((P++)) ;;
      stdbuf)    ((P++)); skip_opts 'ioe' '--input|--output|--error' ;;
      xargs)     ((P++)); XARGS=1; skip_opts 'adEILnPs' '--arg-file|--delimiter|--eof|--replace|--max-lines|--max-args|--max-procs|--max-chars' ;;
      watch)     ((P++)); skip_opts 'n' '--interval' ;;
      exec)      ((P++)); skip_opts 'a' '' ;;
      nohup|builtin|command|time|chronic|unbuffer|'!'|'{'|'}'|if|then|else|elif|do|while|until)
                 ((P++)); skip_opts '' '' ;;
      *) break ;;
    esac
  done
  # `env` без команды печатает окружение, как и `env FOO=1`
  ((envp && P >= n)) && ENVPRINT=1
  return 0
}

# --- Команды, которые текст печатают, но не исполняют --------------------------
# Один список на оба вопроса — «исполняет ли» и «печатает ли содержимое». Пока
# списков было два, diff, comm, paste числились текстовыми, а проверка секретов
# их не знала: `diff .env .env.example` показывал все значения без вопроса.
PRINTERS='cat|less|more|most|head|tail|bat|batcat|nl|tac|xxd|od|hexdump|hd|strings|base64|base32|basenc|cut|sort|uniq|column|comm|paste|join|diff|sdiff|colordiff|cmp|fold|fmt|pr|expand|unexpand|rev|look|jq|yq|grep|egrep|fgrep|zgrep|rg|ag|ack|tr'
# Текстовые, но содержимое файлов не печатают
TEXT_ONLY='echo|printf|wc|man|which|type|whatis|tree|stat|file|date|pwd|whoami|ls'
# Печатают файл, но текстовыми не считаются: исполняют свой язык или пишут
READERS_EXTRA='awk|gawk|mawk|nawk|sed|gsed|dd|scp|rsync|curl|wget|open|xdg-open'

git_sub() { # <индекс слова git в sw> -> GSUB
  local i=$(($1 + 1)) n=${#sw[@]}
  GSUB=""
  while ((i < n)); do
    case "${sw[i]}" in
      -C|-c|--git-dir|--work-tree|--namespace|--super-prefix|--config-env) ((i += 2)) ;;
      -*) ((i++)) ;;
      *) GSUB=${sw[i]}; return ;;
    esac
  done
}

is_text_command() { # hd, sw, P
  [[ "$hd" =~ ^($PRINTERS|$TEXT_ONLY)$ ]] && return 0
  if [[ "$hd" == git ]]; then
    git_sub "$P"
    case "$GSUB" in
      log|grep|show|diff|status|blame|shortlog|describe|rev-parse|ls-files|remote|tag) return 0 ;;
      # branch — чтение, пока не удаляет: `git branch -D` терял неслитые коммиты
      # молча, потому что вся подкоманда считалась текстовой.
      branch) [[ " ${sw[*]:P} " =~ [[:space:]](-[a-zA-Z]*[dD][a-zA-Z]*|--delete)[[:space:]] ]] || return 0 ;;
    esac
  fi
  return 1
}

# --- Секреты ------------------------------------------------------------------
# Проверяется до отсева текстовых команд и не вместе с остальными правилами:
# cat, head и grep до правил разрушения не доходят вовсе. Именно ими секрет
# и достают.
#
# Утечка здесь необратима иначе, чем разрушение: отменять нечего — значение
# уже в контексте модели, то есть у провайдера и в истории сессии на диске.
# Поэтому решение всегда ask: запрет на `cat .env` сняли бы вместе со всеми
# замками, а вопрос с названной ценой человек читает.
secret_hit() { # <что> <вид>
  ask "Команда печатает содержимое: $1 — $2. Прочитанное уедет в контекст модели и останется в истории сессии; отменить это потом нельзя. Если нужны только имена переменных, возьми их без значений: grep -oE '^[A-Za-z_][A-Za-z0-9_]*' $1"
}

# Маска проверяется двумя способами. Сначала — по файлам, которые под неё
# попадают на самом деле. Если файлов нет (ещё нет или каталог другой) —
# по образцам имён: `cat .env*` проходил, потому что строку `.env*`
# сравнивали с именами буквально.
SECRET_SAMPLES='.env .env.local .env.production id_rsa id_ed25519 id_ecdsa server.pem server.key credentials.json secrets.yaml secrets.json terraform.tfstate prod.tfvars .netrc .npmrc .pgpass .git-credentials kubeconfig'
secret_glob() { # <маска> -> 0, если под неё попадает секрет
  local pat=$1 f dir base lit kind
  local -a m=()
  set +f; shopt -s nullglob
  # Раскрытие маски здесь и есть цель: проверить файлы, которые команда прочтёт.
  # Известная часть пути — в кавычках: каталог проекта бывает с пробелами.
  # shellcheck disable=SC2206
  case "$pat" in
    \~/*)  m=( "$HOME_DIR"/${pat#\~/} ) ;;
    /*)    m=( $pat ) ;;
    *)     m=( "$CWD"/$pat ) ;;
  esac
  shopt -u nullglob; set -f
  for f in "${m[@]:0:50}"; do
    if secret_path_kind "$f" >/dev/null; then
      kind=$(secret_path_kind "$f"); secret_hit "$pat (сейчас это ${f#"$CWD"/})" "$kind"; return 0
    fi
  done
  base=${pat##*/}; dir=${pat%/*}; [[ "$dir" == "$pat" ]] && dir=.
  lit=${base%%[\*\?\[]*}
  # `*` и `*.json` по образцам не проверяются: под них попадает что угодно,
  # и вопрос на каждый `cat *.json` отключили бы вместе с замком.
  ((${#lit} >= 2)) || return 1
  for f in $SECRET_SAMPLES; do
    # Сопоставление с маской и есть смысл строки
    # shellcheck disable=SC2053
    [[ "$f" == $base ]] || continue
    if secret_path_kind "$dir/$f" >/dev/null; then
      kind=$(secret_path_kind "$dir/$f"); secret_hit "$pat" "$kind"; return 0
    fi
  done
  return 1
}

secret_token() { # <аргумент> -> 0, если это файл с секретом
  local tok=$1 kind
  [[ -z "$tok" || "$tok" == _ ]] && return 1
  if [[ "$tok" == *[\*\?\[]* ]]; then secret_glob "$tok"; return; fi
  secret_path_kind "$tok" >/dev/null || return 1
  kind=$(secret_path_kind "$tok")
  secret_hit "$tok" "$kind"
  return 0
}

# grep -r печатает строки всех файлов каталога, включая .env. Спрашивать на
# каждый рекурсивный поиск нельзя — это половина поисков за день. Вопрос
# задаётся, только когда искомое похоже на ключ, а в каталоге на глубине
# до трёх уровней действительно лежит файл с секретом, не исключённый из
# поиска. rg и ag скрытые файлы по умолчанию пропускают, их это не касается.
secret_grep_tree() {
  local n=${#sw[@]} i t rec=0 pat="" have_pat=0
  local -a dirs=() inc=() exc=()
  for ((i = P + 1; i < n; i++)); do
    t=${sw[i]}
    case "$t" in
      -r|-R|--recursive|--dereference-recursive) rec=1 ;;
      -e|--regexp) ((i++)); pat=${sw[i]:-}; have_pat=1 ;;
      -f|--file) ((i++)); have_pat=1 ;;
      --include=*) inc+=("${t#*=}") ;;
      --exclude=*) exc+=("${t#*=}") ;;
      --include) ((i++)); inc+=("${sw[i]:-}") ;;
      --exclude) ((i++)); exc+=("${sw[i]:-}") ;;
      --*) ;;
      -*) [[ "$t" == *[rR]* ]] && rec=1 ;;
      *) if ((have_pat)); then dirs+=("$t"); else pat=$t; have_pat=1; fi ;;
    esac
  done
  ((rec)) || return 1
  [[ "${pat,,}" =~ (pass|secret|token|key|cred|auth|dsn|database_url|private|api) ]] || return 1
  ((${#dirs[@]})) || dirs=(.)
  local d f base x hit
  for d in "${dirs[@]}"; do
    norm_path "$d"; [[ -n "$NP" && -d "$NP" ]] || continue
    case "$NP" in /|/proc|/sys|/dev) continue ;; esac
    while IFS= read -r f; do
      base=${f##*/}; hit=1
      # Исключения grep сопоставляются с именем файла как маски
      # shellcheck disable=SC2053
      for x in "${exc[@]}"; do [[ "$base" == $x ]] && hit=0; done
      if ((hit && ${#inc[@]})); then
        hit=0
        # shellcheck disable=SC2053
        for x in "${inc[@]}"; do [[ "$base" == $x ]] && hit=1; done
      fi
      ((hit)) || continue
      if secret_path_kind "$f" >/dev/null; then
        ask "Рекурсивный grep по $d дойдёт до ${f#"$NP"/} ($(secret_path_kind "$f")) и напечатает строки со значениями. Исключи его: --exclude='${base}' — или ищи в коде, а не в каталоге целиком."
        return 0
      fi
    done < <(find "$NP" -xdev -maxdepth 3 \( -name node_modules -o -name .git -o -name vendor -o -name .venv \) -prune \
               -o -type f \( -name '.env*' -o -name '*.env' -o -name 'id_rsa*' -o -name 'id_ed25519*' -o -name 'id_ecdsa*' \
               -o -name '*.pem' -o -name '*.key' -o -name '*.p12' -o -name '*.pfx' -o -name '*.tfstate' -o -name '*.tfvars' \
               -o -name '.netrc' -o -name '.pgpass' -o -name '.npmrc' -o -name '.pypirc' -o -name '.git-credentials' \
               -o -name '.dev.vars' -o -name 'credentials*' -o -name 'secrets.*' \) -print 2>/dev/null | head -n 30)
  done
  return 1
}

secret_rules() { # сегмент k: sw, P, hd, SR[k]
  local n=${#sw[@]} i tok v glob=0 sj pair rest op tgt kind

  # 1. Команды, печатающие содержимое файла, — с секретом в аргументах.
  local reader=0
  if [[ "$hd" =~ ^($PRINTERS|$READERS_EXTRA)$ ]]; then reader=1
  elif [[ "$hd" == git ]]; then
    git_sub "$P"
    case "$GSUB" in show|diff|cat-file|grep|blame) reader=1 ;; esac
  fi
  if ((reader)); then
    for ((i = P + 1; i < n; i++)); do
      tok=${sw[i]}
      if ((glob)); then glob=0; [[ "$tok" == '!'* ]] || { secret_token "$tok" && return 0; }; continue; fi
      case "$tok" in
        # Исключение из поиска — ровно обратное чтению
        --exclude|--exclude-dir|--exclude-from) ((i++)); continue ;;
        --exclude=*|--exclude-dir=*|--exclude-from=*|--glob=!*|--iglob=!*) continue ;;
        # rg -g .env, grep --include .env: значение — имя файла
        -g|--glob|--iglob|--include) glob=1; continue ;;
        # --include=.env, --var-file=x.tfvars, if=.env: проверяется значение.
        # Раньше `=` обрезался до проверки, и эта ветка не срабатывала никогда.
        *=*) v=${tok#*=}; secret_token "$v" && return 0; continue ;;
        -*) continue ;;
      esac
      # git show HEAD:.env — путь после двоеточия
      [[ "$hd" == git && "$tok" == *:* ]] && tok=${tok#*:}
      secret_token "$tok" && return 0
    done
    [[ "$hd" =~ ^(grep|egrep|fgrep)$ ]] && secret_grep_tree && return 0
  fi

  # 2. Файл с секретом на вход перенаправлением: `tr = ' ' < .env`
  rest=${SR[k]}
  while [[ -n "$rest" ]]; do
    pair=${rest%%"$GS"*}; rest=${rest#*"$GS"}
    op=${pair%%"$FS"*}; tgt=${pair#*"$FS"}
    if [[ "$op" == '<' ]] && secret_path_kind "$tgt" >/dev/null; then
      kind=$(secret_path_kind "$tgt"); secret_hit "$tgt" "$kind"; return 0
    fi
  done

  # 3. Печать окружения целиком: в нём лежат ровно те значения, ради которых
  #    секреты и выносят из файлов. `export` и `declare -p` без имён — то же.
  local envmsg="Команда печатает всё окружение целиком, вместе со значениями ключей и паролей. Весь вывод попадёт в контекст модели. Если нужна одна переменная — назови её: printenv APP_ENV. Если нужны только имена — printenv | cut -d= -f1"
  ((ENVPRINT)) && { ask "$envmsg"; return 0; }
  local names=0 opts=""
  for ((i = P + 1; i < n; i++)); do
    if [[ "${sw[i]}" == -* ]]; then opts+=${sw[i]}; else names=1; fi
  done
  case "$hd" in
    printenv) ((names)) || { ask "$envmsg"; return 0; } ;;
    # `set -e` и `set -o pipefail` ничего не печатают — только голый set
    set) ((P + 1 >= n)) && { ask "$envmsg"; return 0; } ;;
    export) [[ $names == 0 && ( -z "$opts" || "$opts" == -p ) ]] && { ask "$envmsg"; return 0; } ;;
    # declare -f печатает функции, а не значения; -p, -x и голый declare — значения
    declare|typeset) [[ $names == 0 && ( -z "$opts" || "$opts" == *[px]* ) ]] && { ask "$envmsg"; return 0; } ;;
  esac

  sj=" ${sw[*]:P} "
  # 4. Хранилища секретов: значение выдаётся расшифрованным. Список имён
  #    (`kubectl get secrets`) значений не показывает и вопроса не стоит.
  if [[ "$sj" =~ [[:space:]]kubectl[[:space:]](.*[[:space:]])?get[[:space:]]+([^[:space:]]+[[:space:]]+)*(secret|secrets)(/[^[:space:]]*)?[[:space:]] ]] \
     && [[ "$sj" =~ [[:space:]](-o|--output)(=|[[:space:]]*)(yaml|json|jsonpath|go-template|custom-columns|template) ]]; then
    ask "Команда покажет содержимое секрета кластера в открытом виде (в -o yaml значения лежат в base64, что защитой не является). Вывод уедет в контекст модели. Если нужны только имена ключей: kubectl get secret <имя> -o jsonpath='{.data}' | jq keys"
    return 0
  fi
  if [[ "$sj" =~ (aws[[:space:]]+secretsmanager[[:space:]]+get-secret-value|aws[[:space:]]+ssm[[:space:]]+get-parameters?[[:space:]].*--with-decryption|vault[[:space:]]+(read|kv[[:space:]]+get)|gcloud[[:space:]]+secrets[[:space:]]+versions[[:space:]]+access|az[[:space:]]+keyvault[[:space:]]+secret[[:space:]]+show|doppler[[:space:]]+secrets|heroku[[:space:]]+config[[:space:]]) ]]; then
    ask "Команда достаёт значение секрета из хранилища в открытом виде — оно попадёт в контекст модели и в историю сессии. Убедись, что задача не решается без самого значения."
    return 0
  fi
  if [[ "$sj" =~ [[:space:]](docker|podman)([[:space:]]+compose|-compose)?[[:space:]].*exec[[:space:]].*[[:space:]](env|printenv)([[:space:]]+-[^[:space:]]*)*[[:space:]]$ ]] \
     || [[ "$sj" =~ [[:space:]](docker|podman)[[:space:]]+([^[:space:]]+[[:space:]]+)*inspect[[:space:]] ]]; then
    ask "Вывод покажет переменные окружения контейнера вместе со значениями — там лежат пароли к базе и ключи. Всё это попадёт в контекст модели."
    return 0
  fi

  # 5. Отправка файла наружу. Замок не сетевой экран и содержимое запроса не
  #    разбирает — он лишь не даёт сделать это не глядя.
  if [[ "$sj" =~ [[:space:]](curl|wget|http|https|xh)[[:space:]] ]] \
     && [[ "$sj" =~ (--data-binary[[:space:]]*@|--data[[:space:]]*@|--data-urlencode[[:space:]]*[^[:space:]]*@|--json[[:space:]]*@|[[:space:]]-d[[:space:]]*@|[[:space:]]-F[[:space:]]*[^[:space:]]*=@|--form[[:space:]]*[^[:space:]]*=@|[[:space:]]-T[[:space:]]|--upload-file|--post-file|--body-file) ]]; then
    ask "Команда отправляет содержимое файла на внешний адрес. Проверь, что именно уходит и куда: после отправки данные считаются раскрытыми, даже если получатель их потом удалит."
    return 0
  fi
  return 1
}

# --- Выключатели самих замков -------------------------------------------------
# Модель могла снять защиту одной командой, не спрашивая человека: создать
# маркер, дописать исключение в secret-allow, обнулить планку храповика.
# README обещает, что это решает человек. Вопрос, а не запрет: человек
# вправе сделать это и руками через агента.
LAYER_FILES='std-hooks-off|secret-allow|secret-patterns|\.ratchet\.json|\.debt\.json|\.gauntlet-pass|gauntlet\.json|policy\.json'
layer_hit() { # <путь> -> 0 и LAYER_NAME
  [[ "$1" =~ (^|/)\.claude/($LAYER_FILES)$ ]] || return 1
  LAYER_NAME=${BASH_REMATCH[2]}
}
layer_ask() {
  ask "Команда меняет $1 — это настройка самих замков: выключатель, исключения из проверки секретов, планка храповика или долга. Такое решение принимает человек, а не модель по ходу задачи. Подтверди, что это твоё решение."
}
layer_rules() { # сегмент k
  local n=${#sw[@]} i t rest pair op tgt last=-1 inplace=0
  rest=${SR[k]}
  while [[ -n "$rest" ]]; do
    pair=${rest%%"$GS"*}; rest=${rest#*"$GS"}
    op=${pair%%"$FS"*}; tgt=${pair#*"$FS"}
    case "$op" in
      '>'|'>>'|'>|'|'&>'|'&>>'|'<>') layer_hit "$tgt" && layer_ask "$tgt" ;;
    esac
  done
  for ((i = 0; i < n - 1; i++)); do
    case "${sw[i]##*/}" in
      ratchet.sh|debt.sh) [[ "${sw[i+1]}" == reset ]] && ask "Сброс ${sw[i]##*/}: планка качества опускается до нуля, и всё накопленное перестаёт проверяться. Решение за человеком — подтверди." ;;
    esac
  done
  case "$hd" in
    touch|tee|cp|mv|ln|install|truncate|rm|unlink|dd|rsync|sed|gsed|perl) ;;
    *) return 0 ;;
  esac
  for ((i = P + 1; i < n; i++)); do [[ "${sw[i]}" == -* ]] || last=$i; done
  for ((i = P + 1; i < n; i++)); do [[ "${sw[i]}" =~ ^(-i|-[a-zA-Z]*i|--in-place.*)$ ]] && inplace=1; done
  [[ "$hd" =~ ^(sed|gsed|perl)$ ]] && ((!inplace)) && return 0
  for ((i = P + 1; i < n; i++)); do
    t=${sw[i]}
    [[ "$t" == of=* ]] && t=${t#of=}
    [[ "$t" == -* ]] && continue
    # Удаление и переименование всей .claude уносит и настройки хуков
    if [[ "$hd" =~ ^(rm|mv)$ && "$t" =~ (^|/)\.claude/?$ ]]; then layer_ask "$t"; continue; fi
    layer_hit "$t" || continue
    # Снятие выключателя включает замки обратно — спрашивать не о чем
    if [[ "$LAYER_NAME" == std-hooks-off ]]; then
      [[ "$hd" =~ ^(rm|unlink)$ ]] && continue
      [[ "$hd" == mv ]] && ((i != last)) && continue
    fi
    layer_ask "$t"
  done
}

# --- Зоны файловой системы ----------------------------------------------------
# Рекурсивное удаление стоит по-разному в разных местах, и одно решение на все
# случаи здесь неверно в обе стороны: запретить всё — значит запретить `rm -rf
# node_modules`, разрешить всё — значит однажды потерять машину.
#
#   system  — запрет. Систему и чужие домашние каталоги восстанавливают,
#             а не откатывают.
#   outside — вопрос. Вне проекта, но своё: кэши, соседние репозитории,
#             временные каталоги. Бывает нужно, стоит одного подтверждения.
#   project — вопрос. Сам каталог проекта целиком.
#   inside  — свободно. Рабочий каталог для того и рабочий.

# Путь приводится к абсолютному виду до сравнения. Раньше `rm -rf ./../..`,
# `$PROJ/..` и `$PROJ/../../../..` считались «внутри проекта», потому что
# начинались с его имени или с точки, — хотя последний из них это корень.
norm_path() { # <путь> -> NP (пусто, если путь зависит от неизвестной переменной)
  local p=$1 user rest part
  case "$p" in
    \~)         p=$HOME_DIR ;;
    \~/*)       p=$HOME_DIR/${p#\~/} ;;
    \~+|\~+/*)  p=$CWD${p#\~+} ;;
    \~-*)       NP=""; return ;;
    \~[A-Za-z_]*)
      user=${p#\~}; user=${user%%/*}; rest=${p#\~"$user"}
      if [[ "$user" == "${USER:-}" ]]; then p=$HOME_DIR$rest
      elif [[ "$user" == root ]]; then p=/root$rest
      else p=/home/$user$rest; fi ;;
  esac
  # $HOME, ${HOME}, ${HOME:?}, ${HOME%/} — всё это домашний каталог
  if [[ "$p" =~ ^\$\{(HOME|PWD|CLAUDE_PROJECT_DIR)([^A-Za-z0-9_}][^}]*)?\}(.*)$ ]] \
     || [[ "$p" =~ ^\$(HOME|PWD|CLAUDE_PROJECT_DIR)()([^A-Za-z0-9_].*)?$ ]]; then
    case ${BASH_REMATCH[1]} in
      HOME) p=$HOME_DIR${BASH_REMATCH[3]} ;;
      PWD)  p=$CWD${BASH_REMATCH[3]} ;;
      *)    p=$PROJ${BASH_REMATCH[3]} ;;
    esac
  fi
  p=${p//'${USER}'/${USER:-${HOME_DIR##*/}}}; p=${p//'$USER'/${USER:-${HOME_DIR##*/}}}
  NP_PART=0
  if [[ "$p" == *'$'* ]]; then
    # Относительный путь с неизвестной переменной — как и раньше, внутри
    # проекта (названная граница). Абсолютный проверяется по известной части:
    # `/var/lib/$APP` — это всё равно /var/lib, а `/$(echo etc)` — что угодно.
    [[ "$p" == /* ]] || { NP=""; return; }
    p=${p%%'$'*}; p=${p%/*}; p=${p:-/}
    NP_PART=1
  fi
  [[ "$p" == /* ]] || p=$CWD/$p
  local -a st=()
  local IFS=/
  for part in $p; do
    case "$part" in
      ''|.) ;;
      ..) ((${#st[@]})) && st=("${st[@]:0:${#st[@]}-1}") ;;
      *) st+=("$part") ;;
    esac
  done
  NP="/${st[*]}"
}

SYSTEM_DIRS='/bin /boot /dev /etc /home /lib /lib32 /lib64 /libx32 /opt /proc /root /run /sbin /snap /srv /sys /usr /var /nix /Users /Library /System /Applications /private /Network /cores'
TEMP_DIRS='/tmp /var/tmp /private/tmp /private/var/tmp /var/folders /private/var/folders'

zone_of() { # <путь> <в контейнере 0|1> -> ZONE
  local p d
  norm_path "$1"; p=$NP
  # Неизвестная переменная: как и раньше, считаем путём внутри проекта.
  # Это названная граница, а не проверка (README, «что замки не ловят»).
  [[ -z "$p" ]] && { ZONE=inside; return; }
  # Внутри контейнера пути хоста ни при чём: /var/www там — каталог
  # приложения. Запрещается только снос корня целиком.
  if ((${2:-0})); then
    [[ "$p" == / || "$p" == '/*' ]] && ((!NP_PART)) && ZONE=system || ZONE=inside
    return
  fi
  if ((NP_PART)); then
    # Известна только часть пути: неизвестное под ней может быть чем угодно
    [[ "$p" == / ]] && { ZONE=outside; return; }
    zone_of "$p/_" 0
    return
  fi
  if [[ "$p" == / || "$p" == '/*' ]]; then ZONE=system; return; fi
  # Маска в имени каталога верхнего уровня: `/e*c` оболочка раскроет в /etc
  local top=${p#/}; top=${top%%/*}
  if [[ "$top" == *[\*\?\[]* ]]; then
    for d in $SYSTEM_DIRS; do
      # Сопоставление с маской и есть смысл проверки
      # shellcheck disable=SC2053
      [[ "${d#/}" == $top ]] && { ZONE=system; return; }
    done
  fi
  if [[ "$p" == "$HOME_DIR" || "$p" == "$HOME_DIR/*" || "$p" == "$HOME_DIR/.*" ]]; then ZONE=system; return; fi
  # Проект проверяется раньше системных каталогов: он сам может лежать в /opt
  # или /srv, и его build/ там ни при чём.
  if [[ "$p" == "$PROJ" ]]; then ZONE=project; return; fi
  if [[ "$p" == "$PROJ"/* ]]; then ZONE=inside; return; fi
  # Временные каталоги лежат внутри /var, но это не система: /var/tmp/build
  # и каталог mktemp на macOS (/var/folders/...) раньше получали запрет.
  local tmpd=${TMPDIR:-}; tmpd=${tmpd%/}
  for d in $TEMP_DIRS $tmpd; do
    [[ "$d" == / ]] && continue
    [[ "$p" == "$d"/* ]] && { ZONE=outside; return; }
  done
  # Своё домашнее, но вне проекта: кэши, черновики, соседние репозитории.
  # Проверяется до /home, иначе весь домашний каталог попал бы в системную зону
  # и вопрос стал бы запретом.
  if [[ "$p" == "$HOME_DIR"/* ]]; then ZONE=outside; return; fi
  for d in $SYSTEM_DIRS; do
    [[ "$p" == "$d" || "$p" == "$d"/* ]] && { ZONE=system; return; }
  done
  ZONE=outside
}

# Устройство, запись в которое стирает диск. Перечислены безвредные — всё
# остальное в /dev считается диском: имён дисков больше, чем помнит любой
# список (rdisk на macOS, xvd в облаке, dm-, md, nbd, loop).
is_disk() { # <путь>
  [[ "$1" == /dev/* ]] || return 1
  case "$1" in
    /dev/null|/dev/zero|/dev/full|/dev/random|/dev/urandom|/dev/stdin|/dev/stdout|/dev/stderr|\
    /dev/tty|/dev/tty*|/dev/pts/*|/dev/fd/*|/dev/shm/*|/dev/console|/dev/log) return 1 ;;
  esac
  return 0
}

# --- Слова, которые проверяют правила -----------------------------------------
# Текст в кавычках бывает двух видов: исполняемый (`bash -c "..."`, `ssh host
# '...'`, `watch "..."`) и данные (сообщение коммита, заголовок PR). Раньше
# кавычки просто заменялись пробелами, и `git commit -m "drop table legacy"`
# получал запрет, который маркер снять не может. Теперь многословный текст
# в кавычках считается данными у команд, которые его не исполняют, и в
# значениях опций-сообщений; у остальных он раскладывается на слова —
# так незнакомая обёртка по-прежнему не прячет команду.
build_tokens() { # sw, P, hd -> T
  local n=${#sw[@]} i w data=0 msg=0 part x
  T=()
  case "$hd" in
    # awk сюда не входит: `awk 'BEGIN{system("rm -rf /etc")}'` исполняет строку
    gh|glab|hg|jj|svn|curl|wget|http|https|xh|jq|yq|sed|gsed|notify-send|terminal-notifier|logger) data=1 ;;
    git)
      # Кроме подкоманд, которые исполняют переданную строку
      case " ${sw[*]:P} " in
        *" rebase "*|*" submodule "*|*" bisect "*|*" filter-branch "*) ;;
        *) data=1 ;;
      esac ;;
  esac
  for ((i = P; i < n; i++)); do
    w=${sw[i]}
    if ((msg)); then
      msg=0
      if [[ "$w" == *[[:space:]]* ]]; then T+=(_); continue; fi
    fi
    case "$w" in
      -m|--message|--title|--body|--notes|--description|--subject|--comment|--reason) msg=1 ;;
      --message=*|--title=*|--body=*|--notes=*|--description=*|--subject=*|--comment=*|--reason=*)
        if [[ "$w" == *[[:space:]]* ]]; then T+=("${w%%=*}=_"); continue; fi ;;
    esac
    if [[ "$w" == *[[:space:]]* ]]; then
      if ((data)); then T+=(_); continue; fi
      x=${w//[\"\'\`\(\)\;\&\|\<\>\{\}]/ }
      for part in $x; do T+=("$part"); done
    else
      T+=("$w")
    fi
    if ((${#T[@]} > MAXTOK)); then
      T=("${T[@]:0:MAXTOK}")
      TOO_BIG="в одной команде больше $MAXTOK слов"
      break
    fi
  done
}

# --- Правила ------------------------------------------------------------------
# Применяются к словам команды, которая действительно исполняется. Каждое
# правило закрывает потерю, которую не откатить: данные, историю, чужую работу.
# Имя команды ищется в любой позиции, а не только первым словом: так ловятся
# и незнакомые обёртки (`watch`, `ssh host`, `parallel`), и полный путь к
# программе — `/bin/rm` и `/usr/local/bin/docker` раньше не узнавались.
MSG_DB="Разрушающая операция с БД. Если она действительно нужна — выполни вручную, осознанно."
MSG_MKFS="Создание файловой системы стирает содержимое устройства целиком."
MSG_CTR="Удаление контейнеров/образов/томов/кэша запрещено политикой. Сначала покажи занятое место и спроси разрешение на конкретную команду."

# Фигурные скобки раскрывает оболочка: `/{etc,usr}` — это /etc и /usr, а без
# раскрытия путь выглядел чужим каталогом и получал вопрос вместо запрета.
# Раскрытие своё, без eval: текст пришёл от модели.
expand_braces() { # <слово> -> BR (варианты)
  local g=$1 pre body post alt
  local -a acc=()
  BR=()
  if [[ "$g" =~ ^([^{]*)\{([^{}]*,[^{}]*)\}(.*)$ ]]; then
    pre=${BASH_REMATCH[1]}; body=${BASH_REMATCH[2]}; post=${BASH_REMATCH[3]}
    local IFS=,
    for alt in $body; do
      expand_braces "$pre$alt$post"
      acc+=("${BR[@]}")
    done
    BR=("${acc[@]}")
  else
    BR=("$g")
  fi
}

rule_rm() { # <индекс>
  local j=$1 nT=${#T[@]} k t rec=0 ddash=0
  local -a tg=()
  for ((k = j + 1; k < nT; k++)); do
    t=${T[k]}
    if ((!ddash)); then
      case "$t" in
        --) ddash=1; continue ;;
        --no-preserve-root) deny "--no-preserve-root снимает единственную встроенную защиту rm от удаления корня." ;;
        --recursive) rec=1; continue ;;
        --*) continue ;;
        -?*) [[ "$t" == *[rR]* ]] && rec=1; continue ;;
      esac
    fi
    tg+=("$t")
  done
  ((rec)) || return 0
  # `find / ... | xargs rm -rf`: цели приходят из предыдущей команды конвейера
  if ((XARGS && j == 0)) && [[ -n "$SRCPATHS" ]]; then
    for t in $SRCPATHS; do tg+=("$t"); done
  fi
  local -a tgx=()
  for t in "${tg[@]}"; do expand_braces "$t"; tgx+=("${BR[@]}"); done
  for t in "${tgx[@]}"; do
    [[ -z "$t" || "$t" == _ ]] && continue
    zone_of "$t" $((j > CONT_FROM))
    case $ZONE in
      system)  deny "Рекурсивное удаление системного пути: $t. Это не откатывается ничем, кроме восстановления машины. Если каталог действительно надо снести — сделай это сам, вне сессии." ;;
      outside) ask_loss "Рекурсивное удаление за пределами проекта: $t. Что там лежит, отсюда не видно, и под git оно, скорее всего, не находится — вернуть будет нечем. Подтверди путь." ;;
      project) ask_loss "Рекурсивное удаление каталога проекта целиком: $t. Вместе с ним уходят незакоммиченные правки и сама история git. Подтверди." ;;
    esac
  done
}

rule_find() { # <индекс>
  local j=$1 nT=${#T[@]} k t del=0 ex=0
  local -a st=()
  k=$((j + 1))
  while ((k < nT)); do
    case "${T[k]}" in -H|-L|-P|-O*) ((k++)) ;; -D) ((k += 2)) ;; *) break ;; esac
  done
  while ((k < nT)); do
    t=${T[k]}
    case "$t" in -*|'('|')'|'!'|,|_) break ;; esac
    st+=("$t"); ((k++))
  done
  for ((; k < nT; k++)); do
    case "${T[k]}" in
      -delete) del=1 ;;
      -exec|-execdir|-ok|-okdir) ex=1 ;;
      rm|unlink|shred|*/rm) ((ex)) && del=1 ;;
    esac
  done
  ((del)) || return 0
  ((${#st[@]})) || st=(.)
  for t in "${st[@]}"; do
    zone_of "$t" $((j > CONT_FROM))
    case $ZONE in
      system)  deny "find с удалением по системному пути обходит защиту rm и выносит всё дерево целиком: $t." ;;
      outside) ask_loss "find с удалением за пределами проекта: $t. Что там лежит, отсюда не видно — вернуть будет нечем. Подтверди путь." ;;
    esac
  done
}

rule_chmod() { # <индекс>
  local j=$1 nT=${#T[@]} k t rec=0 first=1
  local -a tg=()
  for ((k = j + 1; k < nT; k++)); do
    t=${T[k]}
    case "$t" in
      -R|--recursive) rec=1 ;;
      --reference=*) first=0 ;;
      --*) ;;
      # -rwx у chmod — это режим, а не опции
      -[rwxXst]*) if [[ "${T[j]##*/}" == chmod && "$t" =~ ^-[rwxXst]+$ ]]; then first=0
                  else [[ "$t" == *R* ]] && rec=1; fi ;;
      -*) [[ "$t" == *R* ]] && rec=1 ;;
      *) if ((first)); then first=0; else tg+=("$t"); fi ;;
    esac
  done
  if ((!rec)); then
    # Без -R опасен только сам корень или каталог верхнего уровня: `chmod 000 /`
    # и `chown nobody /etc` ломают систему так же, как рекурсивные.
    ((j > CONT_FROM)) && return 0
    local d
    for t in "${tg[@]}"; do
      norm_path "$t"; [[ -z "$NP" ]] && continue
      [[ "$NP" == / ]] && deny "Смена прав или владельца корня файловой системы ломает систему целиком: $t."
      for d in $SYSTEM_DIRS; do
        [[ "$NP" == "$d" ]] && deny "Смена прав или владельца системного каталога верхнего уровня ломает систему целиком: $t."
      done
    done
    return 0
  fi
  for t in "${tg[@]}"; do
    zone_of "$t" $((j > CONT_FROM))
    [[ $ZONE == system ]] && deny "Рекурсивная смена прав или владельца по системному пути ломает систему целиком и чинится только восстановлением: $t."
  done
  return 0
}

# Стирание устройства и системных файлов теми, кто не rm и не dd:
# shred, wipefs, blkdiscard, sgdisk. Запись на диск необратима так же,
# как dd of=/dev/sda, и раньше эти команды проходили молча.
rule_wipe() { # <индекс>
  local j=$1 nT=${#T[@]} k t all=0
  local b=${T[j]##*/}
  local -a tg=()
  for ((k = j + 1; k < nT; k++)); do
    t=${T[k]}
    case "$t" in
      -a|--all|--zap-all|-Z|-o|--clear|--zap) all=1 ;;
      -n|--iterations|-s|--size|--offset|--length|--step|--random-source) ((k++)) ;;
      --*) ;;
      -*) [[ "$b" == wipefs && "$t" == *a* ]] && all=1 ;;
      *) tg+=("$t") ;;
    esac
  done
  # wipefs без -a и sgdisk без разрушающих ключей только показывают
  case "$b" in wipefs|sgdisk) ((all)) || return 0 ;; esac
  for t in "${tg[@]}"; do
    if is_disk "$t"; then
      deny "$b по устройству ($t) уничтожает разделы и данные без возможности отката."
    fi
    [[ "$b" == shred ]] || continue
    zone_of "$t" $((j > CONT_FROM))
    [[ $ZONE == system ]] && deny "shred системного файла ($t) — это удаление без возможности восстановления даже из резервной копии блоков."
  done
  return 0
}

# Перезапись и перенос системных файлов не рекурсивны, но так же ломают
# машину: `> /etc/passwd`, `truncate -s 0 /etc/passwd`, `mv /etc …`.
# Вопрос, а не запрет: в контейнере разработки правка /etc бывает нужна.
system_target_ask() { # <путь> <что делается>
  zone_of "$1" $((J_CUR > CONT_FROM))
  [[ $ZONE == system ]] && ask_loss "$2 системного пути: $1. Такое не откатывается командой — подтверди, что это действительно нужно."
  return 0
}

rule_truncate_mv() { # <индекс>
  local j=$1 nT=${#T[@]} k t
  local b=${T[j]##*/}
  local -a tg=()
  for ((k = j + 1; k < nT; k++)); do
    t=${T[k]}
    case "$t" in
      -s|--size|-r|--reference|-t|--target-directory|-S|--suffix) ((k++)) ;;
      --target-directory=*) tg+=("${t#*=}") ;;
      -*) ;;
      *) tg+=("$t") ;;
    esac
  done
  J_CUR=$j
  if [[ "$b" == truncate ]]; then
    for t in "${tg[@]}"; do system_target_ask "$t" "Обнуление"; done
  elif ((${#tg[@]} > 1)); then
    # У mv все, кроме последнего, — источники: они исчезают со старого места
    for t in "${tg[@]:0:${#tg[@]}-1}"; do system_target_ask "$t" "Перенос"; done
  fi
  return 0
}

rule_dd() { # <индекс>
  local j=$1 nT=${#T[@]} k
  for ((k = j + 1; k < nT; k++)); do
    [[ "${T[k]}" == of=* ]] && is_disk "${T[k]#of=}" && deny "Запись через dd прямо на устройство уничтожает разделы без возможности отката."
  done
  return 0
}

rule_container() { # <индекс>
  local j=$1 nT=${#T[@]} k i t b sub v compose=0
  b=${T[j]##*/}
  [[ "$b" == *-compose ]] && compose=1
  i=$((j + 1))
  # Глобальные опции перед глаголом: `docker --context prod volume rm`,
  # `docker compose -f dev.yml down -v`. Правило требовало глагол сразу
  # после имени, и любая опция между ними его выключала.
  while ((i < nT)); do
    t=${T[i]}
    case "$t" in
      --) ((i++)); break ;;
      --*=*) ((i++)) ;;
      -H|--host|-c|--context|--config|-l|--log-level|--tlscacert|--tlscert|--tlskey|--connection|--url|--identity|\
      --root|--runroot|--storage-driver|--storage-opt|--cgroup-manager|--events-backend|--hooks-dir|--tmpdir|--volumepath|\
      --imagestore|--module|--ssh|-f|--file|-p|--project-name|--profile|--env-file|--project-directory|--ansi|--progress|--parallel)
        ((i += 2)) ;;
      -*) ((i++)) ;;
      compose) ((compose)) && break; compose=1; ((i++)) ;;
      *) break ;;
    esac
  done
  sub=${T[i]:-}
  if ((compose)); then
    case "$sub" in
      down)
        for ((k = i + 1; k < nT; k++)); do
          case "${T[k]}" in
            -v|--volumes|--volumes=true) deny "'compose down -v' удаляет тома вместе с данными. Используй 'down' без -v." ;;
            --rmi|--rmi=*) deny "'compose down --rmi' удаляет образы — это часы пересборки. Используй 'down' без --rmi." ;;
          esac
        done ;;
      rm) deny "$MSG_CTR" ;;
      exec|run) CONT_FROM=$i ;;
    esac
    return 0
  fi
  case "$sub" in
    rm|rmi|prune) deny "$MSG_CTR" ;;
    container|image|volume|network|system|builder|buildx|pod|machine)
      for ((k = i + 1; k < nT; k++)); do
        v=${T[k]}
        [[ "$v" == -* ]] && continue
        case "$v" in rm|rmi|prune|remove|reset) deny "$MSG_CTR" ;; esac
        break
      done ;;
    exec|run) CONT_FROM=$i ;;
  esac
  return 0
}

rule_git() { # <индекс>
  local j=$1 nT=${#T[@]} i k t v sub force=0 plus=0 del=0
  i=$((j + 1))
  # Глобальные опции перед подкомандой: `git -C repo push -f` проходил мимо
  # всех правил, потому что они ждали подкоманду сразу после git.
  while ((i < nT)); do
    t=${T[i]}
    case "$t" in
      -c) v=${T[i+1]:-}
          [[ "${v,,}" == core.hookspath* ]] && deny "Подмена core.hooksPath отключает git-хуки на время команды — обход проверок в обход --no-verify."
          ((i += 2)) ;;
      -c*) [[ "${t,,}" == *core.hookspath* ]] && deny "Подмена core.hooksPath отключает git-хуки на время команды — обход проверок в обход --no-verify."
           ((i++)) ;;
      -C|--git-dir|--work-tree|--namespace|--super-prefix|--config-env) ((i += 2)) ;;
      -*) ((i++)) ;;
      *) break ;;
    esac
  done
  sub=${T[i]:-}; TOOLSUB=$i; ((i++))
  for ((k = i; k < nT; k++)); do
    [[ "${T[k]}" == --no-verify ]] && deny "--no-verify отключает pre-commit проверки — ровно тот слой, ради которого код не читают глазами."
  done
  case "$sub" in
    push)
      for ((k = i; k < nT; k++)); do
        t=${T[k]}
        case "$t" in
          --force) force=1 ;;
          --mirror) deny "push --mirror перезаписывает и удаляет ветки на сервере — это force-push для всего репозитория. Отправь нужные ветки явно." ;;
          -o|--push-option|--repo|--receive-pack|--exec) ((k++)) ;;
          --delete) del=1 ;;
          --*) ;;
          # Склеенные флаги: -fu и -uf — это тоже -f
          -[a-zA-Z]*) [[ "$t" == *f* ]] && force=1; [[ "$t" == *d* ]] && del=1 ;;
          +?*) plus=1 ;;
          # Пустой источник в refspec (`:main`) удаляет ветку на сервере
          :?*) del=1 ;;
        esac
      done
      ((del)) && ask_loss "push удаляет ветку на сервере. Если её коммитов нет больше нигде, они пропадут для всех. Подтверди."
      ((force)) && deny "force-push перезаписывает чужую историю. Используй --force-with-lease."
      # Плюс перед refspec — тот же force, только записанный иначе.
      ((plus)) && deny "'+refspec' в push — это тот же force-push, только записанный иначе: чужие коммиты будут перезаписаны. Используй --force-with-lease." ;;
    commit)
      # `-n` в commit это --no-verify; в push это --dry-run и совершенно безобиден,
      # поэтому короткий флаг проверяется только у commit. Буквы после флага
      # со значением (m, F, C, c, t) — уже значение: `-mn` — сообщение «n».
      for ((k = i; k < nT; k++)); do
        t=${T[k]}
        case "$t" in
          --message|--file|--author|--date|--template|--reuse-message|--reedit-message|--fixup|--squash|--trailer|--cleanup) ((k++)) ;;
          --*) ;;
          -[a-zA-Z]*)
            v=${t:1}
            while [[ -n "$v" ]]; do
              case "${v:0:1}" in
                n) deny "'git commit -n' — это то же --no-verify: pre-commit проверки не выполнятся." ;;
                m|F|C|c|t) [[ -z "${v:1}" ]] && ((k++)); break ;;
              esac
              v=${v:1}
            done ;;
        esac
      done ;;
    reset)
      for ((k = i; k < nT; k++)); do
        [[ "${T[k]}" == --hard ]] && ask_loss "git reset --hard уничтожит незакоммиченные изменения. Подтверди."
      done ;;
    branch)
      # -d сам отказывается удалять неслитое; -D и --delete --force — нет
      local bd=0 bf=0
      for ((k = i; k < nT; k++)); do
        case "${T[k]}" in
          --delete) bd=1 ;; --force) bf=1 ;;
          --*) ;;
          -[a-zA-Z]*) [[ "${T[k]}" == *D* ]] && { bd=1; bf=1; }
                      [[ "${T[k]}" == *d* ]] && bd=1; [[ "${T[k]}" == *f* ]] && bf=1 ;;
        esac
      done
      ((bd && bf)) && ask_loss "Принудительное удаление ветки: неслитые коммиты останутся только в reflog и исчезнут при очистке. Подтверди." ;;
    stash)
      case "${T[i]:-}" in
        drop|clear) ask_loss "git stash ${T[i]} удаляет спрятанные правки — других копий у них нет. Подтверди." ;;
      esac ;;
    clean)
      local f=0 dry=0
      for ((k = i; k < nT; k++)); do
        t=${T[k]}
        case "$t" in
          --force) f=1 ;;
          --dry-run|--interactive) dry=1 ;;
          -e|--exclude) ((k++)) ;;
          --*) ;;
          -[a-zA-Z]*) [[ "$t" == *f* ]] && f=1; [[ "$t" == *[ni]* ]] && dry=1 ;;
        esac
      done
      ((f && !dry)) && ask_loss "git clean удалит неотслеживаемые файлы — в том числе те, что ещё не добавлены в индекс и нигде не сохранены. Подтверди." ;;
    checkout|restore)
      local whole=0 staged=0 worktree=0
      for ((k = i; k < nT; k++)); do
        t=${T[k]}
        case "$t" in
          --staged) staged=1 ;;
          --worktree) worktree=1 ;;
          -s|--source|-b|-B|--orphan|--conflict) ((k++)) ;;
          --*) ;;
          -[a-zA-Z]*) [[ "$t" == *S* ]] && staged=1; [[ "$t" == *W* ]] && worktree=1 ;;
          .|./|'*'|:/|:/.) whole=1 ;;
        esac
      done
      # restore --staged только снимает правки из индекса, рабочее дерево цело
      ((whole)) && ! ((staged && !worktree)) \
        && ask_loss "Откат рабочего дерева целиком сотрёт все несохранённые правки. Подтверди." ;;
  esac
  return 0
}

rule_kubectl() { # <индекс>
  local j=$1 nT=${#T[@]} i k t sub res=""
  i=$((j + 1))
  while ((i < nT)); do
    case "${T[i]}" in
      -n|--namespace|--context|--kubeconfig|--cluster|--user|-s|--server|--as|--as-group|--token|--request-timeout) ((i += 2)) ;;
      -*) ((i++)) ;;
      *) break ;;
    esac
  done
  sub=${T[i]:-}
  case "$sub" in
    delete)
      for ((k = i + 1; k < nT; k++)); do
        t=${T[k]}
        case "$t" in
          -n|--namespace|--context|-l|--selector|-f|--filename|--grace-period|--timeout|-o|--output|--cascade|--field-selector) ((k++)) ;;
          -*) ;;
          *) res=${t,,}; break ;;
        esac
      done
      if [[ "$res" =~ ^(ns|namespace|namespaces)(/|$) || "$res" =~ (^|,)(ns|namespace|namespaces)(,|$) ]]; then
        ask_loss "Удаление namespace сносит всё, что в нём есть, включая PersistentVolumeClaim. Подтверди кластер и имя."
      fi ;;
    exec|debug|run) CONT_FROM=$i ;;
  esac
  return 0
}

MSG_ENV="Команда сносит развёрнутое окружение. Подтверди, что это не продуктивный контур."
rule_helm() { # <индекс>
  local j=$1 nT=${#T[@]} i
  i=$((j + 1))
  while ((i < nT)); do
    case "${T[i]}" in
      -n|--namespace|--kube-context|--kubeconfig|--registry-config|--repository-cache|--repository-config) ((i += 2)) ;;
      -*) ((i++)) ;;
      *) break ;;
    esac
  done
  case "${T[i]:-}" in uninstall|delete|del|un) ask_loss "$MSG_ENV" ;; esac
  return 0
}

rule_tf() { # <индекс>
  local j=$1 nT=${#T[@]} i k sub
  i=$((j + 1))
  while ((i < nT)) && [[ "${T[i]}" == -* ]]; do ((i++)); done
  sub=${T[i]:-}
  case "$sub" in
    destroy|destroy-all) ask_loss "$MSG_ENV" ;;
    apply|run-all|run)
      for ((k = i + 1; k < nT; k++)); do
        case "${T[k]}" in -destroy|--destroy|destroy) ask_loss "$MSG_ENV" ;; esac
      done ;;
  esac
  return 0
}

# Новые зависимости: не запрет, а обязательная пара глаз.
# Пакет проходит любые тесты идеально. Это единственный вектор, который
# система автопроверок не закрывает в принципе.
deps_pkgs() { # <с какого слова> -> 0, если среди аргументов есть пакет
  local k=$1 nT=${#T[@]} t
  for ((; k < nT; k++)); do
    t=${T[k]}
    case "$t" in
      -r|-c|-e|-t|-i|-f|-w|--requirement|--constraint|--editable|--target|--index-url|--extra-index-url|--find-links|\
      --prefix|--root|--src|--upgrade-strategy|--python-version|--platform|--implementation|--abi|--trusted-host|\
      --cache-dir|--log|--proxy|--timeout|--retries|--progress-bar|--registry|--workspace|--tag|--omit|--include|\
      --cache|--loglevel|--install-strategy|--before) ((k++)) ;;
      -*|_|.|./*|../*|/*|'~'*|file:*|*.whl|*.tar.gz|*.tgz) ;;
      # Обновление самого установщика — не новая зависимость проекта
      pip|setuptools|wheel) ;;
      *) return 0 ;;
    esac
  done
  return 1
}
rule_deps() { # <индекс>
  local j=$1 nT=${#T[@]} k b sub="" nxt="" pk=0
  b=${T[j]##*/}
  for ((k = j + 1; k < nT; k++)); do [[ "${T[k]}" == -* ]] || { sub=${T[k]}; TOOLSUB=$k; break; }; done
  nxt=${T[k+1]:-}
  case "$b:$sub" in
    composer:require|yarn:add|pnpm:add|bun:add|npm:add|uv:add|poetry:add|cargo:add|bundle:add) pk=1 ;;
    yarn:global) [[ "$nxt" == add ]] && pk=1 ;;
    npm:i|npm:in|npm:install|npm:isntall|pnpm:i|pnpm:install|bun:i|bun:install|pip:install|pip3:install|pipenv:install|gem:install|go:get)
      deps_pkgs $((k + 1)) && pk=1 ;;
    uv:pip) [[ "$nxt" == install ]] && deps_pkgs $((k + 2)) && pk=1 ;;
  esac
  ((pk)) && ask "Добавляется новая зависимость. Подтверди пакет и его источник — тесты этот риск не покрывают."
  return 0
}

# База данных. Слова «drop table» опасны где угодно, кроме данных (сообщения
# коммита, текста в echo) — данные отсеяны раньше. TRUNCATE без TABLE
# проверяется только рядом с клиентом БД: иначе `truncate -s 0 app.log`
# получил бы запрет.
RE_SQL='migrate:fresh|migrate:reset|db:wipe|drop[[:space:]]+(database|schema)|drop[[:space:]]+table|truncate[[:space:]]+table'
RE_SQL_CLIENT='(^|[^a-z0-9_.-])truncate[[:space:]]+(only[[:space:]]+)?[a-z_"`[]'
SQL_CLIENTS='psql|mysql|mariadb|sqlite3|sqlite|sqlcmd|clickhouse-client|clickhouse|duckdb|usql|cockroach|mysqlsh'
sql_check() { # <текст> <рядом клиент БД 0|1>
  local s=${1,,} st
  [[ "$s" =~ $RE_SQL ]] && deny "$MSG_DB"
  ((${2:-0})) || return 0
  [[ "$s" =~ $RE_SQL_CLIENT ]] && deny "$MSG_DB"
  # DELETE и UPDATE без WHERE задевают все строки таблицы. Вопрос, а не запрет:
  # очистить таблицу сессий в своей базе — обычное дело.
  if [[ "$s" == *delete* || "$s" == *update* ]]; then
    local IFS=';'
    for st in $s; do
      if [[ "$st" =~ (^|[^a-z0-9_])(delete[[:space:]]+from|update[[:space:]]+[a-z_\"\`.]+[[:space:]]+set)[[:space:]] ]] \
         && [[ ! "$st" =~ (^|[^a-z0-9_])where([^a-z0-9_]|$) ]]; then
        ask_loss "DELETE или UPDATE без WHERE затрагивает все строки таблицы. Подтверди, что это и нужно."
      fi
    done
  fi
  return 0
}

token_rules() { # T
  local j b nT=${#T[@]} k sqlc=0
  CONT_FROM=$nT
  # Позиция подкоманды git или пакетного менеджера: `git rm -r --cached .`
  # и `npm rm` — их подкоманды, а не программа rm.
  TOOLSUB=-1
  for ((j = 0; j < nT; j++)); do
    b=${T[j]##*/}
    case "$b" in
      rm) ((j == TOOLSUB)) || rule_rm "$j" ;;
      find) rule_find "$j" ;;
      chmod|chown|chgrp) rule_chmod "$j" ;;
      dd) rule_dd "$j" ;;
      shred|wipefs|blkdiscard|sgdisk) rule_wipe "$j" ;;
      truncate|mv) ((j == TOOLSUB)) || rule_truncate_mv "$j" ;;
      mkfs|mkfs.*|mke2fs|mkdosfs|mkntfs|newfs|newfs_*) deny "$MSG_MKFS" ;;
      diskutil)
        [[ "${T[j+1]:-}" =~ ^(erase|zero|random|secureErase|partitionDisk|reformat) ]] && deny "$MSG_MKFS" ;;
      docker|podman|buildah|nerdctl|docker-compose|podman-compose) rule_container "$j" ;;
      git) rule_git "$j" ;;
      kubectl|oc) rule_kubectl "$j" ;;
      helm) rule_helm "$j" ;;
      terraform|tofu|terragrunt) rule_tf "$j" ;;
      npm|pnpm|yarn|bun|pip|pip3|uv|poetry|pipenv|composer|cargo|go|gem|bundle) rule_deps "$j" ;;
      dropdb) deny "$MSG_DB" ;;
      mysqladmin)
        for ((k = j + 1; k < nT; k++)); do [[ "${T[k],,}" == drop ]] && deny "$MSG_DB"; done ;;
    esac
    [[ "$b" =~ ^($SQL_CLIENTS)$ ]] && sqlc=1
  done
  SQLC=$sqlc
}

# --- Грубая проверка неразобранного -------------------------------------------
# Для того, что разбор не осилил: вложенность глубже предела, строка длиннее
# предела. Только запреты и только по тексту целиком — ложное срабатывание
# здесь возможно, но это цена того, что при выключенных вопросах запрет
# остаётся запретом, а не превращается в тишину.
coarse_rules() { # <текст>
  local s=${1,,}
  s=${s//[\"\'\(\)\`]/ }
  s=${s//$'\n'/ ; }
  local w='[^[:space:];&|]+'
  local sysp="(/|/\*|~|~/|\\\$home/?|\\\$\{home\}/?|/(etc|usr|var|bin|sbin|lib|lib64|boot|opt|root|home|srv|sys|proc|dev|users|library|system|applications|private)(/$w)?)"
  if [[ "$s" =~ (^|[[:space:];&|/])(podman|docker|buildah)(-compose)?([[:space:]]+$w){0,6}[[:space:]]+(rm|rmi|prune|reset)([[:space:]]|$) ]] \
     || [[ "$s" =~ compose([[:space:]]+$w){0,6}[[:space:]]+down([[:space:]]+$w)*[[:space:]]+(-v|--volumes|--rmi)([[:space:]]|$) ]]; then
    deny "В части команды, которую замок не разобрал поштучно, найдено удаление контейнеров, образов или томов. $MSG_CTR"
  fi
  if [[ "$s" =~ (^|[[:space:];&|/])git([[:space:]]+$w){0,6}[[:space:]]+push([[:space:]]+$w)*[[:space:]]+(--force|-[a-z]*f[a-z]*|\+$w|--mirror)([[:space:]]|$) ]] \
     || [[ "$s" =~ (^|[[:space:];&|/])git([[:space:]]+$w)*[[:space:]]+--no-verify ]]; then
    deny "В части команды, которую замок не разобрал поштучно, найден force-push или обход проверок git."
  fi
  [[ "$s" =~ $RE_SQL ]] && deny "В части команды, которую замок не разобрал поштучно, найдена разрушающая операция с БД. $MSG_DB"
  if [[ "$s" =~ (^|[[:space:];&|/])rm([[:space:]]+$w)*[[:space:]]+(-[a-z]*r[a-z]*|--recursive)([[:space:]]+$w)*[[:space:]]+${sysp}([[:space:];]|$) ]] \
     || [[ "$s" =~ (^|[[:space:];&|/])find[[:space:]]+(-[hlp][[:space:]]+)*${sysp}[[:space:]].*(-delete|-exec[[:space:]]+rm) ]] \
     || [[ "$s" =~ (^|[[:space:];&|/])(chmod|chown)[[:space:]]+(-[a-z]*r[a-z]*|--recursive)[[:space:]]+(${w}[[:space:]]+)?${sysp}([[:space:];]|$) ]]; then
    deny "В части команды, которую замок не разобрал поштучно, найдено рекурсивное удаление или смена прав по системному пути."
  fi
  if [[ "$s" =~ (^|[[:space:];&|/])(mkfs(\.[a-z0-9]+)?|mke2fs)([[:space:]]|$) ]] \
     || [[ "$s" =~ (^|[[:space:];&|/])dd[[:space:]].*of=/dev/(sd|nvme|vd|hd|xvd|disk|rdisk|mmcblk|dm-|md|mapper|nbd|loop) ]]; then
    deny "В части команды, которую замок не разобрал поштучно, найдена запись на устройство. $MSG_MKFS"
  fi
  return 0
}

# --- Разбор строки целиком ----------------------------------------------------
# Политика при неполном разборе: понял — решаю, не понял — спрашиваю.
# Молчаливый пропуск здесь был бы худшим вариантом: команду не проверили,
# а выглядит это как проверенную.
analyze() { # <командная строка> <глубина>
  local line=$1 depth=${2:-0}
  # Каталог, в который перешёл `cd`, — свой у каждого уровня: `bash -c "cd /"`
  # не меняет каталог вызывающей строки.
  local CWD=$CWD
  if ((depth > MAXDEPTH)); then
    # Раньше здесь был только вопрос — а при выключенных вопросах он молчал,
    # и команда уходила без единой проверки.
    coarse_rules "$line"
    ask "Команда вложена в обёртки глубже, чем замок разбирает ($depth уровня). Что выполнится на самом деле, отсюда не видно — прочитай сам, прежде чем подтвердить."
    return 0
  fi

  # Предел проверяется до разбора: каждый разбор — отдельный процесс, и тысяча
  # `$(date)` в теле heredoc разбиралась 16 секунд.
  if ((SEGCOUNT >= MAXSEGS)); then
    coarse_rules "$line"
    TOO_BIG="в строке больше $MAXSEGS команд"
    return 0
  fi

  local recs
  if ! recs=$(scan_text "$line") || [[ -z "$recs" && -n "${line//[[:space:]]/}" ]]; then
    coarse_rules "$line"
    ask "Разобрать команду не удалось. Замок не пропускает то, чего не понял, — подтверди её сам."
    return 0
  fi

  local -a W=() WQ=() SS=() SP=() SR=() SH=() SHQ=() SUBS=() PHD=() PTX=() PPT=() SHDONE=()
  local t a b c k=-1
  while IFS="$US" read -r t a b c; do
    case "$t" in
      S) ((k++)); SS[k]=${#W[@]}; SP[k]=$a; SR[k]=""; SH[k]=""; SHQ[k]=1; SHDONE[k]=0 ;;
      W) W+=("${b//$NL_ENC/$'\n'}"); WQ+=("$a") ;;
      R) SR[k]+="$a$FS${b//$NL_ENC/$'\n'}$GS" ;;
      H) SH[a]+="${c//$NL_ENC/$'\n'}"; [[ "$b" == 0 ]] && SHQ[a]=0 ;;
      C) SUBS+=("${b//$NL_ENC/$'\n'}") ;;
    esac
  done <<< "$recs"

  local nseg=$((k + 1)) e i j n rest pair op tgt hd P ENVPRINT XARGS SRCTEXT SRCPATHS CONT_FROM SQLC TOOLSUB
  local -a sw=() sq=() T=()
  for ((k = 0; k < nseg; k++)); do
    if ((++SEGCOUNT > MAXSEGS)); then
      rest=""
      for ((i = SS[k]; i < ${#W[@]}; i++)); do rest+="${W[i]} "; done
      coarse_rules "$rest"
      TOO_BIG="в строке больше $MAXSEGS команд"
      break
    fi
    if ((k + 1 < nseg)); then e=${SS[k+1]}; else e=${#W[@]}; fi
    seg_words "${SS[k]}" "$e"
    n=${#sw[@]}
    PHD[k]=""; PTX[k]=""; PPT[k]=""
    if ((n == 0)); then
      # Только перенаправление: `> .claude/std-hooks-off`, `> /etc/passwd`
      hd=""; P=0; XARGS=0; layer_rules
      redirect_rules "$k"
      continue
    fi
    strip_prefix
    hd=""; ((P < n)) && hd=${sw[P]##*/}

    # Источник конвейера: что приходит на вход этой команде
    SRCTEXT=""; SRCPATHS=""
    if [[ "${SP[k]}" == '|' ]]; then
      for ((j = k - 1; j >= 0; j--)); do
        [[ -n "${PHD[j]}" ]] && { SRCTEXT=${PTX[j]}; SRCPATHS=${PPT[j]}; break; }
      done
    fi
    # Что эта команда отдаёт следующей: текст echo/printf/heredoc, пути find
    PHD[k]=${hd:-_}
    case "$hd" in
      echo|printf) PTX[k]="${sw[*]:P+1}"; PPT[k]=${PTX[k]} ;;
      cat) PTX[k]=${SH[k]} ;;
      find)
        for ((i = P + 1; i < n; i++)); do
          case "${sw[i]}" in -H|-L|-P) ;; -*|'('|'!') break ;; *) PPT[k]+="${sw[i]} " ;; esac
        done ;;
    esac
    redirect_rules "$k"

    layer_rules
    [[ -z "$hd" ]] && { ((ENVPRINT)) && secret_rules; continue; }

    # cd меняет каталог, от которого считаются относительные пути дальше
    if [[ "$hd" == cd || "$hd" == pushd ]]; then
      tgt=""
      for ((i = P + 1; i < n; i++)); do case "${sw[i]}" in -L|-P|-e|-@) ;; *) tgt=${sw[i]}; break ;; esac; done
      if [[ -z "$tgt" ]]; then CWD=$HOME_DIR
      elif [[ "$tgt" != - ]]; then norm_path "$tgt"; [[ -n "$NP" ]] && CWD=$NP
      fi
      continue
    fi

    # Обёртка вокруг другой команды: разбираем то, что внутри.
    case "$hd" in
      bash|sh|zsh|dash|ksh)
        shell_segment && continue ;;
      eval)
        analyze "${sw[*]:P+1}" $((depth + 1))
        ask "eval собирает команду на ходу, и замки видят только заготовку. Прочитай, что получится, прежде чем подтвердить."
        continue ;;
      ssh)
        ssh_segment && continue ;;
      su)
        su_segment && continue ;;
      source|.)
        [[ "${sw[P+1]:-}" == '<('* ]] && ask "Выполнение через подстановку процесса: содержимое замками не проверяется. Подтверди осознанно." ;;
      python|python2|python3|node|ruby|perl|php)
        # Код со стандартного входа: `curl ... | python3 -`
        if [[ "${SP[k]}" == '|' ]] && { ((P + 1 >= n)) || [[ "${sw[P+1]}" == - ]]; }; then
          ask "Команда выполняет то, что приходит на вход интерпретатору. Замки разбирают текст команды и такое содержимое не видят — прочитай его сам, прежде чем подтвердить."
        fi ;;
    esac

    # До отсева текстовых команд: секрет достают именно ими.
    secret_rules

    # Текст на вход клиенту БД — через конвейер, heredoc или here-string
    if [[ "$hd" =~ ^($SQL_CLIENTS)$ ]]; then
      sql_check "$SRCTEXT"$'\n'"${SH[k]}"$'\n'"${PTX[k]}" 1
    fi

    is_text_command && continue

    build_tokens
    token_rules
    test_rules
    local joined=" ${T[*]} "
    sql_check "$joined" "$SQLC"
    ((SQLC)) && sql_check "${SH[k]}" 1
  done

  # Тело heredoc без кавычек у разделителя проходит подстановку:
  # `cat <<EOF` с `$(rm -rf /etc)` внутри выполняет rm. Сами строки — данные.
  for ((k = 0; k < nseg; k++)); do
    [[ -n "${SH[k]:-}" && "${SHQ[k]:-1}" == 0 && "${SHDONE[k]:-0}" == 0 ]] || continue
    [[ "${SH[k]}" == *'$('* || "${SH[k]}" == *'`'* ]] || continue
    while IFS="$US" read -r t a b; do
      [[ "$t" == C ]] && SUBS+=("${b//$NL_ENC/$'\n'}")
    done < <(scan_text "${SH[k]}" dq)
  done

  # $(...) и `...` — исполняемый текст: он разбирается целиком, со всеми
  # своими командами. Раньше тело было одним сегментом, и в
  # `x=$(ls /etc; rm -rf /etc)` проверялась только команда ls.
  local body rest=""
  for body in "${SUBS[@]}"; do
    if ((SEGCOUNT >= MAXSEGS)); then rest+="$body"$'\n'; continue; fi
    analyze "$body" $((depth + 1))
  done
  if [[ -n "$rest" ]]; then
    coarse_rules "$rest"
    TOO_BIG="в строке больше $MAXSEGS команд"
  fi
  return 0
}

test_target() { # <путь> <что делается>
  ((TESTS_ON)) || return 0
  [[ -z "$1" || "$1" == _ ]] && return 0
  norm_path "$1"
  [[ -n "$NP" && "$NP" == "$PROJ"/* && -e "$NP" ]] || return 0   # новый тест — свободно
  local rel=${NP#"$PROJ"/}
  [[ -d "$NP" ]] && rel+=/
  [[ "$rel" =~ $STD_TEST_RE ]] || return 0
  local why="$2 существующего теста: $rel. Тест — надзор над кодом, и ослабить его проще, чем починить реализацию. Подтверди, что тест меняется осознанно, а не подгоняется под текущее поведение."
  if [[ "$STD_TEST_MODE" == deny ]]; then deny "$why"; else ask "$why"; fi
}

test_rules() { # T
  ((TESTS_ON)) || return 0
  local nT=${#T[@]} j k t b inpl sub
  local -a args=()
  for ((j = 0; j < nT; j++)); do
    b=${T[j]##*/}
    case "$b" in
      sed|gsed|perl)
        inpl=0
        for ((k = j + 1; k < nT; k++)); do
          [[ "${T[k]}" =~ ^(-[a-zA-Z]*i|--in-place) ]] && inpl=1
        done
        ((inpl)) || continue
        for ((k = j + 1; k < nT; k++)); do
          case "${T[k]}" in -e|-f|--expression|--file) ((k++)) ;; -*) ;; *) test_target "${T[k]}" "Правка через $b" ;; esac
        done ;;
      tee|rm|unlink|truncate|shred)
        for ((k = j + 1; k < nT; k++)); do
          case "${T[k]}" in -s|--size|-r|--reference) ((k++)) ;; -*) ;; *) test_target "${T[k]}" "Перезапись или удаление" ;; esac
        done ;;
      cp|mv|install|ln)
        args=()
        for ((k = j + 1; k < nT; k++)); do
          case "${T[k]}" in -t|--target-directory|-S|--suffix|-m|--mode|-o|-g) ((k++)) ;; -*) ;; *) args+=("${T[k]}") ;; esac
        done
        ((${#args[@]} > 1)) || continue
        test_target "${args[${#args[@]}-1]}" "Замена"
        if [[ "$b" == mv ]]; then
          for t in "${args[@]:0:${#args[@]}-1}"; do test_target "$t" "Перенос"; done
        fi ;;
      git)
        # `git checkout HEAD~3 -- tests/`, `git restore tests/…`, `git rm tests/…`
        sub=""
        for ((k = j + 1; k < nT; k++)); do
          case "${T[k]}" in -C|-c|--git-dir|--work-tree) ((k++)) ;; -*) ;; *) sub=${T[k]}; break ;; esac
        done
        case "$sub" in
          checkout|restore|rm)
            for ((k = k + 1; k < nT; k++)); do
              case "${T[k]}" in -s|--source|-b|-B) ((k++)) ;; -*) ;; *) test_target "${T[k]}" "git $sub" ;; esac
            done ;;
        esac ;;
    esac
  done
  return 0
}

# Перенаправления сегмента k: here-string как вход, запись на устройство,
# перезапись системного файла. Отдельной функцией — сегмент из одного
# перенаправления (`> /etc/passwd`) не имеет команды, и раньше до этих
# проверок не доходил.
redirect_rules() { # <k>
  local k=$1 rest=${SR[$1]} pair op tgt
  while [[ -n "$rest" ]]; do
    pair=${rest%%"$GS"*}; rest=${rest#*"$GS"}
    op=${pair%%"$FS"*}; tgt=${pair#*"$FS"}
    case "$op" in
      '<<<') PTX[k]+="$tgt"$'\n'
             # `xargs rm -rf <<< /etc` — цели приходят из here-string
             ((XARGS)) && SRCPATHS+="$tgt " ;;
      '>'|'>>'|'>|'|'&>'|'&>>'|'<>')
        is_disk "$tgt" && deny "Запись прямо на устройство ($tgt) уничтожает разделы без возможности отката."
        test_target "$tgt" "Перезапись"
        # Перезапись (не дописывание) системного файла
        if [[ "$op" != '>>' && "$op" != '&>>' && "$tgt" != /dev/* ]]; then
          J_CUR=0; CONT_FROM=99999
          system_target_ask "$tgt" "Перезапись"
        fi ;;
    esac
  done
  return 0
}

# bash/sh: с -c — разбираем тело; со stdin — то, что туда приходит.
# Опции до -c раньше не пропускались: `bash -e -c "rm -rf /etc"` разбирался
# сам в себя до падения, и при выключенных вопросах команда уходила без
# решения.
shell_segment() { # -> 0, если сегмент разобран здесь целиком
  local n=${#sw[@]} i=$((P + 1)) w hasc=0 stdin=0 rest pair op tgt
  while ((i < n)); do
    w=${sw[i]}
    case "$w" in
      --) ((i++)); break ;;
      -) stdin=1; ((i++)) ;;
      -o|+o|-O|+O|--rcfile|--init-file) ((i += 2)) ;;
      --*) ((i++)) ;;
      [-+][a-zA-Z]*)
        [[ "$w" == -*c* ]] && hasc=1
        [[ "$w" == -*s* ]] && stdin=1
        ((i++))
        [[ "$w" == ?*[oO] ]] && ((i++)) ;;
      *) break ;;
    esac
  done
  if ((hasc)); then
    ((i < n)) || return 0
    # Слова после тела — позиционные параметры, и тело их использует:
    # `sh -c 'rm -rf "$1"' _ /etc`. Туда же уезжает команда при сломанных
    # кавычках: `sh -c 'sh -c 'docker volume rm x''` — это тело `sh -c docker`
    # и параметры `volume rm x`. Разбираются вместе, чтобы не гадать.
    local body=${sw[i]}
    ((i + 1 < n)) && body+=" ${sw[*]:i+1}"
    if [[ "$body" != "$line" ]]; then
      analyze "$body" $((depth + 1))
    else
      coarse_rules "$body"
    fi
    return 0
  fi
  if ((i < n && !stdin)); then
    [[ "${sw[i]}" == '<('* ]] && ask "Выполнение через подстановку процесса: содержимое замками не проверяется. Подтверди осознанно."
    # `bash script.sh` — обычный запуск файла; его содержимое — названная граница
    return 1
  fi
  # Команды приходят со стандартного входа
  if [[ -n "${SH[k]}" ]]; then
    SHDONE[k]=1
    analyze "${SH[k]}" $((depth + 1))
    return 0
  fi
  rest=${SR[k]}
  while [[ -n "$rest" ]]; do
    pair=${rest%%"$GS"*}; rest=${rest#*"$GS"}
    op=${pair%%"$FS"*}; tgt=${pair#*"$FS"}
    case "$op" in
      '<<<') analyze "$tgt" $((depth + 1)); return 0 ;;
      '<') return 1 ;;
    esac
  done
  # Текст из echo/printf, пришедший конвейером, разбирается как команда:
  # `echo 'rm -rf /etc' | bash` — это rm -rf /etc.
  [[ -n "$SRCTEXT" ]] && analyze "$SRCTEXT" $((depth + 1))
  ask "Команда выполняет то, что приходит на вход интерпретатору. Замки разбирают текст команды и такое содержимое не видят — прочитай его сам, прежде чем подтвердить."
  return 0
}

# ssh host 'команда' — команда выполняется на другой машине, но потеря там
# та же самая.
ssh_segment() {
  local n=${#sw[@]} i=$((P + 1)) w
  while ((i < n)); do
    w=${sw[i]}
    case "$w" in
      --) ((i++)); break ;;
      -[bcDEeFIiJLlmOopQRSWwB]) ((i += 2)) ;;
      -*) ((i++)) ;;
      *) break ;;
    esac
  done
  ((i + 1 < n)) || return 1
  analyze "${sw[*]:i+1}" $((depth + 1))
  return 0
}

su_segment() {
  local n=${#sw[@]} i w
  for ((i = P + 1; i < n; i++)); do
    w=${sw[i]}
    case "$w" in
      -c|--command) ((i + 1 < n)) && { analyze "${sw[i+1]}" $((depth + 1)); return 0; } ;;
      --command=*) analyze "${w#*=}" $((depth + 1)); return 0 ;;
    esac
  done
  return 1
}

if ((${#CMD} > MAXINPUT)); then
  coarse_rules "$CMD"
  ask "Команда длиной ${#CMD} байт — длиннее, чем замок разбирает. Опасное в ней не найдено, но ручаться за это нельзя: проверь, что выполняется."
  finish
fi

analyze "$CMD" 0
if [[ -n "$TOO_BIG" ]]; then
  ask "Команда разобрана не целиком: $TOO_BIG. Запреты проверены по тексту, но ручаться за остальное нельзя — проверь, что выполняется."
fi
finish
