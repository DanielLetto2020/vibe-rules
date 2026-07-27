# Legacy: rewrites and refactoring, by the rules

> 🇷🇺 [Русская версия](LEGACY.ru.md) · [all docs](README.md)

---

## What this solves

Rules and gates are designed for code being written now. On old code they
break in ways you may not expect:

- the quality threshold is unreachable — the gate is disabled on day one;
- the agent sees old code and "improves it while it's here", handing you a
  four-hundred-line diff instead of thirty;
- "behaviour did not change" is an opinion, because there are no tests.

Below are three modes for working with such areas. All three are set up with
project rules and settings; the shared standards repository stays untouched.

---

## Start with the profile

```bash
/std-core:setup --profile legacy
```

The `legacy` profile differs from the others in four ways:

- **the mutation gate runs as a ratchet from a zero starting bar** — the only
  requirement is "no worse than now";
- **only changed files are scored** — a full run on a large project takes
  hours, so people stop running it;
- **a spec before code is not required** — when fixing a bug in a module
  written in 2017, that is ritual, not value;
- **characterization is required instead** (`characterizeFirst`): before
  changing an uncovered area, its behaviour is pinned down by tests. There is
  no spec, but there must be a reference point.

Safety locks are not relaxed by any of this: no profile permits deleting a
volume, force-pushing, or committing a secret.

Details in [Profiles](PROFILES.md) and [The ratchet](RATCHET.md).

---

## Mode 1. Transition period: old and new side by side

The most common case. The project is rewritten piece by piece, and two
contours live side by side for months, under different rules.

```bash
/std-core:rule new billing-migration migration
```

This creates a rule with the wording already written; three places need
filling in: the boundary between contours, `paths`, and the criterion by which
the migration counts as finished.

What it says, and why:

**The boundary is declared explicitly.** `app/Legacy/**` is old,
`app/Domain/**` is new. Without this the agent cannot tell which is which, and
the rule does nothing at all.

**New code follows the shared rules in full.** No discounts for "it's a
migration" — otherwise the new contour becomes a second old one.

**Old code is touched only for a stated task.** "While I'm here", "in
passing", "since it was open" — no. A style-only edit creates diffs nobody
reads and hides the real changes inside them. This is precisely the mistake an
agent makes by default: it sees code that violates the rules and treats fixing
it as its duty.

**The old code's style is preserved.** Bringing it to the new conventions
happens only together with the move.

---

## Mode 2. A freeze zone

An area that is not touched at all: no tests and no way to write them without
a staging environment, or it is being rewritten on another branch, or it is
being retired.

```bash
/std-core:rule new old-reports freeze
```

The template has two mandatory blanks, and both earn their place.

**The reason.** Valid: "no tests and no environment", "being rewritten on
branch X", "retired by end of quarter". Invalid: "scary to touch" — that
describes a feeling, not a boundary, and such a freeze never lifts.

**The lifting condition.** An event or a date. A freeze without a deadline
becomes permanent, and a year later nobody remembers why this area is
off-limits.

What is still allowed under a freeze: reading it and relying on it, and fixing
production incidents — with a stated task and a mandatory test reproducing the
failure.

---

## Mode 3. Moving an area into the new contour

The order is mandatory, one commit per step.

### Step 1. Pin the behaviour

```
tell the agent: pin down the behaviour of the Billing module
```

This runs the `legacy-characterize` procedure. It writes **characterization
tests** — they verify not how things should be, but **how they are right
now**, quirks and bugs included. A test that fails against existing behaviour
is wrong here: it describes a wish, not a fact.

This is the only way to turn "behaviour did not change" from an opinion into a
checkable statement.

**An important limitation.** The agent builds the oracle but is not the
oracle: it does not know which quirks are bugs and which are requirements
somebody depends on. A human reviews the list of pinned quirks. That is
usually ten minutes and one or two genuine discoveries.

### Step 2. The new implementation

Written to the shared rules. The same characterization tests must be green
against it.

### Step 3. Switching the call sites

A separate commit, so that rolling back is a single action.

### Step 4. Deleting the old code

```
tell the agent: remove the Billing module from the legacy contour
```

The `safe-removal` procedure: what gets deleted is what has no references
left, not what "looks unused". The difference between those two phrasings is
usually one production incident.

---

## How gates behave on legacy

**The ratchet does not demand growth.** The bar equals the best result
reached. A project at 12% passes with 12%. The only requirement is not to hand
in worse.

**The bar rises on its own** as areas are migrated: new code comes with tests,
the average climbs, and the ratchet locks in what was reached.

**When a drop is legitimate** — say, a large well-covered module was removed:

```bash
ratchet.sh reset 40
```

A separate command on purpose: lowering the bar should be a visible human
decision, not a side effect.

---

## The typical rollout mistake

Setting a strict profile on legacy and expecting quality to follow.

```
day 1:  build red, nobody can commit
day 2:  "let's disable it for now"
day 8:  no checks at all
```

The reverse order works: weak requirements that are **actually followed**,
plus a ratchet that prevents backsliding. A quarter later that yields more
than a strict threshold switched off on day two.

---

## What standards do not solve on legacy

- **They do not find bugs in old code.** Characterization tests pin behaviour
  as it is — bugs included. Finding those is separate work.
- **They do not replace domain knowledge.** A quirk in a discount calculation
  may be a requirement one person in the company still remembers.
- **They do not speed up the migration.** They make it reversible and
  checkable — a different property.

---

## Next

- [Project-level rules](CUSTOMIZATION.md) — where project rules live
- [The ratchet](RATCHET.md) — how the bar works and how to move it
- [Examples](EXAMPLES.md), scenario 3 — old code without tests, step by step
