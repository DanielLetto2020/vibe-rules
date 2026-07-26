# How this works, in plain words

> 🇷🇺 [Русская версия](START.ru.md) · [back to README](../README.md)

This page is for someone opening the repository for the first time. No jargon;
every unfamiliar word is explained where it first appears.

---

## The problem everything grew from

Imagine a very fast developer who turns up every morning with complete amnesia.
They know PHP, Vue and Python well. They remember nothing about your project,
yesterday's conversation or the team's agreements.

That is not a metaphor — it is how an AI agent works: every session starts
from a blank slate.

So every morning you brief them again. And there are two catches.

**First: briefing costs money.** Everything you say each morning is paid for in
every session, by every developer.

**Second, and it matters more: the more you say, the less is followed.** Dump
eighty rules on someone and they will remember ten. Which ten is not up to you.

Hence the whole design: **don't say everything at once — put each thing where
it will be found exactly when it is needed.**

---

## Four places to put a rule

### 1. The morning briefing

You say out loud: "we're building billing on Laravel 11, tests run like this,
business logic lives in Actions." Short, specific to this project, every day.

That is the `CLAUDE.md` file in the project root. It is read at the start of
every session, which is why it stays short.

### 2. A label on the machine

You don't explain the milling machine's rules every morning — you put a label
on the machine. Whoever walks up to it reads it.

That is how **path-scoped rules** work: the Vue rule sits on `.vue` files, the
migration rule on the migrations folder. There can be two hundred of them and
the morning briefing does not grow by a single line.

### 3. A manual on the shelf

"How to add a new parser" is not a rule, it is a fifteen-step procedure. Nobody
carries it in their head; you fetch it when you take on that kind of task.

### 4. A lock on the machine

The important one. If a part must never go in without a clamp, you don't write
that on a label. You make the machine **physically refuse to start** without
the clamp.

These are scripts that fire before a command runs. They take no part in the
briefing and work regardless of what the agent read or remembered.

> **The central idea of this repository:**
> a rule in prose is a request; a rule in a lock is a guarantee.

A request is honoured nine times out of ten. A lock has no percentage.

---

## Glossary

A few words appear throughout the docs and are worth explaining once.

### Lock

A script that fires before a dangerous action and stops it. For example
`podman volume rm` — deleting a data volume — is blocked before the command
reaches the system.

Locks come in three strengths:

- **deny** — the command will not run (deleting data, force-push);
- **ask** — you decide (editing a server manifest, adding a dependency);
- **stay quiet** — an ordinary action, nothing to interfere with.

### Gate

A check the work must pass to count as done: linter, type checker, tests.
A red gate means "not done", not "almost done".

All gates run from one command so nobody has to remember five of them.

### Mutation testing

A way to check not the code, but **the tests themselves**.

The tool takes your code and deliberately breaks it in a hundred places: turns
`>` into `>=`, plus into minus, deletes a line. After each break it runs the
tests.

- Tests go red — the break was caught, good.
- Tests stay green — those tests guard nothing at that spot.

Why it matters: coverage tells you a line was executed. It does not tell you
the line was verified. A suite with 100% coverage can miss almost every bug —
it runs everything and checks nothing.

The share of breaks caught is called the **mutation score**.

### Ratchet

A ratchet turns one way only. A car jack: you pump, the car goes up; you let
go, it does not drop back.

Test quality works the same here. The bar is not set in advance — it equals
**the best result the project has already reached**:

```
run 1:  20%   bar set at 20
run 2:  45%   better → bar rises
run 3:  44%   within tolerance, passes
run 4:  30%   STOP — worse than it already was
```

One requirement: **don't make it worse than it is now.** Improving is optional.

Why not simpler? A fixed threshold does not work. Set 70% on an existing
project that really sits at 30% and the build is red from day one — the check
gets switched off within a week. Set 20% and it catches nothing. A ratchet
works from any starting point, including zero.

### Profile

A set of requirements matched to the state of the project. A throwaway
prototype does not need what a billing system needs.

The profile is worked out automatically — from how many people commit, how many
commits exist and whether tests exist. One command changes it.

**Important:** a profile moves the quality bar but **never touches the safety
locks**. No profile allows deleting a volume, force-pushing or committing
a password.

| Profile | For | Strictness |
|---|---|---|
| prototype | testing an idea, code likely thrown away | almost nothing required |
| solo | real project, single author | moderate, without ceremony |
| team | code is read by people who did not write it | moderate + consistency |
| legacy | old code without tests | pin current behaviour first |
| corporate | an organisation policy applies | required checks come from above |
| regulated | money, personal data | maximum; editing tests is forbidden |

### Rules and profiles are different things

A common confusion, so it gets its own note.

**A profile** decides *how strictly to check*: whether a spec is required,
whether gates run before a commit, where the test-quality bar sits.

**A rule** says *how code is written here*. It does not depend on the profile
at all.

The same rule — "validation lives in one place" — applies equally in a
throwaway prototype and in a billing system. The difference is not in the rules
but in how many checks the work must pass.

**You don't write different rules for different profiles** — you write one and
it works everywhere. How to write one is [a page of its own](WRITING-RULES.md).

### Module

A set of rules for one technology: Laravel, Vue, Postgres, Kubernetes. It is
connected automatically — the system looks at the project's files and works out
what is needed.

Language and framework modules are separate: PHP is not always Laravel.
A plain PHP project gets the language rules and nothing irrelevant.

---

## What a day looks like

A developer opens the project and types: "add order creation".

1. The agent sees `CLAUDE.md` — stack, commands, where things live.
2. It opens the controllers folder and the HTTP-layer label **arrives by
   itself**: validation goes here, responses through that class, no logic here.
3. The task resembles the "new feature" procedure — the agent takes it off the
   shelf and follows the steps: acceptance criteria, then a failing test, then
   the code.
4. It tries to add a package — **a lock stops it** and asks you. A malicious
   package passes every test flawlessly; this is the one thing automation
   cannot catch.
5. It tries to weaken an old test so it goes green — **a lock stops it**.
   Writing a new test is free; weakening an existing one is not.
6. At the end, a separate list: what needs your eyes — migrations, contract
   changes, anything touching money and access.

The developer did none of this by hand: no copying rules, no reminding about
standards. It just happened.

---

## What you run yourself

Three commands, ever:

```bash
/std-core:setup      once per project: detects, installs, configures
/std-core:sync       when the project gains a new technology
/std-gauntlet:run    before committing (a lock reminds you anyway)
```

Everything else happens on its own.

Two things still need you personally: **read the acceptance criteria before
work starts**, and **read the "needs your eyes" list at the end**. Those are
the points where nothing replaces you.

---

## What this does not do

Honest limits matter more than completeness:

- it does not catch performance problems or race conditions — happy-path tests
  never see them;
- it cannot tell correct code from unextendable code;
- it does not verify that the task itself was stated correctly;
- it does not protect against a malicious dependency — that passes every check
  flawlessly.

The list of what stays with a human does not shrink as automation grows. That
is expected and by design.

---

## Where to go next

- [Writing your own rule](WRITING-RULES.md) — step by step, with examples
- [Profiles](PROFILES.md) — where they live, how to pick and adapt one
- [Examples](EXAMPLES.md) — five walkthroughs: onboarding, a new feature,
  legacy code, removal, a project-specific rule
- [Architecture](ARCHITECTURE.md) 🇷🇺 — why it is built this way
- [Rule or lock](ENFORCEMENT.md) 🇷🇺 — deciding where a requirement belongs
- [The gauntlet](../plugins/std-gauntlet/docs/GAUNTLET.md) 🇷🇺 — the five
  stages in detail
