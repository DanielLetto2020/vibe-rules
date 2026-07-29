# Contributing

> 🇷🇺 Правила пишутся на русском — см. [README.ru.md](README.ru.md).
> Discussion in English or Russian is equally welcome.

## The one question to answer first

**Can a machine check this?**

If yes, it does not belong in prose. A rule written as text is a request —
the model reads it and follows it most of the time. A rule compiled into a
linter config or a hook is a guarantee.

| Answer | Where it goes | `enforcement` |
|---|---|---|
| Dangerous, irreversible action | `std-core/scripts/*.sh` | `hook` |
| Formalisable as a code property | `configs/` of the module | `lint` |
| Formalisable as system behaviour | project tests | `test` |
| Cost of error not covered by tests | rule text, explicit list | `review` |
| None of the above | rule text | `prose` |

A module made entirely of `prose` is a bad module. The test suite prints, on
every run, how many rules a machine backs (`lint`, `hook`, `test`) and how many
rest on a person (`review`, `prose`). The second number is the metric, and it is
expected to fall over time: `review` means "a human will read the code" — the
very thing this repository is meant to reduce.

## When to add a rule at all

Only in reaction, never in anticipation:

- the model made the same mistake a second time;
- code review caught something the model should have known;
- you typed the same correction into chat twice.

"Let's write down everything we know about Laravel" is the fastest way to turn
this repository into text nobody reads, that also inflates context in every
session for every developer.

## Adding a module

```bash
cp -r templates/module plugins/std-<slug>
```

1. Fill in `.claude-plugin/plugin.json` — `name` must match the directory name.
   Set `version` explicitly; without it every commit counts as a new release.
2. Write rules in `rules/`. One file, one topic. Required frontmatter:

   ```yaml
   ---
   paths: ["src/**/*.ts"]   # without this the rule loads in EVERY session
   owner: "@team"
   enforcement: lint
   since: "2026-07-26"
   ---
   ```

3. Put anything automatable into `configs/` — a ready linter config the project
   can adopt. A rule marked `enforcement: lint` **must** have a counterpart
   there, otherwise it is prose pretending to be a check.
4. Register the module in `.claude-plugin/marketplace.json`. Without this entry
   it cannot be installed.
5. Run `tests/run.sh`. Red means not ready.

Language rules and framework rules are separate modules. PHP is not always
Laravel: `std-php-base` covers the language, `std-php-laravel` stacks on top.
Follow that split for new stacks.

## Writing a good rule

- **Verifiable, not aspirational.** "2-space indentation" over "format
  properly". "Validation only in FormRequest" over "validate input".
- **Under 15 bullets.** Long rules are followed less reliably than short ones.
- **Explain *why* only where it isn't obvious** — a reason nobody can derive
  from the code is worth its tokens; a reason everybody knows is not.
- **Don't contradict another rule.** When two rules conflict, the model picks
  one arbitrarily and you won't know which.

## Adding a lock

Locks live in `plugins/std-core/scripts/` and are wired in `hooks/hooks.json`.

A hook is a pure function: JSON in, `allow` / `deny` / `ask` out. That makes it
fully testable without invoking a model. **Every lock must come with cases in
`tests/test-hooks.sh`** — both the blocked call and a similar call that must
pass. A lock that blocks too much gets disabled within a week.

Prefer `ask` over `deny` for anything a human might legitimately want to do.
`deny` is for the irreversible.

## Tests

```bash
tests/run.sh              # everything, no model involved, seconds
tests/test-context.sh     # verifies rules actually load — invokes a model
```

`test-context.sh` is deliberately kept out of CI: it spends tokens. Run it
locally before releasing a module.

## Pull requests

- One module or one coherent change per PR.
- Say **why** the rule exists — what went wrong that made it necessary.
- Green `tests/run.sh` is required.
- New rules need an `owner`. A rule without one has nobody to update it when it
  goes stale.

## Quarterly review

A rule that was never violated in a quarter is either already enforced by a
linter — delete the text, keep the check — or nobody needs it. Both outcomes
are progress. This repository is supposed to shrink as automation grows.
