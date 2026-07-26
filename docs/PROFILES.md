# Profiles: where they live and how to change them

> 🇷🇺 [Русская версия](PROFILES.ru.md) · [back to README](../README.md) ·
> [start with the basics](START.md)

---

## In short

**A profile is a set of requirements about checks**, not about code. It decides
whether a spec is required, whether gates run before a commit, where the
test-quality bar sits, and what happens when an existing test is edited.

Rules do **not** depend on the profile — see
[Writing your own rule](WRITING-RULES.md).

Three places a profile lives:

| Where | What is there | Who edits it |
|---|---|---|
| `plugins/std-core/profiles/profiles.json` | six ready profiles | whoever maintains the standards repo |
| `.claude/gauntlet.json` in the project | the chosen profile and its settings | you, in your project |
| the `--profile` argument | which profile to pick | you, at setup |

---

## Choosing a profile

When setting up a project:

```bash
/std-core:setup --profile solo
```

With no argument the profile is inferred — from the number of authors, the
number of commits and whether tests exist.

To see what would be chosen without changing anything:

```bash
/std-core:setup --dry-run
```

Change it later with the same command and a different value. Settings you
edited by hand are preserved.

---

## What lands in the project

After setup the project gets `.claude/gauntlet.json`:

```json
{
  "profile": "solo",
  "gates": {
    "style": "./vendor/bin/pint --test",
    "types": "./vendor/bin/phpstan analyse --no-progress",
    "test": "php artisan test"
  },
  "mutation": { "enabled": true, "mode": "ratchet", "floor": 50 },
  "requireBeforeCommit": true,
  "guardTests": "ask",
  "specFirst": true
}
```

**This file is committed.** The whole team gets the same requirements, and the
history shows when and why they changed.

---

## Adapting a profile to your project

The common case: the profile almost fits, but one thing gets in the way.

Just edit `.claude/gauntlet.json` — it takes precedence over the profile
definition. Running `setup` again will not overwrite your changes.

### Examples

**Gates before every commit get in the way.** Say you have a rule of
committing after every small edit:

```json
{ "requireBeforeCommit": false }
```

**Stricter about tests.** By default the profile asks before an existing test
is edited; you want it forbidden:

```json
{ "guardTests": "deny" }
```

Values: `off` — don't interfere, `ask` — ask, `deny` — forbid.

**Your own test command.** Detection found the wrong thing, or nothing:

```json
{
  "gates": {
    "test": "make test-fast",
    "e2e": "npx playwright test"
  }
}
```

You choose the keys; the order in the file is the order of execution. Put cheap
and fast checks first so an obvious mistake surfaces in seconds.

**A fixed mutation threshold instead of the ratchet.** When quality is already
high and you want a firm bar:

```json
{ "mutation": { "enabled": true, "mode": "absolute", "threshold": 80 } }
```

Or switch it off entirely:

```json
{ "mutation": { "enabled": false } }
```

**No spec required.** For a project where tasks are small and obvious:

```json
{ "specFirst": false }
```

### What cannot be overridden

Safety locks: deleting volumes and images, force-push, `migrate:fresh`,
plaintext secrets. They behave identically under every profile and are not
configurable from a project — otherwise a profile would become a way to switch
protection off.

---

## Creating your own profile

Useful when a team has a mode none of the six cover. For example an "internal
tool": tests needed, spec not, gates light.

Add it to the standards repository, in
`plugins/std-core/profiles/profiles.json`:

```json
"internal-tool": {
  "title": "Internal tool",
  "when": "A utility for ourselves: if it breaks, the same people fix it.",
  "specFirst": false,
  "requireBeforeCommit": true,
  "guardTests": "ask",
  "gates": ["style", "test"],
  "mutation": { "enabled": true, "mode": "ratchet", "floor": 30 },
  "rationale": "A spec is redundant: the requester and the implementer are the same person. Tests are not — other teams use the tool and a breakage is noticed late."
}
```

Fields:

| Field | What it sets |
|---|---|
| `title` | human-readable name |
| `when` | when to apply it — one line, shown during setup |
| `specFirst` | require acceptance criteria before code |
| `requireBeforeCommit` | run gates before committing |
| `guardTests` | `off` / `ask` / `deny` when an existing test is edited |
| `gates` | which checks are required: `style`, `types`, `test`, `security` |
| `mutation` | [ratchet](RATCHET.md) from a floor, `absolute` with a threshold, or off |
| `rationale` | **why it is this way** — required |

`rationale` is not a formality. In six months nobody will remember why this
profile skips the spec, and it will either be broken or abandoned.

After adding:

```bash
tests/run.sh                            check the structure
/std-core:setup --profile internal-tool
```

### Automatic detection

If you want the profile picked automatically, add a rule to the `detection`
section of the same file. Think twice, though: intent is hard to infer from
code, and getting it wrong is irritating.

`corporate` and `regulated` are deliberately **never** auto-selected: deciding
from code that a project handles money or medical data is not reliable, and the
error is expensive.

---

## Seeing what is in force

```bash
cat .claude/gauntlet.json          what the project records
/std-gauntlet:run --list           which gates will run
/std-core:doctor                   full diagnostics
```

The agent receives the profile's requirements at the start of a session — if
the profile requires a spec, it knows without reading the file.

---

## Next

- **the mutation gate** → [Ratchet](RATCHET.md)
- **rules, not checks** → [Writing a rule](WRITING-RULES.md)
