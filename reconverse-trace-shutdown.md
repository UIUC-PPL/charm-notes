# Reconverse: trace modules that rely on ConverseExit never write

**Status: root-caused and FIXED 2026-07-28. Validated on Anvil job
19558722 (80M FoF, 1 node, 8 procs x 15 PEs, reconverse): rc=0, all
120 PEs wrote `.sum` + `.sumd` plus the `.sts` (241 files), components
line correct.**

## Symptom

`-tracemode summary +sumDetail` on charm-over-reconverse (Anvil, FoF at
2B, job 19557822 arm B): the run completes correctly — components
right, `[0] CombineSummary called!` printed, `Trace: traceroot:` parsed
— but the trace directory contains ZERO files. The identical build
recipe on classic-converse charm (macOS laptop, 2M dataset) writes
per-PE `.sum` and `.sumd` files normally. `-tracemode projections` on
reconverse writes all its logs fine, which is what makes the failure
look mysterious.

## Root cause

Classic converse calls the global `traceClose()` from `ConverseExit`
(mainline `src/conv-core/convcore.C:4149`); that loops over registered
trace modules and closes each. Reconverse's `ConverseExit`
(`reconverse/src/convcore.cpp`) is a PE barrier + comm-backend teardown
and calls **no trace hook at all** — nothing in the reconverse checkout
references `traceClose`.

Whether a trace module survives this depends on where it writes:

- **trace-projections works** because its registered exit function does
  its own parallel shutdown: PE 0 broadcasts
  `TraceProjectionsBOC::closingTraces()`, which calls `closeTrace()` on
  every PE (trace-projections.C:2687) before `CkContinueExit`. It never
  needs converse's `traceClose()`.
- **trace-summary fails** because its per-PE `.sum`/`.sumd` writes live
  in `SumLogPool`'s destructor, reached only via
  `TraceSummary::traceClose()` — i.e., only from the converse-driven
  global `traceClose()`. Its exit function `CombineSummary` handles
  `+sumonly` (PE 0 collects), but for plain summary and `+sumDetail` it
  just calls `CkContinueExit` and trusts `ConverseExit` to close — the
  trust reconverse breaks. (The upstream `.sumall` parallel-shutdown
  branch is commented out over an assert; it is unrelated to the per-PE
  files.)

General lesson: on reconverse, ANY trace module (or other subsystem)
whose cleanup depends on `ConverseExit` callbacks silently does
nothing. Audit for other `traceClose`-dependent modes before trusting
them (`sumonly`'s final write path, trace-perfReport, etc.).

## Fix (charm side, upstreamable to the reconverse branch)

Make summary self-closing from its exit function, mirroring the
projections pattern — `src/ck-perf/trace-summary.{ci,C,h}` and
`trace-summaryBOC.h`:

- new broadcast entry `TraceSummaryBOC::closeSummaryOnPe()`: disables
  the module (`setTraceOnPE(0)`), writes the `.sum.sts` on PE 0, calls
  `endComputation()`, then frees the log pool via a new
  `TraceSummary::closePool()` (whose `SumLogPool` destructor writes
  this PE's `.sum`/`.sumd`), and finally contributes to an empty
  reduction to PE 0, whose target calls `CkContinueExit()`.
- `CombineSummary`'s fall-through branch broadcasts `closeSummaryOnPe`
  instead of calling `CkContinueExit` directly; the GID-zero guard is
  generalized to all modes.

Safe on classic converse too: the `ConverseExit`-driven global
`traceClose()` dispatches through `ALLDO`, which skips modules whose
`traceOnPE()` is 0 — nothing closes or frees twice.

### Trap found on the way: `removeTrace()` is unsafe mid-run

The first fix attempt called `TraceSummary::traceClose()` from the
broadcast. Every rank then segfaulted at a nil address inside
`_processHandler` (Anvil job 19558318 — files written, run correct,
exit crash). Cause: `TraceArray::removeTrace()` leaves a NULL hole in
the trace array, and the reverse-iteration dispatch macro
`ALLREVERSEDO` (trace.h:222, used by `endExecute`) calls
`traces[i]->traceOnPE()` with NO null guard — unlike forward `ALLDO`.
The `endExecute` of the very entry method that called `traceClose`
walks into the hole. Classic converse never hits this because
`traceClose` historically runs only after the scheduler stops.
General lesson: any trace-module close that runs while messages are
still being delivered must disable the module (`setTraceOnPE(0)`), not
remove it from the array.

Applied (uncommitted working-tree patch) in both reconverse-branch
checkouts: laptop `~/software/recharm/charm` and Anvil
`$PROJECT/x-lkale/software/recharm/tracedcharm` (rebuilt there;
`traced-bin/FoF3.2b.sumdetail` links the fixed lib). Patch file:
`$PROJECT/x-lkale/software/recharm/sumdetail-close.patch`.

## The right long-term fix

Reconverse should invoke the trace-shutdown hook at exit like classic
converse does (a `traceClose()`-equivalent callback before comm
teardown in `ConverseExit`), so modules don't each need self-closing
exit functions. That needs a hook-registration mechanism, since
reconverse (a standalone library) cannot reference charm's
`traceClose` symbol directly. Worth an issue on
charmplusplus/reconverse once the charm-side fix is validated.
