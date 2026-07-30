#!/usr/bin/env python3
"""Согласованность документации: внутри себя и с кодом.

Документация разъезжается быстрее кода: у неё нет прогона, который краснеет.
За четыре дня разошлись обещание автовыбора профиля и его отмена — в одном
файле, через два абзаца. Здесь проверяется то, что можно проверить машиной.

Не проверяется смысл текста: это работа человека. Проверяются связи, которые
обязаны совпадать, и именно они ломаются молча.

Документация одноязычная — русская. Английские версии убраны вместе с расчётом
на внешнюю аудиторию: две версии одного текста расходятся на второй же правке,
и расходятся незаметно. Проверка следит, чтобы второй язык не завёлся снова.
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
badge = re.search(r"badge/(?:modules|[^-]*)-(\d+)-", read("README.md"))
if not badge:
    bad("README.md: бейдж с числом модулей", "найден", "нет")
elif int(badge.group(1)) != real_modules:
    bad("README.md: число модулей в бейдже", real_modules, badge.group(1))
else:
    ok(f"README.md: бейдж совпадает с числом модулей ({real_modules})")

print("== границы замков названы и совпадают с корпусом ==")
corpus = (ROOT / "tests" / "hook-corpus.tsv").read_text(encoding="utf-8")
gaps = len([ln for ln in corpus.split("\n") if ln.startswith("gap\t")])
rows = table_rows(read("README.md"), "### Что замки не ловят", "Как это читать")

if gaps == 0:
    bad("корпус", "хотя бы одна известная граница", 0)
else:
    ok(f"в корпусе перечислено границ: {gaps}")

if rows == gaps:
    ok("таблица границ совпадает с корпусом")
else:
    bad("таблица границ против корпуса", f"{gaps} строк", f"{rows} строк")

print("== ключевые утверждения не разъехались ==")
# Формулировка «у замка нет процента» противоречит модели угроз: замок
# закрывает забывчивость, а не намерение, и обещать больше нельзя.
if "у замка нет процента" in read("README.md").lower():
    bad("README.md: обещание без оговорок", "формулировка убрана", "осталась")
else:
    ok("README.md: замок не выдаётся за абсолютную гарантию")

profiles_json = (ROOT / "plugins" / "std-core" / "profiles" / "profiles.json").read_text()
for ghost in ("regulated", "corporate"):
    where = [f for f in ("README.md", "docs/START.md", "docs/PROFILES.md")
             if ghost in read(f) and ghost not in profiles_json]
    if where:
        bad(f"профиль '{ghost}' упоминается, но его нет в наборе", "нет упоминаний", ", ".join(where))
    else:
        ok(f"профиля '{ghost}' нет ни в наборе, ни в документации")

print("== документация одноязычная ==")
ru_dupes = sorted(str(p.relative_to(ROOT)) for p in ROOT.rglob("*.ru.md") if ".git" not in str(p))
if ru_dupes:
    bad("файлы с языковым суффиксом", "нет", ", ".join(ru_dupes))
else:
    ok("файлов *.ru.md не осталось")

lang_marks = []
for p in sorted(ROOT.rglob("*.md")):
    if ".git" in str(p) or "sandbox" in str(p):
        continue
    body = p.read_text(encoding="utf-8")
    if "English version" in body or "Русская версия" in body:
        lang_marks.append(str(p.relative_to(ROOT)))
if lang_marks:
    bad("плашки переключения языка", "нет", ", ".join(lang_marks))
else:
    ok("плашек переключения языка не осталось")

print("== ссылки ведут на существующие файлы ==")
# Массовое переименование ломает ссылки бесшумно: страница открывается,
# ссылка ведёт в никуда, и узнаёт об этом только читатель.
broken = []
link_rx = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")
for p in sorted(ROOT.rglob("*.md")):
    rel = p.relative_to(ROOT)
    if ".git" in str(p) or "sandbox" in str(p) or str(rel) == "CLAUDE.md":
        continue
    for m in link_rx.finditer(p.read_text(encoding="utf-8")):
        target = m.group(1)
        if target.startswith(("http://", "https://", "mailto:", "#")):
            continue
        path_part = target.split("#", 1)[0]
        if not path_part:
            continue
        if not (p.parent / path_part).exists():
            broken.append(f"{rel} → {target}")

if broken:
    for b in broken[:12]:
        bad("битая ссылка", "существующий файл", b)
else:
    ok("битых относительных ссылок нет")

print()
print(f"Пройдено: {GREEN}{passed}{OFF}   Провалено: {RED if failed else GREEN}{failed}{OFF}")
sys.exit(1 if failed else 0)
