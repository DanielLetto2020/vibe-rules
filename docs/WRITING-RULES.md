# Writing your own rule

> 🇷🇺 [Русская версия](WRITING-RULES.ru.md) · [back to README](../README.md) ·
> [start with the basics](START.md)

---

## First, an untangling: rules and profiles are different things

A common confusion, so let's clear it up before anything else.

**A profile** answers "how strictly should this be checked". It governs the
checks: whether a spec is required, whether gates run before a commit, where
the test-quality bar sits, whether editing a test needs confirmation.

**A rule** answers "how do we write code here". It does not depend on the
profile at all.

The same rule — "validation only in FormRequest" — applies equally in a
throwaway prototype and in a billing system. The difference between them is not
in the rules but in how many checks the work must pass to count as done.

So **you do not write different rules for different profiles.** You write one,
and it works everywhere.

---

## Where a requirement belongs

Before writing a rule, check that it should be a rule at all. One question
settles it:

> **Can a machine check this without a human?**

| Answer | Where it goes | Example |
|---|---|---|
| Yes, and it's a dangerous action | **lock** | deleting a volume, force-push |
| Yes, a linter catches it | **linter config** | indentation, function length, `any` in TypeScript |
| Yes, a test catches it | **test** | system behaviour |
| No, but a human must look | **rule** | "migrations are always read by eye" |
| No, it's an agreement | **rule** | "don't touch the legacy module without asking" |

If a linter can check it, it does not belong in prose. Prose is read and
usually followed. A linter does not ask.

A rule is for what **a machine cannot verify**: reasons behind decisions,
agreements, boundaries of responsibility, traps specific to a project.

---

## Two kinds of rules

### Shared — for every project on that stack

Lives in this repository under `plugins/std-<stack>/rules/`. Everyone who
connects the module gets it.

Write one when the requirement holds for any project using that technology.
For example: "every Redis key has a TTL" — true everywhere.

### Project rule — only here

Lives in the project itself under `.claude/rules/`, is committed with the code
and never reaches the shared repository.

Write one when the requirement is true only in this project: team agreements,
traps in this codebase, deviations from a shared rule.

Create it with:

```bash
/std-core:rule new billing-legacy backend
```

A template appears with prompts. Then fill it in.

---

## When a rule is worth adding at all

Three legitimate triggers, all of them **after the fact**, never in
anticipation:

1. The agent made the same mistake **a second time**.
2. Review caught something it should have known.
3. You typed the same correction into chat twice.

An illegitimate trigger: "let's write down everything we know about Laravel
just in case". That is the fastest way to kill the repository — plenty of text,
no adherence, and context spent in every session by every developer.

A rule costs money. It has to pay for itself.

---

## What a rule is made of

```markdown
---
paths:
  - "app/Http/**/*.php"
owner: "@backend"
enforcement: review
since: "2026-07-26"
---

# Heading: what the rule is about

- Each point is stated so it can be verified.
- Reasons appear where they are not obvious.
```

Field by field.

### `paths` — where the rule applies

The most important field. It decides **when** the rule reaches the agent.

```yaml
paths:
  - "app/Http/**/*.php"     # only HTTP-layer files
```

The agent opens a file under `app/Http/` — the rule arrives. Working on the
frontend — it does not, and no context is spent.

**Without `paths` a rule loads in every session**, even when irrelevant. Do
that only for things that genuinely touch everything: for example, "tests are
never bent to fit the implementation".

Pattern examples:

| Pattern | Matches |
|---|---|
| `**/*.vue` | every Vue component in any folder |
| `app/Models/**` | everything inside the models folder |
| `**/migrations/**` | migrations wherever they live |
| `**/*.{ts,tsx}` | TypeScript files with either extension |

Checking that a pattern hits the right files is easy: open such a file and run
`/context` — the rule should appear in the list.

### `owner` — who is responsible

Who updates the rule when it goes stale. Without an owner, nobody will dare
touch it in six months: is it still relevant, or was it simply forgotten?

For a project rule this can be a team or a person, whatever you use.

### `enforcement` — what backs it up

Here the author answers the awkward question: **how is this checked?**

| Value | Meaning |
|---|---|
| `hook` | a lock prevents the violation |
| `lint` | a linter catches it, and the config ships with the module |
| `test` | the test suite catches it |
| `review` | not automatable, a human looks |
| `prose` | an agreement, or the reason behind a decision |

A rule marked `lint` with no linter config is self-deception: it looks like a
check and behaves like a request.

`prose` is only legitimate for what a machine genuinely cannot verify.
Anything else marked `prose` is technical debt.

### `since` — when it appeared

A date. It helps during the quarterly review to tell a living rule from
a leftover.

---

## How to phrase the points

### Verifiable, not aspirational

| Poor | Good |
|---|---|
| Write readable code | Methods up to 15 lines |
| Validate your data | Validation only in FormRequest |
| Mind performance | Load relations with `with()`, never query inside a loop |
| Think about security | Secrets come from environment variables only |

The test is simple: **can you say unambiguously whether this point was
violated?** If two people look at the code and disagree, the wording is bad.

### Reasons where they are not obvious

No need to explain the obvious. Explain what looks strange:

> Compare type-safely: `(int)$x === self::STATUS`, not `$x === 3`. Under
> Postgres an integer column comes back as a string, and this bug does not
> reproduce on SQLite.

Without the second sentence the rule looks like nitpicking. With it, it makes
sense and nobody works around it.

### Short

Aim for under 15 points per file. Long rules are followed less reliably than
short ones. If it doesn't fit, it is probably two rules.

### No contradictions

If two rules say different things, the agent picks one arbitrarily and you
won't know which. Before adding, look for an existing rule on the same topic.

---

## When a shared rule doesn't fit your project

That happens legitimately. A shared rule says "validation in FormRequest", but
your legacy module won't be migrated for another six months.

Three options, in order of severity:

**1. Record the deviation.** The module stays connected, and the reason goes
into the project's precedence file:

```markdown
### Validation in controllers inside the billing module
Reason: not migrated to FormRequest, migration scheduled. New code follows the
shared rule.
```

**2. Write a project rule** that refines the shared one. On a contradiction the
project rule wins — that is stated in the precedence file created at setup.

**3. Switch the module off entirely:**

```bash
/std-core:rule override php-laravel
```

The deviation is recorded automatically, but you fill in the reason by hand.
A deviation without a reason is indistinguishable from an oversight six months
later.

Before dropping a module, check whether only one of its rules conflicts.

---

## Check that the rule works

Once written, make sure it arrives:

1. Open a file matched by `paths`.
2. Run `/context` — the rule should be listed.
3. Ask a question on the rule's topic and see whether the agent refers to it.

The third step matters more than the first two. A rule can load and still go
unnoticed if it is vaguely worded.

---

## Quarterly review

A rule that was never violated in a quarter is either:

- already enforced by a linter, so the text can go (the check stays), or
- needed by nobody, so it can go entirely.

Both outcomes are progress. A standards repository should shrink as automation
grows, not swell.

---

## Where to go next

- [The basics in plain words](START.md)
- [Profiles](PROFILES.md) — where check strictness is configured
- [Examples](EXAMPLES.md) — the fifth walkthrough covers a project rule
- [Rule or lock](ENFORCEMENT.md) 🇷🇺 — more on the boundary
- [Adding a module](../CONTRIBUTING.md) — if you need a whole new stack
