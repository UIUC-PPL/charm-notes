# charm-notes

Practitioner notes for Charm++ / Converse development, maintained as a
living record by the PPL group (primarily via Claude Code sessions
working on Charm-based projects). This is the FAST layer of a two-speed
documentation model:

- **Fast (this repo)**: lessons are appended while the evidence is
  fresh — what happened, on what system, what the fix was, dated.
  Entries may be informal, opinionated, and occasionally retracted
  (retractions stay in place; they are lessons too).
- **Slow (the charm manual)**: entries that mature — verified, general,
  stable — are periodically distilled into proper sections of
  `doc/` in [charmplusplus/charm](https://github.com/charmplusplus/charm)
  via documentation-only pull requests. When that happens, the note
  gains a "upstreamed to manual" marker but is not deleted.

## Contents

| file | what it is |
|---|---|
| `charm_best_practices.md` | Accumulated practitioner lessons: message-memory invariants, scheduler/runtime pitfalls, SMP and launch-layout traps, group/array creation ordering, reduction cost models, benchmarking discipline, macOS-specific hazards. |
| `syntax_quick_ref.md` | Quick syntax lookup: chares, SDAG, groups, nodegroups, reductions, custom reducers, callbacks. |
| `machines/*.md` | Per-machine environment profiles (folder layout, installed runtimes, run idioms, machine-specific hazards). Each machine loads only its own profile. |

## Using these notes with Claude Code on a new machine

1. Clone this repo somewhere stable, e.g. `~/software/charm-notes`.
2. In `~/.claude/CLAUDE.md`, import the machine profile and point at the
   notes:

   ```markdown
   @~/software/charm-notes/machines/<this-machine>.md

   ## Charm++ / Converse work
   When the task involves Charm++, Converse, or reconverse, read
   ~/software/charm-notes/charm_best_practices.md and
   ~/software/charm-notes/syntax_quick_ref.md before writing code.
   Update charm_best_practices.md (commit + push) when a session earns
   a general lesson.
   ```

3. If no profile exists for the machine yet, copy an existing one as a
   template and fill it in.

## Contribution policy

- An entry needs an **earned lesson with evidence**: what was observed,
  on what system/scale, what the resolution was, and a date. Speculation
  is fine if labeled as such.
- **Scope discipline**: general Charm/Converse lessons only. Lessons
  specific to one project belong in that project's own design notes;
  machine specifics belong in `machines/`.
- Maintainers push directly (pull before appending — two concurrent
  sessions on different machines is the common conflict source).
  Everyone else: pull requests, reviewed by the maintainers.
- No secrets of any kind — this repo is public.
