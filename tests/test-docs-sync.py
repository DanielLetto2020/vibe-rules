#!/usr/bin/env python3
"""Согласованность документации: между языками и с кодом.

Документация разъезжается быстрее кода: у неё нет прогона, который краснеет.
За четыре дня разошлись обещание автовыбора профиля и его отмена — в одном
файле, через два абзаца. Здесь проверяется то, что можно проверить машиной.

Не проверяется смысл текста: это работа человека. Проверяются связи, которые
обязаны совпадать, и именно они ломаются молча.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GREEN, RED, OFF = "\033[32m", "\033[31m", "\033[0m"

passed = failed = 0


def ok(msg: str) -> None:
    global passed
    print(f"  {GREEN}OK{OFF}   {msg}")
    passed += 1


def bad(msg: str, want, got) -> None:
    global failed
    print(f"  {RED}FAIL{OFF} {msg}\n     ожидали: {want}\n     получили: {got}")
    failed += 1


def read(name: str) -> str:
    return (ROOT / name).read_text(encoding="utf-8")


def table_rows(text: str, start: str, stop: str) -> int:
    """Число строк таблицы между двумя маркерами."""
    inside = False
    rows = 0
    for line in text.split("\n"):
        if start in line:
            inside = True
            continue
        if inside and stop in line:
            break
        if inside and line.startswith("| `"):
            rows += 1
    return rows


print("== число модулей ==")
real_modules = len([p for p in (ROOT / "plugins").iterdir() if p.is_dir()])
for readme in ("README.md", "README.ru.md"):
    text = read(readme)
    badge = re.search(r"badge/(?:modules|[^-]*)-(\d+)-", text)
    if not badge:
        bad(f"{readme}: бейдж с числом модулей", "найден", "нет")
    elif int(badge.group(1)) != real_modules:
        bad(f"{readme}: число модулей в бейдже", real_modules, badge.group(1))
    else:
        ok(f"{readme}: бейдж совпадает с числом модулей ({real_modules})")

print("== границы замков названы на обоих языках и совпадают с корпусом ==")
corpus = (ROOT / "tests" / "hook-corpus.tsv").read_text(encoding="utf-8")
gaps = len([ln for ln in corpus.split("\n") if ln.startswith("gap\t")])

en = table_rows(read("README.md"), "### What the locks do not catch", "The right way")
ru = table_rows(read("README.ru.md"), "### Что замки не ловят", "Как это читать")

if gaps == 0:
    bad("корпус", "хотя бы одна известная граница", 0)
else:
    ok(f"в корпусе перечислено границ: {gaps}")

for lang, rows in (("англ", en), ("рус", ru)):
    if rows == gaps:
        ok(f"таблица границ ({lang}) совпадает с корпусом")
    else:
        bad(f"таблица границ ({lang}) против корпуса",
            f"{gaps} строк", f"{rows} строк")

print("== ключевые утверждения не разъехались ==")
# Формулировка «замок это гарантия» противоречит модели угроз. Она уже была
# исправлена в одном языке и осталась в другом — проверяем оба.
for readme in ("README.md", "README.ru.md"):
    text = read(readme).lower()
    if "no percentage" in text or "у замка нет процента" in text:
        bad(f"{readme}: обещание без оговорок", "формулировка убрана", "осталась")
    else:
        ok(f"{readme}: замок не выдаётся за абсолютную гарантию")

# Профили: в наборе четыре, документация не должна упоминать несуществующие
profiles_json = (ROOT / "plugins" / "std-core" / "profiles" / "profiles.json").read_text()
for ghost in ("regulated", "corporate"):
    where = [f for f in ("README.md", "README.ru.md", "docs/START.md", "docs/START.ru.md",
                         "docs/PROFILES.md", "docs/PROFILES.ru.md")
             if ghost in read(f) and ghost not in profiles_json]
    if where:
        bad(f"профиль '{ghost}' упоминается, но его нет в наборе", "нет упоминаний", ", ".join(where))
    else:
        ok(f"профиля '{ghost}' нет ни в наборе, ни в документации")

print("== парные документы ==")
# Часть документов одноязычная намеренно (внутреннее устройство). Проверяем те,
# у которых пара заявлена: если .ru.md есть, английский обязан существовать.
for ru_doc in sorted((ROOT / "docs").glob("*.ru.md")):
    en_doc = ru_doc.with_name(ru_doc.name.replace(".ru.md", ".md"))
    if not en_doc.exists():
        bad(f"{ru_doc.name}: нет английской пары", en_doc.name, "нет файла")
    else:
        ok(f"{ru_doc.name} и {en_doc.name} — пара на месте")

print()
print(f"Пройдено: {GREEN}{passed}{OFF}   Провалено: {RED if failed else GREEN}{failed}{OFF}")
sys.exit(1 if failed else 0)
