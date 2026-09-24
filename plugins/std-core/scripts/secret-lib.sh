#!/usr/bin/env bash
# secret-lib.sh — словарь секретов: какие пути и какое содержимое считаются
# утечкой. Подключается через source, сам ничего не решает.
#
# Отдельный файл, потому что точек проверки четыре: чтение (Read), команда
# (Bash), запись файла (Write/Edit) и коммит. Пока словарь был один на одну
# точку, остальные три не проверяли ничего, а выглядело это как защита.
# Разъехавшийся словарь — та же дыра, только незаметная: паттерн добавили
# в одном месте, а утекает через другое.
#
# Проектные дополнения: .claude/secret-patterns — по одному ERE на строку,
# строки с # игнорируются. Файл не публикуется (внутренние имена систем,
# префиксы внутренних токенов), поэтому в репозитории его нет и быть не должно.

# --- Пути ---------------------------------------------------------------------

# Образцы и шаблоны исключаются до всего остального: они заводятся ровно затем,
# чтобы их читали и коммитили. Проверка «сначала исключения, потом совпадения»,
# а не наоборот: `.env.example` совпадает с маской `.env.*`.
secret_path_kind() { # <путь> -> печатает вид секрета, код 0; иначе код 1
  local p="$1" base
  # Регистр приводится: на macOS файловая система к нему нечувствительна,
  # и Read .ENV возвращает содержимое .env. Для имени файла-секрета регистр
  # ничего не меняет и в Linux: SERVER.PEM — такой же ключ.
  base=${p##*/}; base=${base,,}

  case "$base" in
    *.example|*.sample|*.dist|*.template|*.tpl|*.tmpl) return 1 ;;
    *.pub|*.pub.key|*.crt|*.cer) return 1 ;;
  esac

  case "$base" in
    .env|.env.*|*.env|.env~|.dev.vars)
      printf 'файл окружения'; return 0 ;;
    # Ключи SSH часто лежат с суффиксом: id_rsa_github, id_ed25519.bak.
    # Публичная половина (*.pub) отсеяна выше.
    id_rsa*|id_dsa*|id_ecdsa*|id_ed25519*|identity|deploy_key|deploy_key.*)
      printf 'приватный ключ SSH'; return 0 ;;
    *.pem|*.p12|*.pfx|*.jks|*.keystore|*.ppk|*.asc|*.gpg)
      printf 'ключ или хранилище ключей'; return 0 ;;
    *.key)
      printf 'ключ'; return 0 ;;
    .netrc|_netrc|.pgpass|.my.cnf|.git-credentials|.npmrc|.pypirc|.dockercfg|\
    .vault-token|.s3cfg|.boto|.htpasswd)
      printf 'файл учётных данных'; return 0 ;;
    credentials.json|client_secret*.json|service-account*.json|service_account*.json)
      printf 'учётные данные облачного сервиса'; return 0 ;;
    auth.json)
      printf 'учётные данные пакетного менеджера'; return 0 ;;
    *.tfstate|*.tfstate.backup|*.tfvars|*.tfvars.json)
      printf 'состояние Terraform: значения секретов лежат в нём открытым текстом'; return 0 ;;
    secrets.yaml|secrets.yml|secret.yaml|secret.yml|secrets.json|secrets.toml|*.secret.*|sealed-secret*.yaml)
      printf 'манифест секретов'; return 0 ;;
    kubeconfig|kubeconfig.*)
      printf 'доступ к кластеру'; return 0 ;;
  esac

  # Каталоги, где секретом является всё содержимое. Проверяются по пути,
  # потому что имя файла там ни о чём не говорит: `config`, `credentials`.
  # Ведущий «/» дописывается: относительный путь .aws/credentials — тот же
  # каталог, что и /home/u/.aws/credentials, а маска требует слэша перед ним.
  case "/$p" in
    */.ssh/*)             printf 'каталог ключей SSH'; return 0 ;;
    */.aws/*)             printf 'учётные данные AWS'; return 0 ;;
    */.gnupg/*)           printf 'ключи GPG'; return 0 ;;
    */.kube/config)       printf 'доступ к кластеру'; return 0 ;;
    */.docker/config.json) printf 'учётные данные реестра образов'; return 0 ;;
    */.config/gcloud/*)   printf 'учётные данные Google Cloud'; return 0 ;;
    */.azure/*)           printf 'учётные данные Azure'; return 0 ;;
    */.config/gh/hosts.yml) printf 'токен GitHub'; return 0 ;;
  esac

  return 1
}

# --- Содержимое ---------------------------------------------------------------

# Два набора: имена полей ищутся без учёта регистра, префиксы токенов — с
# учётом. Один общий вызов с -i давал бы совпадения на `akia` в обычном тексте,
# а без -i пропускал бы `Password:` с большой буквы. Разделение дешевле обеих
# ошибок.
_secret_re_nocase() {
  # Ключ бывает в кавычках ('password' => …, "password": …), разделитель —
  # =, :, := (Go) или => (PHP). Раньше требовалось `password` и сразу `=`/`:`,
  # и мимо шли JSON, массивы конфигурации Laravel/Yii и Go.
  printf '%s\n' \
    '(aws_secret_access_key|aws_access_key_id|aws_session_token)[[:space:]]*[:=]' \
    '(password|passwd|pwd|secret|api_?key|apikey|access_?key|auth_?token|token|private_?key|client_?secret)["'"'"']?[[:space:]]*(=>|:=|[:=])[[:space:]]*["'"'"'][^"'"'"'{$<]{8,}["'"'"']' \
    '(authorization|proxy-authorization)[[:space:]]*:[[:space:]]*(bearer|basic)[[:space:]]+[A-Za-z0-9._~+/=-]{16,}' \
    '^[[:space:]]*(-[[:space:]]*)?(export[[:space:]]+)?[A-Za-z0-9_.]*(key|token|secret|password|passwd|pwd|credentials?|dsn)[[:space:]]*[:=][[:space:]]*[^"'"'"'[:space:]${<]{12,}' \
    '(postgres|postgresql|mysql|mariadb|mongodb|mongodb\+srv|redis|rediss|amqp|amqps|ftp|https?)://[^:@/[:space:]]+:[^@/[:space:]]{4,}@'
}

_secret_re_case() {
  printf '%s\n' \
    'AKIA[0-9A-Z]{16}' \
    'ASIA[0-9A-Z]{16}' \
    '-----BEGIN [A-Z ]*PRIVATE KEY-----' \
    '-----BEGIN PGP PRIVATE KEY BLOCK-----' \
    '(sk|rk)_live_[0-9A-Za-z]{20,}' \
    'sk-(proj|svcacct|admin)-[A-Za-z0-9_-]{20,}' \
    'sk-ant-[A-Za-z0-9_-]{16,}' \
    'sk-[A-Za-z0-9]{32,}' \
    '(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{16,}' \
    'github_pat_[A-Za-z0-9_]{20,}' \
    'glpat-[A-Za-z0-9_-]{16,}' \
    'xox[baprs]-[A-Za-z0-9-]{10,}' \
    'AIza[0-9A-Za-z_-]{35}' \
    'ya29\.[A-Za-z0-9_-]{20,}' \
    'SG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}' \
    'dop_v1_[a-f0-9]{32,}' \
    'hf_[A-Za-z0-9]{30,}' \
    'npm_[A-Za-z0-9]{30,}' \
    'pypi-AgEIcHlwaS5vcmc[A-Za-z0-9_-]{10,}' \
    '[0-9]{8,10}:AA[A-Za-z0-9_-]{32,}' \
    'eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
}

# Дополнения проекта. Внутренние префиксы токенов и имена систем не могут жить
# в публичном репозитории, но проверять их надо — поэтому файл проектный.
_secret_re_project() { # <корень проекта>
  local f="$1/.claude/secret-patterns"
  [[ -f "$f" ]] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$f" 2>/dev/null
}

# Строка-заглушка. Без этой проверки приходится держать слепые зоны — раньше
# из скана были целиком исключены `*.md` и тесты, потому что в примерах много
# похожего на ключи. Слепая зона хуже неточности: настоящий токен в README
# и настоящий ключ в фикстуре — два самых обычных места утечки.
secret_is_placeholder() { # <строка> -> 0, если это заглушка
  printf '%s' "$1" | grep -qiE \
    '://[^:@/]+:(pass|password|passwd|pwd|secret|changeme)@|your[-_]|your(personal|own|real|actual|api|access|secret|bot)|[-_]here([^a-z0-9]|$)|my[-_]secret|<[^>]{1,40}>|x{4,}|X{4,}|changeme|change[-_]me|placeholder|example|sample|dummy|redacted|todo|fixme|\*{4,}|\.\.\.|\$\{|\$\(|%[A-Za-z_]+%|\{\{|process\.env|os\.environ|getenv|env\(|config\(|secret\(|Deno\.env|import\.meta\.env' \
    && return 0
  # Кириллица: `grep -i` не приводит её регистр в однобайтовой локали, поэтому
  # оба написания перечислены явно.
  printf '%s' "$1" | grep -qE 'пример|Пример|ПРИМЕР|заглушк|Заглушк|подстав|Подстав|секрет_сюда' && return 0
  return 1
}

# Узкий фильтр — только для строк, совпавших со строгим форматом токена
# (AKIA + 16 символов, ghp_ + 36 и подобные). Широкий здесь применять нельзя:
# документационный ключ AWS содержит слово EXAMPLE, и по нему отбрасывался бы
# любой настоящий ключ, рядом с которым стоит слово «example» — а такое
# соседство встречается ровно в тех конфигурациях, которые копируют с примера.
# Формат сам по себе достаточно специфичен; отбрасываем только явный мусор.
secret_is_stub() { # <строка> -> 0, если это очевидно не ключ
  # «your-…», «…-here», «YourPersonal…» — заглушки из README и .env.example:
  # формат префикса настоящий, значение — нет.
  printf '%s' "$1" | grep -qE 'x{4,}|X{4,}|\*{4,}|\.{3,}|<[^>]{1,40}>|\$\{|\{\{|%[A-Za-z_]+%|[Yy]our[-_A-Z]|[-_][Hh]ere([^A-Za-z0-9]|$)' && return 0
  return 1
}

# Отбор находок из размеченного потока: TAG:номер:текст, где TAG — G (общий
# паттерн, широкий фильтр), S (строгий формат, узкий фильтр) или P (паттерн
# проекта, узкий фильтр).
#
# Фильтр заглушек смотрит на совпавший фрагмент, а не на всю строку. Иначе
# настоящий пароль терялся из-за соседства: `DB_PASSWORD="…"  # TODO: вынести`
# или `postgres://app:…@db.example.com` — слово «todo» или «example» стояло
# рядом со значением, а не было им.
_secret_match() { # <тег> <строка> -> совпавший фрагмент (или вся строка)
  local m=""
  case "$1" in
    G) m=$(printf '%s\n' "$2" | grep -oEi -f <(_secret_re_nocase) 2>/dev/null | head -1) ;;
    S) m=$(printf '%s\n' "$2" | grep -oE  -f <(_secret_re_case)   2>/dev/null | head -1) ;;
  esac
  printf '%s' "${m:-$2}"
}

_secret_pick() { # <корень проекта>
  local root="$1" line tag rest num text frag
  local -a chosen=() seen=()
  while IFS= read -r line; do
    tag=${line%%:*}; rest=${line#*:}
    num=${rest%%:*}; text=${rest#*:}
    [[ " ${seen[*]-} " == *" $num "* ]] && continue
    frag=$(_secret_match "$tag" "$text")
    if [[ "$tag" == "G" ]]; then
      secret_is_placeholder "$frag" && continue
    else
      secret_is_stub "$frag" && continue
    fi
    secret_allowed "$text" "$root" && continue
    seen+=("$num")
    chosen+=("$num:$text")
    [[ ${#chosen[@]} -ge 5 ]] && break
  done
  [[ ${#chosen[@]} -eq 0 ]] && return 0
  printf '%s\n' "${chosen[@]}" | sort -t: -k1,1n
}

# Исключения проекта: .claude/secret-allow, по подстроке на строку. Механизм
# обязателен — без него первое ложное срабатывание чинят через --no-verify,
# то есть отключают весь слой, а не одну строку.
secret_allowed() { # <строка> [<корень проекта>] -> 0, если разрешена
  local line="$1" f="${2:-}/.claude/secret-allow" pat
  [[ -f "$f" ]] || return 1
  while IFS= read -r pat; do
    [[ -z "$pat" || "$pat" == \#* ]] && continue
    [[ "$line" == *"$pat"* ]] && return 0
  done < "$f"
  return 1
}

# Находки в файле. Печатает строки вида «номер:текст», не больше пяти:
# список длиннее не читают, а первая находка уже требует действия.
secret_content_hits() { # <файл> [<корень проекта>]
  local f="$1" root="${2:-}"
  [[ -f "$f" ]] || return 0

  # Двоичные файлы не разбираем: grep выдал бы мусор вместо строки.
  if LC_ALL=C grep -qP '\x00' "$f" 2>/dev/null; then return 0; fi

  {
    grep -nEi -f <(_secret_re_nocase) "$f" 2>/dev/null | sed 's/^/G:/'
    grep -nE  -f <(_secret_re_case)   "$f" 2>/dev/null | sed 's/^/S:/'
    if [[ -n "$root" ]]; then
      local extra; extra=$(_secret_re_project "$root")
      [[ -n "$extra" ]] && grep -nEi -f <(printf '%s\n' "$extra") "$f" 2>/dev/null | sed 's/^/P:/'
    fi
  } | _secret_pick "$root"
}

# То же для текста на входе — для скана индекса перед коммитом, где файла
# на диске в нужной версии нет.
secret_text_hits() { # stdin -> строки находок [<корень проекта>]
  local root="${1:-}" text
  text=$(cat)
  {
    printf '%s\n' "$text" | grep -nEi -f <(_secret_re_nocase) 2>/dev/null | sed 's/^/G:/'
    printf '%s\n' "$text" | grep -nE  -f <(_secret_re_case)   2>/dev/null | sed 's/^/S:/'
    if [[ -n "$root" ]]; then
      local extra; extra=$(_secret_re_project "$root")
      [[ -n "$extra" ]] && printf '%s\n' "$text" | grep -nEi -f <(printf '%s\n' "$extra") 2>/dev/null | sed 's/^/P:/'
    fi
  } | _secret_pick "$root"
}
