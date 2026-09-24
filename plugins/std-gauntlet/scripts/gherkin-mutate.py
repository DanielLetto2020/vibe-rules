#!/usr/bin/env python3
"""
gherkin-mutate.py — мутация данных в спецификации.

Отличается от мутационного тестирования кода. Там портят исходники и смотрят,
заметят ли тесты. Здесь портят **значения в примерах спецификации** и смотрят
на то же самое.

Зачем это отдельно. Тест может убивать всех мутантов кода и при этом не быть
связанным со спецификацией: он проверяет собственные захардкоженные значения,
а не те, что написаны в сценарии. Такой тест зеленеет при любой правке
требования — то есть охраняет не то, что заказано.

Проверка простая: меняем в сценарии «заказ на 1500» на «заказ на 1501».
Если тест остался зелёным — он этих данных не читает. Спецификация и тест
разошлись, и никто об этом не узнает.

    gherkin-mutate.py --features features/ --run "vendor/bin/behat"
    gherkin-mutate.py --dry-run          показать мутации, не запуская тесты
    gherkin-mutate.py --json             машинный вывод для гейта

Коды возврата: 0 — все мутанты убиты, 1 — есть выжившие, 2 — ошибка запуска.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import signal
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

# Строки Gherkin, в которых имеет смысл искать данные. Заголовки и описания
# пропускаем: там значений нет, а правка сломает разбор.
STEP_RE = re.compile(
    r"^\s*(Given|When|Then|And|But|Дано|Когда|Тогда|И|Но|Если|То)\s+",
    re.IGNORECASE,
)
TABLE_ROW_RE = re.compile(r"^\s*\|.*\|\s*$")

# Что портим и на что. Значения подобраны так, чтобы изменение было
# наблюдаемым: сдвиг на единицу ловит границы, ноль ловит пустой случай.
NUMBER_RE = re.compile(r"(?<![\w.])(\d+(?:[.,]\d+)?)(?![\w.])")
QUOTED_RE = re.compile(r'"([^"]{1,60})"|«([^»]{1,60})»')

# Копия исходника на время мутации лежит рядом с файлом, а не во временном
# каталоге: SIGKILL не перехватить, и следующий запуск должен найти, что
# вернуть на место. Расширение не .feature — раннер сценариев её не подхватит.
BACKUP_SUFFIX = ".gherkin-mutate-orig"


@dataclass
class Mutation:
    file: str
    line_no: int
    original: str
    mutated: str
    kind: str
    survived: bool | None = None

    @property
    def where(self) -> str:
        return f"{self.file}:{self.line_no}"


@dataclass
class Report:
    mutations: list[Mutation] = field(default_factory=list)

    @property
    def killed(self) -> int:
        return sum(1 for m in self.mutations if m.survived is False)

    @property
    def survived(self) -> list[Mutation]:
        return [m for m in self.mutations if m.survived is True]

    @property
    def score(self) -> int:
        done = [m for m in self.mutations if m.survived is not None]
        if not done:
            return 100
        return round(self.killed / len(done) * 100)


def mutate_number(text: str) -> list[tuple[str, str]]:
    """Каждое число строки → соседнее и → ноль. Сдвиг на единицу ловит ошибки
    на границе.

    Каждое, а не первое: в строке примеров «| 1000 | 900 |» вторая колонка —
    ожидаемый результат, и раньше она не портилась никогда. Тест, который
    читал из примера сумму заказа, а итог держал в себе, получал 100%."""
    out = []
    for m in NUMBER_RE.finditer(text):
        raw = m.group(1)
        sep = "," if "," in raw else "."
        try:
            if sep in raw:
                val = float(raw.replace(",", "."))
                shifted = f"{val + 1:.2f}".replace(".", sep)
            else:
                val = int(raw)
                shifted = str(val + 1)
        except ValueError:
            continue
        out.append((text[: m.start(1)] + shifted + text[m.end(1) :], "число сдвинуто"))
        if raw not in ("0", "0.0", "0,0"):
            zero = "0" + (f"{sep}00" if sep in raw else "")
            out.append((text[: m.start(1)] + zero + text[m.end(1) :], "число обнулено"))
    return out


def mutate_quoted(text: str) -> list[tuple[str, str]]:
    """Каждое значение в кавычках → заведомо другое."""
    out = []
    for m in QUOTED_RE.finditer(text):
        val = m.group(1) if m.group(1) is not None else m.group(2)
        if not val.strip():
            continue
        replaced = "ЗАВЕДОМО-ДРУГОЕ" if any(c.isalpha() and ord(c) > 127 for c in val) else "DEFINITELY-OTHER"
        start, end = (m.start(1), m.end(1)) if m.group(1) is not None else (m.start(2), m.end(2))
        out.append((text[:start] + replaced + text[end:], "значение подменено"))
    return out


def collect(features: Path) -> list[tuple[Path, int, str, str, str]]:
    """Находит строки-кандидаты и готовит для каждой варианты порчи."""
    found: list[tuple[Path, int, str, str, str]] = []
    files = sorted(features.rglob("*.feature")) if features.is_dir() else [features]
    for f in files:
        try:
            lines = f.read_text(encoding="utf-8").splitlines()
        except (UnicodeDecodeError, OSError):
            continue
        for i, line in enumerate(lines, 1):
            if not (STEP_RE.match(line) or TABLE_ROW_RE.match(line)):
                continue
            for mutated, kind in mutate_number(line) + mutate_quoted(line):
                if mutated != line:
                    found.append((f, i, line, mutated, kind))
    return found


def restore_leftovers(features: Path) -> list[Path]:
    """Возвращает на место спецификации, оставшиеся испорченными после
    прогона, убитого без возможности прибраться (SIGKILL, выключение)."""
    root = features if features.is_dir() else features.parent
    restored = []
    for b in sorted(root.rglob("*" + BACKUP_SUFFIX)):
        orig = b.with_name(b.name[: -len(BACKUP_SUFFIX)])
        shutil.copy2(b, orig)
        b.unlink()
        restored.append(orig)
    return restored


# SIGTERM (так Bash-инструмент останавливает команду по таймауту) и SIGHUP
# по умолчанию убивают процесс, не выполнив finally, — и спецификация
# оставалась испорченной: «Дано заказ на 1001 рублей». Сигнал превращается
# в обычный выход; пока файл восстанавливается, он откладывается.
_restoring = False
_pending: list[int] = []


def _on_signal(signum, _frame):
    if _restoring:
        _pending.append(signum)
        return
    raise SystemExit(128 + signum)


def install_signal_handlers() -> None:
    for name in ("SIGTERM", "SIGHUP"):
        sig = getattr(signal, name, None)
        if sig is not None:
            signal.signal(sig, _on_signal)


def run_tests(cmd: str, cwd: Path, timeout: int) -> bool:
    """True — тесты зелёные.

    shell=True здесь намеренно: команда прогона задаётся владельцем проекта
    в его же конфигурации и может быть составной — `make test && npm test`,
    `vendor/bin/behat --tags=@smoke`. Это конфигурация, а не пользовательский
    ввод: тот, кто её пишет, и так может выполнить что угодно в своей оболочке.
    Так же работают остальные гейты.
    """
    try:
        r = subprocess.run(cmd, shell=True, cwd=cwd, timeout=timeout,  # noqa: S602
                           capture_output=True, text=True)
        return r.returncode == 0
    except subprocess.TimeoutExpired:
        # Зависший прогон считаем красным: мутация что-то сломала настолько,
        # что тесты не завершились — значит она замечена
        return False
    except OSError:
        return False


def main() -> int:
    global _restoring
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--features", default="features", help="файл или каталог .feature")
    ap.add_argument("--run", default="", help="команда прогона тестов")
    ap.add_argument("--timeout", type=int, default=300)
    ap.add_argument("--limit", type=int, default=40, help="сколько мутаций максимум")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    features = Path(args.features)
    if not features.exists():
        print(f"нет спецификаций: {features}", file=sys.stderr)
        return 2

    install_signal_handlers()
    for f in restore_leftovers(features):
        print(f"восстановлена спецификация после прерванного прогона: {f}", file=sys.stderr)

    candidates = collect(features)
    if not candidates:
        print("в спецификациях не нашлось значений для порчи.")
        print("Мутация данных работает там, где в сценариях есть конкретные")
        print("числа и значения в кавычках. «Дано корректный заказ» портить нечем —")
        print("и, кстати, такой сценарий ничего толком не проверяет.")
        return 0

    # Ограничение осознанное: каждая мутация — полный прогон тестов.
    # Лучше проверить сорок мест за приемлемое время, чем не проверить ничего.
    truncated = len(candidates) > args.limit
    if truncated:
        candidates = candidates[: args.limit]

    report = Report()

    if args.dry_run:
        for f, ln, orig, mut, kind in candidates:
            report.mutations.append(Mutation(str(f), ln, orig.strip(), mut.strip(), kind))
        if args.json:
            print(json.dumps({"mutations": [m.__dict__ for m in report.mutations]},
                             ensure_ascii=False, indent=2))
        else:
            print(f"Нашлось мутаций: {len(report.mutations)}"
                  + (f" (показаны первые {args.limit})" if truncated else ""))
            for m in report.mutations:
                print(f"\n  {m.where}  [{m.kind}]")
                print(f"    было:  {m.original}")
                print(f"    стало: {m.mutated}")
        return 0

    if not args.run:
        print("нужна команда прогона: --run \"vendor/bin/behat\"", file=sys.stderr)
        return 2

    cwd = Path.cwd()

    # Базовый прогон: если тесты красные до всякой мутации, результат
    # бессмыслен — любая мутация «убита» по причине, не связанной с ней
    if not run_tests(args.run, cwd, args.timeout):
        print("тесты красные до мутаций — сначала почини их", file=sys.stderr)
        return 2

    for idx, (f, ln, orig, mut, kind) in enumerate(candidates, 1):
        backup = f.with_name(f.name + BACKUP_SUFFIX)
        shutil.copy2(f, backup)
        try:
            lines = f.read_text(encoding="utf-8").splitlines(keepends=True)
            ending = "\n" if lines[ln - 1].endswith("\n") else ""
            lines[ln - 1] = mut + ending
            f.write_text("".join(lines), encoding="utf-8")

            green = run_tests(args.run, cwd, args.timeout)
            m = Mutation(str(f), ln, orig.strip(), mut.strip(), kind, survived=green)
            report.mutations.append(m)
            if not args.json:
                mark = "\033[31mВЫЖИЛ\033[0m" if green else "\033[32mубит\033[0m"
                print(f"  [{idx}/{len(candidates)}] {mark}  {m.where}  {kind}")
        finally:
            _restoring = True
            shutil.copy2(backup, f)
            backup.unlink()
            _restoring = False
            if _pending:
                raise SystemExit(128 + _pending[0])

    if args.json:
        print(json.dumps({
            "score": report.score,
            "killed": report.killed,
            "total": len(report.mutations),
            "truncated": truncated,
            "survived": [{"where": m.where, "kind": m.kind,
                          "original": m.original, "mutated": m.mutated}
                         for m in report.survived],
        }, ensure_ascii=False, indent=2))
    else:
        print()
        print("=" * 62)
        print(f"Мутация данных: убито {report.killed} из {len(report.mutations)} "
              f"(score {report.score}%)")
        if truncated:
            print(f"Проверены первые {args.limit} мутаций — остальные пропущены.")
        print("=" * 62)
        if report.survived:
            print("\nВыжившие мутанты — тесты не читают эти значения:\n")
            for m in report.survived:
                print(f"  {m.where}  [{m.kind}]")
                print(f"    было:  {m.original}")
                print(f"    стало: {m.mutated}")
            print("\nЗначит тест проверяет собственные захардкоженные данные,")
            print("а не те, что записаны в сценарии. Правка требования такой тест")
            print("не заденет — он охраняет не то, что заказано.")

    return 1 if report.survived else 0


if __name__ == "__main__":
    sys.exit(main())
