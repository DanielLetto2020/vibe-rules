#!/usr/bin/env python3
"""
lint-modules.py — структурная валидация репозитория стандартов.

Проверяет то, что можно проверить без модели и без токенов: манифесты,
frontmatter правил, размеры, живость хуков, согласованность каталога.

Главная проверяемая метрика — доля правил, за которыми не стоит машина.
Это prose и review вместе: prose соблюдается с некоторой вероятностью,
review означает «человек прочитает код» — то самое чтение, от которого
репозиторий обещает избавить. Считать одну prose было приятнее и неверно:
получалось 4% там, где неавтоматизировано две трети набора.

Цифра должна падать со временем. Правило, вбитое в линтер, хук или тест,
работает всегда; остальное работает, пока о нём помнят.

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

# Поля, которые Claude Code понимает в plugin.json. Неизвестное поле не ломает
# загрузку, но `claude plugin validate --strict` считает его ошибкой — а этой
# команды нет в CI, поэтому проверяем сами. Опечатка в имени поля означает,
# что настройка молча не применяется.
KNOWN_MANIFEST_FIELDS = {
    "$schema", "name", "displayName", "version", "description", "author",
    "homepage", "repository", "license", "keywords", "defaultEnabled",
    "skills", "commands", "agents", "workflows", "hooks", "mcpServers",
    "outputStyles", "lspServers", "experimental", "userConfig", "channels",
    "dependencies",
}
MAX_RULE_BULLETS = 15
MAX_ALWAYS_ON_LINES = 60  # для правил без paths: они грузятся в каждую сессию

errors: list[str] = []
warnings: list[str] = []
VERSIONED: list[tuple[str, str | None]] = []
stats = {"rules": 0, "prose": 0, "review": 0, "lint": 0, "hook": 0, "test": 0,
         "refs": 0, "skills": 0, "modules": 0}


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

        unknown = set(manifest) - KNOWN_MANIFEST_FIELDS
        # Ключи-комментарии допустимы: JSON не имеет комментариев, и это
        # общепринятый способ пояснить конфигурацию
        unknown = {k for k in unknown if not k.startswith("_")}
        if unknown:
            err(f"{name}: неизвестные поля в plugin.json: {', '.join(sorted(unknown))}. "
                f"Опечатка означает, что настройка молча не применяется; "
                f"`claude plugin validate --strict` такое отвергает")

        # Стандартные пути подхватываются автоматически. Указание их в
        # манифесте создаёт дубль, и Claude Code отказывается загружать
        # компонент: плагин ставится, а хуки молча не действуют.
        # `claude plugin validate` этого не видит — ошибка возникает только
        # при загрузке, поэтому проверяем сами.
        DEFAULT_PATHS = {
            "hooks": ("./hooks/hooks.json", "hooks/hooks.json"),
            "skills": ("./skills/", "./skills", "skills/", "skills"),
            "commands": ("./commands/", "./commands", "commands/", "commands"),
            "agents": ("./agents/", "./agents", "agents/", "agents"),
        }
        for field, defaults in DEFAULT_PATHS.items():
            val = manifest.get(field)
            if isinstance(val, str) and val in defaults:
                err(f"{name}: поле '{field}' указывает на стандартный путь '{val}'. "
                    f"Он подхватывается автоматически, а явное указание создаёт "
                    f"дубль — компонент не загрузится. Убери поле из манифеста")

        for field, typ in (("keywords", list), ("dependencies", list), ("author", dict)):
            if field in manifest and not isinstance(manifest[field], typ):
                err(f"{name}: поле {field} должно быть {typ.__name__}, "
                    f"а не {type(manifest[field]).__name__} — плагин не загрузится")
        # Версии либо у всех модулей, либо ни у одного. Смесь опаснее обоих
        # вариантов: часть модулей обновляется у пользователей при каждом
        # коммите, часть — только при ручном бампе, и понять, что доехало,
        # а что нет, невозможно.
        VERSIONED.append((name, manifest.get("version")))

    check_rules(plugin_dir, name)
    check_skills(plugin_dir, name)
    check_hooks(plugin_dir, name, manifest or {})
    check_commands(plugin_dir, name)


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
        else:
            stats[enf] += 1

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

        # За «машинным» enforcement обязан стоять файл, который можно открыть.
        # Раньше это была надежда: enforcement считался честным по слову автора,
        # а lint без configs/ давал лишь предупреждение. Метка, за которой
        # ничего нет, обманывает ровно там, где важна — в отчёте о том, сколько
        # правил проверяется машиной.
        if enf in ("lint", "hook", "test"):
            refs = fm.get("enforcement_ref")
            if isinstance(refs, str):
                refs = [refs]
            if not refs:
                err(f"{rel}: enforcement={enf} без enforcement_ref — не видно, чем правило "
                    f"подкреплено. Укажи конфиг линтера, скрипт хука или конфигурацию гейта.")
            else:
                for r in refs:
                    target = plugin_dir / r
                    if not target.exists():
                        target = ROOT / r          # ссылка на общий файл репозитория
                    if not target.exists():
                        err(f"{rel}: enforcement_ref '{r}' не существует — "
                            f"подкрепление указано, но проверить его нечем")
                    stats["refs"] += 1


def check_commands(plugin_dir: Path, name: str) -> None:
    """Команда, запускающая скрипт, обязана предупредить о пути установки.

    Путь содержит версию (.../std-core/0.9.0/scripts/...) и исчезает при первом
    же обновлении. Без предупреждения агент показывает человеку этот путь как
    способ запуска — проверено на живом проекте, работает ровно один релиз.
    """
    for cmd in sorted(plugin_dir.glob("commands/*.md")):
        text = cmd.read_text(encoding="utf-8")
        if "CLAUDE_PLUGIN_ROOT" not in text:
            continue
        if "называй команду, а не путь" not in text:
            err(f"{cmd.relative_to(ROOT)}: команда запускает скрипт, но не запрещает "
                f"показывать человеку путь установки. Путь содержит версию и "
                f"перестанет существовать после обновления")


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

    # Версия должна быть у всех и одна: модули публикуются вместе, а обновление
    # доезжает до пользователя только при её изменении. Разнобой означает, что
    # часть модулей у людей свежая, часть нет, и понять что где невозможно.
    without_v = [n for n, ver in VERSIONED if not ver]
    if without_v:
        err(f"версия не задана у модулей: {', '.join(without_v[:5])}. "
            f"Без неё обновление до пользователя не доедет, а `claude plugin "
            f"validate --strict` не проходит. Поднять всем: tools/bump.sh")
    versions = {ver for _, ver in VERSIONED if ver}
    if len(versions) > 1:
        err(f"версии модулей различаются: {', '.join(sorted(versions)[:4])}. "
            f"Набор публикуется целиком — версия должна быть одна. "
            f"Выровнять: tools/bump.sh <версия>")
    mp_ver = None
    try:
        mp_ver = json.loads(MARKETPLACE.read_text()).get("metadata", {}).get("version")
    except Exception:
        pass
    if mp_ver and versions and mp_ver not in versions:
        err(f"версия каталога ({mp_ver}) не совпадает с версией модулей "
            f"({sorted(versions)[0]}). Обновить: tools/bump.sh")

    print("=" * 66)
    print(f"Модулей: {stats['modules']}   Правил: {stats['rules']}   Скиллов: {stats['skills']}")
    if stats["rules"]:
        machine = stats["lint"] + stats["hook"] + stats["test"]
        human = stats["prose"] + stats["review"]
        share = human / stats["rules"] * 100
        print(f"Чем подкреплены правила: машиной {machine} "
              f"(lint {stats['lint']}, hook {stats['hook']}, test {stats['test']}), "
              f"человеком {human} (review {stats['review']}, prose {stats['prose']})")
        print(f"Не автоматизировано: {human}/{stats['rules']} ({share:.0f}%) "
              f"— review это «человек прочитает», то есть ровно то, "
              f"от чего репозиторий обещает избавить. Цифра должна снижаться.")
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
