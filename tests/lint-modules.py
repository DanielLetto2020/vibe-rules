#!/usr/bin/env python3
"""
lint-modules.py — структурная валидация репозитория стандартов.

Проверяет то, что можно проверить без модели и без токенов: манифесты,
frontmatter правил, размеры, живость хуков, согласованность каталога.

Главная проверяемая метрика — доля правил с enforcement: prose.
Она должна падать со временем: правило, оставшееся прозой, соблюдается
с некоторой вероятностью, а вбитое в линтер или хук — всегда.

Коды возврата: 0 — чисто, 1 — есть ошибки.
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PLUGINS = ROOT / "plugins"
MARKETPLACE = ROOT / ".claude-plugin" / "marketplace.json"

VALID_ENFORCEMENT = {"lint", "hook", "test", "review", "prose"}
MAX_RULE_BULLETS = 15
MAX_ALWAYS_ON_LINES = 60  # для правил без paths: они грузятся в каждую сессию

errors: list[str] = []
warnings: list[str] = []
VERSIONED: list[tuple[str, str | None]] = []
stats = {"rules": 0, "prose": 0, "skills": 0, "modules": 0}


def err(msg: str) -> None:
    errors.append(msg)


def warn(msg: str) -> None:
    warnings.append(msg)


def parse_frontmatter(text: str) -> tuple[dict, str]:
    """Минимальный парсер YAML-frontmatter: скаляры и простые списки.

    Полноценный YAML тут не нужен и потянул бы зависимость, а тесты должны
    запускаться в любом CI без установки пакетов.
    """
    if not text.startswith("---"):
        return {}, text
    end = text.find("\n---", 3)
    if end == -1:
        return {}, text
    raw = text[3:end].strip("\n")
    body = text[end + 4:]

    data: dict = {}
    key = None
    for line in raw.split("\n"):
        if not line.strip() or line.strip().startswith("#"):
            continue
        m = re.match(r"^(\s*)-\s+(.*)$", line)
        if m and key:                                  # элемент списка
            data.setdefault(key, [])
            if isinstance(data[key], list):
                data[key].append(m.group(2).strip().strip("\"'"))
            continue
        m = re.match(r"^([A-Za-z_][\w-]*):\s*(.*)$", line)
        if m:
            key, val = m.group(1), m.group(2).strip()
            if val.startswith("[") and val.endswith("]"):
                items = [i.strip().strip("\"'") for i in val[1:-1].split(",")]
                data[key] = [i for i in items if i]
            elif val:
                data[key] = val.strip("\"'")
            else:
                data[key] = []
    return data, body


def check_json(path: Path) -> dict | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        err(f"{path.relative_to(ROOT)}: файл отсутствует")
    except json.JSONDecodeError as e:
        err(f"{path.relative_to(ROOT)}: невалидный JSON — {e}")
    return None


def check_marketplace() -> set[str]:
    """Каталог согласован с содержимым директории plugins/."""
    listed: set[str] = set()
    data = check_json(MARKETPLACE)
    if not data:
        return listed

    for field in ("name", "owner", "plugins"):
        if field not in data:
            err(f"marketplace.json: нет обязательного поля '{field}'")

    for entry in data.get("plugins", []):
        name = entry.get("name")
        source = entry.get("source", "")
        if not name or not source:
            err(f"marketplace.json: запись без name/source: {entry}")
            continue
        listed.add(name)
        src = (ROOT / source.lstrip("./")).resolve()
        if not src.is_dir():
            err(f"marketplace.json: '{name}' указывает на несуществующий путь {source}")

    on_disk = {p.name for p in PLUGINS.iterdir() if p.is_dir()}
    for missing in sorted(on_disk - listed):
        err(f"модуль '{missing}' есть на диске, но не объявлен в marketplace.json — он не установится")
    for ghost in sorted(listed - on_disk):
        err(f"модуль '{ghost}' объявлен в marketplace.json, но его нет на диске")
    return listed


def check_plugin(plugin_dir: Path) -> None:
    name = plugin_dir.name
    stats["modules"] += 1

    manifest = check_json(plugin_dir / ".claude-plugin" / "plugin.json")
    if manifest:
        if manifest.get("name") != name:
            err(f"{name}: plugin.json.name='{manifest.get('name')}' не совпадает с именем папки")
        # Версии либо у всех модулей, либо ни у одного. Смесь опаснее обоих
        # вариантов: часть модулей обновляется у пользователей при каждом
        # коммите, часть — только при ручном бампе, и понять, что доехало,
        # а что нет, невозможно.
        VERSIONED.append((name, manifest.get("version")))

    check_rules(plugin_dir, name)
    check_skills(plugin_dir, name)
    check_hooks(plugin_dir, name, manifest or {})


def check_rules(plugin_dir: Path, name: str) -> None:
    rules_dir = plugin_dir / "rules"
    if not rules_dir.is_dir():
        return
    for rule in sorted(rules_dir.rglob("*.md")):
        rel = rule.relative_to(ROOT)
        stats["rules"] += 1
        text = rule.read_text(encoding="utf-8")
        fm, body = parse_frontmatter(text)

        if not fm:
            err(f"{rel}: нет frontmatter — правило неуправляемо (нет владельца и способа проверки)")
            continue

        if not fm.get("owner"):
            err(f"{rel}: не указан owner — у правила без владельца нет того, кто его обновит")

        enf = fm.get("enforcement")
        if not enf:
            err(f"{rel}: не указан enforcement (lint|hook|test|review|prose)")
        elif enf not in VALID_ENFORCEMENT:
            err(f"{rel}: enforcement='{enf}' вне допустимых значений {sorted(VALID_ENFORCEMENT)}")
        elif enf == "prose":
            stats["prose"] += 1

        if not fm.get("since"):
            warn(f"{rel}: нет since — не видно, когда правило появилось")

        paths = fm.get("paths")
        if paths is None:
            lines = len([ln for ln in body.strip().split("\n") if ln.strip()])
            if lines > MAX_ALWAYS_ON_LINES:
                err(f"{rel}: без paths правило грузится в КАЖДУЮ сессию, а в нём {lines} строк "
                    f"(предел {MAX_ALWAYS_ON_LINES}) — добавь paths или сократи")
        else:
            if isinstance(paths, str):
                paths = [paths]
            if not paths:
                err(f"{rel}: paths объявлен пустым — правило не загрузится никогда")
            for p in paths:
                if p.startswith("/"):
                    err(f"{rel}: glob '{p}' абсолютный — paths резолвятся от корня проекта")
                if "[" in p and "]" not in p:
                    err(f"{rel}: glob '{p}' с незакрытой скобкой не совпадёт ни с чем")

        bullets = len(re.findall(r"^\s*[-*]\s+", body, re.M))
        if bullets > MAX_RULE_BULLETS:
            warn(f"{rel}: {bullets} пунктов (ориентир {MAX_RULE_BULLETS}) — длинные правила соблюдаются хуже")

        if enf == "lint" and not (plugin_dir / "configs").is_dir():
            warn(f"{rel}: enforcement=lint, но в модуле нет configs/ — фактически это prose")


def check_skills(plugin_dir: Path, name: str) -> None:
    for skill in sorted(plugin_dir.glob("skills/*/SKILL.md")):
        rel = skill.relative_to(ROOT)
        stats["skills"] += 1
        fm, _ = parse_frontmatter(skill.read_text(encoding="utf-8"))
        if not fm.get("description"):
            err(f"{rel}: нет description — Claude не сможет подобрать скилл по задаче")
        elif len(fm["description"]) < 40:
            warn(f"{rel}: description короткий ({len(fm['description'])} симв.) — "
                 f"скилл будет подбираться ненадёжно, опиши триггеры явно")
        if fm.get("name") and fm["name"] != skill.parent.name:
            warn(f"{rel}: frontmatter name='{fm['name']}' не совпадает с именем папки '{skill.parent.name}'")


def check_hooks(plugin_dir: Path, name: str, manifest: dict) -> None:
    hooks_file = plugin_dir / "hooks" / "hooks.json"
    if not hooks_file.is_file():
        return
    data = check_json(hooks_file)
    if not data:
        return
    for event, groups in data.get("hooks", {}).items():
        for group in groups:
            for hook in group.get("hooks", []):
                cmd = hook.get("command", "")
                m = re.search(r'\$\{CLAUDE_PLUGIN_ROOT\}"?(/[\w./-]+)', cmd)
                if not m:
                    if "${CLAUDE_PLUGIN_ROOT}" not in cmd:
                        warn(f"{name}/hooks.json [{event}]: команда без ${{CLAUDE_PLUGIN_ROOT}} — "
                             f"путь сломается после установки плагина")
                    continue
                script = plugin_dir / m.group(1).lstrip("/")
                if not script.is_file():
                    err(f"{name}/hooks.json [{event}]: скрипт не найден — {m.group(1)}")
                elif not os.access(script, os.X_OK):
                    err(f"{name}/hooks.json [{event}]: скрипт не исполняемый — {m.group(1)} "
                        f"(chmod +x)")


def main() -> int:
    if not PLUGINS.is_dir():
        print("Не найдена директория plugins/", file=sys.stderr)
        return 1

    check_marketplace()
    for plugin_dir in sorted(p for p in PLUGINS.iterdir() if p.is_dir()):
        check_plugin(plugin_dir)

    with_v = [n for n, v in VERSIONED if v]
    without_v = [n for n, v in VERSIONED if not v]
    if with_v and without_v:
        err(f"версии заданы у части модулей ({len(with_v)} из {len(VERSIONED)}): "
            f"{', '.join(with_v[:3])}… Обновления доезжают до пользователей "
            f"по-разному, и понять, что применилось, невозможно. "
            f"Либо задать версии всем, либо убрать у всех.")

    print("=" * 66)
    print(f"Модулей: {stats['modules']}   Правил: {stats['rules']}   Скиллов: {stats['skills']}")
    if stats["rules"]:
        share = stats["prose"] / stats["rules"] * 100
        print(f"Доля prose-правил: {stats['prose']}/{stats['rules']} ({share:.0f}%) "
              f"— эта цифра должна снижаться от квартала к кварталу")
    print("=" * 66)

    for w in warnings:
        print(f"  ПРЕДУПР  {w}")
    for e in errors:
        print(f"  ОШИБКА   {e}")

    if errors:
        print(f"\nПРОВАЛЕНО: ошибок {len(errors)}, предупреждений {len(warnings)}")
        return 1
    print(f"\nOK: ошибок нет, предупреждений {len(warnings)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
