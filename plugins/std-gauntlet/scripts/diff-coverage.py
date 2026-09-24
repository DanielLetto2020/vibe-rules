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

Коды возврата:
  0 — порог взят или мерить нечего;
  1 — ниже порога;
  3 — проверка не выполнена: нет отчёта, отчёт не про этот проект, не найдена
      точка отсчёта (неглубокий клон), не git-репозиторий.
Код 2 оставлен самому Python — ошибки запуска и аргументов. Раньше «не
проверено» тоже было двойкой, и опечатка в пути к скрипту выглядела как «нет
отчёта»: гейт показывал «не проверено» и прогон не краснел.
"""
from __future__ import annotations

import argparse
import fnmatch
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

# Файлы, которых в отчёте о покрытии не бывает по природе: сами тесты,
# их окружение, объявления типов, конфигурация сборки. Их отсутствие в отчёте
# ни о чём не говорит, и засчитывать их строки непокрытыми — значит валить
# каждую задачу, в которой написан тест.
TEST_DIRS = {"test", "tests", "__tests__", "__mocks__", "spec", "specs", "e2e",
             "cypress", "playwright", "features", "fixtures", "testdata"}
TEST_NAME_RE = re.compile(
    r"(^test_.*\.py$|_test\.(py|go|rb|exs?)$|_spec\.rb$"
    r"|\.(test|spec|cy|stories)\.[^.]+$"
    r"|(Test|Tests|TestCase|Spec)\.(php|java|kt|cs|scala|swift)$"
    r"|^conftest\.py$|^setupTests\.[jt]sx?$"
    r"|\.d\.ts$|\.config\.[cm]?[jt]s$)"
)

# Строка файла, которого нет в отчёте, засчитывается непокрытой, только если
# похожа на код. Пустые строки, комментарии и одинокие скобки не исполняются
# ни в одном отчёте — считать их значило бы завышать долю непокрытого.
TRIVIAL_LINE_RE = re.compile(
    r"^\s*($|#|//|/\*|\*|<!--|-->|[{}()\[\];,]+\s*$|<\?php\s*$|\?>\s*$)"
)

GREEN, RED, YELLOW, OFF = "\033[32m", "\033[31m", "\033[33m", "\033[0m"
NOT_VERIFIED = 3


def run_git(args: list[str], cwd: Path) -> tuple[int, str]:
    """git с настройками, которые не зависят от чужого ~/.gitconfig.

    core.quotepath=off — иначе путь не латиницей приходит в кавычках
    с восьмеричными кодами и выпадает из разбора. Остальное (префиксы, внешние
    diff-программы, textconv) задаётся флагами у самих команд: diff.noprefix
    или diff.mnemonicPrefix у человека в конфиге меняли заголовки файлов,
    и изменённые файлы молча пропадали.
    """
    r = subprocess.run(["git", "-c", "core.quotepath=off", "-c", "color.ui=never", *args],
                       cwd=cwd, capture_output=True,
                       encoding="utf-8", errors="surrogateescape")
    return r.returncode, r.stdout


def git(*args: str, cwd: Path) -> str:
    rc, out = run_git(list(args), cwd)
    return out if rc == 0 else ""


def has_head(cwd: Path) -> bool:
    return bool(git("rev-parse", "--verify", "--quiet", "HEAD", cwd=cwd).strip())


class BaseUnavailable(Exception):
    """Точка отсчёта задана или обнаружена, но из неё не получить диапазон."""


def pick_base(cwd: Path, explicit: str | None) -> str | None:
    """Точка отсчёта: от чего считать «изменённое».

    Ветка сравнивается с общим предком основной ветки, а не с её текущей
    головой: иначе чужие коммиты, приехавшие в main после ответвления,
    попадают в диапазон и гейт требует покрыть чужой код.

    Если основная ветка есть, а общего предка нет, — это не «мерить нечего».
    Так выглядит неглубокий клон в CI (actions/checkout по умолчанию берёт
    глубину 1): раньше гейт тихо переходил на незакоммиченную работу, которой
    в CI нет, и проходил на пустом знаменателе.
    """
    if explicit:
        if not git("rev-parse", "--verify", "--quiet", explicit + "^{commit}", cwd=cwd).strip():
            raise BaseUnavailable(f"точка отсчёта «{explicit}» не найдена в репозитории")
        return explicit
    head = git("rev-parse", "HEAD", cwd=cwd).strip()
    if not head:
        return None
    unreachable: list[str] = []
    for ref in ("origin/main", "origin/master", "main", "master"):
        if not git("rev-parse", "--verify", "--quiet", ref, cwd=cwd).strip():
            continue
        base = git("merge-base", "HEAD", ref, cwd=cwd).strip()
        if not base:
            unreachable.append(ref)
            continue
        # Мы на основной ветке или она нас не обогнала — считаем
        # незакоммиченную работу относительно HEAD.
        return None if base == head else base
    shallow = git("rev-parse", "--is-shallow-repository", cwd=cwd).strip() == "true"
    if unreachable:
        raise BaseUnavailable(
            f"общий предок с {unreachable[0]} не найден"
            + (" — клон неглубокий" if shallow else ""))
    if shallow:
        # Сборка PR в CI: забрана одна ветка на глубину 1, основной нет вовсе.
        # Работа уже закоммичена, «незакоммиченной» нет — знаменатель пуст.
        raise BaseUnavailable("основная ветка не найдена, а клон неглубокий")
    # Основной ветки нет вовсе — считаем незакоммиченную работу.
    return None


def unquote_c(s: str) -> str:
    """Путь в кавычках из вывода git: \\t, \\n, \\", \\\\ и восьмеричные байты.

    С core.quotepath=off кавычки остаются только у путей с управляющими
    символами, кавычкой или обратной косой — но и такие файлы бывают."""
    body = s[1:-1] if len(s) > 1 and s.endswith('"') else s[1:]
    simple = {"t": b"\t", "n": b"\n", "r": b"\r", '"': b'"', "\\": b"\\",
              "a": b"\a", "b": b"\b", "f": b"\f", "v": b"\v"}
    out = bytearray()
    i = 0
    while i < len(body):
        c = body[i]
        if c == "\\" and i + 1 < len(body):
            nxt = body[i + 1]
            if re.match(r"[0-7]{3}", body[i + 1:i + 4]):
                out.append(int(body[i + 1:i + 4], 8) & 0xFF)
                i += 4
                continue
            out += simple.get(nxt, nxt.encode("utf-8", "surrogateescape"))
            i += 2
            continue
        out += c.encode("utf-8", "surrogateescape")
        i += 1
    return out.decode("utf-8", "surrogateescape")


def diff_path(header: str) -> str | None:
    """Путь из строки «+++ b/…» с явно заданным префиксом."""
    raw = header[4:]
    if raw.startswith('"'):
        raw = unquote_c(raw)
    else:
        # Путь с пробелом git завершает табуляцией — для разбора патча.
        raw = raw[:-1] if raw.endswith("\t") else raw
    if raw == "/dev/null":
        return None
    return raw[2:] if raw.startswith("b/") else raw


def changed_lines(cwd: Path, base: str | None) -> dict[str, set[int]]:
    """Изменённые и добавленные строки: файл -> номера строк в новой версии.

    Пути — относительно проекта (--relative): в монорепозитории git иначе
    отдаёт их от корня репозитория (api/src/m.py), отчёт подпроекта — от его
    каталога (src/m.py), и не совпадало ничего.
    """
    if base is None:
        # Незакоммиченная работа — это рабочее дерево против HEAD, а не против
        # индекса: иначе после git add новый файл пропадал из виду. Без единого
        # коммита сравниваем с пустым деревом.
        base = "HEAD" if has_head(cwd) else git("hash-object", "-t", "tree", "/dev/null", cwd=cwd).strip()
    out = git("diff", "--unified=0", "--no-color", "--no-ext-diff", "--no-textconv",
              "--relative", "--src-prefix=a/", "--dst-prefix=b/",
              "--diff-filter=ACMR", base, cwd=cwd)

    result: dict[str, set[int]] = {}
    current: str | None = None
    for line in out.splitlines():
        if line.startswith("+++ "):
            path = diff_path(line)
            current = path if path and Path(path).suffix in SOURCE_SUFFIXES else None
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
    for path in git("ls-files", "-z", "--others", "--exclude-standard", cwd=cwd).split("\0"):
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


def parse_xml(path: Path) -> tuple[dict[str, dict[int, int]], list[str]]:
    """Clover и Cobertura: две схемы, одна на PHP, другая на всё остальное.
    Возвращает файлы и корни <source> (у Cobertura пути файлов — от них).

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
        return files, []
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as e:
        print(f"{RED}отчёт о покрытии не разбирается{OFF}: {path} — {e}", file=sys.stderr)
        return files, []

    sources = [(s.text or "").strip() for s in root.iter("source") if (s.text or "").strip()]

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
    return {k: v for k, v in files.items() if v}, sources


def _is_abs(p: str) -> bool:
    return p.startswith("/") or bool(re.match(r"^[A-Za-z]:/", p))


def _norm(p: str) -> str:
    n = os.path.normpath(p).replace(os.sep, "/")
    return "" if n == "." else n


def _top(p: str) -> str:
    return p.split("/", 1)[0] if "/" in p else ""


class ReportIndex:
    """Пути отчёта, приведённые к путям проекта.

    Раньше сравнивали по хвосту: отчётный путь, оканчивающийся на изменённый.
    Так app.py сопоставлялся с /ci/build/sub/app.py — покрытым, — хотя рядом
    в отчёте был свой /ci/build/app.py, непокрытый. Теперь каждый путь отчёта
    переводится в путь проекта по отдельности: абсолютный внутри проекта —
    напрямую, из чужого контейнера — по самому длинному существующему хвосту,
    относительный — от корней <source>, от проекта, от корня репозитория.
    """

    def __init__(self, cwd: Path, files: dict[str, dict[int, int]], sources: list[str]):
        self.cwd = cwd
        self.toplevel = git("rev-parse", "--show-toplevel", cwd=cwd).strip()
        self.prefix = git("rev-parse", "--show-prefix", cwd=cwd).strip()
        self.roots = self._roots(sources)
        self.used_roots: set[str] = set()
        self._repo_files: list[str] | None = None
        self.lines: dict[str, dict[int, int]] = {}
        for name, lines in files.items():
            rel = self._resolve(name)
            if rel is None:
                continue
            merged = self.lines.setdefault(rel, {})
            for ln, h in lines.items():
                merged[ln] = max(h, merged.get(ln, 0))
        self.tops = {_top(p) for p in self.lines}

    @property
    def mapped(self) -> bool:
        return bool(self.lines)

    def _inside(self, abs_path: str) -> str | None:
        """Абсолютный путь → относительно проекта, если он внутри."""
        rel = os.path.relpath(os.path.realpath(abs_path), str(self.cwd)).replace(os.sep, "/")
        if rel == ".":
            return ""
        return None if rel == ".." or rel.startswith("../") else rel

    def _in_repo(self, abs_path: str) -> bool:
        if not self.toplevel:
            return False
        rel = os.path.relpath(os.path.realpath(abs_path), self.toplevel)
        return rel != ".." and not rel.startswith("../")

    def _strip_prefix(self, rel: str) -> str:
        if self.prefix and rel.startswith(self.prefix):
            return rel[len(self.prefix):]
        return rel

    def _roots(self, sources: list[str]) -> list[str]:
        roots: list[str] = []
        for s in sources:
            s = s.replace("\\", "/").rstrip("/") or "/"
            if _is_abs(s):
                r = self._inside(s)
                if r is None and not self._in_repo(s):
                    # Корень из чужого контейнера (/ci/build/src): ищем самый
                    # длинный его хвост, который есть каталогом в проекте.
                    parts = [x for x in s.split("/") if x and not x.endswith(":")]
                    for i in range(len(parts)):
                        cand = "/".join(parts[i:])
                        if (self.cwd / cand).is_dir():
                            r = cand
                            break
                if r is not None:
                    roots.append(r)
            else:
                roots.append(self._strip_prefix(_norm(s)))
        return roots

    def _longest_suffix(self, path: str) -> str | None:
        parts = [x for x in path.split("/") if x and not x.endswith(":")]
        for i in range(len(parts)):
            cand = "/".join(parts[i:])
            if (self.cwd / cand).is_file():
                return cand
        return None

    def _unique_owner(self, rel: str) -> str | None:
        """Отчётный путь без корня (pkg/old.py) — единственный файл проекта,
        который им оканчивается (src/pkg/old.py). Не единственный — не гадаем."""
        if self._repo_files is None:
            out = git("ls-files", "-z", "--cached", "--others", "--exclude-standard", cwd=self.cwd)
            self._repo_files = [p for p in out.split("\0") if p]
        hits = [p for p in self._repo_files if p.endswith("/" + rel)]
        return hits[0] if len(hits) == 1 else None

    def _resolve(self, name: str) -> str | None:
        n = name.replace("\\", "/")
        if re.match(r"^[A-Za-z]:/", n):
            return self._longest_suffix(n)   # отчёт снят на Windows
        if _is_abs(n):
            rel = self._inside(n)
            if rel is not None:
                return rel
            if self._in_repo(n):
                return None          # соседний подпроект монорепозитория
            return self._longest_suffix(n)
        n = _norm(n)
        for root in self.roots:
            cand = _norm(f"{root}/{n}") if root else n
            if (self.cwd / cand).is_file():
                self.used_roots.add(root)
                return cand
        if (self.cwd / n).is_file():
            return n
        stripped = self._strip_prefix(n)
        if stripped != n and (self.cwd / stripped).is_file():
            return stripped
        return self._unique_owner(n)

    def get(self, path: str) -> dict[int, int] | None:
        return self.lines.get(path)

    def in_scope(self, path: str) -> bool:
        """Отвечает ли отчёт за этот файл.

        Да — если файл под корнем, от которого в отчёте есть измеренные файлы,
        или в том же каталоге верхнего уровня, что и они. Нет — для каталогов,
        которые инструмент покрытия не смотрит вовсе: миграции, маршруты,
        конфиги у PHPUnit с <source><include>app</include>. Считать их строки
        непокрытыми значило бы валить каждую миграцию."""
        for root in self.used_roots:
            if root == "" or path == root or path.startswith(root + "/"):
                return True
        return _top(path) in self.tops


def looks_like_test(path: str) -> bool:
    parts = path.split("/")
    return any(p in TEST_DIRS for p in parts[:-1]) or bool(TEST_NAME_RE.search(parts[-1]))


def code_lines(f: Path, lines: set[int]) -> list[int]:
    try:
        text = f.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []
    return [ln for ln in sorted(lines)
            if 0 < ln <= len(text) and not TRIVIAL_LINE_RE.match(text[ln - 1])]


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
    excludes = cfg.get("exclude") or []
    if isinstance(excludes, str):
        excludes = [excludes]
    if not git("rev-parse", "--git-dir", cwd=cwd):
        print(f"{YELLOW}не git-репозиторий — изменённые строки определить не из чего, покрытие НЕ проверено{OFF}")
        return NOT_VERIFIED

    try:
        base = pick_base(cwd, args.base)
    except BaseUnavailable as e:
        print(f"{YELLOW}{e} — изменённые строки не определить, покрытие НЕ проверено{OFF}")
        print("В CI нужна история до общего предка: actions/checkout → fetch-depth: 0")
        print("(или git fetch --unshallow). Точку отсчёта можно задать явно:")
        print(".claude/gauntlet.json → \"diffCoverage\": { \"base\": \"origin/main\" }")
        return NOT_VERIFIED

    changed = changed_lines(cwd, base)
    changed = {p: ls for p, ls in changed.items()
               if not any(fnmatch.fnmatch(p, g) for g in excludes)}
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
        return NOT_VERIFIED

    if report.suffix == ".info":
        files, sources = parse_lcov(report.read_text(encoding="utf-8", errors="replace")), []
    else:
        files, sources = parse_xml(report)
    if not files:
        print(f"{YELLOW}в отчёте {report} нет данных о строках — проверка не выполнена{OFF}")
        return NOT_VERIFIED
    index = ReportIndex(cwd, files, sources)

    total = covered = 0
    misses: list[str] = []
    absent: list[tuple[str, int]] = []   # файл вне отчёта в его области
    outside: list[str] = []              # файл в каталоге, который отчёт не смотрит
    for path, lines in sorted(changed.items()):
        cov = index.get(path)
        if cov is not None:
            for ln in sorted(lines):
                if ln not in cov:          # строка не исполняемая: комментарий, скобка
                    continue
                total += 1
                if cov[ln] > 0:
                    covered += 1
                elif len(misses) < 15:
                    misses.append(f"{path}:{ln}")
            continue
        if looks_like_test(path):
            continue
        if not index.in_scope(path):
            outside.append(path)
            continue
        # Файла нет в отчёте, хотя соседей инструмент измерил: его не выполнил
        # ни один тест. Раньше такой файл пропускался молча, и новый модуль,
        # который никто не импортирует, давал «проверять нечего».
        code = code_lines(cwd / path, lines)
        if code:
            absent.append((path, len(code)))
            total += len(code)
            for ln in code:
                if len(misses) < 15:
                    misses.append(f"{path}:{ln} (файла нет в отчёте)")

    if total == 0:
        if outside and not index.mapped:
            print(f"{YELLOW}пути в отчёте {report} не сопоставились ни с одним файлом проекта "
                  f"— покрытие НЕ проверено{OFF}")
            print("Изменены: " + ", ".join(outside[:5]) + (" …" if len(outside) > 5 else ""))
            print("Отчёт снят в другом каталоге, устарел или относится к другому проекту.")
            return NOT_VERIFIED
        print("среди изменённых строк нет исполняемых — проверять нечего")
        if outside:
            print("Вне области отчёта (инструмент эти каталоги не измеряет): "
                  + ", ".join(outside[:5]) + (" …" if len(outside) > 5 else ""))
        return 0

    pct = covered / total * 100
    print(f"покрытие изменённых строк: {covered}/{total} = {pct:.0f}% (порог {args.min:.0f}%)")
    if absent:
        print("Нет в отчёте о покрытии — строки засчитаны непокрытыми: "
              + ", ".join(f"{p} ({n})" for p, n in absent[:5]) + (" …" if len(absent) > 5 else ""))
    if outside:
        print("Вне области отчёта, не учитываются: "
              + ", ".join(outside[:5]) + (" …" if len(outside) > 5 else ""))

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
    if absent:
        print()
        print("Файла нет в отчёте, значит его не выполнил ни один тест. Если покрывать")
        print("его не нужно (скрипт сборки, генерируемый код) — это решение человека,")
        print("и записывается оно явно: .claude/gauntlet.json → \"diffCoverage\":")
        print("{ \"exclude\": [\"путь/или/*.маска\"] }")
    return 1


if __name__ == "__main__":
    sys.exit(main())
