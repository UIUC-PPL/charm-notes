---
name: charm-notes
description: Practitioner notes from the UIUC Parallel Programming Lab for Charm++, Converse, Reconverse, LCI and AMPI — hard-won runtime lessons, a syntax quick reference, reconverse investigation notes, and per-machine build/launch profiles (Anvil, Delta, Frontier, macOS). Use this skill whenever a task involves Charm++ code (.ci files, chares, groups, nodegroups, chare arrays, SDAG, reductions, CkCallback, quiescence detection, load balancing, pup, zerocopy/GPU), Converse or Reconverse runtime internals, the LCI communication layer, charmc or charm build options, Projections tracing, or building, launching and debugging Charm-based programs on clusters (srun, charmrun, lcrun, +pemap, SMP layout, affinity). Consult it before writing, reviewing or debugging such code, even if the user does not mention these notes.
---

# charm-notes

Living practitioner notes for Charm++ / Converse / Reconverse / LCI, kept by
the PPL group. Entries are dated, evidence-backed, and sometimes retracted
(retractions stay in place and are lessons too). They record what actually
happened on real systems, so prefer them over general memory of Charm++
when the two disagree, and mention the dated entry you relied on.

All paths below are relative to this skill's directory.

## Which file to read

| Task | Read |
|---|---|
| Writing or reviewing Charm++ code (syntax, .ci/.C skeletons, SDAG, groups, nodegroups, reductions, threaded entries, templated modules, Makefiles) | `syntax_quick_ref.md` (630 lines; read the relevant sections) |
| Design, correctness, performance, debugging, runtime behaviour | `charm_best_practices.md` — large, search it (see below) |
| Building or running on a specific machine | `machines/<machine>.md` — only the one in use |
| Reconverse quiescence-detection / completion latency at scale | `reconverse-qd-latency.md` |
| Projections or other traces missing on reconverse | `reconverse-trace-shutdown.md` |
| Core interference, preemption, pemap collisions | `reconverse-core-interference-monitor.md` |

Read `syntax_quick_ref.md` before writing new Charm++ code, and search
`charm_best_practices.md` for the topic before proposing a design or a
diagnosis — many entries exist because the obvious approach failed.

## Searching charm_best_practices.md

It is ~3,300 lines of dated sections, so do not read it whole. List the
section headings, pick the relevant ones, then read those line ranges:

```bash
grep -n '^##' charm_best_practices.md
grep -n -i 'quiescence\|CkWaitQD' charm_best_practices.md   # or any keyword
```

Rough map of what is in there:

- **Model discipline**: no bare globals, CkCallback-based library design,
  counting completion, message-memory ownership, marshalling costs,
  nodegroup entry methods running on any PE, null-proxy sends.
- **Quiescence and termination**: QD stalls and heartbeats, aggregation
  layers vs QD, idle-callback work, idempotent terminal steps.
- **Reductions and collectives**: large-payload and sparse reducers,
  gather patterns, within-node broadcast contracts.
- **Creation ordering, SMP and launch layout**: group/array-map race,
  `+pemap`/affinity, PEs per node, launcher process-count gates.
- **Reconverse and LCI**: registration paths, `+lci_ndevices`, QD latency,
  Ccd ticks, startup hangs, ConverseInit differences from classic Converse,
  machine-layer properties, broadcast fan-out, lcrun bootstrap directory,
  memory pools vs network completions, one-sided put notification.
- **GPU**: zerocopy registration, streams per chare, overdecomposition.
- **Tracing and measurement**: Projections, `+sumDetail`, trace provenance,
  benchmarking discipline, FP results under `-march`, misleading green runs.
- **Build system**: charm + reconverse builds, extern modules, retracted
  charmc claim.

## Machine profiles

`machines/` holds one profile per machine (anvil, delta, frontier, mac):
module recipes, build commands, launcher idioms, filesystem layout,
measured hazards. Load only the profile for the machine actually in use —
identify it from the user, the hostname, or the environment, and ask if
unclear. General lessons live in `charm_best_practices.md`, not in profiles.

## LCI coverage

The notes cover LCI as Reconverse's transport (devices, registration,
completion, launch). They do not document the LCI API itself. For direct
LCI programming questions, say so and work from the LCI sources and docs
(github.com/uiuc-hpc/lci) when available rather than from memory.

## Adding lessons

The repo's contribution policy (README.md) applies: an entry needs an
earned lesson with evidence — what was observed, on what system and scale,
what resolved it, and a date. Label speculation. Keep project-specific
material out; machine specifics go in `machines/`. Never include secrets.

- **Working in a git checkout of this repo** (e.g. Claude Code, where the
  skill is symlinked to a clone): when a session earns a general lesson,
  `git pull`, append a dated `##` section to the right file, commit, and
  push (or open a PR if the user is not a maintainer). Ask before pushing
  unless the user has said to.
- **Installed as an uploaded skill** (claude.ai, read-only copy): do not
  try to edit these files. Draft the entry in the notes' style, name the
  target file, and give it to the user to commit.
