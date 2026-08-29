# Investigation note: reconverse quiescence-detection latency at scale

For whoever picks this up (Kale / charm-comparison project / reconverse
team). Written 2026-07-28 from the paratreet2/FoF campaign.

> **UPDATE 2026-08-01 — read this before pursuing the QD hypotheses below.**
> The microbenchmark this note asks for (see "Where to look in
> reconverse": QD settle vs PE count on an idle system) now exists:
> `charm/tests/charm++/qd/qdbench`. Measured on exclusive Anvil
> wholenodes at ppn 15 (jobs 19608513, 19608517), **QD settle is
> 0.16-0.54 ms at 120, 240 AND 480 PEs** in 20 of 26 runs. It does not
> scale badly with PE count.
>
> The other 6 runs fall off a cliff partway through, in which ring
> throughput degrades 20-80x AND settle jumps to 77-101 ms *together*,
> from the same phase onward, never recovering. Cliff rate: 0/14 at
> 1 node, 1/6 at 2 nodes, 5/6 at 4 nodes.
>
> So the ~90 ms figure below is most likely the cliff state, not the cost
> of quiescence detection. The framing "QD is slow at 480 PEs" looks
> wrong; the question to chase is what collapses inter-node messaging
> mid-run.
>
> **2026-08-02 — the Anvil/IBV experiment the 2026-07-30 addendum asked
> for has now been run (jobs 19610112 / 19610179 / 19620654).** IBV does
> have its own idle-path stall, and it is characterized:
>
> - The trigger is ELAPSED TIME, ~0.6-1.1 s, not traffic. A 5 s busy-wait
>   before any messaging leaves the FIRST ring message already ~70x
>   degraded (phase-0 ring 132 ms at -d 0 vs 7760-9899 ms at -d 5000),
>   and severity grows with the length of the wait.
> - It is the transport, not the machine: a fixed local compute loop
>   times 11.142-11.173 ms in every phase of every run (<0.2% spread)
>   while ring time goes 142 -> 12941 ms. CPU frequency/power decay under
>   480 spinning PEs is excluded.
> - Degraded cost is a scale-independent ~208 us/hop at 480 PEs and
>   ~250 us/hop at 240 PEs, against ~2.4 us clean.
> - Payload 0-64 KB changes nothing. QD settle degrades a full phase
>   BEFORE bulk ring traffic does, which is why applications meet this as
>   a QD problem.
> - **Qualifies the "single-in-flight" framing below:** 1, 4, 16 AND 64
>   tokens in flight all cliff at the same ~0.8 s onset, so global
>   sparsity is not the whole story. At 480 PEs even 64 in flight leaves
>   each PE idle most of the time, so this does not separate global
>   sparsity from PER-PE idleness — but the -d result points at the
>   latter.
> - Not an obvious backoff: reconverse's idle path spins with no sleep
>   (scheduler.cpp:111-122) and LCI has no backoff/usleep in source.
>   LCI_USE_REG_CACHE is already ON, so uncached registration is out.
>
> Consistent with the 25 ms-per-QD-round anatomy below: 3 rounds x 25 ms
> ~= the 75-100 ms settles. Note idle-path QD rounds (~25 ms) are ~100x
> worse than even the DEGRADED ring hop (~208 us), so PE idleness depth
> appears to matter on top of the global elapsed-time effect.
>
> The trace evidence in this note remains valid as observation — the gaps
> are real and contain no events — but the attribution to QD internals
> (confirmation rounds, timer-paced polling) is unsupported.
> `+lci_ndevices` does not prevent any of it. Full per-phase data:
> charm_best_practices.md, "Root characterization".

## Symptom

On an IDLE 480-PE system (4 Anvil wholenode, 32 procs x 15 PEs,
reconverse), quiescence detection takes ~90-130 ms per invocation.
Two instances measured precisely in one flush-clean Projections trace
(FoF 80M, binary FoF3.pool3.noagg, commit 51cb8cd, job 19542091):

1. Explicit `CkWaitQD` after the union-find edge cascade: last real
   message work ends t=3.0022 s; `onQD` fires 3.0898 -> **87.8 ms**.
2. `CkStartQD(postComponentLabelingCb)` inside unionFindLib
   (unionFindLib.C:832) after the set_component cascade: last work
   3.1058; all PEs sit traced-idle with ZERO events of any kind until
   a simultaneous idle-end + callback delivery at 3.2349 ->
   **~129 ms** (may be TWO chained QDs: line 1302 starts another QD
   to return to the application).

Total: ~220 ms of QD settle around ~15 ms of actual union-find work.
Consequence: the FoF "uf2" phase reads 0.05-0.5 s with large variance —
the variance IS QD settle jitter. Suspected same mechanism behind
inflated barrier-to-barrier stage walls seen elsewhere (e.g. laptop
2-proc x 4-PE reset/register walls of 0.5-1.7 s).

## Ruled out (checked in the raw trace logs)

- Application timers / OS calls / file I/O / stdout: the gap cores
  contain no entry events, no user events, no pack/unpack events on
  ANY of 480 PEs; the app performs no file I/O in this phase; the one
  library stdout line prints before the gap; Projections buffers never
  flushed (no type-8 markers, no banner, counts << +logsize).
- Slow reduction traffic: RecvMsg(CkReductionMsg) clusters sit
  entirely at the gap BOUNDARIES (the boss-count reduction before, the
  label-collection reduction after); the gap core has none.
- Trace overhead: traced run reproduces untraced timings to ~ms.

## Where to look in reconverse

- The QD implementation (early reconverse QD was reworked around a
  ping/reduction barrier when CkWaitQD hangs were fixed, 2026-07).
  Questions: how many confirmation rounds; what triggers a round
  (message-driven vs scheduler-idle polling vs timer); per-round cost
  at 480 PEs. 90-130 ms on an idle machine suggests either timer-paced
  rounds or O(rounds x latency) with large constants.
- Compare classic Converse netlrts on the same node count: expected
  ~ms. A microbenchmark pair belongs in the classic-vs-reconverse
  regression set: (a) QD settle time on an idle system vs PE count;
  (b) time from last contribution to callback delivery for an
  empty group/array reduction vs PE count.

## Evidence artifacts

- Trace: laptop ~/software/clusterFinding/traces/pool3-noagg/ (482
  files) and Anvil $PROJECT/x-lkale/software/clusterfinding/
  results-trace-pool3/noagg. Time profile snapshot:
  timeProfileAfterDualTreeWalk.png (gaps at 3.00-3.09 and 3.13-3.23).
- Census methodology: charm_best_practices.md "Reading Projections
  traces" (raw-log gap analysis).

## Workarounds available to applications meanwhile

- Replace completion reductions/QD where counts are knowable: direct
  done-messages for few-element completion (e.g. 32 library elements),
  message counting instead of QD for bounded cascades.
- Budget ~100 ms per QD at this scale when interpreting phase timings;
  do not attribute QD-settle windows to the phases that contain them.

## Addendum (2026-07-28): LCI IBV completion assert at 2B scale

A related-family data point, distinct from the latency issue above:
FoF at 1.98B particles, 8 Anvil nodes / 64 procs x 960 PEs (heavier
per-process load than the successful 16-node run of the same binary),
died mid-run with, on multiple ranks:

    lci:Assert failed: wcs[i].status == IBV_WC_SUCC
    (backend_ibv_inline.hpp:poll_comp_impl:118)

Survivors hung until the job time limit (abort propagation did not
complete — contrast the clean CmiAbort shutdown measured on macOS/tcp).
The IDENTICAL binary and dataset succeeded twice at 16 nodes / 128
procs, so the trigger correlates with per-endpoint load, not code.
This is the InfiniBand sibling of the macOS ofi post_send assert
(charmplusplus/reconverse#188 records the registration-path findings).
Logs: $PROJECT/x-lkale/software/clusterfinding/results-2b/
n8_2b.rep1.log (job 19550663).

## Addendum (2026-07-30): root cause narrowed — QD protocol exonerated,
## sparse cross-process message latency indicted

Kale's challenge: QD is counting + asynchronous reductions/broadcasts
and should not take 100 ms; suspect a system call in the critical path
or a sliver of continuous activity. Both hypotheses were tested.

Code audit (charm qd.C + reconverse scheduler/conv-conds): no sleep,
no timer, no 100 ms constant anywhere in the QD path. `_dummy_dq`
(the +qd fake-QD timer) defaults to 0. Each QD hop is idle-gated via
`CcdCallOnCondition(CcdPROCESSOR_STILL_IDLE)`; reconverse raises
STILL_IDLE every idle scheduler iteration and runs condition callbacks
synchronously, so a hop on an idle PE costs microseconds. The protocol
needs >=3 idle-gated tree round-trips (counts, counts-unchanged,
dirty-check) — milliseconds at any scale, if messages flow at normal
latency. The only literal 100 ms sleep in reconverse is in the
ConverseExit spin of non-rank-0 threads — exit path only.

Trace evidence (2B sum-detail, 1 ms x per-EP x per-PE, 1920 PEs): ten+
gaps of 83-146 ms with total EP activity under 15 ms machine-wide per
gap — no sliver of application activity; the machine is genuinely
silent at the entry-method level. Every gap ends with a BROADCAST wave
(recvNoKeepBroadcast / next-phase entries) landing on all PEs; the
13.117 s gap shows the same broadcast active on one process BEFORE the
gap and on the remaining processes 146 ms AFTER — a broadcast stalled
mid-propagation.

Microbenchmark (Kale's design: ring pingpong, then CkStartQD callback,
10 phases, no exit — `~/software/recharm/qdbench/`, laptop):

| config                          | ring 400 hops | QD settle |
|---|---|---|
| reconverse 1 proc x 4 PEs       | 0.65 ms       | 0.015 ms  |
| reconverse 2 procs (lcrun, ofi/tcp) | 1600-4500 ms | 12-205 ms (mean 61) |
| classic converse 2 procs (netlrts)  | 34-99 ms  | 0.5-1.1 ms |

Same qd.C in both runtimes. CONCLUSION: the QD protocol is fine; the
~100 ms settles are the cost of a chain of SPARSE (single-in-flight)
cross-process messages, each of which costs ~5-10 ms on reconverse's
macOS ofi/tcp path — ~100x classic converse on the same kernel path,
and ~100x reconverse's own SUSTAINED-traffic latency (~45 us one-way
measured earlier). A latency that appears only for isolated messages
after idle points at a timer in the transport (delayed-ACK/Nagle
interaction in the tcp provider, or an LCI progress backoff), i.e.
Kale's "system call in the critical path" — in LCI/libfabric, not in
charm. QD, barrier-completion reductions, and phase-start broadcasts
are exactly chains of sparse messages, which is why every quiet
phase boundary pays it.

Open: the Anvil gaps (90-130 ms at 480-1920 PEs) are on the IBV
backend — no Nagle there, so the same experiment should run on Anvil
(2 nodes, 1 min) to see whether IBV has its own idle-path stall or the
Anvil gaps have a different constant. The reconverse issue to file is
now sharp: "single-in-flight inter-process message latency is
~100x sustained latency; QD/phase transitions serialize on it."

## Addendum (2026-07-30, later): the 25 ms spikes — one QD round per spike,
## anatomy from raw logs

Kale spotted three tiny activity spikes 25 ms apart inside a silent gap
(pool3-noagg traces, 480 PEs / 32 procs on Anvil IBV; window
2.98-3.10 s). Raw-log analysis of that window:

- Strictly inside the gap there are ZERO traced events (no entries, no
  creations) across all 480 PEs. The spikes are UNTRACED work: idle
  END/BEGIN pairs. At 3.0119, 3.0374, and 3.0632 s (spacing 25.5 and
  25.8 ms), ~1150-1180 wakeups each: essentially every PE leaves idle
  for ~1 us and returns. That is a converse-level message wave touching
  all PEs — QdMsg handlers are converse handlers, invisible to tracing.
  Three waves = the three QD rounds (counts, counts-unchanged, dirty
  check); the phase restart lands one spacing after the third
  (~3.089 s, 346 wakeups + the real broadcast).
- Fine structure of a round: the DOWNWARD broadcast lands on all 480
  PEs within ~100 us (wakeups are simultaneous, not staggered by tree
  level — the broadcast path is fast). Then a small echo of 11-12
  wakeups ~13 ms later (interior tree parents receiving reports), and
  the next wave ~25.5 ms after the previous. So the UPWARD path — the
  point-to-point child->parent report chain, crossing process
  boundaries ~2 levels deep at 32 processes — stalls ~12.7 ms PER
  CROSS-PROCESS HOP.

So the same disease as the laptop measurement, with the transport
swapped: sparse single point-to-point messages after idle cost ~12.7 ms
on Anvil IBV (should be ~5 us) and ~5-10 ms on macOS ofi/tcp (should
be ~45 us). Two utterly different transports, same magnitude — the
common layer is LCI/reconverse's receive/progress path when idle, not
the NIC and not the kernel TCP stack alone. Broadcast delivery is fast
on both; it is the isolated point-to-point message that pays.

Summary for the reconverse issue: QD costs (rounds) x (cross-process
tree depth) x (sparse-message latency) = 3 x 2 x 12.7 ms ~= 76-130 ms,
matching every observed settle. Fix the sparse-message idle-path
latency and QD collapses to milliseconds; nothing in charm needs to
change.

## Addendum (2026-08-20): FRONTIER / Slingshot-CXI, 896 PEs — the same
## 60-80 ms settles, but the transport explanation above does NOT fit

Measured in the paratreet2/FoF3 2B campaign, job 5310158, two independent
traced reps of the same binary at 896 PEs (128 processes x ppn 7, +ndev 4,
+backend_poll_thread 2).  Full analysis: `~/software/reports/relay37.txt`.

- SEVEN QD episodes per run.  SIX settle for 53-81 ms with the machine
  already completely quiet: 438.8 ms (rep 2) and 368.4 ms (rep 1) of pure
  QD wall time, 8-10% of the measured window and ~22% of ALL the idle time
  in it.
- The round anatomy is the Anvil anatomy with a smaller constant: 3-4
  machine-wide wakeup waves, 12-29 ms apart (typically ~21), then onQD.  The
  downward broadcast leg lands on all 896 PEs inside one 0.5 ms bin, so the
  cost is entirely on the UPWARD child->parent report leg.  Method: bin
  END_IDLE(15) records — QdMsg handlers are Converse handlers and emit no
  entry events, but every QD message that lands makes a PE leave the idle
  loop.  Tool: `~/software/scripts/relay40-wakeups.py`.
- ROUNDS ARE FASTER ON A BUSY MACHINE.  In the one episode where the machine
  is 90% busy throughout, rounds are 13 ms apart and onQD lands 0.5 ms after
  the last piece of work.  QD is free when there is work to overlap it; the
  cost appears only at a quiet phase boundary.

WHY THE 2026-07-30 ATTRIBUTION (sparse cross-process message latency on the
idle path) DOES NOT CARRY OVER TO FRONTIER:

- The matched control exists and is clean.  `tests/charm++/qd/qdbench` at the
  SAME 896 PEs, the SAME 128 x ppn 7 layout, the SAME +lci_ndevices 4
  +backend_poll_thread 2, on the same machine, settles in **0.45 ms** (job
  5312377, `~/software/reports/relay31.txt`), with benign scaling from 224
  PEs and no cliff in 16 runs.  The application is 150x slower with the same
  protocol, same runtime, same knobs, same scale.
- The Frontier idle-stall test was negative independently: 0 of 160,000
  samples over 1 ms.  Slingshot/CXI does not show the InfiniBand behaviour.
- FOF_QD_NOIDLE is a wash, not a fix: it removes the idle gate but multiplies
  QD rounds by 8, and application wall time did not move (5138 vs 5246 ms,
  inside repeatability).  `~/software/reports/relay30.txt`.

So on Frontier the inflation is a property of the APPLICATION'S STATE, not of
the fabric and not of PE count.  qdbench has no GPU work, no registered device
memory and a tiny footprint; the application has all three.  THE NEXT
EXPERIMENT is therefore a qdbench variant that adds a large registered/device
allocation and an outstanding GPU stream, and nothing else.  If settle jumps
from 0.45 ms to tens of ms, the reconverse/LCI issue can be written precisely
against the progress path under registration or device polling.  If it stays
flat, instrument the upward report leg per tree level in qd.C and run it
inside the application.

Application-side workaround, unchanged in spirit from the section above and
now concrete for paratreet2: `examples/fof3/FoF3.C:127` waits for global
quiescence purely to let the canopy re-sends to `Driver::recvTC` settle, and
`src/Driver.h:332` posts a second CkWaitQD immediately afterwards.  The
re-send count is knowable in TreePiece::upwardPass.  Those two waits are
~150 ms of the ~196 ms that the 8.10-8.30 s region of the trace costs.
