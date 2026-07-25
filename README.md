# vibe-rules

[![gates](https://github.com/DanielLetto2020/vibe-rules/actions/workflows/validate.yml/badge.svg)](https://github.com/DanielLetto2020/vibe-rules/actions/workflows/validate.yml)
[![release](https://img.shields.io/github/v/release/DanielLetto2020/vibe-rules?color=blue)](https://github.com/DanielLetto2020/vibe-rules/releases)
[![license](https://img.shields.io/github/license/DanielLetto2020/vibe-rules?color=blue)](LICENSE)
[![modules](https://img.shields.io/badge/modules-20-blue)](#modules)

> 🇷🇺 [Русская версия](README.ru.md)

**Modular development standards for Claude Code.** One repository, all your
projects. Rules load only when relevant. Checks run as hooks, not as polite
requests.

> **Note on language:** rule texts are written in Russian. The architecture,
> tooling and tests are language-agnostic — fork it and write your own rules in
> any language. See [Writing your own rules](#writing-your-own-rules).

---

## The problem

Claude Code starts every session with an empty context. Two constraints follow:

1. **Everything you say costs tokens** — in every session, for every developer.
2. **The more you say, the less is followed.** The docs recommend keeping
   `CLAUDE.md` under 200 lines: long files consume context *and* reduce
   adherence.

So the question isn't *what to write*. It's *where to put it so it's found
exactly when needed*.

And a second, harder problem: a rule written as prose is a **request**. The
model reads it, understands it, follows it most of the time. A rule compiled
into a hook is a **guarantee**. There is no percentage.

## The idea

Rules are organised **by when they load**, not by topic:

| Layer | Where it lives | When it enters context | Cost |
|---|---|---|---|
| **Lock** | hooks, linter configs | never — it executes | 0 tokens, 100% enforced |
| **Always-on** | project `CLAUDE.md` | every session | expensive, ≤200 lines |
| **Path-scoped** | `rules/*.md` with `paths:` | when a matching file is opened | pay only when relevant |
| **Task-scoped** | `skills/*/SKILL.md` | when the task matches | pay only when relevant |
| **Reference** | `docs/*.md` | when Claude decides to read it | nearly free |

Every rule declares how it is enforced — `hook`, `lint`, `test`, `review`
or `prose`. The test suite prints the share of `prose` rules. **That number
must go down.** A standards repository should shrink as automation grows,
not swell.

## Quick start

```bash
# once per machine
/plugin marketplace add DanielLetto2020/vibe-rules
/plugin install std-core@vibe-rules

# in each project
/std-core:link --auto      # detects your stack, links the right modules
/std-gauntlet:init         # configures quality gates
/context                   # verify what actually loaded
```

`--auto` reads `composer.json`, `package.json`, `pyproject.toml`, compose
files, Kubernetes manifests and Ansible playbooks. Real output from five
different projects:

| Project | Modules linked |
|---|---|
| Laravel + Vue + Postgres | `core` `gauntlet` `php-base` `php-laravel` `js-base` `js-vue3` `sql-postgres` |
| Legacy Yii2 | `core` `gauntlet` `php-base` `php-yii2` `sql-postgres` |
| FastAPI + Kafka + Redis | `core` `gauntlet` `py-base` `py-fastapi` `cache-redis` `msg-kafka` `ops-containers` |
| Nuxt + Playwright | `core` `gauntlet` `js-base` `js-nuxt` `js-playwright` |
| Infrastructure only | `core` `gauntlet` `ops-k8s` `ops-ansible` `ops-containers` |

Note the split: **PHP is not always Laravel.** Language rules and framework
rules are separate modules — a plain PHP or Symfony project still gets
`php-base`, and framework modules stack on top.

## Modules

| Module | Covers |
|---|---|
| `std-core` | locks, rule linking, diagnostics — install everywhere |
| `std-gauntlet` | the gauntlet: spec, tests, mutation, metrics, gates — install everywhere |
| `std-php-base` | PHP as a language: `strict_types`, types, strict comparison |
| `std-js-base` | JS/TS as a language: no `any`, promises, `??` over `\|\|` |
| `std-py-base` | Python as a language: annotations, mutable defaults, resources |
| `std-php-laravel` | HTTP layer, Eloquent, tests |
| `std-php-yii2` | controllers, ActiveRecord, driver type pitfalls |
| `std-js-vue3` | SFC, composition, typed props |
| `std-js-nuxt` | SSR, data fetching, server routes |
| `std-js-playwright` | E2E: selectors, waits, flake control |
| `std-py-fastapi` | schemas, dependencies, async pitfalls |
| `std-py-parsers` | networking, retries, resilience to source changes |
| `std-sql-postgres` | zero-downtime migrations, indexes |
| `std-sql-sqlite` | engine limits, differences from production |
| `std-msg-rabbitmq` | acks, idempotency, DLQ |
| `std-msg-kafka` | keys, partitions, offsets, ordering |
| `std-cache-redis` | TTL, invalidation, locks |
| `std-ops-containers` | images, layers, secrets, non-root |
| `std-ops-k8s` | resources, probes, zero-downtime rollouts |
| `std-ops-ansible` | idempotency, inventory, secrets |

## The gauntlet

Inspired by Robert C. Martin's [stated approach](https://x.com/unclebobmartin/status/2080257779395154409)
of not reading code written by his agents, and instead surrounding them with
constraints. Five stages, each verifying the one before it:

1. **Spec** in plain language — the only artefact a human always reads.
2. **Tests** derived from the spec, written in a session separate from the
   implementation.
3. **Mutation testing** — the only stage that verifies the tests themselves.
4. **Metrics** instead of reading diffs.
5. **A list for human eyes** — what nothing else can catch.

One command runs everything:

```bash
/std-gauntlet:run          # all gates
/std-gauntlet:run --fast   # skip mutation, for tight loops
```

### Why mutation testing is the load-bearing part

Coverage tells you a line was executed. It does not tell you it was verified.

Here is a real run from this repository's demo project — a discount function
and a test asserting "the result is positive":

```
tests pass  →  mutation: 0 of 4 killed (MSI 0%)     ← the test guards nothing
```

The test was green. It protected nothing. Strengthening the assertions:

```
tests pass  →  mutation: 2 of 4 killed (MSI 50%)
```

The two survivors turned out to be **equivalent mutants**: silently clamping
the discount made the boundary unobservable. Making the requirement explicit —
above 50% is an error, not a silent clamp — brought it to 100%.

That is the real payoff: mutation testing didn't just find a weak test, it
exposed a vague requirement.

### The lock that makes it mandatory

`guard-commit` blocks a commit if sources changed after the last green
gauntlet run. Without it, gates are a good intention — run when remembered.
With it, "work is done" and "checks passed" become the same event.

## What the locks actually block

Locks are `PreToolUse` hooks. They execute regardless of what the model decided
or remembered. 49 unit tests cover them.

| Lock | Blocks |
|---|---|
| `guard-bash` | container/image/volume deletion, force-push, `--no-verify`, `migrate:fresh`, `DROP DATABASE`, `rm -rf /` |
| `guard-tests` | **editing an existing test** (creating new ones is free) |
| `guard-infra` | edits to k8s manifests, playbooks, CI config, Dockerfiles, applied migrations, `.env` |
| `guard-deps` | adding a dependency by editing `composer.json`/`package.json` directly |
| `guard-commit` | committing without a green gauntlet run |
| `secret-scan` | secrets written in plaintext (`PostToolUse`) |

`guard-tests` closes the central hole in the whole approach: when a test fails,
the model has two options — fix the code or weaken the test. The second is
faster. So editing an existing test escalates to a human, while writing a new
one does not.

## Working with existing code

New features get a spec. Legacy code doesn't have one — and that's a different
problem, so it gets a different procedure.

**`legacy-characterize`** — pin current behaviour before changing anything:

1. Pick a narrow boundary — one function, one endpoint.
2. Run it on real inputs and **record the outputs as the baseline, without
   judging whether they're correct.** If something looks like a bug, it still
   gets pinned. The goal is to catch the system as it is, not to improve it.
3. List the oddities found, show them to the human, fix nothing yet.
4. **Verify the baseline can fail** — break the code on purpose; the test must
   go red. Otherwise the baseline is worthless.
5. Only now make changes. Any deviation is visible immediately.

The governing principle: **the agent builds the oracle and maintains it, but
never *is* the oracle.** What counts as correct is decided by a human or by the
existing system.

**`safe-removal`** — deletion is more dangerous than addition, for a
non-obvious reason: after deleting something, green tests prove nothing. If the
functionality wasn't covered, its disappearance goes unnoticed until a user
complains a week later. So the order is inverted: prove it's unused *first*,
then remove — entry point, then implementation, then dependencies, and data in
a separate release, never the same one.

## How rules reach a project

Claude Code plugins distribute skills, commands, agents and hooks — but **not
`.claude/rules/`**. And only `rules` support path-scoped loading via `paths:`,
which is deterministic rather than left to the model's judgement.

So rules are symlinked, and `std-link.sh` resolves the repository path
dynamically from `known_marketplaces.json` — the link survives
`/plugin update`. Symlinks contain absolute paths, so they are added to
`.gitignore` automatically, and a `SessionStart` hook verifies they're alive:
a silently broken rule is worse than a missing one.

## Tests

```bash
tests/run.sh
```

Nothing here invokes a model or spends tokens — it runs in seconds and is safe
as a blocking CI gate:

1. **Executable bits** — a non-executable hook fails silently.
2. **Module structure** — manifests, frontmatter, `owner`, `enforcement`, dead
   `paths:`, always-on context size, prose share.
3. **Locks** — 49 cases: JSON in, `allow`/`deny`/`ask` out.
4. **Stack detection and link integrity** — 20 cases, including regressions for
   bugs found during development.
5. **`claude plugin validate --strict`** on every module.

Separately, `tests/test-context.sh` verifies what usually stays an act of
faith: that a rule **actually loaded** into context for the right file. It's
built on the `InstructionsLoaded` hook, which journals every instruction file
Claude loads.

Three bugs were caught by these tests, not in production:

- `xargs -r` returns 0 on empty input — "no files" was indistinguishable from
  "match found", so Python projects were getting Kubernetes rules;
- `jq`'s `//` operator treats `false` as empty, so `requireBeforeCommit: false`
  silently didn't work;
- `grep` with a list containing non-existent paths returns 2, which under
  `set -o pipefail` reads as "not found".

## Writing your own rules

A module is a plugin under `plugins/std-<slug>/`. Copy the skeleton:

```bash
cp -r templates/module plugins/std-<slug>
```

Every rule needs frontmatter:

```yaml
---
paths: ["app/Http/**/*.php"]   # without this, the rule loads in EVERY session
owner: "@backend"               # who keeps it current
enforcement: lint               # hook | lint | test | review | prose
since: "2026-07-26"
---
```

`enforcement` is the important field. It forces the author to answer: *how is
this actually checked?* `prose` is only legitimate for things a machine cannot
verify — design rationale, agreements, boundaries. Anything else marked `prose`
is technical debt.

Write rules that can be verified: "validation only in FormRequest" beats
"validate your input". Keep them under 15 bullets — long rules are followed
less well than short ones.

Then register the module in `.claude-plugin/marketplace.json` and run
`tests/run.sh`. See [CONTRIBUTING.md](CONTRIBUTING.md).

## What this does not solve

Honest boundaries matter more than completeness:

- performance, race conditions, cost of operation — invisible to happy-path tests;
- architectural entropy — code can be correct and unextendable;
- correctness of the spec itself;
- a malicious dependency passes every check flawlessly.

The list in `std-gauntlet/rules/30-human-eyes.md` does not shrink as automation
grows. That's expected.

## Documentation

- [Examples](docs/EXAMPLES.md) — four walkthroughs from install to daily use
- [Architecture](docs/ARCHITECTURE.md) — why it's built this way
- [Enforcement](docs/ENFORCEMENT.md) — the rule-versus-lock boundary
- [The gauntlet](plugins/std-gauntlet/docs/GAUNTLET.md) — the five stages in detail
- [Contributing](CONTRIBUTING.md) — adding modules and rules
- [Security](SECURITY.md) — trust model and how to report a vulnerability

## License

MIT
