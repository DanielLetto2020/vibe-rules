# The ratchet: how it works and how to configure it

> 🇷🇺 [Русская версия](RATCHET.ru.md) · [all docs](README.md)

---

## What it is

A ratchet turns one way only. A car jack: you pump, the car goes up; you let
go, it does not drop back — the pawl holds it.

Same thing here, except what it holds is **test quality**.

The bar is not set in advance. It equals the best result the project has
already reached. Improve, and the bar rises. Try to hand in something worse and
the gate goes red.

```
run 1:  20%   bar set at 20
run 2:  45%   better → bar rises to 45
run 3:  44%   within tolerance, passes
run 4:  30%   FAIL — worse than it already was
```

One requirement: **don't make it worse than it is now.** Improving is optional.

---

## What the percentages are

This is the **mutation score** — the share of deliberate code breakages the
tests noticed.

The tool takes your code and breaks it in a hundred places: turns `>` into
`>=`, plus into minus, deletes a line. After each break it runs the tests.

- Tests go red — the break was caught.
- Tests stay green — those tests guard nothing there.

Coverage says "the line was executed". Mutation score says "the line was
verified". The second is the honest one: a suite with 100% coverage can miss
almost every bug.

---

## Why not just a threshold

A fixed threshold fails predictably.

Set 70% on an existing project that really sits at 30%:

```
day 1:  build red, nobody can commit
day 2:  "let's disable it for now"
day 8:  no check at all
```

Set 20% so it passes: unverified code flows in freely, the threshold does not
get in the way. There is a check, and it achieves nothing.

**Both options are bad.** A threshold is either unreachable or useless.

A ratchet works from any starting point, including zero. That is why it can be
switched on today on any project: it will not block work, and it will not let
things slide.

---

## Where things live

| File | What it holds | In git |
|---|---|---|
| `.claude/gauntlet.json` | settings: mode, starting bar | yes |
| `.claude/.ratchet.json` | current bar, best result, history | no |

The state is deliberately not committed: the bar depends on what was run on a
particular machine, and syncing it through git would mean constant conflicts.
In CI the bar starts from the value in the settings.

To inspect the current state:

```bash
ratchet.sh show
```

```
bar:   45%
best:  45%
history:
  2026-07-26T18:12Z  20%
  2026-07-26T19:30Z  45%
  2026-07-27T09:15Z  44%
```

The history exists for the "did this get better or worse over the quarter"
conversation — a single number does not answer it.

---

## Settings

All in `.claude/gauntlet.json`, under `mutation`.

### Mode

```json
{ "mutation": { "enabled": true, "mode": "ratchet", "floor": 50 } }
```

| Field | Values | Effect |
|---|---|---|
| `enabled` | `true` / `false` | whether the mutation gate runs at all |
| `mode` | `ratchet` / `absolute` | ratchet or fixed threshold |
| `floor` | number | starting bar for the ratchet |
| `threshold` | number | threshold for `absolute` mode |
| `changedOnly` | `true` / `false` | score only the changed files |

### A fixed threshold instead of the ratchet

When quality is already high and you want a firm number:

```json
{ "mutation": { "enabled": true, "mode": "absolute", "threshold": 80 } }
```

No ready-made profile is set this way: a stated figure is needed where an
outside party requires it — an audit, a regulation, a contract. That is
a person's decision, not something inferred from the repository.

### Changed files only

On a large project a full mutation run takes hours — so people stop running
it. Limiting it to changed files turns it into a check that actually happens:

```json
{ "mutation": { "mode": "ratchet", "floor": 0, "changedOnly": true } }
```

That is how the `legacy` profile is set. The tool receives
`--git-diff-filter=AM` (Infection) or `--since` (Stryker).

### Off entirely

```json
{ "mutation": { "enabled": false } }
```

Sensible for static sites and prototypes: there is nothing to mutate.

---

## Tolerance

A mutation run is not deterministic: timeouts, parallelism, test order. A
one-or-two point swing is noise, not decay.

So the bar is checked with a **2 point** tolerance: at a bar of 45, a 43 passes
and a 42 does not.

The tolerance is a constant in the script itself (`TOLERANCE=2` in
`ratchet.sh`). Raise it only if your runs are genuinely noisier — but first
find out why.

---

## When the gate goes red

```
RATCHET: 30% below the bar of 45%

The bar is the best this project has already reached. Going below means new
code is verified worse than the code already here.
```

**What to do, in order:**

1. Open the tool's report: which mutants survived, in which files.
2. Work through them — usually the assertion is too weak: it checks "not empty"
   instead of an exact value, or never touches a boundary.
3. Strengthen the assertions. More often than not you need a sharper check in
   an existing test, not a new test.

For a guided walkthrough, ask the agent to "go through the surviving mutants" —
the `mutation-harden` procedure covers it step by step.

**What not to do:** raise the tolerance, disable the gate, or bulk-exclude
mutants. That turns the check into decoration.

---

## Resetting the bar

Sometimes legitimate. You removed a large, well-covered module — the average
honestly dropped, and that is not decay.

```bash
ratchet.sh reset 40
```

A separate command on purpose: lowering the bar should be **a visible human
decision**, not a side effect of automation. The history records it as
"set manually".

---

## Can the logic itself be changed

Yes — the ratchet is an ordinary script:
`plugins/std-gauntlet/scripts/ratchet.sh`. Change it in the standards
repository, not in a project.

What is worth adjusting there:

- **tolerance** — the `TOLERANCE` constant at the top;
- **how much history is kept** — currently the last 50 runs;
- **the rule for raising the bar** — currently the bar equals the best result;
  you could make it "the average of the last three" if your runs are very
  noisy.

After editing, run `tests/run.sh`: the ratchet's logic is covered by tests and
they will catch a change in behaviour you did not intend.

If you need a fundamentally different regime — neither ratchet nor fixed
threshold — add a third `mode` alongside rather than rewriting the existing
ones: other projects are already configured against them.

---

## A second ratchet: compliance debt

The same principle applied to a second metric — the number of places that do
not match the standard. This metric moves the other way (lower is better), so
it has its own script, `debt.sh`, and its own state, `.claude/.debt.json`.

```bash
debt.sh count           count violations
debt.sh check           compare against the bar (this is what the `debt` gate does)
debt.sh show            bar, best achieved, history
debt.sh reset <number>  raise the bar deliberately
```

Why it sits next to a plain linter gate: the `types` gate asks "are there zero
errors?". On an existing project the answer is no, the gate is red always, and
it gets switched off on day one. The `debt` gate asks "are there no more errors
than before?" — a project can answer yes from the start, and the bar drops as
the files you touch get brought in line.

The counting command is inferred from the stack or set explicitly:

```json
{ "debt": { "command": "./vendor/bin/phpstan analyse --error-format=raw --no-progress" } }
```

It has one requirement: print one line per violation as `path:line: …`. That is
what `phpstan --error-format=raw`, `eslint -f unix`, `ruff
--output-format=concise` and `mypy` do. Tool summary lines are not counted —
otherwise the number would change when the linter is upgraded rather than when
the code changes.

The first run records a fact, not an aspiration: the bar equals what is there
today. From then on it can only go down; raising it is a deliberate human
decision via `reset`, needed when the config gets stricter or the linter is
upgraded.

How to use this in practice is the `std-modernize` procedure: measure, pick a
spot by cost, cover it with characterization tests, bring it in line, record
the new bar.

---

## What the ratchet does not do

- **It does not verify the specification.** Tests can kill every mutant and
  still check the wrong requirement.
- **It does not see performance or race conditions** — no happy-path test does.
- **It does not replace review of what tests never cover**: migrations,
  contracts, dependencies, access control.

---

## Next

- [The gauntlet](../plugins/std-gauntlet/docs/GAUNTLET.md) 🇷🇺 — five stages,
  the ratchet is the third
- [Profiles](PROFILES.md) — which mode each profile enables
