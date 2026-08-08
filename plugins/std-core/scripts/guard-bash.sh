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

INPUT=$(cat)

# std:hooks-off — человек отключил замки в этом проекте (.claude/std-hooks-off).
# Правила при этом остаются и грузятся как раньше: стандарт возвращается
# к тексту без проверки. Что замки выключены, напоминает session-check.sh —
# единственный хук, которого маркер не глушит.
[[ -f "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/std-hooks-off" ]] && exit 0

# Словарь секретов общий с остальными точками проверки: чтением файла, записью
# и коммитом. Пока он был у каждой свой, добавленный паттерн закрывал одну
# дорогу из четырёх.
. "$(dirname "${BASH_SOURCE[0]}")/secret-lib.sh"

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

deny() { emit deny "$1"; }
ask()  { emit ask  "$1"; }

# --- std:jq-guard — отсутствие разборщика JSON не должно открывать ворота ------
# Было: jq не найден -> пустая строка -> тихий exit 0 -> все замки выключены,
# и никто об этом не знает. Это ровно то, что репозиторий называет худшим
# случаем: молчаливо сломанная проверка. Теперь — отказ с объяснением.
read_command() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$INPUT" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("tool_input", {}).get("command", "") or "", end="")
except Exception:
    pass' 2>/dev/null
    return 0
  fi
  return 1
}

if ! CMD=$(read_command); then
  deny "Замки не работают: на машине нет ни jq, ни python3, а без них запрос не разобрать. Пока их нет, любая команда блокируется — иначе защита выключилась бы молча. Поставь jq в своём терминале (apt install jq / brew install jq / dnf install jq) и повтори."
fi

[[ -z "$CMD" ]] && exit 0

# --- Разбор командной строки --------------------------------------------------
# Проверять правилами всю строку целиком нельзя: тогда `echo "не запускай
# migrate:fresh"` блокируется наравне с самим migrate:fresh, а `bash -c "docker
# volume rm"` проходит, потому что опасное слово спрятано в аргументе. Поэтому
# строка сначала разбирается: отделяются сегменты, у каждого определяется
# головная команда, и правила применяются только к тому, что действительно
# исполняется.

MAXLEN=20000   # страховка от посимвольного прохода по гигантской строке

# Подстановка присваиваний из той же строки: `D=docker; $D volume rm x`.
# Переменная из другой команды или из окружения так не раскрывается — это
# записано в известные границы, а не выдаётся за проверку.
expand_assignments() {
  local s="$1" pair name value
  while IFS= read -r pair; do
    [[ -z "$pair" ]] && continue
    name=${pair%%=*}
    value=${pair#*=}
    value=${value%\"}; value=${value#\"}
    value=${value%\'}; value=${value#\'}
    [[ -z "$value" ]] && continue
    s=${s//\$\{$name\}/$value}
    s=${s//\$$name/$value}
  done < <(printf '%s' "$s" | grep -oE '(^|[;&|[:space:]])[A-Za-z_][A-Za-z0-9_]*=[^[:space:];&|]+' \
             | sed 's/^[;&|[:space:]]*//')
  printf '%s' "$s"
}

# Разбиение на сегменты с учётом кавычек. Наивный split по ; && || | разрезал бы
# `echo "a; rm -rf /"` пополам и вернул бы ложное срабатывание, которое мы как
# раз убираем. Содержимое $(...) выносится отдельным сегментом: это исполняемый
# текст, и проверять его надо, а не пропускать вместе с обёрткой.
SEP=$'\x1f'
split_segments() { # <строка> -> сегменты через \x1f
  local s="$1" n=${#1} i=0 c st=0 cur="" out="" depth
  local sub
  while ((i < n)); do
    c=${s:i:1}
    case $st in
      0)
        case "$c" in
          "'") st=1; cur+="$c" ;;
          '"') st=2; cur+="$c" ;;
          '\')  ((i++)); cur+="${s:i:1}" ;;
          ';'|'&'|'|'|$'\n')
            out+="$cur$SEP"; cur="" ;;
          '$')
            if [[ "${s:i+1:1}" == "(" ]]; then
              depth=1; ((i += 2)); sub=""
              while ((i < n && depth > 0)); do
                case "${s:i:1}" in
                  '(') ((depth++)); sub+="(" ;;
                  ')') ((depth--)); ((depth > 0)) && sub+=")" ;;
                  *)   sub+="${s:i:1}" ;;
                esac
                ((i++))
              done
              ((i--))
              out+="$sub$SEP"
            else
              cur+="$c"
            fi ;;
          '`')
            ((i++)); sub=""
            while ((i < n)) && [[ "${s:i:1}" != '`' ]]; do sub+="${s:i:1}"; ((i++)); done
            out+="$sub$SEP" ;;
          *) cur+="$c" ;;
        esac ;;
      1)
        cur+="$c"; [[ "$c" == "'" ]] && st=0 ;;
      2)
        case "$c" in
          '"') cur+="$c"; st=0 ;;
          '\') cur+="$c"; ((i++)); cur+="${s:i:1}" ;;
          '$')
            if [[ "${s:i+1:1}" == "(" ]]; then
              depth=1; ((i += 2)); sub=""
              while ((i < n && depth > 0)); do
                case "${s:i:1}" in
                  '(') ((depth++)); sub+="(" ;;
                  ')') ((depth--)); ((depth > 0)) && sub+=")" ;;
                  *)   sub+="${s:i:1}" ;;
                esac
                ((i++))
              done
              ((i--))
              out+="$sub$SEP"
            else
              cur+="$c"
            fi ;;
          *) cur+="$c" ;;
        esac ;;
    esac
    ((i++))
  done
  out+="$cur"
  printf '%s' "$out"
}

# Пробелы по краям и обрамляющие кавычки. Порядок важен: `"rm -rf ~/" `
# с хвостовым пробелом кавычку не терял, и внутренняя команда уезжала
# в разбор закавыченной — то есть мимо всех правил. Найдено фаззингом.
unquote() { # <строка>
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  while [[ ${#s} -ge 2 ]]; do
    case "$s" in
      \"*\") s=${s#\"}; s=${s%\"} ;;
      \'*\') s=${s#\'}; s=${s%\'} ;;
      *) break ;;
    esac
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
  done
  printf '%s' "$s"
}

# Снятие обёрток, за которыми стоит настоящая команда: sudo, env, timeout 30,
# nice, ведущие присваивания. Без этого `sudo docker volume rm` считался бы
# командой sudo и не проверялся.
strip_prefixes() { # <сегмент> -> сегмент без обёрток
  local s="$1" changed=1
  s="${s#"${s%%[![:space:]]*}"}"
  while ((changed)); do
    changed=0
    case "$s" in
      [A-Za-z_]*=*)
        if [[ "$s" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+(.*)$ ]]; then
          s="${BASH_REMATCH[1]}"; changed=1
        fi ;;
    esac
    case "$s" in
      sudo\ *|doas\ *|nice\ *|ionice\ *|stdbuf\ *|command\ *|builtin\ *|exec\ *|nohup\ *)
        s="${s#* }"; changed=1 ;;
      env\ *)
        s="${s#env }"; changed=1 ;;
      time\ *)
        s="${s#time }"; changed=1 ;;
      timeout\ *)
        s="${s#timeout }"
        s="${s#-* }"
        s="${s#* }"; changed=1 ;;
      xargs\ *)
        s="${s#xargs }"; changed=1 ;;
    esac
    s="${s#"${s%%[![:space:]]*}"}"
  done
  printf '%s' "$s"
}

# Команды, которые текст печатают или ищут, но не исполняют. Опасные слова
# в их аргументах — это данные: `git log --grep "drop database"` ничего не
# роняет, а раньше блокировался.
is_text_command() { # <сегмент>
  local s="$1" head sub
  head=${s%%[[:space:]]*}
  head=${head##*/}
  case "$head" in
    echo|printf|cat|less|more|head|tail|wc|sort|uniq|column|man|which|type|whatis|\
    grep|egrep|fgrep|rg|ag|ack|jq|yq|diff|comm|tree|stat|file|date|pwd|whoami)
      return 0 ;;
    ls)
      return 0 ;;
    git)
      sub=$(printf '%s' "$s" | awk '{for (i=2; i<=NF; i++) if ($i !~ /^-/) {print $i; exit}}')
      case "$sub" in
        log|grep|show|diff|status|blame|shortlog|describe|rev-parse|ls-files|remote|branch|tag)
          return 0 ;;
      esac
      return 1 ;;
  esac
  return 1
}

# --- Секреты ------------------------------------------------------------------
# Проверяется до is_text_command и не вместе с остальными правилами: cat, head
# и grep числятся текстовыми командами и до apply_rules не доходят вовсе.
# Именно ими секрет и достают.
#
# Утечка здесь необратима иначе, чем разрушение: отменять нечего — значение
# уже в контексте модели, то есть у провайдера и в истории сессии на диске.
# Поэтому решение всегда ask: запрет на `cat .env` сняли бы вместе со всеми
# замками, а вопрос с названной ценой человек читает.
secret_rules() { # <сегмент>
  local s="$1" head tok kind
  s=${s//\"/ }; s=${s//\'/ }
  head=$(strip_prefixes "$s"); head=${head%%[[:space:]]*}; head=${head##*/}

  # 1. Команды, печатающие содержимое файла, — с секретом в аргументах.
  case "$head" in
    cat|less|more|head|tail|bat|nl|tac|xxd|od|strings|base64|awk|sed|cut|jq|yq|\
    grep|egrep|fgrep|rg|ag|scp|rsync|curl|wget|open|xdg-open)
      for tok in $s; do
        case "$tok" in -*) continue ;; esac
        tok=${tok%%=*}
        if kind=$(secret_path_kind "$tok"); then
          ask "Команда печатает содержимое: $tok — $kind. Прочитанное уедет в контекст модели и останется в истории сессии; отменить это потом нельзя. Если нужны только имена переменных, возьми их без значений: grep -oE '^[A-Za-z_][A-Za-z0-9_]*' $tok"
        fi
        # Аргумент вида --var-file=secrets.tfvars и подобные
        case "$tok" in
          *=*) if kind=$(secret_path_kind "${tok#*=}"); then
                 ask "В аргументе указан ${tok#*=} — $kind. Содержимое попадёт в вывод и в контекст модели."
               fi ;;
        esac
      done ;;
  esac

  # 2. Печать окружения целиком: в нём лежат ровно те значения, ради которых
  #    секреты и выносят из файлов.
  if printf '%s' "$s" | grep -Eq '(^|[;&|[:space:]])(printenv|env)[[:space:]]*$' \
     || printf '%s' "$s" | grep -Eq '(^|[;&|[:space:]])(set|export[[:space:]]+-p|declare[[:space:]]+-x)[[:space:]]*$'; then
    ask "Команда печатает всё окружение целиком, вместе со значениями ключей и паролей. Весь вывод попадёт в контекст модели. Если нужна одна переменная — назови её: printenv APP_ENV. Если нужны только имена — printenv | cut -d= -f1"
  fi

  # 3. Хранилища секретов: значение выдаётся расшифрованным.
  if printf '%s' "$s" | grep -Eq 'kubectl[^;&|]*(get|describe)[[:space:]]+(secret|secrets)([[:space:]]|$)'; then
    ask "Команда покажет содержимое секрета кластера в открытом виде (в get -o yaml значения лежат в base64, что защитой не является). Вывод уедет в контекст модели. Если нужны только имена ключей: kubectl get secret <имя> -o jsonpath='{.data}' | jq keys"
  fi
  if printf '%s' "$s" | grep -Eq '(aws[[:space:]]+secretsmanager[[:space:]]+get-secret-value|aws[[:space:]]+ssm[[:space:]]+get-parameter[^;&|]*--with-decryption|vault[[:space:]]+(read|kv[[:space:]]+get)|gcloud[[:space:]]+secrets[[:space:]]+versions[[:space:]]+access|az[[:space:]]+keyvault[[:space:]]+secret[[:space:]]+show|doppler[[:space:]]+secrets|heroku[[:space:]]+config([[:space:]]|$))'; then
    ask "Команда достаёт значение секрета из хранилища в открытом виде — оно попадёт в контекст модели и в историю сессии. Убедись, что задача не решается без самого значения."
  fi
  if printf '%s' "$s" | grep -Eq '(docker|podman)[[:space:]]+(inspect|exec[^;&|]*[[:space:]](env|printenv)([[:space:]]|$))'; then
    ask "Вывод покажет переменные окружения контейнера вместе со значениями — там лежат пароли к базе и ключи. Всё это попадёт в контекст модели."
  fi

  # 4. Отправка файла наружу. Замок не сетевой экран и содержимое запроса не
  #    разбирает — он лишь не даёт сделать это не глядя.
  if printf '%s' "$s" | grep -Eq '(^|[;&|[:space:]])(curl|wget|http|httpie)([[:space:]]|$)' \
     && printf '%s' "$s" | grep -Eq '(--data-binary[[:space:]]*@|--data[[:space:]]*@|-d[[:space:]]*@|-F[[:space:]]*[^[:space:]]*=@|--form[[:space:]]*[^[:space:]]*=@|-T[[:space:]]|--upload-file|--post-file)'; then
    ask "Команда отправляет содержимое файла на внешний адрес. Проверь, что именно уходит и куда: после отправки данные считаются раскрытыми, даже если получатель их потом удалит."
  fi
}

# --- Правила ------------------------------------------------------------------
# Применяются к сегменту, который действительно исполняется. Каждое правило
# закрывает потерю, которую не откатить: данные, историю, чужую работу.
apply_rules() { # <сегмент>
  local s="$1"
  # Кавычки заменяются пробелами перед сопоставлением. Иначе `"rm -rf ~/"`,
  # прилетевший из `bash -c`, не совпадал с правилом: перед rm стояла кавычка,
  # а правило требовало границу слова. Найдено фаззингом. Текстовые команды
  # к этому моменту уже отсеяны, поэтому данные в кавычках сюда не доходят.
  s=${s//\"/ }
  s=${s//\'/ }

  # 1. Контейнеры: удаление образов, томов, кэша. Потеря необратима и стоит
  #    часов пересборки.
  if printf '%s' "$s" | grep -Eq '(^|[;&|[:space:]])(podman|docker|buildah)([[:space:]]+compose)?[[:space:]]+((container|image|volume|network|system)[[:space:]]+)?(rm|rmi|prune)'; then
    deny "Удаление контейнеров/образов/томов/кэша запрещено политикой. Сначала покажи занятое место и спроси разрешение на конкретную команду."
  fi
  if printf '%s' "$s" | grep -Eq '(podman|docker)([[:space:]]+compose|-compose)[[:space:]]+down[^;&|]*[[:space:]](-v|--volumes)([[:space:]]|$)'; then
    deny "'compose down -v' удаляет тома вместе с данными. Используй 'down' без -v."
  fi

  # 2. Git: необратимое и обход проверок.
  if printf '%s' "$s" | grep -Eq 'git[[:space:]]+push([[:space:]]|$)'; then
    if printf '%s' "$s" | grep -Eq '(--force([[:space:]]|$)|[[:space:]]-f([[:space:]]|$))' \
       && ! printf '%s' "$s" | grep -q 'force-with-lease'; then
      deny "force-push перезаписывает чужую историю. Используй --force-with-lease."
    fi
    # Плюс перед refspec — тот же force, только записанный иначе.
    if printf '%s' "$s" | grep -Eq '[[:space:]]\+[A-Za-z0-9_./*-]+(:[A-Za-z0-9_./*-]+)?([[:space:]]|$)'; then
      deny "'+refspec' в push — это тот же force-push, только записанный иначе: чужие коммиты будут перезаписаны. Используй --force-with-lease."
    fi
  fi
  if printf '%s' "$s" | grep -Eq 'git[[:space:]][^;&|]*--no-verify'; then
    deny "--no-verify отключает pre-commit проверки — ровно тот слой, ради которого код не читают глазами."
  fi
  # `-n` в commit это --no-verify; в push это --dry-run и совершенно безобиден,
  # поэтому короткий флаг проверяется только у commit.
  if printf '%s' "$s" | grep -Eq 'git[[:space:]]+commit([[:space:]]+[^;&|]*)?[[:space:]]-[A-Za-z]*n[A-Za-z]*([[:space:]]|$)'; then
    deny "'git commit -n' — это то же --no-verify: pre-commit проверки не выполнятся."
  fi
  if printf '%s' "$s" | grep -Eq 'git[[:space:]]+(-c[[:space:]]+)?core\.hooksPath[[:space:]]*='; then
    deny "Подмена core.hooksPath отключает git-хуки на время команды — обход проверок в обход --no-verify."
  fi
  if printf '%s' "$s" | grep -Eq 'git[[:space:]]+reset[[:space:]]+--hard'; then
    ask "git reset --hard уничтожит незакоммиченные изменения. Подтверди."
  fi
  if printf '%s' "$s" | grep -Eq 'git[[:space:]]+clean[[:space:]]+[^;&|]*-[a-zA-Z]*[dx]'; then
    ask "git clean удалит неотслеживаемые файлы — в том числе те, что ещё не добавлены в индекс и нигде не сохранены. Подтверди."
  fi
  if printf '%s' "$s" | grep -Eq 'git[[:space:]]+(checkout|restore)[[:space:]]+(--[[:space:]]+)?(\.|\*)([[:space:]]|$)'; then
    ask "Откат рабочего дерева целиком сотрёт все несохранённые правки. Подтверди."
  fi

  # 3. База данных: разрушающие операции.
  if printf '%s' "$s" | grep -Eqi 'migrate:fresh|migrate:reset|db:wipe|drop[[:space:]]+(database|schema)|drop[[:space:]]+table|truncate[[:space:]]+table'; then
    deny "Разрушающая операция с БД. Если она действительно нужна — выполни вручную, осознанно."
  fi

  # 4. Файловая система.
  if printf '%s' "$s" | grep -Eq '(^|[[:space:]])rm([[:space:]]|$)'; then
    if printf '%s' "$s" | grep -q -- '--no-preserve-root'; then
      deny "--no-preserve-root снимает единственную встроенную защиту rm от удаления корня."
    fi
    if printf '%s' "$s" | grep -Eq '(^|[[:space:]])(-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)([[:space:]]|$)'; then
      if printf '%s' "$s" | grep -Eq '(^|[[:space:]])(/|/\*|~|~/|\$HOME/?|\$\{HOME\}/?|/etc|/usr|/var|/bin|/lib|/opt|/root|/home)([[:space:]]|$)'; then
        deny "Рекурсивное удаление от корня, из домашней или из системной директории."
      fi
    fi
  fi
  if printf '%s' "$s" | grep -Eq '(^|[[:space:]])find([[:space:]]|$)' \
     && printf '%s' "$s" | grep -Eq '(-delete([[:space:]]|$)|-exec[[:space:]]+rm)' \
     && printf '%s' "$s" | grep -Eq 'find[[:space:]]+(/|~|~/|\$HOME|/etc|/usr|/var|/bin|/lib|/opt|/root|/home)([[:space:]]|$)'; then
    deny "find с удалением по системному пути обходит защиту rm и выносит всё дерево целиком."
  fi
  if printf '%s' "$s" | grep -Eq '(^|[[:space:]])dd([[:space:]]|$)' \
     && printf '%s' "$s" | grep -Eq 'of=/dev/(sd|nvme|vd|hd|disk|mmcblk)'; then
    deny "Запись через dd прямо на устройство уничтожает разделы без возможности отката."
  fi
  if printf '%s' "$s" | grep -Eq '(^|[[:space:]])mkfs(\.[a-z0-9]+)?([[:space:]]|$)'; then
    deny "Создание файловой системы стирает содержимое устройства целиком."
  fi
  if printf '%s' "$s" | grep -Eq '(^|[[:space:]])(chmod|chown)([[:space:]]|$)' \
     && printf '%s' "$s" | grep -Eq '(^|[[:space:]])(-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)([[:space:]]|$)' \
     && printf '%s' "$s" | grep -Eq '(^|[[:space:]])(/|~|~/|\$HOME|/etc|/usr|/var|/bin|/lib|/opt|/root|/home)([[:space:]]|$)'; then
    deny "Рекурсивная смена прав или владельца по системному пути ломает систему целиком и чинится только восстановлением."
  fi

  # 5. Оркестрация: снос окружения одной командой.
  if printf '%s' "$s" | grep -Eq 'kubectl[[:space:]]+delete[[:space:]]+(namespace|ns)([[:space:]]|$)'; then
    ask "Удаление namespace сносит всё, что в нём есть, включая PersistentVolumeClaim. Подтверди кластер и имя."
  fi
  if printf '%s' "$s" | grep -Eq '(helm[[:space:]]+(uninstall|delete)|terraform[[:space:]]+destroy)'; then
    ask "Команда сносит развёрнутое окружение. Подтверди, что это не продуктивный контур."
  fi

  # 6. Новые зависимости: не запрет, а обязательная пара глаз.
  #    Пакет проходит любые тесты идеально. Это единственный вектор, который
  #    система автопроверок не закрывает в принципе.
  if printf '%s' "$s" | grep -Eq '(composer[[:space:]]+require|npm[[:space:]]+i(nstall)?[[:space:]]+[a-z@]|yarn[[:space:]]+add|pnpm[[:space:]]+add|pip[[:space:]]+install[[:space:]]+[a-z])'; then
    ask "Добавляется новая зависимость. Подтверди пакет и его источник — тесты этот риск не покрывают."
  fi
}

# Исполнение текста, который замок прочитать не может: из потока, из подстановки
# процесса, через eval. Раньше это молча проходило. Разбирать содержимое честно
# невозможно, поэтому решение отдаётся человеку — граница названа, а не спрятана.
check_opaque() { # <сегмент>
  local s="$1" head
  head=$(strip_prefixes "$s")
  head=${head%%[[:space:]]*}
  head=${head##*/}
  case "$head" in
    bash|sh|zsh|dash|ksh)
      # `bash script.sh` — обычный запуск файла, он тут ни при чём.
      if ! printf '%s' "$s" | grep -Eq '[[:space:]][^-][^[:space:]]*'; then
        ask "Команда выполняет то, что приходит на вход интерпретатору. Замки разбирают текст команды и такое содержимое не видят — прочитай его сам, прежде чем подтвердить."
      fi
      if printf '%s' "$s" | grep -Eq '<\('; then
        ask "Выполнение через подстановку процесса: содержимое замками не проверяется. Подтверди осознанно."
      fi ;;
  esac
}

# Политика при неполном разборе: понял — решаю, не понял — спрашиваю.
# Молчаливый пропуск здесь был бы худшим вариантом: команду не проверили,
# а выглядит это как проверенную.
analyze() { # <командная строка> <глубина>
  local line="$1" depth="${2:-0}" seg body head
  if ((depth > 3)); then
    ask "Команда вложена в обёртки глубже, чем замок разбирает ($depth уровня). Что выполнится на самом деле, отсюда не видно — прочитай сам, прежде чем подтвердить."
  fi

  local -a segs=()
  if ((${#line} > MAXLEN)); then
    # Длинную строку всё равно проверяем правилами: разрушающая команда
    # в её начале должна быть поймана. Но «правила молчат» здесь не значит
    # «безопасно» — значит «разобрать целиком не удалось».
    apply_rules "$line"
    ask "Команда длиной ${#line} символов — длиннее, чем замок разбирает целиком. Опасное в ней не найдено, но ручаться за это нельзя: проверь, что выполняется."
  fi

  mapfile -d "$SEP" -t segs < <(split_segments "$line")
  if [[ ${#segs[@]} -eq 0 && -n "${line//[[:space:]]/}" ]]; then
    ask "Разобрать команду не удалось. Замок не пропускает то, чего не понял, — подтверди её сам."
  fi

  for seg in "${segs[@]}"; do
    [[ -z "${seg//[[:space:]]/}" ]] && continue
    # Табуляция приводится к пробелу до разбора: снятие обёрток сравнивает
    # начало сегмента с образцами вида «sudo », и `env\tFOO=1\tdocker volume rm`
    # проходил мимо — обёртка не снялась, головой команды осталось `env`.
    # Найдено фаззингом.
    seg=${seg//$'\t'/ }
    seg=$(strip_prefixes "$seg")

    head=${seg%%[[:space:]]*}
    head=${head##*/}

    # Обёртка вокруг другой команды: разбираем то, что внутри.
    case "$head" in
      bash|sh|zsh|dash|ksh)
        if printf '%s' "$seg" | grep -Eq '[[:space:]]-[a-z]*c([[:space:]]|$)'; then
          body=$(printf '%s' "$seg" | sed -E 's/^[^[:space:]]+[[:space:]]+(-[a-z]*c)[[:space:]]+//')
          analyze "$(unquote "$body")" $((depth + 1))
          continue
        fi ;;
      eval)
        body=${seg#eval }
        analyze "$(unquote "$body")" $((depth + 1))
        ask "eval собирает команду на ходу, и замки видят только заготовку. Прочитай, что получится, прежде чем подтвердить."
        continue ;;
    esac

    check_opaque "$seg"
    # До is_text_command: секрет достают именно текстовыми командами, и для них
    # apply_rules не выполняется вовсе.
    secret_rules "$seg"
    is_text_command "$seg" && continue
    apply_rules "$seg"
  done
}

analyze "$(expand_assignments "$CMD")" 0
exit 0
