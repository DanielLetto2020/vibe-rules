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
]

# Файлы, где совпадение допустимо: сам страж описывает, что искать.
ALLOWLIST = {"tests/no-private-data.py", "tests/private-patterns.example"}


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
    try:
        out = subprocess.run(
            ["git", "ls-files", "-z"], cwd=ROOT,
            capture_output=True, text=True, check=True,
        ).stdout
        return [f for f in out.split("\0") if f]
    except (subprocess.CalledProcessError, FileNotFoundError):
        skip = {".git", "node_modules", "vendor", ".venv"}
        return [
            str(p.relative_to(ROOT))
            for p in ROOT.rglob("*")
            if p.is_file() and not skip & set(p.relative_to(ROOT).parts)
        ]


def main() -> int:
    extra = load_private_patterns()
    try:
        compiled = [(reason, re.compile(rx)) for reason, rx in PATTERNS + extra]
    except re.error as e:
        print(f"Ошибка в шаблоне из {PRIVATE_PATTERNS_FILE.name}: {e}", file=sys.stderr)
        return 1

    findings: list[str] = []
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
