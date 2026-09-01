# Design note: an optional core-interference monitor for reconverse

Drafted 2026-08-26 (Kale + Claude session, from the FoF campaign's
diagnostic experience). Status: proposal — not yet an issue/PR. Intended
target: the reconverse Converse layer (timers, threads, cpuaffinity all
live there), surfaced through charm on `reviewed-with-reconverse` once the
staging process reaches new-feature PRs.

## What it is

An **opt-in performance-debugging tool** (off by default, zero dormant
cost) that answers one question the existing tools cannot: *is some worker
PE's core being timesliced by something that is not application code* —
helper threads, another PE bound to the same core, OS/IRQ activity, an
undersized cgroup, orphaned processes — and if so, which PE, how often,
and by what.

## Why (the incident record)

Every one of these presented as an unexplained 5–30% slowdown or a hang,
and each cost real allocation time to diagnose by hand:

1. **Frontier GPU-helper affinity** (2026-08): ROCm helper threads
   inherited PE pinning and timesliced worker cores. Worth **−22% at
   2B/16 nodes and −63% at 7168 PEs** (machines/frontier.md; relay108) —
   it is a FIXED-SIZE tax, so its share grows as phases shrink: a 5 ms
   gather phase went 21x, the treewalk only 1.5x. Quote the scale with
   the number. **Discovery chain (corrected 2026-09-01):** idle-exit
   binning -> the off-core detector -> schedstat -> the pthread
   interposer. NOT the gap monitor — relay44 shows its counters were
   unmoved by the fix. The gap monitor's role was establishing that
   ~10 ms holes existed at all; the off-core detector named the cause.
2. **Anvil 10 ms scheduling holes** (2026-08-11): unpinned runs; one
   descheduled PE stalled its whole process's phaseB barrier.
3. **Slurm cgroup traps** (Anvil, two variants): `-N 1`-only sbatch
   header → 1 core for the whole job; `--cpus-per-task=15` → 120
   busy-poll PEs allowed 120 of 128 cores with binds failing. Hangs.
4. **`+setcpuaffinity` same-core collisions** (Anvil 2026-08-11): the
   automatic spread bound two PEs to one PU at some shapes.
5. **Orphaned processes** from a killed multi-process run contaminating
   timings (laptop, load average 192).

## Provenance — the app-level prototype

`paratreet2/fof/FoF.C` (`FOF3STAT keepalive_gaps`, committed 241ddb4):
a Converse-level timer re-arms every 100 ms and measures how LATE it
fires vs schedule, counting gaps over 5/10/25 ms; one line per process
at exit. **It is PER-PROCESS at every level** (statics behind a mutex,
one sender rank, printed once per process — corrected 2026-09-01; an
earlier revision of this note said per-PE). A runtime version should be
per-PE, which is a real design change, not a transcription.
Converse-level so it is invisible to QD (a message-per-tick heartbeat
deadlocks `CkWaitQD` — measured during the compression-wave work).
The physics: a size-independent lateness of ~one scheduler quantum
(10 ms) means the OS descheduled the thread, not the network.

**The runtime half was already prototyped** (found 2026-09-01, not
previously recorded here): `projections-tools/charm-instrumentation.diff`
— tracked since 2026-09-01 in paratreet2 `projections-tools/`, never
committed to charm — patches `src/ck-core/init.C` and `src/ck-core/qd.C`
with exactly the Layer-2 discriminator proposed below
(`getrusage(RUSAGE_THREAD).ru_nivcsw`), emitting Projections user events
(off-core / running / nivcsw, e.g. event 9112 "nivcsw advanced across the
gap"). So this note is a productisation proposal, not a from-scratch
design: start from that diff. It still applies cleanly to charm
`origin/main` (`qd.C` is byte-identical across main and both reconverse
branches), so the QD-visibility half need not wait for the branch
migration at all.

Reconverse makes the signal *cleaner* than it can ever be in classic
Charm: workers busy-poll and never voluntarily block, so any lateness is
either preemption or a long entry method — and those two are separable
(below). Classic Charm would have to exclude voluntary idle-sleep first.

## Design

### Layer 1 — static pemap collision check (at affinity setup)

After binding, gather every PE's resolved PU across all processes on the
node (the `+showcpuaffinity` machinery already computes the map) and WARN
on duplicates. Catches `+pemap` typos, surprising `pe % count` wraps, and
the auto-spread collisions of incident 4 — at startup, before any time is
wasted. **Advisory, never abort**: SMT siblings and deliberate
oversubscription (testing on laptops) are legitimate.

### Layer 2 — dynamic preemption monitor (opt-in, e.g. `+interferencecheck`)

- Per-PE Converse timer tick, **default period 20 ms** (see "period"
  below), measuring lateness vs schedule. No messages, ever.
- On each late tick, read two per-thread deltas:
  `getrusage(RUSAGE_THREAD).ru_nivcsw` (involuntary context switches)
  and thread CPU time. This is the **discriminator**:
  - CPU time ≈ wall gap, Δnivcsw ≈ 0 → a LONG ENTRY METHOD ran.
    Not a false positive — count it separately as a grainsize/
    responsiveness warning (long EPs are what stall LB, QD, and
    process-barrier phases).
  - CPU time lags wall, Δnivcsw > 0 → PREEMPTION. The real target.
- `sched_getcpu()` sampled at each tick accumulates the per-PE observed
  CPU set: a migrating PE ⇒ pinning absent; two PEs reporting the same
  CPU ⇒ collision **attributed** ("PE 7 and PE 12 both on core 51"),
  which is a diagnosis, not just a warning.
- **Adaptive burst**: on a PE's first anomalous tick, drop that PE to
  2–5 ms for a short window and histogram the gaps. Preemption
  fingerprints itself (gaps cluster at quantum multiples, nivcsw
  climbing); long EPs produce gaps matching the EP duration distribution
  with nivcsw flat. With mid-size EPs in the mix the fine-period
  histogram is bimodal and the populations separate.

### Reporting

Silent when clean. End of run: one line per process (max gap, log2 gap
histograms split preemption/long-EP, nivcsw totals, collision pairs).
Verbose knob for per-PE detail. Same shape as the FoF prototype's output,
which proved readable at 128 processes.

### Period choice (why 20 ms, why the prototype's 100 ms should not survive)

Per-occurrence detection probability for a transient hole of length g is
≈ g/period (the tick's due time must fall inside the hole): a 10 ms
quantum hole is caught ~10% per occurrence at 100 ms, ~50% at 20 ms,
near-certainly at 10 ms. SUSTAINED sharing (incidents 3, 4) is caught at
any period — half of all ticks are late — so the period buys sensitivity
to sparse, short interference (helper wakeups, IRQ bursts). Cost at
20 ms is ~50 ticks/s/PE of clock-read + counter math, negligible in a
busy-poll runtime. The prototype's 100 ms was an app-side artifact:
bolted into a production binary during timing campaigns (zero
perturbation mattered most) hunting a fault frequent enough that 10%
sampling per event still accumulated definitive counts.

### Trigger condition — the trap the app-level fix fell into

`FoFDevice.cpp:1053` gives up silently when the PE's mask is not exactly
one CPU (`if (CPU_COUNT(&save) != 1) return;` — "not pinned: nothing to
protect"). But `machines/frontier.md` now RECOMMENDS multi-process GPU
launches with no charm affinity flag, where Slurm hands each PE a 7-core
mask — so **in the currently recommended configuration the measured fix
is inactive, with no warning printed**. By the fix's own reasoning
(`FoFDevice.cpp:958-962`) a wide-masked helper still rotates victims
among the PE's cores; it is less catastrophic than being welded to one
core, not free.

Lessons for both the monitor and any HAPI/runtime port:
- Do NOT gate on `CPU_COUNT == 1`. Gate on "the helper's inheritable mask
  overlaps cores that carry PEs" — which covers the multi-core-mask case.
- Any "declined to act" path must SAY SO once, at startup. A silent
  no-op is how a fix stops being applied without anyone noticing (the
  campaign already lost relay103 to a neighbouring trap: unsetting
  `FOF_HELPER_CPUS` left the fix active, so the A/B compared two good
  placements).

### Companion item: the shrink/expand GPU memory daemon

Same symptom class, different mechanism, already IN
`reconverse-specific-build`: `src/arch/cuda/hybridAPI/hapi_memory_daemon.cpp`
(278 lines), a standalone executable built only when `SHRINKEXPAND` is on
(CMakeLists.txt:819), holding device memory across checkpoint/restart.
Under that flag it also replaces the normal device-init path
(`hapi_impl.cpp:210-215`). Charm does NOT fork it — it creates FIFOs and
waits on `/tmp/daemon_ready_<device>` — so its affinity comes from the
LAUNCHER, and the remedy is launcher-side pinning, not an in-process
scope. Two defects found by inspection 2026-09-01 (unmeasured):
- The main loop reads a FIFO opened `O_NONBLOCK` then set blocking; with
  no writer attached `read()` returns 0 immediately, so the
  `usleep(1000)` "spin-loop guard" yields a permanent **1 kHz wakeup
  loop** rather than preventing one.
- The `bytes_read < 0` / `EINTR` branch `continue`s with no sleep at all
  — an unthrottled spin if signals arrive repeatedly.
It also holds its own CUDA context (daemon line 134), so it spawns its
own helper threads inheriting the DAEMON's mask; one daemon per device
(four on a GH200 node).

### Constraints

- **No messages** (QD safety — hard requirement, learned twice).
- **Advisory only**, opt-in, tunable period, off = dormant.
- Linux-first (`RUSAGE_THREAD`, `sched_getcpu`); degrade to gap-timing
  only where those are absent (macOS).
- Keep it out of the timing path when off: the flag gates timer arming,
  not per-message work; nothing per-handler when disabled.

### Testability (fits the staged-PR + CI process)

- Layer 1 is deterministically CI-able: launch with a deliberately
  colliding `+pemap`, assert the warning.
- Layer 2 has a plausible CI test on dedicated runners: spawn an
  interference thread pinned onto a worker's core, assert detection;
  mark it optional/excluded on shared runners where it would flake.

## Sizing

Roughly: cpuaffinity gather+check ~50 lines; tick machinery + rusage
deltas + histograms ~200; burst mode ~50; docs/flags ~50. One
self-contained PR, reviewable by two people in a sitting.
