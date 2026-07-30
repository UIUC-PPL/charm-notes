# Investigation note: reconverse quiescence-detection latency at scale

For whoever picks this up (Kale / charm-comparison project / reconverse
team). Written 2026-07-28 from the paratreet2/FoF campaign.

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
