# Security Policy

> 🇷🇺 [Русская версия](SECURITY.ru.md) · [back to README](README.md)

## Reporting a vulnerability

Report privately via
[GitHub Security Advisories](https://github.com/DanielLetto2020/vibe-rules/security/advisories/new).
Do not open a public issue for a vulnerability.

Expect a first response within 7 days.

## What is in scope

This repository ships shell scripts that run automatically inside your
development environment as Claude Code hooks. That makes the following in
scope:

- **Command injection in hook scripts** — hooks receive JSON on stdin
  containing tool input, including arbitrary strings from the model and the
  user. A payload that escapes into shell evaluation is a vulnerability.
- **A lock that can be bypassed** — `guard-bash`, `guard-tests`,
  `guard-infra`, `guard-deps`, `guard-commit`. If a destructive command passes
  a lock that should stop it, that is a vulnerability, not a feature request.
  The exception is the gaps listed under
  [what the locks do not catch](README.md#what-the-locks-do-not-catch) — script
  files, your own binaries, destruction inside a language runtime. Those are
  named on purpose and pinned in `tests/hook-corpus.tsv`; a new bypass outside
  that list is worth reporting, and a corpus entry is welcome with it.
- **Path traversal in `std-link.sh`** — it creates symlinks based on values
  resolved from configuration files.
- **Secret disclosure** — `secret-scan` writes matched lines to stderr; a case
  where it leaks a secret into a log or the transcript is in scope.
- **Anything in this repository that transmits data off the machine.** Nothing
  here is supposed to make network calls. A path that does is a vulnerability
  by definition.

## What is not in scope

- **A rule being wrong or incomplete.** Rules are advice to a language model,
  not a security boundary. Open a normal issue.
- **The model ignoring a rule.** Prose rules are requests, not guarantees —
  that is stated throughout the documentation. If a rule needs to be
  guaranteed, it should become a hook: that is a feature request.
- **Vulnerabilities in third-party tools** referenced by configs (PHPStan,
  Stryker, Infection, ruff and others). Report those upstream.

## Trust model, stated plainly

Installing this repository means **executing its shell scripts on your
machine**, automatically, on tool calls. Before installing:

- read `plugins/*/scripts/*.sh` — there are eight of them and they are short;
- read `plugins/*/hooks/hooks.json` to see when each one fires;
- note that nothing here makes network calls, reads outside the project
  directory, or sends telemetry — and verify that claim yourself rather than
  taking it on trust.

Locks reduce the damage an agent can do. They are not a sandbox and cannot
contain a deliberately hostile agent — a shell is available to it by design.
For untrusted work, isolate the environment itself: a container, a VM, or a
separate account.

## Supported versions

Only the latest release. This is a young project; fixes go into `main` and the
next tag.
