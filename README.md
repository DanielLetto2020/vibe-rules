# vibe-rules

[![gates](https://github.com/DanielLetto2020/vibe-rules/actions/workflows/validate.yml/badge.svg)](https://github.com/DanielLetto2020/vibe-rules/actions/workflows/validate.yml)
[![release](https://img.shields.io/github/v/release/DanielLetto2020/vibe-rules?color=blue)](https://github.com/DanielLetto2020/vibe-rules/releases)
[![license](https://img.shields.io/github/license/DanielLetto2020/vibe-rules?color=blue)](LICENSE)
[![modules](https://img.shields.io/badge/modules-29-blue)](#modules)

> 🇷🇺 [Русская версия](README.ru.md)

**Standards your AI agent actually follows.**

You explain the same conventions every session. The agent follows them most of
the time — and the times it doesn't are the ones you catch in review, if you
catch them at all.

There are two kinds of content here, and the second matters more:

- **rules** — text the agent reads. They don't all arrive at once, only when
  relevant: the Vue rule shows up when a `.vue` file is opened;
- **locks** — scripts that fire before a dangerous command runs. Deleting
  a data volume will not happen, whatever the agent decided.

> A rule in prose is a request. A rule in a lock is a guarantee.
> A request is honoured nine times out of ten. A lock has no percentage.

The end goal is to reach a state where not reading the generated code is a
defensible position rather than recklessness. Not by trusting the agent, but by
automating the distrust.

### 👉 First time here?

**[How this works, in plain words](docs/START.md)** — no jargon, with examples
and a glossary. Fifteen minutes, and everything after reads easily.

> **On language:** rule texts are written in Russian. The architecture, tooling
> and tests are language-agnostic — fork it and write your own rules in any
> language.

## The problem

Claude Code starts every session with an empty context. Two constraints follow:

1. **Everything you say costs tokens** — in every session, for every developer.
2. **The more you say, the less is followed.** The docs recommend keeping
   `CLAUDE.md` under 200 lines: long files consume context *and* reduce
   adherence.

So the question isn't *what to write*. It's *where to put it so it's found
exactly when needed*.

## The idea

Rules are organised **by when they load**, not by topic:

| Layer | Analogy | When it reaches the agent | Cost |
|---|---|---|---|
| **Lock** | a lock on the machine | never — it simply fires | 0 tokens, 100% enforced |
| **Always-on** | the morning briefing | every session | expensive, ≤200 lines |
| **Path-scoped** | a label on the machine | when a matching file is opened | pay only when relevant |
| **Task-scoped** | a manual on the shelf | when the task matches | pay only when relevant |
| **Reference** | the library down the hall | when the agent decides to look | nearly free |

Explained with examples in [How this works, in plain words](docs/START.md).

Every rule records **what backs it up**: a lock, a linter, a test, human
review — or nothing but an agreement ("prose").

The field is called `enforcement`, and it forces the author to answer an
awkward question: how is this actually checked? If the answer is "it isn't, we
hope people remember" — the rule should either be automated or dropped.

The test suite prints the share of unbacked rules. **That number must go
down.** A standards repository should shrink as automation grows, not swell.

### A file you touched gets brought up to standard

A loaded rule and an applied rule are different things. Rules arrive when
a file is read, but the write happens at the end of a long chain of reasoning,
and three of fifteen bullets get applied. The rest were not knowingly broken —
they were forgotten.

So after every write a hook names the modules whose `paths` matched the file:

```
Файл pages/index.vue подпадает под правила: std-js-base/10-language,
std-js-nuxt/20-data, std-js-vue3/20-reactivity, std-web-css/10-styles,
std-web-html/10-markup … Сверь с ними написанное — целиком файл, а не
только новые строки.
```

The radius is deliberately limited: **the whole file is checked, only what is
within the edit gets fixed**, and wider mismatches are reported to a human.
Without that limit one edit produces a diff of hundreds of lines — and in
a project without tests nothing backs that initiative up.

This is how a codebase written in mixed styles converges: one touched file at
a time, rather than in a refactor scheduled for someday. Disable with
`STD_RECHECK=0`.

## Quick start

```bash
# once per machine
/plugin marketplace add DanielLetto2020/vibe-rules
/plugin install std-core@vibe-rules

# in each project — one command
/std-core:setup --scope project
```

`setup` reads your repository, works out what kind of project this is,
installs the plugins it needs, links the matching stack modules and writes the
gate configuration. Nothing to pick by hand.

### Bound to the project, not to your machine

`--scope project` writes `.claude/settings.json` listing the marketplace and
the required plugins. Anyone who clones the repository is offered the install
on first open — nothing to set up by hand, and the setup cannot drift between
teammates.

Without it plugins are installed for your machine only (`--scope user`,
the default), and the project's files stay untouched. `--scope local` is the
same but for this project only and not committed.

Stack detection reads `composer.json`, `package.json`, `pyproject.toml`,
compose files, Kubernetes manifests and Ansible playbooks. Real output from
five different projects:

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

## Profiles: strictness that fits the project

One level of strictness for every project does not work. On a prototype it
slows down the very thing being tested; on legacy it is unreachable and gets
switched off on day one; in a team a lax setting means there are no standards
at all.

| Profile | When | Spec | Test-edit lock | Mutation gate |
|---|---|---|---|---|
| `prototype` | the default | not required | off | off |
| `solo` | on request: single author with tests | required | ask | ratchet from 50% |
| `team` | on request: code read by people who did not write it | required | ask | ratchet from 60% |
| `legacy` | 200+ commits, almost no tests | characterize first | ask | ratchet from 0%, changed files only |

**Safety locks are identical in every profile.** No profile permits deleting a
volume, force-pushing or committing a secret — the profile only moves the
quality bar.

**Strictness is not guessed from the repository.** The default is `prototype`:
rules and locks work, the quality bar does not rise on its own. `solo` and
`team` are opted into explicitly — `/std-core:setup --profile solo`.

Only `legacy` is detected automatically, and it is not about strictness but
about the mode of work: untested code is changed only after its current
behaviour has been pinned down.

The reason for that default is practical. Strictness used to be inferred from
the number of authors, so a static site without a single test got `solo` —
demanding a spec and a gate run for gates the project does not have.
A requirement with nothing to enforce it devalues the ones that do.

### The ratchet

A ratchet turns one way only: a car jack goes up as you pump and does not drop
back when you let go.

A fixed threshold has a characteristic failure mode. On an existing project the real
mutation score is usually 20–40%. A 70% gate is unreachable today, so it gets
disabled on day one. A 20% gate is useless — it does not stop unverified code
from arriving.

The ratchet sets the bar to **the best result the project has already
achieved**, minus a small tolerance for run-to-run noise. Improving is
optional; regressing is not.

```
run 1:  20%  → bar rises to 20%
run 2:  45%  → bar rises to 45%
run 3:  44%  → passes, within tolerance
run 4:  30%  → FAILS — new code is verified worse than what already exists
```

That is what makes the gate usable on legacy from day one, at any starting
point. Settings, history and how to change the logic — [the ratchet
page](docs/RATCHET.md).

## Organisation policy

Rules in this repository are universal practices. A company usually also has a
**policy** — which technologies are permitted, which minimum versions, which
packages are out. That is a different axis: this repository says *how to use
Postgres*, a policy says *Postgres 13+ and nothing else*.

`std-policy` is the mechanism for it. The content stays private — in your own
repository — while the enforcement is public and shared:

```json
{
  "runtime": { "php": "8.1", "node": "18" },
  "stability": { "denyPrerelease": true },
  "deniedPackages": { "some/lib": "unmaintained since 2023" },
  "staticAssets": { "maxBinaryKb": 512 },
  "exempt": { "enabled": false, "reason": "" }
}
```

A `PreToolUse` lock checks dependency changes against it: a beta version,
a banned package or a runtime below the minimum is blocked before it lands.
Twenty test cases cover the lock.

Two properties matter more than the feature list:

- **A policy never unlocks safety.** Even with `exempt: true` — for a project
  built by an outside contractor, or with an approved deviation — deleting
  a volume and force-pushing stay blocked. Otherwise the exemption flag would
  become the way to switch protection off entirely.
- **No policy file, no interference.** Projects without a policy see nothing.

A policy is independent of the profile: the required gate set comes from the
policy and a project cannot weaken it, only add to it.

## Rules for one project only

Shared modules describe a technology. Every project also has things true only
here: team agreements, traps in this codebase, deviations from a shared rule
with a reason.

Those live next to the shared ones and **are committed with the code**:

```
.claude/rules/
  00-precedence.md     ← declares which source wins, in git
  std-php-laravel      ← shared module, a symlink, gitignored
  std-web-css          ← shared module
  billing-legacy.md    ← this project's rule, in git
```

```bash
/std-core:rule new billing-legacy backend   # create from a template
/std-core:rule list                         # what is where
/std-core:rule override php-laravel         # switch a shared module off here
```

A project rule loads exactly like a shared one — by file path. The only
difference is where it comes from and that it never reaches the shared
repository.

### Why precedence has to be declared

Claude Code loads every rule with **equal weight**. There is no automatic
"the project wins". If a project rule and a shared module contradict each
other, the model picks one arbitrarily and nobody finds out which.

`00-precedence.md` states it plainly: the project rule wins, **and the
contradiction must be reported rather than silently resolved**. The second
half matters more — a contradiction means either the shared rule needs
refining or the local deviation is obsolete, and both are decisions for
a human.

Switching a shared module off records the deviation in that same file and
marks the reason as mandatory. A deviation without a reason is
indistinguishable from an oversight six months later.

## Modules

| Module | Covers |
|---|---|
| `std-core` | locks, rule linking, diagnostics — install everywhere |
| `std-gauntlet` | the gauntlet: spec, tests, mutation, metrics, gates — install everywhere |
| `std-policy` | mechanism for an organisation's stack policy: allowed technologies, minimum versions |
| `std-api-http` | versioning, field and path naming, contracts, status codes |
| `std-arch-services` | service boundaries, request auth, gateway without logic |
| `std-arch-approach` | choosing DDD, code-first or db-first by complexity |
| `std-ops-observability` | structured logs, business metrics, alerting, verified backups |
| `std-php-base` | PHP as a language: `strict_types`, types, strict comparison |
| `std-js-base` | JS/TS runtime behaviour: promises, comparison, dates, money |
| `std-py-base` | Python as a language: annotations, mutable defaults, resources |
| `std-php-laravel` | HTTP layer, Eloquent, tests |
| `std-php-yii2` | controllers, ActiveRecord, driver type pitfalls |
| `std-web-html` | semantics, accessibility, forms, resource loading |
| `std-web-css` | cascade, specificity, units, responsive layout |
| `std-web-design` | following the design already in place; deliberate choices when starting fresh |
| `std-js-typescript` | type strictness, runtime boundaries, discriminated unions |
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
   Its second form is **corrupting values in the spec**: change a number in a
   scenario, and if the test stays green it is not checking what was ordered.
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
5. **Profiles, ratchet and setup** — 20 cases: profile inference from a
   synthetic git history, ratchet raising and holding the bar, profile
   controlling lock strictness, repeated setup preserving manual edits.
6. **Stack policy** — 20 cases, including: an exempt project keeps its safety
   locks, and a project without a policy file is left alone.
7. **Project-level rules** — 19 cases: template, precedence file, deviation
   recording, and the split between committed project rules and gitignored
   shared symlinks.
8. **`claude plugin validate --strict`** on every module.

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

**[Documentation map](docs/README.md)** — what is where, with a "when to open
this" note for each page and quick answers to common questions.

If there is time for one page only:
**[How this works, in plain words](docs/START.md)**.


## License

MIT
