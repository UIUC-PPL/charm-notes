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
| `lci.md` | LCI reference: API and completion semantics, protocol thresholds, bootstrap/launch, configuration, sharp edges, errors in LCI's own docs. Claims labelled by evidence and pinned to an LCI commit. |
| `reconverse-*.md` | Investigation and design notes: QD latency at scale, trace modules not writing at shutdown, a core-interference monitor. |
| `SKILL.md` | Entry point when this repo is used as a Claude skill: when to use the notes and which file to read for which task. |

## Using these notes as a Claude skill

The repo root is a skill: `SKILL.md` tells Claude when the notes apply and
how to find the right file, so Claude loads them automatically in any
conversation about Charm++, Converse, Reconverse, or LCI.

### Claude Code (recommended on machines where you build and run)

1. Clone this repo somewhere stable, e.g. `~/software/charm-notes`.
2. Link it in as a personal skill, so `git pull` keeps the skill current:

   ```sh
   mkdir -p ~/.claude/skills
   ln -s ~/software/charm-notes ~/.claude/skills/charm-notes
   ```

3. Optionally, still import the machine profile in `~/.claude/CLAUDE.md`,
   so the machine facts are always loaded rather than loaded on demand:

   ```markdown
   @~/software/charm-notes/machines/<this-machine>.md
   ```

   The older "read charm_best_practices.md before writing code" line is no
   longer needed; the skill does that.
4. If no profile exists for the machine yet, copy an existing one as a
   template and fill it in.

Because the skill is a live clone, sessions can append lessons and push
them, per the contribution policy below.

### claude.ai (web, desktop and mobile apps)

1. Build the package from the committed state of the repo:
   `scripts/package-skill.sh` writes `dist/charm-notes.skill`.
2. In claude.ai, open Settings → Capabilities, make sure code execution is
   on, and upload `dist/charm-notes.skill` under Skills. (On Team and
   Enterprise plans an admin may need to allow custom skills.)
3. The skill is then available in every new chat.

An uploaded skill is a snapshot: re-run the script and re-upload (replacing
the old one) after the notes change. In claude.ai the notes are read-only,
so Claude drafts new lessons for you to commit rather than editing them.

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
