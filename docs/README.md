# Documentation map

> 🇷🇺 [Русская версия](README.ru.md) · [back to the main page](../README.md)

A page so you don't have to read everything. Find your situation — it says what
to open and how long it takes.

🇷🇺 marks a document that is currently Russian-only.

---

## Where to go, by situation

### First time here, not sure what this is

**[How this works, in plain words](START.md)** · ~15 min

No jargon. The amnesiac developer metaphor, the four places a rule can live,
and a glossary of every word you will meet later: lock, gate, mutation testing,
ratchet, profile, module.

After it the rest reads easily. Before it, barely at all.

### Want to see it working

**[Examples](EXAMPLES.md)** · ~15 min

Five end-to-end walkthroughs with real command output: onboarding an existing
project, a new feature, legacy code without tests, removing functionality,
a rule for one project only.

### Rolling this out on my project

1. [Quick start](../README.md#quick-start) — three commands
2. [Profiles](PROFILES.md) — which mode to pick and how to adapt it
3. [Examples, walkthrough 1](EXAMPLES.md) — what to do when the project
   already has its own `CLAUDE.md`

### The agent got it wrong again — I want to write a rule

**[Writing your own rule](WRITING-RULES.md)** · ~10 min

Where a requirement belongs (a lock, a linter, a test, or actually a rule),
what a rule is made of, how to phrase it so it can be verified, and what to do
when a shared rule doesn't fit your project.

It also untangles a common confusion: **rules do not depend on profiles**.

### The checks are too strict, or not strict enough

**[Profiles](PROFILES.md)** · ~10 min

Where the six ready profiles live, how to choose one, how to adapt it without
touching the shared repository, and how to create your own. Plus what you
**cannot** override — the safety locks.

### The mutation gate is red and I don't know why

**[The ratchet](RATCHET.md)** · ~10 min

What the percentages mean, why the bar rises by itself, where the state is
kept, every setting, what to do when it fails and how to legitimately reset it.

### My project has specifics the shared rules don't cover

**[Project-level rules](CUSTOMIZATION.md)** · ~10 min

Four levels of customization: a project rule, a recorded departure from a
shared rule, your own gate commands, opting out of a module entirely. What of
it goes into git and what does not, and how to confirm a rule actually loads.

### I'm rewriting legacy or running a large refactor

**[Legacy and refactoring](LEGACY.md)** · ~10 min

Three modes: a transition period with two contours, a freeze zone, moving an
area across step by step. Ready-made rule templates, plus the mistake that
gets checks switched off on legacy by day two.

### I want to understand why it's built this way

- **[Architecture](ARCHITECTURE.md)** 🇷🇺 — three decisions that look odd
  without an explanation: why rules did not become skills, why the path is
  resolved dynamically, why language is separated from framework
- **[Enforcement](ENFORCEMENT.md)** 🇷🇺 — the boundary between a request and a
  guarantee, and what cannot be automated at all
- **[The gauntlet](../plugins/std-gauntlet/docs/GAUNTLET.md)** 🇷🇺 — five
  stages: spec, tests, mutation, metrics, the list for a human

### I want to add a module to the shared repository

**[Contributing](../CONTRIBUTING.md)** · ~10 min

When a rule is worth adding at all, how to add a module for a new stack, what
is required of locks and tests.

### I'm about to install this and I'm thinking about security

**[Trust model](../SECURITY.md)** · ~5 min

Installing means running someone else's shell scripts on your machine. What is
in scope, what is not, and why you should read the scripts yourself rather than
take a claim on trust.

---

## Every document

| Document | For whom | Time |
|---|---|---|
| [Plain words](START.md) | everyone, start here | 15 min |
| [Examples](EXAMPLES.md) | anyone who wants to see it work | 15 min |
| [Writing a rule](WRITING-RULES.md) | whoever keeps standards in a team | 10 min |
| [Project-level rules](CUSTOMIZATION.md) | whoever has project specifics | 10 min |
| [Legacy and refactoring](LEGACY.md) | whoever rewrites old code | 10 min |
| [Profiles](PROFILES.md) | whoever configures a project | 10 min |
| [The ratchet](RATCHET.md) | whoever deals with the quality gate | 10 min |
| [The gauntlet](../plugins/std-gauntlet/docs/GAUNTLET.md) 🇷🇺 | whoever rolls out the full pipeline | 10 min |
| [Architecture](ARCHITECTURE.md) 🇷🇺 | whoever works on this repository | 10 min |
| [Enforcement](ENFORCEMENT.md) 🇷🇺 | whoever decides where a requirement goes | 5 min |
| [Contributing](../CONTRIBUTING.md) | whoever adds modules | 10 min |
| [Security](../SECURITY.md) | whoever owns what gets installed | 5 min |

---

## Quick answers

When you need one fact rather than a read:

| Question | Where |
|---|---|
| What commands exist? | [main page](../README.md#quick-start) |
| Why didn't my rule load? | [writing a rule → check it works](WRITING-RULES.md#check-that-the-rule-works) |
| What is `enforcement` and what do I put there? | [writing a rule](WRITING-RULES.md#enforcement--what-backs-it-up) |
| How do I switch off the pre-commit check? | [profiles → adapting](PROFILES.md#adapting-a-profile-to-your-project) |
| Where is the quality bar stored? | [ratchet → where things live](RATCHET.md#where-things-live) |
| My project is legacy — where do I start? | [legacy](LEGACY.md) |
| A shared rule gets in my project's way | [project rules → departures](CUSTOMIZATION.md#when-a-project-rule-contradicts-a-shared-one) |
| How do I add a rule without touching the shared repo? | [project-level rules](CUSTOMIZATION.md) |
| How do I mark an area as off-limits? | [legacy → freeze zone](LEGACY.md#mode-2-a-freeze-zone) |
| Tests are green — but do they check the spec? | [spec data mutation](../plugins/std-gauntlet/docs/GAUNTLET.md) |
| What can't be overridden? | [profiles → what cannot](PROFILES.md#what-cannot-be-overridden) |
| What does this system not do? | [plain words → what this does not do](START.md#what-this-does-not-do) |
