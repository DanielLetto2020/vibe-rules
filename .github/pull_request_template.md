<!--
A rule is added in reaction, never in anticipation. See CONTRIBUTING.md.
-->

## What changed

<!-- The change itself, in one or two sentences. -->

## Why

<!--
The concrete incident behind it: what the model got wrong, what review caught,
what you had to correct twice. "Might be useful" is not a reason — every rule
costs context in every session for every developer.
-->

## Enforcement

<!--
For a new or changed rule, state how it is enforced and why that level:

- `hook` / `lint` / `test` — what exactly checks it, and where the config lives
- `review` / `prose` — why a machine cannot check this

A rule marked `lint` without a matching entry in `configs/` is prose pretending
to be a check.
-->

## Checklist

- [ ] `tests/run.sh` passes
- [ ] New locks come with cases in `tests/test-hooks.sh` — both the blocked call
      and a similar call that must still pass
- [ ] New modules are registered in `.claude-plugin/marketplace.json`
- [ ] New rules have `paths`, `owner`, `enforcement` and `since`
- [ ] No contradiction with an existing rule
