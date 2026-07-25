# Examples: from install to daily use

> 🇷🇺 Русская версия описания — в [README.ru.md](../README.ru.md).

Four walkthroughs covering what actually happens once the standards are wired
into a project.

---

## Example 1 — Onboarding an existing project

A Laravel project that already has its own `CLAUDE.md`. Ten minutes.

```bash
/std-core:link --auto
```

```
Standards repository: ~/.claude/plugins/marketplaces/vibe-rules
  + std-core        -> .../std-core/rules
  + std-gauntlet    -> .../std-gauntlet/rules
  + std-php-base    -> .../std-php-base/rules
  + std-php-laravel -> .../std-php-laravel/rules
  + std-js-base     -> .../std-js-base/rules
  + std-js-vue3     -> .../std-js-vue3/rules
  + std-sql-postgres -> .../std-sql-postgres/rules
  + .gitignore: added .claude/rules/std-*
```

Then configure the gates:

```bash
/std-gauntlet:init
```

This reads the project, finds the real test and lint commands, and reports the
**actual mutation score**. Expect an unpleasant number next to a healthy
coverage figure — that number is the argument for everything else.

### The one manual step

Open your existing `CLAUDE.md` and delete everything now delivered by a module.
If it says "validation goes in FormRequest" and `std-php-laravel` says the same
thing, remove it from the project file. Duplication doesn't break anything
immediately — it burns context in every session and drifts apart from the
shared rule over time.

Keep only what is unique to this repository: versions, commands, layer map,
traps.

### Handling conflicts

Rules from `.claude/rules/` and your `CLAUDE.md` carry **equal weight**. There
is no automatic "project wins". If they contradict each other, the model picks
one arbitrarily and you won't know which.

So state it explicitly. Add to the project `CLAUDE.md`:

```markdown
## Rule precedence
Rules in this file take precedence over the shared ones in `.claude/rules/std-*`.
If you see a contradiction — follow this file and **tell me about it**.
```

The second sentence matters more than the first: it turns a silent conflict
into a signal that the shared rule needs fixing.

---

## Example 2 — A new feature

> "Add an order cancellation endpoint."

The task matches the `feature-by-spec` description, so Claude picks up the
procedure.

**1. Spec first, shown to you before any code:**

```gherkin
Feature: Order cancellation

  Scenario: successful cancellation
    Given a paid order for 1500
    When the customer cancels it
    Then the money is refunded
    And the order status becomes "cancelled"

  Scenario: cancelling an already shipped order
    Given an order in status "shipped"
    When the customer cancels it
    Then the cancellation is rejected
    And the customer sees "order already shipped"
```

Unhappy paths are mandatory: no permission, already shipped, repeat
cancellation, payment provider unreachable. **Work stops here until you
confirm.** This is the only point where an error is caught by nothing below.

**2. Failing tests derived from the spec** — and proof they fail for the right
reason ("method not found" is right; "syntax error in the test" is not).

**3. Implementation.** Opening `app/Http/` pulls in the HTTP-layer rule;
opening `app/Models/` pulls in the Eloquent rule. Both arrive automatically
because a matching file was read.

**4. A lock fires** when a refund package is about to be installed:

```
Adding a new dependency. Confirm the package and its source —
tests do not cover this risk.
```

**5. Gates:**

```bash
/std-gauntlet:run
```

```
▸ style      passed
▸ types      passed
▸ test       passed
▸ mutation   passed

════ SUMMARY ════
  ✓ style
  ✓ types
  ✓ test
  ✓ mutation

ALL GATES PASSED

This does NOT mean the changes need no review. Gates do not cover:
  migrations and schema · API contract changes · new dependencies
  money, access control, personal data · k8s manifests and playbooks
  performance, race conditions, cost of operation
```

**6. Trying to commit** before re-running the gates after an edit:

```
Sources changed since the last successful gate run: app/Actions/CancelOrder.php.
Checks are stale — run /std-gauntlet:run before committing.
```

---

## Example 3 — Legacy code with no tests

> "Fix the discount calculation in the old module, there are no tests there."

`legacy-characterize` takes over, and it **does not start fixing**.

1. **Narrow the boundary** — one function with an observable input and output.
2. **Pin current behaviour** on real inputs. Outputs are recorded as the
   baseline *without judging whether they are correct*. If something looks like
   a bug, it still gets pinned — the goal is to catch the system as it is.
3. **Report the oddities**, fix none of them yet.
4. **Verify the baseline can fail** — break the code on purpose, the test must
   go red. If it doesn't, the baseline pins something that doesn't affect the
   result.
5. **Now fix.** The baseline goes red in exactly one place, and that's visible.

Where inputs come from, in descending order of value: production logs, an
anonymised database snapshot, boundary values (empty, zero, negative, maximum,
unicode, very long), random generation. Invented "nice" inputs give false
confidence — they land on the happy path, while the system fails on dirty data.

**The governing principle:** the agent builds the oracle and maintains it, but
never *is* the oracle. What counts as correct behaviour is decided by a human
or by the existing system.

---

## Example 4 — Removing a feature

> "Rip out the old promo code system."

`safe-removal` inverts the usual order, for a reason that isn't obvious:

> **After a deletion, green tests prove nothing.** If the functionality wasn't
> covered, its disappearance goes unnoticed by every test — until a user
> complains a week later.

1. **Find every consumer** — not just direct calls: routes, scheduled jobs,
   queue handlers (a message may arrive from another service), templates,
   fixtures, config, feature flags, docs, client SDKs. Search by fragments of
   the name too — a call may be assembled from strings.
2. **Prove it's unused.** Absence of call sites is not proof. Logs and metrics
   over a representative period: an endpoint with zero calls in a month and one
   called quarterly at period close are different cases. If there's no data,
   Claude says so plainly rather than deleting on a hunch.
3. **Remove in stages**, outermost first: disable the entry point → deploy and
   observe → delete the implementation → drop now-unused dependencies →
   **data last, in a separate release.**

Between "stopped writing to the column" and "dropped the column" there must be
a pause. Code rolls back in a minute; deleted data never does.

Tests of the removed feature go with it — the only legitimate reason to delete
a test. A test covering both removed and surviving behaviour is trimmed, not
deleted.

---

## What you run by hand, ever

```bash
/std-core:link --auto     once per project
/std-gauntlet:init        once per project
/std-gauntlet:run         before committing (the lock reminds you anyway)
```

Everything else happens on its own: rules arrive when a matching file is
opened, procedures engage when the task matches, locks fire when something
dangerous is attempted.

The two things that still require you personally: **read the spec before work
starts**, and **read the "needs human eyes" list at the end**. Those are the
points where nothing can replace you.
