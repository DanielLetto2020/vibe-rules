#!/usr/bin/env python3
"""Фаззинг разбора команд в guard-bash.sh.

Корпус (hook-corpus.tsv) проверяет то, что мы придумали заранее. Здесь
проверяются свойства, которые обязаны держаться на командах, которых никто
не писал: разбор shell вручную — критический путь, и ошибка в нём выглядит
как работающий замок.

Проверяемые свойства:

  1. Не падает      — код возврата 0, на stdout либо валидный JSON, либо пусто.
  2. Не зависает    — укладывается в таймаут.
  3. Не пропускает  — разрушающая команда в любой обёртке не получает «pass».
  4. Не мешает      — безобидная команда в любой обёртке не получает «deny».

Генерация детерминированная (фиксированное зерно): падение обязано
воспроизводиться, иначе его нельзя чинить. Зерно можно задать аргументом.

  tests/fuzz-guard-bash.py [число кейсов] [зерно]
"""
import json
import random
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GUARD = ROOT / "plugins" / "std-core" / "scripts" / "guard-bash.sh"

GREEN, RED, DIM, OFF = "\033[32m", "\033[31m", "\033[2m", "\033[0m"
TIMEOUT = 15

# Команды, которые обязаны быть остановлены в любой записи.
DESTRUCTIVE = [
    "docker volume rm data",
    "podman system prune -af",
    "rm -rf /",
    "rm -rf ~/",
    "git push --force origin main",
    "php artisan migrate:fresh",
    'psql -c "DROP TABLE users"',
    "mkfs.ext4 /dev/sdb1",
    "dd if=/dev/zero of=/dev/sda",
    "buildah rm --all",
]

# Команды, которые обязаны проходить: блокировать их нельзя ни в какой обёртке.
BENIGN = [
    "ls -la",
    "git status",
    "git log --oneline -20",
    "podman ps -a",
    "php artisan test",
    "npm run build",
    "cat README.md",
    "rm -rf ./build/cache",
    "docker compose up -d",
    "python3 manage.py check",
]

# Обёртки, которые замок обязан снимать, добираясь до настоящей команды.
WRAPPERS = [
    "sudo {}",
    "env FOO=bar {}",
    "timeout 30 {}",
    "nice -n 10 {}",
    "bash -c \"{}\"",
    "sh -c '{}'",
    "VAR=1 {}",
]

# Шум, который не меняет смысла команды, но ломает наивное сопоставление.
NOISE = [
    lambda c: c.replace(" ", "  ", 1),
    lambda c: c.replace(" ", "\t", 1),
    lambda c: f"{c} # комментарий с кириллицей",
    lambda c: f"cd /tmp && {c}",
    lambda c: f"{c} && echo готово",
    lambda c: f"echo начали; {c}",
    lambda c: f"{c} 2>/dev/null",
    lambda c: f"  {c}  ",
    lambda c: f"{c} | tee /tmp/лог.txt",
]


def decide(command: str) -> tuple[str, str]:
    """Возвращает (решение, проблема). Решение: pass|deny|ask."""
    payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": command}})
    try:
        p = subprocess.run(["bash", str(GUARD)], input=payload,
                           capture_output=True, text=True, timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return "", f"разбор не завершился за {TIMEOUT} с"
    if p.returncode != 0:
        return "", f"код возврата {p.returncode}: {p.stderr.strip()[:120]}"
    out = p.stdout.strip()
    if not out:
        return "pass", ""
    try:
        data = json.loads(out)
        return data["hookSpecificOutput"]["permissionDecision"], ""
    except (ValueError, KeyError) as e:
        return "", f"на выходе не решение, а {out[:80]!r} ({e})"


def build(rnd: random.Random, base: str) -> str:
    """Обкладывает команду случайными обёртками и шумом."""
    cmd = base
    for _ in range(rnd.randint(0, 2)):
        cmd = rnd.choice(WRAPPERS).format(cmd)
    for _ in range(rnd.randint(0, 2)):
        cmd = rnd.choice(NOISE)(cmd)
    if rnd.random() < 0.15:                      # редкие длинные строки
        cmd = f"{cmd} # {'x' * rnd.randint(500, 3000)}"
    return cmd


def main() -> int:
    cases = int(sys.argv[1]) if len(sys.argv) > 1 else 240
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 20260729
    rnd = random.Random(seed)

    failures: list[str] = []
    checked = 0

    for i in range(cases):
        dangerous = i % 2 == 0
        base = rnd.choice(DESTRUCTIVE if dangerous else BENIGN)
        cmd = build(rnd, base)
        decision, problem = decide(cmd)
        checked += 1

        if problem:
            failures.append(f"{problem}\n     команда: {cmd[:160]}")
            continue
        if dangerous and decision == "pass":
            failures.append(f"разрушающая команда прошла\n     команда: {cmd[:160]}")
        if not dangerous and decision == "deny":
            failures.append(f"безобидная команда заблокирована\n     команда: {cmd[:160]}")

    print(f"  Проверено случайных записей: {checked}   зерно: {seed}")
    if failures:
        for f in failures[:10]:
            print(f"  {RED}FAIL{OFF} {f}")
        if len(failures) > 10:
            print(f"  {DIM}...ещё {len(failures) - 10}{OFF}")
        print(f"\n  Пройдено: {GREEN}{checked - len(failures)}{OFF}   "
              f"Провалено: {RED}{len(failures)}{OFF}")
        print(f"  {DIM}Воспроизвести: tests/fuzz-guard-bash.py {cases} {seed}{OFF}")
        return 1

    print(f"  {GREEN}Свойства держатся{OFF}: не падает, не зависает, "
          f"разрушающее не проходит, безобидное не блокируется")
    return 0


if __name__ == "__main__":
    sys.exit(main())
