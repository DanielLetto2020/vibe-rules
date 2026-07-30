#!/usr/bin/env python3
"""
no-private-data.py — страж: не даёт внутренним данным попасть в публичный
репозиторий.

Правила здесь пишутся обезличенно. Источником может быть внутренний регламент
организации, но в публичную часть уходит только техническая суть: «поля API
в camelCase», а не «по регламенту компании N, согласовано с таким-то».

Проверяется содержимое всех отслеживаемых git файлов и имена файлов.
Запускается первым шагом общего прогона и в CI — утечка блокирует сборку,
а не обнаруживается после публикации.

## Два набора шаблонов

**Универсальные** (в этом файле) — признаки утечки, не выдающие ничьих
секретов: внутренние домены, ФИО, частные IP, корпоративная почта, оборот
«согласовано с».

**Свои** (`tests/.private-patterns`, в `.gitignore`) — названия конкретных
внутренних систем, подразделений, продуктов. Они сами по себе приватны,
поэтому в публичном репозитории их быть не должно даже в списке запрещённых.
Образец: `tests/private-patterns.example`.

Коды возврата: 0 — чисто, 1 — найдена утечка.
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PRIVATE_PATTERNS_FILE = ROOT / "tests" / ".private-patterns"

# Универсальные признаки. Намеренно широкие: ложное срабатывание стоит минуту
# на переформулировку, пропущенная утечка в публичной истории не исправляется.
PATTERNS: list[tuple[str, str]] = [
    ("внутренний хост системы сборки или репозитория пакетов",
     r"(?i)\b(?:git|satis|nexus|artifactory|jenkins|gitlab|jira|confluence)\."
     r"[a-z0-9-]+\.(?:ru|local|internal|lan|corp)\b"),

    # Требуем, чтобы после зоны ничего не продолжалось: иначе шаблон ловит
    # имена файлов вида CLAUDE.local.md и settings.local.json
    ("внутренний домен",
     r"(?i)(?<![\w.-])[a-z0-9][a-z0-9-]*\.(?:local|internal|lan|corp)(?![\w.-])"),

    ("ФИО в тексте правил (отчество на -вич/-вна)",
     r"\b[А-ЯЁ][а-яё]+\s+[А-ЯЁ][а-яё]+\s+[А-ЯЁ][а-яё]+(?:вич|вна|чна)\b"),

    ("фамилия с инициалами",
     r"\b[А-ЯЁ][а-яё]{2,}\s+[А-ЯЁ]\.\s?[А-ЯЁ]\.\B"),

    ("оборот из внутреннего распорядительного документа",
     r"(?i)(?:согласовано с|владелец процесса|приложение\s*№|"
     r"утверждено\s+(?:приказом|распоряжением))"),

    ("корпоративная почта",
     r"[\w.+-]+@(?!example\.|test\.|localhost)[\w-]*(?:corp|internal|holding)[\w.-]*\.\w+"),

    ("частный IP-адрес",
     r"\b(?:10\.\d{1,3}|192\.168|172\.(?:1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3}\b"),

    # Путь с домашним каталогом выдаёт имя пользователя машины, а заодно
    # раскладку рабочих каталогов. Попадает в репозиторий обычно случайно:
    # скопированной командой из терминала или примером вывода. Разрешены
    # плейсхолдеры и стандартные имена пользователей контейнеров и раннеров
    # CI — без них нельзя показать ни пример пути, ни рабочий Containerfile.
    ("путь с домашним каталогом конкретной машины",
     r"(?:/home/|/Users/|(?i:C:\\Users\\))"
     r"(?!user\b|username\b|you\b|имя\b|name\b|dev\b|node\b|app\b|runner\b|"
     r"vscode\b|ubuntu\b|linuxbrew\b|<|\$|\{|%)[A-Za-z][\w.-]{1,30}"),

    ("личная или рабочая почта",
     r"(?<![\w.+-])[\w.+-]{2,}@"
     r"(?!example\.|test\.|localhost|users\.noreply\.github\.com|noreply\.)"
     r"[\w-]{2,}\.[a-z]{2,}(?![\w-])"),

    # Ключи и токены. Отдельно от secret-scan.sh, который смотрит на проекты
    # пользователей: здесь охраняется сам репозиторий стандартов, и правила
    # для него строже — публикуется всё содержимое целиком и навсегда.
    ("похоже на ключ доступа",
     r"(?:AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|sk-ant-[A-Za-z0-9_-]{16,}|"
     r"(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{20,}|"
     r"glpat-[A-Za-z0-9_-]{16,}|xox[baprs]-[A-Za-z0-9-]{10,}|"
     r"AIza[0-9A-Za-z_-]{35}|-----BEGIN [A-Z ]*PRIVATE KEY-----)"),

    ("пароль в открытом виде",
     r"(?i)(?:password|passwd|secret|api_?key|token)\s*[:=]\s*"
     r"[\"'](?![^\"']*(?:your|example|xxx|changeme|placeholder|\$\{|<))"
     r"[^\"'\s]{8,}[\"']"),

    ("строка подключения с паролем",
     r"(?i)(?:postgres|postgresql|mysql|mongodb|redis|amqp|https?)://"
     r"[^:@/\s]+:(?!password|пароль|\$|<|\{)[^@/\s]{4,}@"),
]

# Файлы, где совпадение допустимо по самой их природе: страж описывает, что
# ищет; словарь секретов перечисляет форматы ключей; тесты и корпус обязаны
# содержать образцы — без них проверки нечем проверить.
#
# Список именно перечисляет файлы, а не маску каталога: «все тесты разрешены»
# означало бы, что настоящий ключ, случайно вставленный в новый тест, уедет
# в публикацию.
ALLOWLIST = {
    "tests/no-private-data.py",
    "tests/private-patterns.example",
    "tests/test-secrets.sh",
    "tests/test-hooks.sh",
    "tests/hook-corpus.tsv",
    "plugins/std-core/scripts/secret-lib.sh",
    "plugins/std-core/scripts/guard-secrets.sh",
    "plugins/std-core/scripts/precommit-secrets.sh",
}


def load_private_patterns() -> list[tuple[str, str]]:
    """Дополнительные шаблоны организации из файла, который не публикуется.

    Формат: одна регулярка на строку, пустые строки и # — комментарии.
    Отсутствие файла не ошибка: универсальных шаблонов достаточно, чтобы
    поймать типовую утечку.
    """
    if not PRIVATE_PATTERNS_FILE.exists():
        return []
    out: list[tuple[str, str]] = []
    for raw in PRIVATE_PATTERNS_FILE.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        out.append(("внутреннее название из локального списка", line))
    return out


def tracked_files() -> list[str]:
    """Отслеживаемое плюс новое, ещё не добавленное в индекс.

    Раньше проверялось только отслеживаемое, и файл, созданный в этой же
    сессии, страж не видел: `git add -A` перед коммитом добавлял его уже
    после проверки. Утечка проходила бы ровно в том случае, ради которого
    страж и заведён, — в свежем файле.
    """
    try:
        out = subprocess.run(
            ["git", "ls-files", "-z"], cwd=ROOT,
            capture_output=True, text=True, check=True,
        ).stdout
        files = [f for f in out.split("\0") if f]
        new = subprocess.run(
            ["git", "ls-files", "-z", "--others", "--exclude-standard"], cwd=ROOT,
            capture_output=True, text=True, check=True,
        ).stdout
        files += [f for f in new.split("\0") if f]
        return files
    except (subprocess.CalledProcessError, FileNotFoundError):
        skip = {".git", "node_modules", "vendor", ".venv"}
        return [
            str(p.relative_to(ROOT))
            for p in ROOT.rglob("*")
            if p.is_file() and not skip & set(p.relative_to(ROOT).parts)
        ]


def is_stub(reason: str, matched: str) -> bool:
    """Совпадение — заглушка из документации, а не настоящий ключ.

    Проверяются именно символы-заполнители, а не любой повтор: заголовок
    «-----BEGIN RSA PRIVATE KEY-----» состоит из дефисов, и правило «четыре
    одинаковых символа подряд» глушило настоящий приватный ключ. Найдено
    самотестом сразу после того, как фильтр был написан.
    """
    if "ключ" not in reason and "пароль" not in reason:
        return False
    return bool(re.search(r"[xX0*_]{4,}", matched))


def selftest(compiled: list[tuple[str, re.Pattern]]) -> list[str]:
    """Проверка самой проверки: без неё правка шаблона молча выключает охрану.

    Гоняется каждый раз — стоит миллисекунды. Ошибка здесь означает, что
    репозиторий остаётся зелёным, не проверяя того, ради чего страж заведён.
    """
    must_catch = [
        "/home/maxim/projects/thing",
        "/Users/Ivan/work",
        "путь C:\\Users\\Ivan\\Desktop",
        "контакт: me@personal-domain.ru",
        "AKIAIOSFODNN7REALKEYX",
        "token: ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4o5",
        'password = "RealPass12345"',
        "postgres://user:realpw123@db.host/app",
        "-----BEGIN RSA PRIVATE KEY-----",
        "хост build.internal",
        "10.10.5.7",
    ]
    must_pass = [
        "/home/user/project",
        "/home/dev/app",
        "путь ~/.claude/rules",
        "почта someone@example.com",
        "60618599+DanielLetto2020@users.noreply.github.com",
        "token: ghp_xxxxxxxxxxxxxxxxxxxxxxxx",
        'password = "${DB_PASSWORD}"',
        'api_key = "your-key-here"',
        "postgres://user:password@localhost/db",
        "127.0.0.1:8080",
    ]

    def hit(line: str) -> str | None:
        for reason, rx in compiled:
            m = rx.search(line)
            if m:
                if is_stub(reason, m.group(0)):
                    continue
                return reason
        return None

    problems = []
    for line in must_catch:
        if hit(line) is None:
            problems.append(f"самотест: утечка «{line[:40]}» НЕ ловится")
    for line in must_pass:
        r = hit(line)
        if r is not None:
            problems.append(f"самотест: безобидное «{line[:40]}» помечено как «{r}»")
    return problems


def main() -> int:
    extra = load_private_patterns()
    try:
        compiled = [(reason, re.compile(rx)) for reason, rx in PATTERNS + extra]
    except re.error as e:
        print(f"Ошибка в шаблоне из {PRIVATE_PATTERNS_FILE.name}: {e}", file=sys.stderr)
        return 1

    # Самотест гоняется только по универсальным шаблонам: локальные могут
    # совпасть с образцами из набора, и тогда «безобидное» справедливо
    # признаётся утечкой — ошибка была бы не в страже, а в тесте.
    universal = [(reason, rx) for reason, rx in compiled
                 if reason != "внутреннее название из локального списка"]
    findings: list[str] = selftest(universal)
    checked = 0

    for rel in tracked_files():
        if rel in ALLOWLIST:
            continue
        path = ROOT / rel

        for reason, rx in compiled:
            if rx.search(rel):
                findings.append(f"{rel}: имя файла — {reason}")

        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, FileNotFoundError, IsADirectoryError):
            continue
        checked += 1

        for lineno, line in enumerate(text.splitlines(), 1):
            for reason, rx in compiled:
                m = rx.search(line)
                if m:
                    # Заглушка из документации — не находка. Фильтр применяется
                    # только к ключам и паролям: для домена, ФИО и пути «xxxx»
                    # ничего не значит, а строгость там нужнее.
                    if is_stub(reason, m.group(0)):
                        continue
                    # Находку не печатаем целиком: вывод попадает в логи CI,
                    # которые тоже публичны
                    shown = m.group(0)
                    if len(shown) > 20:
                        shown = shown[:20] + "…"
                    findings.append(f"{rel}:{lineno}: {reason} — «{shown}»")

    print("=" * 68)
    print(f"Страж приватных данных: проверено {checked} файлов, "
          f"шаблонов {len(compiled)} "
          f"(универсальных {len(PATTERNS)}, локальных {len(extra)})")
    print("=" * 68)

    if not extra:
        print("  подсказка: свои названия систем и подразделений добавь")
        print("  в tests/.private-patterns — этот файл не публикуется")

    if findings:
        print()
        for f in findings:
            print(f"  УТЕЧКА  {f}")
        print(f"\nПРОВАЛЕНО: найдено совпадений {len(findings)}.")
        print("Публиковать нельзя. Переформулируй обезличенно: техническая суть")
        print("правила остаётся, упоминание организации, людей и внутренних")
        print("систем уходит.")
        return 1

    print("\nOK: внутренних данных не найдено")
    return 0


if __name__ == "__main__":
    sys.exit(main())
