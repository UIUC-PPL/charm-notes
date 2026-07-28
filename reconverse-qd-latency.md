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
