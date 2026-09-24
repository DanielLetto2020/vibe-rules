#!/usr/bin/env python3
"""Прогон корпуса замка на Bash: обходы, ложные срабатывания, известные границы.

Отдельно от test-hooks.sh намеренно. Там проверяется, что каждый замок вообще
работает; здесь — что он не протекает на переписанной форме той же команды
и не срабатывает на безобидной. Первое ловит регрессии, второе — раздражение,
из-за которого замки отключают целиком.

Доля ложных срабатываний печатается числом: правило, которое мешает работать,
снимают вместе со всеми остальными, поэтому цифру надо видеть, а не угадывать.

Каждая строка deny прогоняется дважды: второй раз — в проекте с выключенными
вопросами (.claude/std-hooks-off). Маркер обязан глушить вопросы и не трогать
запреты; раньше `bash -e -c "rm -rf /etc"` при маркере уходил в бесконечную
рекурсию и падал без решения — то есть команда выполнялась.

Окружение фиксировано: свой HOME и свой каталог проекта во временном каталоге.
Зоны удаления считаются от них, и без этого `rm -rf ./../..` давал запрет на
одной машине и вопрос на другой — в зависимости от того, где лежит клон.

Зависимостей нет: ни jq, ни bash-специфики. Тест обязан идти на чужой машине.
"""
import atexit
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GUARD = ROOT / "plugins" / "std-core" / "scripts" / "guard-bash.sh"
CORPUS = ROOT / "tests" / "hook-corpus.tsv"

GREEN, RED, YELLOW, DIM, OFF = "\033[32m", "\033[31m", "\033[33m", "\033[2m", "\033[0m"

SANDBOX = Path(tempfile.mkdtemp(prefix="hook-corpus-"))
HOME = SANDBOX / "home" / "dev"
PROJECT = HOME / "proj"
PROJECT_OFF = HOME / "proj-off"
for d in (PROJECT, PROJECT_OFF / ".claude"):
    d.mkdir(parents=True, exist_ok=True)
(PROJECT_OFF / ".claude" / "std-hooks-off").touch()
atexit.register(shutil.rmtree, SANDBOX, ignore_errors=True)


def decision(command: str, project: Path = PROJECT) -> str:
    payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": command}})
    env = dict(os.environ, HOME=str(HOME), CLAUDE_PROJECT_DIR=str(project))
    proc = subprocess.run(
        ["bash", str(GUARD)], input=payload, capture_output=True, text=True,
        timeout=30, env=env, cwd=project,
    )
    out = proc.stdout.strip()
    if not out:
        return "pass"
    try:
        return json.loads(out)["hookSpecificOutput"]["permissionDecision"]
    except (ValueError, KeyError):
        return f"мусор на выходе: {out[:60]}"


def unescape(field: str) -> str:
    """\\t — табуляция, \\n — перевод строки, \\\\ — сам обратный слэш.

    Файл разделён табами и строками, поэтому оба символа внутри команды
    записываются экранированными. Кейсы с ними нужны: на табуляции замок
    протекал, а многострочные команды (heredoc, перенос через обратный слэш)
    давали и протечки, и ложные запреты.
    """
    out, i = [], 0
    while i < len(field):
        c = field[i]
        if c == "\\" and i + 1 < len(field) and field[i + 1] in "tn\\":
            out.append({"t": "\t", "n": "\n", "\\": "\\"}[field[i + 1]])
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def load_cases():
    for num, raw in enumerate(CORPUS.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = raw.split("\t")
        if len(parts) < 3:
            print(f"  {RED}ОШИБКА{OFF} строка {num}: нужно три поля через табуляцию")
            sys.exit(1)
        yield parts[0].strip(), unescape(parts[1]), parts[2].strip()


def main() -> int:
    if not GUARD.exists():
        print(f"  {RED}FAIL{OFF} не найден {GUARD}")
        return 1

    passed = failed = 0
    false_positives = []   # безобидное, которое заблокировали
    leaks = []             # опасное, которое прошло
    off_leaks = []         # запрет, который снял выключатель вопросов
    gaps = []              # признанные границы

    for want, command, note in load_cases():
        got = decision(command)
        # Известная граница: ожидаем, что не поймаем. Если вдруг поймали —
        # это не ошибка, а повод перевести строку в deny/ask и убрать из README.
        if want == "gap":
            gaps.append((command, note, got))
            if got == "pass":
                passed += 1
            else:
                print(f"  {YELLOW}ГРАНИЦА ЗАКРЫЛАСЬ{OFF} «{command}» теперь {got} — "
                      f"переведи строку корпуса в {got} и убери из таблицы README")
                passed += 1
            continue

        if got == want and want == "deny":
            # Запрет обязан пережить выключатель вопросов
            got = decision(command, PROJECT_OFF)
            if got != "deny":
                failed += 1
                off_leaks.append(command)
                print(f"  {RED}FAIL{OFF} {note} — при std-hooks-off\n     команда:  {command}\n"
                      f"     ожидали:  deny\n     получили: {got}")
                continue

        if got == want:
            passed += 1
            continue

        failed += 1
        print(f"  {RED}FAIL{OFF} {note}\n     команда:  {command}\n"
              f"     ожидали:  {want}\n     получили: {got}")
        if want == "pass":
            false_positives.append(command)
        elif got == "pass":
            leaks.append(command)

    total = passed + failed
    real = [c for w, c, _ in load_cases() if w in ("deny", "ask")]
    benign = [c for w, c, _ in load_cases() if w == "pass"]

    print()
    print(f"  Кейсов: {total}   опасных: {len(real)}   безобидных: {len(benign)}   "
          f"известных границ: {len(gaps)}")
    if benign:
        fp_rate = len(false_positives) / len(benign) * 100
        colour = GREEN if not false_positives else RED
        print(f"  Ложных срабатываний: {colour}{len(false_positives)}/{len(benign)} "
              f"({fp_rate:.0f}%){OFF} — замок, который мешает работать, отключают целиком")
    if leaks:
        print(f"  {RED}Протечек: {len(leaks)}{OFF}")
    if off_leaks:
        print(f"  {RED}Запретов, снятых выключателем вопросов: {len(off_leaks)}{OFF}")

    print(f"\n  Пройдено: {GREEN}{passed}{OFF}   Провалено: "
          f"{RED if failed else GREEN}{failed}{OFF}")
    if gaps:
        print(f"  {DIM}Границы названы вслух — README, раздел «что замки не ловят»{OFF}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
