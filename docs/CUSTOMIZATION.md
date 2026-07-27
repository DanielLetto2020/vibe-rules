# Project-level rules, without touching the shared repository

> 🇷🇺 [Русская версия](CUSTOMIZATION.ru.md) · [all docs](README.md)

---

## The problem

Shared modules describe a technology: how Laravel code is written here, how a
Vue component is laid out. But every project has its own things — agreements,
traps, justified departures from a general rule.

Putting those in the shared repository is wrong: it is linked into other
projects, and your quirk becomes their problem. Adding them to `CLAUDE.md` is
wrong for a different reason: it loads in full on every session, whatever you
happen to be working on.

So a project gets its own layer of rules. It lives in the project repository,
is committed with the code, and loads by the same mechanics as the shared ones.

---

## Four levels of customization

From most common to least:

| Level | Where | When you need it |
|---|---|---|
| Project rule | `.claude/rules/<name>.md` | a convention no shared module covers |
| Departure | `.claude/rules/00-precedence.md` | a shared rule does not fit here, and there is a reason |
| Gate settings | `.claude/gauntlet.json` | different check commands, different mutation mode |
| Module opt-out | `/std-core:rule override <module>` | a whole module is not about this project |

All of it lives in the project's git. The shared standards repository stays
untouched.

---

## A project rule

```bash
/std-core:rule new api-conventions backend
```

This creates `.claude/rules/api-conventions.md` with a skeleton. The second
argument is a path hint: `backend`, `frontend`, `infra`, `tests`, `always`.

Inside, the same format as shared rules:

```markdown
---
paths:
  - "app/Http/**/*.php"
owner: "@petrov"
enforcement: prose
since: "2026-07-27"
---

# API responses

- Errors follow RFC 7807; the `type` field is mandatory.
- Pagination is cursor-based only: we have endpoints over millions of rows,
  and `offset` there takes the database down.
```

**`paths` is the field that matters most.** Without it the rule loads on every
session and burns context even when it is irrelevant. With it, the rule arrives
exactly when a matching file is open.

Then commit the rule. It reaches everyone working on the project and — unlike
shared modules, which are symlinks — genuinely lives in git.

To see what is already there:

```bash
/std-core:rule list
```

```
Project rules (in git):
  api-conventions.md    @petrov  "app/Http/**/*.php"
  billing-migration.md  @ivanov  "app/Legacy/**"

Shared modules (symlinks, not in git):
  std-php-laravel       ok
  std-js-vue            ok

Precedence declared: 00-precedence.md
```

---

## When a project rule contradicts a shared one

Claude Code loads all rules with equal weight. There is no automatic "project
beats shared": on a contradiction the model picks one, and you never find out
which.

So the hierarchy is declared explicitly:

```bash
/std-core:rule precedence
```

This produces `.claude/rules/00-precedence.md`, which says two things:

1. **On a contradiction, the project rule wins.** The shared module describes
   the usual way; the project knows its own circumstances.
2. **Having noticed a contradiction, the agent must say so** rather than
   choosing silently.

The second point matters more. A divergence means either that the shared rule
needs refining or that the departure is no longer needed. Both are decisions
for a human.

### Departures are recorded with a reason

In the same file, in the section below:

```markdown
## Departures

### Validation in controllers, not FormRequest
Module: std-php-laravel, rule 10-http.
Reason: the billing module has not been moved to FormRequest; the move is
planned for Q4. New code follows the shared rule.
```

The reason is mandatory. Six months on, a departure without one is
indistinguishable from an oversight, and nobody will dare remove it.

---

## Turning off a shared module entirely

```bash
/std-core:rule override php-laravel
```

The symlink is removed and a stub with a place for the reason is appended to
`00-precedence.md`. Fill it in right away — the command will remind you.

To restore it: `/std-core:sync`.

This is a rare case. Usually you do not want to disable a module, only to
disagree with one of its rules — a departure is enough for that.

---

## Check settings

`.claude/gauntlet.json` is written during setup and edited by hand afterwards.

```json
{
  "gates": {
    "style": "./vendor/bin/pint --test",
    "types": "./vendor/bin/phpstan analyse --no-progress",
    "test": "php artisan test --parallel"
  },
  "mutation": { "enabled": true, "mode": "ratchet", "floor": 30 },
  "requireSpecFirst": false
}
```

Change it freely: commands to match your build, mutation gate mode, threshold.
Details in [The ratchet](RATCHET.md) and [Profiles](PROFILES.md).

To see the result:

```bash
/std-gauntlet:run --list
```

---

## What of this goes into git

| File | In git | Why |
|---|---|---|
| `.claude/rules/*.md` (yours) | yes | it is the team's standard, shared by all |
| `.claude/rules/std-*` (symlinks) | no | they point at an install path, different per machine |
| `.claude/gauntlet.json` | yes | check settings are the same for everyone |
| `.claude/.ratchet.json` | no | the bar depends on runs on one particular machine |
| `.claude/.std-trace.jsonl` | no | rule-loading journal, local diagnostics |

The `.gitignore` entries for this are written during setup.

---

## Checking that a rule actually loads

A rule you wrote may not work: a typo in `paths`, a wrong glob. That looks
exactly like "the rule exists" — the agent simply does not do what you asked.

Open a file the rule is supposed to cover and look:

```bash
/context
```

Your rule should appear under Memory files. If it is not there, the glob did
not match.

A second way, without spending tokens:

```bash
/std-core:doctor
```

It shows the journal of actual loads: which rules arrived, when, and on which
files.

---

## When to write a rule, and when not to

A rule is written **after the fact**:

- the agent made the same mistake a second time;
- review caught something it should have known;
- you are typing the same correction into the chat for the second time.

Not "let's write it down just in case". Every rule is a tax on context in
every session for every developer. A rule set that only grows stops being read
— by people and by the model alike.

And the main test: **can a machine check this?** If yes, it belongs in a linter
config or a hook, not in prose. A rule in prose is a request; a rule in a hook
is a guarantee.

How to phrase them — [Writing your own rule](WRITING-RULES.md).

---

## Next

- [Legacy and rewrites](LEGACY.md) — rules for a transition period
- [Writing your own rule](WRITING-RULES.md) — phrasing and pitfalls
- [Examples](EXAMPLES.md), scenario 5 — a project rule end to end
