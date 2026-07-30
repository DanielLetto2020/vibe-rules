#!/usr/bin/env python3
"""
diff-coverage.py — покрыты ли тестами строки, изменённые в этой работе.

Зачем отдельно от общего покрытия. Общий процент — плохой гейт: на большом
проекте он двигается на десятые доли и не реагирует на то, что в этой задаче
дописали двести строк без единого теста. Порог по нему либо недостижим, либо
бесполезен — та же болезнь, от которой мутационный гейт лечат храповиком.

Покрытие изменённых строк ведёт себя иначе: оно относится только к новому
коду, поэтому абсолютный порог здесь работает и означает ровно то, что
написано. И считается за секунды — в отличие от мутационного прогона,
это проверка, которую запускают на каждой итерации.

Что оно НЕ значит: покрытая строка — это выполненная строка, а не проверенная.
Ассерты и их качество — предмет мутационного гейта, и одно другого не заменяет.

    diff-coverage.py [--base <ref>] [--min <процент>] [--report <файл>]

Коды возврата: 0 — порог взят или мерить нечего, 1 — ниже порога,
2 — не найден отчёт о покрытии (проверка не выполнена).
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

# Расширения, для которых покрытие вообще имеет смысл. Изменения в разметке,
# конфигурации и документации в знаменатель попадать не должны: иначе правка
# README роняет гейт, и его снимают целиком.
SOURCE_SUFFIXES = {
    ".php", ".py", ".ts", ".tsx", ".js", ".jsx", ".vue", ".go", ".rb",
    ".java", ".kt", ".cs", ".rs", ".scala", ".swift",
}

# Где отчёты лежат по умолчанию у распространённых инструментов.
REPORT_CANDIDATES = [
    "coverage.xml", "clover.xml", "cobertura.xml", "coverage/clover.xml",
    "coverage/cobertura-coverage.xml", "coverage/coverage-final.xml",
    "build/logs/clover.xml", "coverage/lcov.info", "lcov.info",
    "coverage/coverage.xml", ".coverage.xml",
]

GREEN, RED, YELLOW, OFF = "\033[32m", "\033[31m", "\033[33m", "\033[0m"


def git(*args: str, cwd: Path) -> str:
    r = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else ""


def pick_base(cwd: Path, explicit: str | None) -> str | None:
    """Точка отсчёта: от чего считать «изменённое».

    Ветка сравнивается с общим предком основной ветки, а не с её текущей
    головой: иначе чужие коммиты, приехавшие в main после ответвления,
    попадают в диапазон и гейт требует покрыть чужой код.
    """
    if explicit:
        return explicit
    for ref in ("origin/main", "origin/master", "main", "master"):
        if git("rev-parse", "--verify", "--quiet", ref, cwd=cwd).strip():
            base = git("merge-base", "HEAD", ref, cwd=cwd).strip()
            if base and base != git("rev-parse", "HEAD", cwd=cwd).strip():
                return base
    # Ветки нет или мы на ней самой — считаем незакоммиченную работу.
    return None


def changed_lines(cwd: Path, base: str | None) -> dict[str, set[int]]:
    """Изменённые и добавленные строки: файл -> номера строк в новой версии."""
    args = ["diff", "--unified=0", "--no-color", "--diff-filter=ACMR"]
    if base:
        args.append(base)
    out = git(*args, cwd=cwd)

    result: dict[str, set[int]] = {}
    current: str | None = None
    for line in out.splitlines():
        if line.startswith("+++ b/"):
            path = line[6:].strip()
            current = path if Path(path).suffix in SOURCE_SUFFIXES else None
            continue
        if current and line.startswith("@@"):
            m = re.search(r"\+(\d+)(?:,(\d+))?", line)
            if not m:
                continue
            start = int(m.group(1))
            count = int(m.group(2) or 1)
            if count:
                result.setdefault(current, set()).update(range(start, start + count))

    # Файл, ещё не добавленный в индекс, в diff не попадает вовсе. Без этого
    # шага только что написанный и никем не покрытый модуль давал бы 100%:
    # знаменатель пуст, значит «всё покрыто» — худший вид зелёного гейта.
    for path in git("ls-files", "--others", "--exclude-standard", cwd=cwd).splitlines():
        path = path.strip()
        if not path or Path(path).suffix not in SOURCE_SUFFIXES:
            continue
        f = cwd / path
        try:
            n = sum(1 for _ in f.open(encoding="utf-8", errors="replace"))
        except OSError:
            continue
        if n:
            result.setdefault(path, set()).update(range(1, n + 1))

    return {k: v for k, v in result.items() if v}


def find_report(cwd: Path, explicit: str | None) -> Path | None:
    if explicit:
        p = (cwd / explicit) if not os.path.isabs(explicit) else Path(explicit)
        return p if p.is_file() else None
    for cand in REPORT_CANDIDATES:
        p = cwd / cand
        if p.is_file():
            return p
    return None


def parse_lcov(text: str) -> dict[str, dict[int, int]]:
    """LCOV: SF:<файл> … DA:<строка>,<попаданий>."""
    files: dict[str, dict[int, int]] = {}
    current: str | None = None
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("SF:"):
            current = line[3:]
            files.setdefault(current, {})
        elif line.startswith("DA:") and current:
            try:
                num, hits = line[3:].split(",")[:2]
                files[current][int(num)] = int(float(hits))
            except ValueError:
                continue
        elif line == "end_of_record":
            current = None
    return files


def parse_xml(path: Path) -> dict[str, dict[int, int]]:
    """Clover и Cobertura: две схемы, одна на PHP, другая на всё остальное.

    Отчёт с объявлением DTD не разбирается вовсе. Разборщик из стандартной
    библиотеки внешние сущности не подставляет, но объявленные внутри могут
    раскрываться рекурсивно и съесть память — а отчёт о покрытии приезжает
    и артефактом чужой сборки. Защита от этого в stdlib нет, ставить ради
    неё пакет нельзя (прогон обязан идти на голой машине), и цена отказа
    здесь нулевая: ни один инструмент покрытия DTD в отчёт не пишет.
    """
    files: dict[str, dict[int, int]] = {}
    head = path.read_bytes()[:8192].upper()
    if b"<!DOCTYPE" in head or b"<!ENTITY" in head:
        print(f"{RED}отчёт {path} содержит объявление DTD — не разбирается{OFF}", file=sys.stderr)
        print("Отчёты о покрытии DTD не содержат; такой файл выглядит подменённым.", file=sys.stderr)
        return files
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as e:
        print(f"{RED}отчёт о покрытии не разбирается{OFF}: {path} — {e}", file=sys.stderr)
        return files

    # Clover: <file name="..."><line num="12" type="stmt" count="3"/>
    for f in root.iter("file"):
        name = f.get("name") or f.get("path")
        if not name:
            continue
        lines = files.setdefault(name, {})
        for ln in f.iter("line"):
            num = ln.get("num") or ln.get("number")
            hits = ln.get("count") or ln.get("hits")
            if num is None or hits is None:
                continue
            # Строки-объявления класса и метода исполняемыми не считаются:
            # они «покрываются» самим фактом загрузки файла и завышают цифру.
            if (ln.get("type") or "stmt") not in ("stmt", "cond", "method"):
                continue
            if ln.get("type") == "method":
                continue
            try:
                lines[int(num)] = int(float(hits))
            except ValueError:
                continue

    # Cobertura: <class filename="..."><lines><line number="12" hits="0"/>
    for c in root.iter("class"):
        name = c.get("filename")
        if not name:
            continue
        lines = files.setdefault(name, {})
        for ln in c.iter("line"):
            num, hits = ln.get("number"), ln.get("hits")
            if num is None or hits is None:
                continue
            try:
                lines[int(num)] = int(float(hits))
            except ValueError:
                continue
    return {k: v for k, v in files.items() if v}


def match_file(changed: str, report_files: dict[str, dict[int, int]]) -> dict[int, int] | None:
    """Сопоставление путей: в отчётах они бывают абсолютные, относительные
    и с префиксом контейнера, в котором шёл прогон."""
    if changed in report_files:
        return report_files[changed]
    norm = changed.lstrip("./")
    for name, lines in report_files.items():
        n = name.replace("\\", "/")
        if n.endswith("/" + norm) or n == norm or n.lstrip("./") == norm:
            return lines
    return None


def load_cfg(cwd: Path) -> dict:
    """Настройки живут там же, где остальные гейты, — .claude/gauntlet.json.
    Отдельный файл настроек для одного гейта означал бы, что часть конфигурации
    проекта лежит не там, где её ищут."""
    import json
    f = cwd / ".claude" / "gauntlet.json"
    if not f.is_file():
        return {}
    try:
        data = json.loads(f.read_text(encoding="utf-8"))
    except (ValueError, OSError):
        return {}
    cfg = data.get("diffCoverage")
    return cfg if isinstance(cfg, dict) else {}


def main() -> int:
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--base", default=None, help="ref для сравнения (по умолчанию — общий предок с основной веткой)")
    ap.add_argument("--min", type=float, default=None)
    ap.add_argument("--report", default=os.environ.get("DIFF_COV_REPORT"))
    ap.add_argument("--project", default=os.environ.get("CLAUDE_PROJECT_DIR", "."))
    args = ap.parse_args()

    cwd = Path(args.project).resolve()

    # Приоритет: аргумент команды, затем переменная окружения, затем конфиг
    # проекта, затем умолчание. Порядок обычный — частное важнее общего.
    cfg = load_cfg(cwd)
    if args.min is None:
        env_min = os.environ.get("DIFF_COV_MIN")
        args.min = float(env_min) if env_min else float(cfg.get("min", 80))
    if args.report is None and cfg.get("report"):
        args.report = str(cfg["report"])
    if args.base is None and cfg.get("base"):
        args.base = str(cfg["base"])
    if not (cwd / ".git").exists() and not git("rev-parse", "--git-dir", cwd=cwd):
        print("не git-репозиторий — изменённые строки определить не из чего")
        return 0

    base = pick_base(cwd, args.base)
    changed = changed_lines(cwd, base)
    if not changed:
        print("изменённых строк в исходниках нет — проверять нечего")
        return 0

    report = find_report(cwd, args.report)
    if report is None:
        # Молчаливый успех здесь означал бы «покрытие в порядке», хотя его
        # никто не мерил. Гейт обязан отличать «хорошо» от «не проверено».
        print(f"{YELLOW}отчёт о покрытии не найден — покрытие изменённых строк НЕ проверено{OFF}")
        print("Ожидались: " + ", ".join(REPORT_CANDIDATES[:5]) + " …")
        print("Прогони тесты с отчётом (например, --coverage-clover coverage.xml)")
        print("или укажи путь: .claude/gauntlet.json → \"diffCoverage\": { \"report\": \"…\" }")
        return 2

    text = report.read_text(encoding="utf-8", errors="replace")
    report_files = parse_lcov(text) if report.suffix == ".info" else parse_xml(report)
    if not report_files:
        print(f"{YELLOW}в отчёте {report} нет данных о строках — проверка не выполнена{OFF}")
        return 2

    total = covered = 0
    misses: list[str] = []
    for path, lines in sorted(changed.items()):
        cov = match_file(path, report_files)
        if cov is None:
            continue
        for ln in sorted(lines):
            if ln not in cov:          # строка не исполняемая: комментарий, скобка
                continue
            total += 1
            if cov[ln] > 0:
                covered += 1
            elif len(misses) < 15:
                misses.append(f"{path}:{ln}")

    if total == 0:
        print("среди изменённых строк нет исполняемых — проверять нечего")
        return 0

    pct = covered / total * 100
    print(f"покрытие изменённых строк: {covered}/{total} = {pct:.0f}% (порог {args.min:.0f}%)")

    if pct + 1e-9 >= args.min:
        print(f"{GREEN}пройден{OFF}")
        return 0

    print(f"{RED}ниже порога{OFF}. Не покрыты тестами:")
    for m in misses:
        print(f"  {m}")
    if total - covered > len(misses):
        print(f"  … и ещё {total - covered - len(misses)}")
    print()
    print("Это строки, которые написаны в этой работе и не выполняются ни одним")
    print("тестом. Покрытая строка ещё не значит проверенная — но непокрытая")
    print("значит непроверенная наверняка.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
