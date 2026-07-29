#!/usr/bin/env python3
"""Прогон корпуса замка на Bash: обходы, ложные срабатывания, известные границы.

Отдельно от test-hooks.sh намеренно. Там проверяется, что каждый замок вообще
работает; здесь — что он не протекает на переписанной форме той же команды
и не срабатывает на безобидной. Первое ловит регрессии, второе — раздражение,
из-за которого замки отключают целиком.

Доля ложных срабатываний печатается числом: правило, которое мешает работать,
снимают вместе со всеми остальными, поэтому цифру надо видеть, а не угадывать.

Зависимостей нет: ни jq, ни bash-специфики. Тест обязан идти на чужой машине.
"""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GUARD = ROOT / "plugins" / "std-core" / "scripts" / "guard-bash.sh"
CORPUS = ROOT / "tests" / "hook-corpus.tsv"

GREEN, RED, YELLOW, DIM, OFF = "\033[32m", "\033[31m", "\033[33m", "\033[2m", "\033[0m"


def decision(command: str) -> str:
    payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": command}})
    proc = subprocess.run(
        ["bash", str(GUARD)], input=payload, capture_output=True, text=True, timeout=30
    )
    out = proc.stdout.strip()
    if not out:
        return "pass"
    try:
        return json.loads(out)["hookSpecificOutput"]["permissionDecision"]
    except (ValueError, KeyError):
        return f"мусор на выходе: {out[:60]}"


def load_cases():
    for num, raw in enumerate(CORPUS.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = raw.split("\t")
        if len(parts) < 3:
            print(f"  {RED}ОШИБКА{OFF} строка {num}: нужно три поля через табуляцию")
            sys.exit(1)
        # Табуляция внутри команды записывается как \t: сам файл разделён
        # табами, и настоящий символ разъехался бы по полям. Кейс с табами
        # нужен — на нём замок протекал.
        command = parts[1].replace("\\t", "\t")
        yield parts[0].strip(), command, parts[2].strip()


def main() -> int:
    if not GUARD.exists():
        print(f"  {RED}FAIL{OFF} не найден {GUARD}")
        return 1

    passed = failed = 0
    false_positives = []   # безобидное, которое заблокировали
    leaks = []             # опасное, которое прошло
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

    print(f"\n  Пройдено: {GREEN}{passed}{OFF}   Провалено: "
          f"{RED if failed else GREEN}{failed}{OFF}")
    if gaps:
        print(f"  {DIM}Границы названы вслух — README, раздел «что замки не ловят»{OFF}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
