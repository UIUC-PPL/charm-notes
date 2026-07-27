# Charm++ / Converse — Practitioner Notes, Tips, Hard-Won Lessons

Companion to `syntax_quick_ref.md` (lookup) and `concepts_taught.md`
(pedagogical index). This file is experience, not curriculum: things learned
building and debugging real runtime code (seed balancer in reconverse,
2026-07). Audience: future Claude sessions and students doing Charm++ or
runtime-level work.

## Application-level discipline

- **No bare globals, ever.** Per-PE state = member data of a group branch,
  accessed via `ckLocalBranch()`. `readonly` for set-once-in-mainchare
  values. `thread_local` may appear to work in a threads-per-PE runtime but
  is wrong at the model level (breaks under non-SMP builds, migration, and
  review by anyone who knows Charm++). Runtime-internal code (Converse
  itself) is a different regime with its own conventions (Cpv/Csv, and in
  reconverse, thread_local by existing convention).
- **Design libraries around CkCallback**: accept `CkCallback done` in the
  API, signal with `contribute(done)`, never name a client chare. Clients
  need only `extern module X;`. Test harness (`main.ci/.C`) should be a
  disposable example client, not load-bearing.
- **Counting completion beats "done" flags**: no message-order guarantees.
  For per-PE data collection at exit: broadcast to a stats group, each
  branch prints/contributes, reduction target exits.
- **Plain chares** may `delete this` after their final send. Parent-child
  reporting via a marshalled `CkCallback` or parent proxy both work; the
  callback form (`CkCallback(CkIndex_W::done(), thishandle)`) composes best.

## Message-memory rules (runtime-level, sharp edges)

- **Never byte-copy an UNPACKED envelope.** A charm envelope fresh from
  ckNew/send contains live pointer state and is NOT a self-contained byte
  string. Before memcpy'ing a message into any aggregate (batch, log,
  buffer), run the CldInfoFn's pack fn (`pfn`). Symptom of violating this:
  responses misrouted to null/garbage objects, wrong small results computed
  "instantly," crashes far from the cause. Pointer handoff within a process
  and CmiSyncSendAndFree-of-the-original are exempt (no copy happens).
- **CmiAlloc blocks are refcounted** (`CmiChunkHeader.ref`); `CmiReference`
  shares ownership. A NEGATIVE ref field means "sub-message": it is the
  byte offset back to the enclosing allocation's header, and CmiFree walks
  it (`CmiAllocFindEnclosing`) and decrements the enclosing block. This
  enables zero-copy scatter of a batch: embed per-record headers with
  negative refs, hand out interior pointers, bump the batch refcount to the
  record count; block dies with its last record. Offsets are relative =>
  survive wire copies.
- **Zero-copy has a hidden cost cross-node**: interior pointers pin the
  transport's receive buffer until the last record is consumed => pool
  starvation. Measured ~15% slowdown on 2-process runs. Policy that won:
  zero-copy for same-node batches, copy-and-release for cross-node,
  decided at the receiver.
- Messages executed via `CmiHandleMessage` are freed by the handler side
  (charm frees creation messages after the constructor). Exactly one owner
  at all times; design any queue holding raw message pointers around that.
- **`CmiFree` must free the ENCLOSING block, never `msg`.** After the
  negative-ref walk (`CmiAllocFindEnclosing`), the pointer handed to the
  allocator must be `parentBlk`; `msg` may be an interior sub-message
  pointer. Regressed silently in reconverse when the pinned-memory work
  (#160) rewrote the free as `comm_backend::free(msg)` — every allocator
  (`std::free`, mempool) locates its bookkeeping at `ptr - header`, so an
  interior pointer aborts ("pointer being freed was not allocated"), but
  ONLY on the last owner of a shared batch => single-PE runs pass, >=2 PE
  runs with the batching seed balancer abort. Lesson doubled: merges from
  main can break invariants only the balancer branch exercises — after any
  merge, rerun a >=2 PE seed-batch smoke test (fib is enough) before
  trusting the build.

## Benchmarking discipline

- **Check the banner**: "built without optimization / error checking
  enabled" invalidates performance numbers (can be several×).
- **Repeats or it didn't happen**: on a laptop, 2-process runs swing ±50%;
  report median of >=3. Single-process multi-PE runs are far more stable.
- **Verify the transport before blaming the runtime**: on macOS, libfabric
  has NO shm provider — local cross-process traffic rides TCP loopback at
  ~45 µs one-way (64KB ~3 ms). `FI_LOG_LEVEL=info` shows the chosen
  provider; `fi_info` lists what exists. Linux clusters (fi_shm, IBV,
  slingshot) are ~1-2 µs — conclusions about viable grainsize DO NOT
  transfer from mac cross-process runs.
- **Grainsize rule with the right denominator**: grain >= ~20× the
  *per-crossing* message cost that actually applies (per-message scheduling
  overhead ~ a few µs is usually not the binding constraint; transport is).
- Two standard probes bracket scheduler work: a chain/creation benchmark
  (throughput, per-message overhead: chaintest ~0.8 µs/creation on healthy
  reconverse main, 1 PE) and pingpong (latency: ~0.17 µs one-way in-process,
  ~0.3 µs old converse ~1.4 µs). Any scheduler change must hold BOTH.
- Derive per-unit overheads from excess-over-sequential divided by unit
  count (e.g., per-seed cost from fib threshold sweeps) — two thresholds
  giving the same per-unit number = the model is right.
- **Before building an optimization, find a control configuration where it
  can save NOTHING, and read the "waste" counter there.** A counter that
  lumps necessary work in with savable work overstates the opportunity by
  the necessary share; the control run measures that floor directly.
  (paratreet2 FoF: the "redundant descents" counter at 1 process — where
  the merge graph is empty and every counted descent is unavoidable
  verification — exposed a ~100k floor that persisted at all process
  counts, flipping a planned framework surgery to a no-go.) Corollary:
  loopback/oversubscribed extrapolations of concurrency-driven waste can
  point the WRONG WAY vs a real network — measure the actual curve before
  committing framework changes.

## Debugging on macOS

- **lldb strips DYLD_LIBRARY_PATH** (SIP): set it inside lldb with
  `settings set target.env-vars DYLD_LIBRARY_PATH=...`, then `run`.
- **Missing output ≠ early crash**: stdout through a pipe is block-buffered;
  a segfault discards everything unflushed (even the startup banner). Get
  ground truth under lldb, not from what printed.
- Apple clang still defaults to C++98: any charm arch file for mac must add
  `-std=gnu++17` — and to CMK_NATIVE_CXX_FLAGS / CMK_SEQ_CXX_FLAGS too,
  because conv-mach-darwin.sh snapshots those from CMK_CXX_FLAGS *before*
  the arch-specific script appends (charmxi builds with NATIVE).
- `!`-prefix shell in a Claude session has the user's login context but NO
  TTY: interactive sudo and passphrase-protected ssh keys fail there; use a
  real terminal for those.

## Runtime/scheduler lessons (reconverse era)

- **"Idle" must mean all-queues-empty.** A scheduler that declares idle
  because *the one thing it just polled* was empty (register-queues table,
  one slot/iteration) fires BEGIN/STILL_IDLE spuriously under load,
  triggers steal-on-idle from loaded PEs, corrupts idle statistics, and
  pays an idle-flap per message (measured: 3.3× per-creation overhead).
  Fix shape: sweep all slots within an iteration before declaring idle.
- **No clock reads in the per-iteration path.** CmiWallTimer per idle
  iteration (LONG_IDLE checks, adaptive gates) is an anti-pattern; read
  timers at grain boundaries (after handling a message) or use the cycle
  counter (cntvct_el0 / invariant TSC, ~1-2 ns). Ticks are the right unit
  for object-load measurement on-node; wall time (= ticks×scale+offset,
  calibrated) for traces. Hazards for ticks: heterogeneous E/P cores, VM
  migration re-basing counters.
- **Network progress is not a queue**: its backlog is invisible until
  polled and a dry poll costs real time. Gate it by TIME (latency budget
  under load; unconditionally when idle), not by iteration count —
  iteration duration varies by the grainsize, so counter gates are
  grainsize-blind.
- Handler registration order must be identical on every PE (indices travel
  in message headers). Same-code-path registration per thread is the
  guarantee; assert it in debug builds.
- **Deterministic lockstep beats broadcast**: if every PE can compute the
  same result from the same seed (graph construction, retry sequences),
  no startup collective is needed at all — and quality *checks* (reject &
  retry) stay lockstep too; only quality *selection* (pick best of P
  candidates) requires a reduction.

## Build-system notes (charm + reconverse)

- `./build charm++ reconverse-<plat> --with-fetch-reconverse-dir=$PWD/reconverse`
  consumes the checkout IN PLACE (`FETCHCONTENT_SOURCE_DIR_RECONVERSE`):
  switching branches in `charm/reconverse` + `make` in the build dir
  rebuilds against the new branch — the cheap way to A/B runtime variants.
  First post-switch make may show one transient error line; re-run to a
  clean pass before trusting binaries.
- Don't hand-edit CMAKE_CXX_FLAGS in a configured charm build tree
  (mixed-flag objects => instant segfaults); wipe and rebuild via ./build.
- Run idiom: `lcrun -n <procs> env DYLD_LIBRARY_PATH=<charm>/lib ./app
  +pe <total PEs> <args>`. `+pe` is total across processes. Single-process
  runs don't need lcrun.
- Converse-only programs: `charmc -language converse++`.

## SMP correctness, registration & library-modernization patterns (2026-07)

- **`CkAssert` is a no-op in optimized builds** (`CMK_OPTIMIZE=1` /
  `CMK_ERROR_CHECKING=0` — which is what a production charm build is):
  it compiles to `((void)0)`, so a "passing" test whose checks are
  CkAsserts may be vacuously green. Use `CkEnforce` (always on) for
  correctness checks in tests, and prove any assertion harness
  non-vacuous once by deliberately breaking the condition and watching
  it abort. (Corollary: the build banner's "error checking enabled"
  warning cuts both ways — that is also the only build where CkAssert
  does anything.)
- **A shared nodegroup can be lock-free on purpose — don't "fix" it with a
  mutex.** A nodegroup branch is shared by all worker PEs of a process
  (concurrent pthreads). A well-designed one (e.g. paratreet's CacheManager)
  keeps the hot path lock-free: concurrent structural updates via NARROW
  atomics (atomic child-pointer `exchange` for lock-free tree fills, an atomic
  per-PE request bitmask), and lockless reads. Any coarse/data-path lock is
  self-defeating: it serializes the very concurrency that is the point, and —
  because readers are lockless — a mutex on a *writer* can't serialize against
  them anyway (false comfort). Keep whatever narrow structural mutex exists
  (e.g. guarding just non-thread-safe std::map inserts) narrow. The correct
  tool for *mutating* shared cached data after setup is PHASE SEPARATION, not
  a lock: mutate in a phase that is quiescence-separated (`CkWaitQD`, also the
  cross-PE memory barrier) from any concurrent reader. Record this invariant
  loudly in the code so a future contributor doesn't add a lock (paratreet2:
  `CacheManager.h` header block + `design/cache-concurrency.md`).
- **A build-time snapshot shipped to a remote cache goes stale on later
  mutation.** If you flatten local state into a message and ship it to a
  peer's cache once (at build/setup), then mutate the original later, the
  peer keeps the old copy — nothing links them. Symptom: a post-setup
  update (relabel, annotate, per-leaf mutation) is visible locally and on
  the same process, but a remote consumer reads pre-mutation data — so
  bugs hide until you run on >=2 PROCESSES (not just >=2 PEs; same-process
  PEs share the live objects). Fixes: (a) re-push the snapshot after the
  mutation (track who took a copy; send an in-place update keyed so
  existing pointers stay valid), or (b) make the consumer fetch live on
  demand instead of caching a copy. Found in paratreet2: post-build
  `callPerLeafFn` mutations were invisible to remote source leaves under
  non-matching decompositions (a build-time `flat_subtree` copy); matching
  decomps dodged it by fetching live. Test the multi-PROCESS path
  explicitly — single-process (even multi-PE) will not surface it.
- **Registration strings live forever**: any `const char*` handed to a
  Ck registration API (`CkIndex_X<T>::__register(name, size)` for
  templated-chare instantiations) is kept by pointer, not copied.
  Returning `.c_str()` of a temporary compiles and "works" until the
  table is read. Build the name on the heap and deliberately leak it —
  registration runs once per type.
- **Reset accumulators at round START, not round end.** A chare that
  accumulates contributions across a counted round (`data += child;
  if (++recv_count == expected) {...; recv_count = 0;}`) must also
  reinitialize `data` when `recv_count == 0` is first seen. Relying on
  "it was fresh at construction" breaks the first time anyone runs a
  second round (rebuild, re-annotation pass). Found as a latent
  double-count in ParaTreeT's TreeCanopy.
- **SMP parallelism without atomics — frozen-phase pattern**: split
  work into (1) parallel per-PE phase over disjoint data, (2) freeze +
  fully compress results, barrier, (3) parallel detection phase that
  READS only frozen data and WRITES only per-PE private buffers,
  barrier, (4) small serial merge on one PE, (5) parallel owner-side
  apply/relabel. Caveat that motivates step 4 being serial: "noted"
  merge operations are transitive (a→b noted on one PE and a→c on
  another implies b~c), so applying them is itself a union-find, not a
  scatter of independent writes.
- **Library modernization order that worked**: copy wholesale → build →
  run existing minimal example as smoke test → prune (`unifdef -U` for
  feature-flagged code, works on .ci too) → re-test → only then change
  interfaces. Never assemble a new library from hand-picked pieces and
  debug the dead pile.
- **Prefetch ordering constraint**: anything a traversal's cache
  prefetch ships (canopy/top-level node data) must be finalized BEFORE
  the prefetch, not merely before the traversal. On-demand-fetched data
  (leaves) only needs to be ready by traversal time.

## Message-driven design heuristics (from the seed-LB papers, validated)

- Balance load AND priority AND memory — optimizing one concentrates
  pathology in another (IPPS'93).
- Move few, chunky things: batch transfers, take from the oldest/shallowest
  end; per-exchange work O(k) with small fixed k.
- Push load info piggybacked + delta-suppressed; never poll for it.
- Deque discipline for D&C: execute newest (depth-first, memory ∝ depth),
  export oldest (chunkiest).
- Metrics that matter: hops-per-seed flat in P; work-count vs sequential
  within a few %; consistency ACROSS RUNS, not just mean speedup.

## Gather patterns + template-module hygiene (2026-07-18)

- **Concat reduction beats a hand-rolled gather-to-one**: to collect per-PE
  buffers on one PE, `contribute(bytes, buf.data(), CkReduction::concat, cb)`
  is completion detection AND transport in one primitive. The alternative
  (broadcast a callback + count CkNumPes() point-to-point messages at the
  collector) has a real ordering hazard: Charm++ does not order a broadcast
  relative to p2p sends, so the collector may see data before it knows the
  callback. The count pattern is only needed when contributors send variable
  numbers of messages.
- **Visitors with state are fine through pupped broadcasts** (paratreet
  startDown): members (proxies, cutoffs) pup into the broadcast; per-PE
  side-effect state should NOT live in the visitor (it's copied per chare) —
  route it to a group's `ckLocalBranch()` via a plain public non-entry
  method. Traversal work for chares homed on a PE runs on that PE, so no
  locking is needed on the branch.
- **Stale-object trap after editing a templated library .ci**: example
  Makefiles that don't list the library's generated decl.h as a dependency
  will happily link old objects (compiled from the old generated template
  code) against the new library — runtime entry registration can then
  diverge across TUs. After any library .ci change, `make clean` the
  client examples before trusting their tests.

## Determinism traps: dedup, sentinels, untested paths (2026-07-19)

- **"Reorder the calls" can hide a duplicate-generation bug**: when a collector
  APPENDS every re-sent round of data (instead of replacing) and the shipper
  then sorts with an UNSTABLE sort before shipping, it ships an arbitrary
  generation per key — and moving the shipper call later doesn't fix it. The
  fix is keep-newest dedup (`stable_sort` + last occurrence per key), not call
  ordering. Symptom class: nondeterministically stale data — a rarely-wrong
  answer, not a crash.
- **Initialize domain fields to an invalid sentinel, not by accident**:
  fresh mmap'd heap is zero, and zero was a *valid* fragment id — so
  "uninitialized" build-time annotations (min=max=0) masqueraded as a
  uniform fragment 0 and would have satisfied a validity assertion.
  `group_number = -1` made the pre-phase-1 state deterministically
  rejectable (min_frag >= 0), which is what made the ordering tripwire
  non-vacuous.
- **A code path whose in-vivo counter can stay 0 on all realistic inputs
  needs a unit test, not just production observation.** Example: in a
  top-down dual-tree walk, an "accept at the topmost pair" certificate can be
  permanently pre-empted by a finer-grained resolution reached first, so its
  production hit-count stays 0 — which reads like dead code but is really
  "never exercised by these inputs." Deliberately construct an input that
  forces the path rather than trusting a live counter.

## Marshalling ownership, reconverse QD, opt-in capabilities (2026-07-22)

- **`CkPointer<T>` on a same-PE (local) call transfers ownership of the
  sender's live object, not a copy.** If the receiver then wraps it in a
  `shared_ptr`/`unique_ptr` while the sender still owns the same object, both
  free it → double-free (glibc `malloc_printerr`). Use `CkReference<T>`
  (aliases the caller's object, no ownership transfer) and `clone()` (PUP::able)
  if the receiver must own an independent copy. Rule: a receiver that will OWN
  the argument must not be handed a CkPointer to a caller-owned live object on
  the local path.
- **A missing virtual destructor on a polymorphic base held by
  `unique_ptr<Base>` is a platform-dependent time bomb.** Deleting a derived
  object through the base with no virtual `~Base` is a sized-deallocation
  mismatch → heap corruption. It can run for weeks on macOS and crash on the
  first Linux/glibc run. "Works on the laptop" says nothing about the cluster
  allocator; give every polymorphic base a virtual dtor.
- **`CkWaitQD`/`CkStartQD` can hang on RECONVERSE even when the system is
  genuinely idle** (classic Converse's QD is unaffected — this is
  reconverse-specific, so it only bites on a reconverse build). Reliable
  workaround: an explicit broadcast+reduction no-op barrier (a readonly group
  entry `ping(cb){ contribute(cb); }`) — every branch must exist and reply
  before it completes, and readonly-group same-source delivery order guarantees
  prior creations already landed. Prefer an explicit reduction barrier over QD
  for startup synchronization on reconverse. Corollary: a project that develops
  on classic Converse but deploys on reconverse won't see this locally — it
  surfaces only on the reconverse machine.
- **Opt-in capability for a templated callback interface without taxing other
  implementations.** To give ONE implementer of a generic `open()`-style
  callback extra context (e.g. a tree node's key) without changing the
  signature everyone implements: an anonymous-namespace SFINAE helper that sets
  `v.field = x` iff the type declares `field`, plus a no-op overload for the
  rest (chosen at compile time, removed by the optimizer). Implementers that
  don't opt in are byte-for-byte unchanged — keeps a general-purpose framework
  general. (Same idiom as a `static constexpr` trait flag.) Aside: a node's
  Morton key stays valid on cache-shipped copies; parent POINTERS may not —
  prefer keys for data that must survive shipping.
- **Charm example Makefiles often lack header-dependency tracking**: after a
  pull that changes a `.ci`/header, stale `.o`s link against the old generated
  signature (undefined-symbol on the OLD prototype is the tell). `make clean`;
  don't trust an incremental rebuild across `.decl.h` changes.

## Aggregation layers vs quiescence; layout-changing flags (2026-07-23)

- **Items parked in a sender-side aggregation buffer (tramlib/htram) are
  invisible to RTS quiescence detection** — QD counts messages, and a
  buffered item is not yet a message, so a bare `CkWaitQD()` can fire with
  work still parked and silently drop it (even with a periodic timed flush:
  that's a race, not a guarantee). Correct completion is an ITERATED loop:
  arm QD -> on fire, flush all buffers -> QD again -> reduce residual
  buffered-item counts across PEs -> repeat until the reduction says zero
  (htram's `htramQuiesce` implements exactly this; a one-shot flush+QD is
  not enough because processing flushed items can buffer new ones). If a
  library offers such a quiesce entry, use it instead of building counter-QD.
- **A `-D` flag that changes a shared class's layout must reach every TU
  that includes the header** — e.g. a member that exists only `#ifdef X`
  makes library-vs-client builds ABI-incompatible if the flag differs.
  Thread the flag through ONE build variable that all Makefiles inherit
  (not per-example OPTS edits), and bundle any prerequisite defines with it
  (duplicated `-D`s are harmless; a missing one in a single TU is not).

## Group-creation ordering: the array-map race (2026-07-24)

- **Two creation regimes, two guarantees (Kale).** Everything a MAINCHARE
  constructor creates (groups, nodegroups, chare arrays, readonly buffers)
  is batched from PE 0 with sequence information and INSTALLED IN CREATION
  ORDER on every PE before the scheduler executes anything else — so
  during mainchare-ctor time, "create map group, then array using it" (or
  any later-created-uses-earlier-created pattern) is unconditionally safe;
  all other messages are buffered until installation completes. (Dynamic
  insertion via doneInserting is a wrinkle on top; and the mainchare ctor
  must not be paused/threaded.) POST-INIT creation — e.g. from a threaded
  driver that rebuilds arrays per iteration — gets NONE of that: ordering
  rests solely on per-message group dependencies, which have holes (next
  bullet). Know which regime your creation code runs in.
- **Charm++'s group-dependency buffering protects `setMap` — EXCEPT when
  combined with `bindTo`.** Normal path (CkCreateArray, ckarray.C): the
  location cache is created with a group dependency on the map, the
  location manager on the cache, the array on the manager — a transitive
  chain, so the array constructor's map lookup is safe on any runtime
  (classic Converse AND reconverse share this Ck-layer code). But
  `bindTo` reuses the bound-to array's existing location manager, the
  `locMgr.isZero()` block is SKIPPED, and NO dependency on a freshly
  created map is declared: the array-creation broadcast races the
  map-group creation broadcast, and a remote process that loses aborts in
  the CkArray constructor with "ERROR! Local branch of array map is
  NULL!". Loss probability grows with process count (paratreet2: clean
  through 16 processes on Anvil, died at 32, on both runtimes; never lost
  on laptop loopback). Fix: any barrier between the map ckNew and the
  array ckNew. Best fix, no barrier at all: declare the map as a USER
  group dependency of the array creation — `CkEntryOptions e;
  e.setGroupDepID(opts.getMap()); CProxy_X::ckNew(..., opts, &e);` —
  CkCreateArray copies user dependencies onto the CkArray creation, so
  each PE buffers the array-creation message until its map branch exists;
  the MESSAGE waits, no thread waits, nothing else is disturbed. (QD as
  the barrier is too broad: it requires that no other computation is in
  flight. A reduction over the map branches is unavailable: CkArrayMap
  derives from IrrGroup, not Group, so its constructor has no
  contribute() — the constructor-contribute idiom, e.g. megatest
  groupcast.C, works only for regular groups.) Upstream bug candidate:
  bindTo + fresh setMap should declare this dependency itself.
- **An array map is not just placement — it defines element HOMES.**
  Replacing a custom map with explicit `insert(pe)` keeps the elements
  where you wanted them but `lastKnown()` then falls back to the DEFAULT
  map's homes (round-robin over all PEs); anything that routes by
  lastKnown (e.g. an aggregation layer delivering to the element's PE)
  starts targeting PEs that never registered handlers. If home-based
  routing exists anywhere downstream, keep the map.
- **Meta-lesson, earned the embarrassing way: attribute a runtime-level
  failure to a specific runtime only after reading that runtime's code.**
  The first analysis blamed reconverse for lacking the buffering (laptop
  classic passed, Anvil reconverse failed) — wrong on both counts: the
  mechanism lives in the shared Ck layer, and classic Converse crashes
  too. "Passes here, fails there" distinguishes ENVIRONMENTS (timing,
  scale, network), not necessarily implementations.

## SMP launch layout + within-process stage chaining (2026-07-25)

- `charmrun +pN` WITHOUT `++ppn` on an SMP build launches N PROCESSES
  x 1 worker PE each (default ppn is 1) — not one process with N PEs.
  Single-process multi-PE runs need `+pN ++ppn N`. Any test whose
  validity depends on the process/PE split (e.g. comparing per-process
  results against a global reference) should assert `CkNumNodes()`
  itself rather than trust the launch line; the failure mode is a
  silently wrong comparison, not an error. Read the startup banner
  ("SMP mode: P processes, W worker threads") before debugging
  "wrong results" in a parallel config.
- A harness can silently mask the bug class it exists to catch when a
  LATER phase is self-healing: a distributed FoF full check passes even
  if the intra-process phase under-merges, because the cross-process
  phase's edge predicate (different labels within range => edge) also
  repairs same-process misses. Keep (and run) the narrow phase-level
  test; the end-to-end check is not a superset.
- Within-process barrier across a group's branches, without blocking:
  there is no built-in construct (contribute() reduces globally;
  CmiNodeBarrier blocks worker threads). The idiom: an atomic counter
  on a nodegroup branch, deposited via ckLocalBranch() at the end of
  each PE's stage entry (one deposit per PE); the depositor whose
  fetch_add returns size-1 triggers the next stage by sending entry
  messages to the process's PEs (group proxy element sends). No thread
  waits; the scheduler stays free. Memory ordering is sound because
  the deposits are RMWs on one atomic (release sequence: the last
  fetch_add synchronizes with all earlier ones), and message delivery
  synchronizes the receiving PE. A per-process serial step can run
  inline on the last depositor (exclusive by construction). Finish
  with ONE ordinary contribute() carrying results to the driver.

## Large-payload reductions: pre-merge, direct sends, reduce-scatter (2026-07-25, Kale)

Cost model to reason with: per-byte costs are ~0.1-0.5 ns, per-message
costs are a couple of microseconds. A reduction spanning tree exists to
amortize PER-MESSAGE cost (the root receives 2-4 messages instead of
P); it does nothing for per-byte cost — and for CONCAT it multiplies
it, since every interior vertex re-allocates and re-copies its
subtree's cumulative payload (total bytes copied ~ payload x tree
depth, attributed to runtime overhead, invisible to entry-method
profiles).

- Large contributions, any reducer: collect locally first and
  contribute from a NODEGROUP (make one if none exists) — P/PEs-per-
  process fewer contributions, and intra-process duplicates merge in
  shared memory for free.
- Large contributions, concat specifically: skip the tree entirely and
  send each (pre-merged, per-process) contribution DIRECTLY to the
  root. N_proc messages x ~2 us is noise; the avoided tree re-copies
  of an MB-scale payload are tens to hundreds of ms. Spanning trees
  are for SHORT messages.
- Sparse keyed data (label -> count maps) does not fit the built-in
  elementwise reducers (fixed-length, position-aligned arrays). A
  custom merging reducer only helps when cross-contribution key
  collisions are dense (data shrinks along the tree); when keys are
  mostly unique the root volume is irreducible and interior merges
  cost more than memcpys. The stronger move is REDUCE-SCATTER (Kale's
  naming): shard the key space, sum per shard where the data lives,
  and reduce only the small dense summary (a fixed-size histogram fits
  the standard mold perfectly).
- Look for structure that removes keys from global reduction entirely:
  in the FoF component histogram, the label's sign proved most keys
  (process-local components) never needed cross-process summing at all
  — 99.97% of a 400 MB gather vanished before any transport question.

## Reconverse/LCI: registration paths are the soft spot (2026-07-26)

Cross-machine finding (Anvil + macOS laptop, same day, same subsystem):

- FIRST CHECK when diagnosing reconverse/LCI transfer costs:
  `grep LCI_USE_REG_CACHE <build>/CMakeCache.txt`. Builds have shipped
  with it OFF; on a real RDMA fabric (Anvil) that means full memory
  registration per transfer — the observed "heavy pingpong costs" —
  while on the macOS OFI-tcp provider registration is near-free, so
  laptop numbers won't show the problem.
- Plain message-passing on reconverse is SOLID and fast: charm++
  pingpong cross-process loopback roundtrips ~54 us on macOS/tcp for
  arrays, chares, groups — beating classic netlrts (~120-260 us,
  comm-thread relay) on the same machine. Intra-process both are
  sub-microsecond.
- The ncpy/zero-copy paths are the least-exercised code: per-send
  zero-copy API costs ~2x on small payloads (extra rendezvous trip —
  expected), but PERSISTENT registered buffers (CkNcpyBuffer with
  CK_BUFFER_REG / CK_BUFFER_NODEREG, as in benchmarks/charm++/
  pingpong's PingN constructor) HANG the phase outright on the OFI-tcp
  backend — both ranks poll in CsdScheduler -> LCI progress -> kevent
  for a message that never arrives.
- Elimination discipline that localized it (reusable pattern): the
  hanging benchmark phase differed from working application traffic in
  three ways — nodegroup routing, [exclusive] entries, ncpy
  registration. A 30-line minimal pingpong testing plain AND exclusive
  nodegroup entries passed both (54-92 us), leaving registration as
  the culprit. Write the minimal contrast test BEFORE blaming the
  obvious suspect: the "obvious" ones (nodegroups, exclusive) were
  innocent.
- Practical: applications using plain marshalled/message sends
  (paratreet2 included) are unaffected. Avoid CkNcpyBuffer persistent
  registration on reconverse until fixed; reconverse issue filed with
  reproducers.
- Diagnosis mechanics on macOS: a hung-looking benchmark under a PIPE
  shows nothing (block buffering) — rerun under `script -q <log> <cmd>`
  to get a pseudo-TTY and per-line flushes; `sample <pid>` gives the
  polling stack without lldb.

### Same subsystem, quantified on real RDMA hardware (Anvil, 2026-07-26)

Companion to the section above, which flagged `LCI_USE_REG_CACHE` as the
first thing to check. Here is what it actually costs and why, measured on
InfiniBand HDR rather than the macOS tcp provider. Anvil-specific mechanics
live in `machines/anvil.md`; the mechanisms below are general to
reconverse/LCI.

- The cost is TWO `ibv_reg_mr` calls per message, not one: the sender
  registers at `rendezvous.hpp:210` and the receiver at `:127`, every
  message, with no cache. On EPYC/HDR each `ibv_reg_mr` is ~15 us and each
  `ibv_dereg_mr` ~13 us, and that cost is FLAT from 4 KB to 64 KB — so the
  penalty is a fixed ~45-50 us adder, not a bandwidth effect. A
  size-independent adder at tens of microseconds is the signature; look for
  registration, not the fabric.
- `LCI_USE_REG_CACHE` is a COMPILE-time option defaulting OFF, and it cannot
  be enabled at runtime — `network.cpp` asserts on
  `RegCache::is_enabled()`, which is `constexpr`. Rebuild with
  `-DLCI_USE_REG_CACHE=ON`. No external dependency: LCI vendors the UCS
  rcache in `third_party/ucx`, gated on that same option.
- Measured effect of turning it on (same binary, cache toggled at runtime by
  `LCI_ATTR_USE_REG_CACHE` once it is compiled in — which makes a properly
  controlled A/B possible): 8 KB 50.7 -> 6.2 us (8.2x), 32 KB 54.8 -> 7.9
  (7.0x), 128 KB 65.3 -> 13.3 (4.9x), 2 MB 180.6 -> 131.5 (1.37x). Flat
  saving, so the RATIO shrinks as bandwidth takes over. Verified by
  interposition: 0 per-message registrations with the cache on, exactly 2000
  for 1000 iterations with it off. At the charm++ level the same change is
  ~7x on 16 KB messages.
- What remains after the fix is ~3 us over the eager path — one extra
  RTS/RTR round trip, which is what rendezvous SHOULD cost. If your
  rendezvous overhead is tens of microseconds rather than a few, it is not
  the protocol.
- The eager/rendezvous threshold is NOT at `packet_size`, which is the
  natural guess. It is
  `max_bcopy_size = packet_size - LCI_CACHE_LINE - sizeof(tag_t) - sizeof(rcomp_t)`
  (= 8116 on the wire for the default 8192), and Converse's own 20-byte
  `CmiMessageHeader` comes out of that too, so the usable payload limit is
  8096. Verified to the byte: 8096 -> 3.59 us, 8097 -> 51.02 us. Raising
  `LCI_ATTR_PACKET_SIZE` moves the cliff but the packet pool is registered
  at startup and scales with it (~272 MB -> ~1.1 GB pinned per process at
  4x), so prefer the registration cache.
- Technique worth reusing: LD_PRELOAD-interpose `ibv_reg_mr`/`ibv_dereg_mr`
  to count and time registrations in a live run — it turns "I think it is
  registering" into a number. Two traps: do NOT include
  `<infiniband/verbs.h>` (it `#define`s `ibv_reg_mr` to a static-inline
  dispatcher, renaming your symbol), and resolve the real function with
  `dlvsym(RTLD_NEXT, "ibv_reg_mr", "IBVERBS_1.1")` — plain `dlsym` picks the
  legacy `IBVERBS_1.0` entry, which has a different `ibv_mr` layout and
  segfaults. Do not interpose `ibv_reg_mr_iova2`; libibverbs calls it
  internally.

### Reconverse sends inter-process traffic over the NIC even within a node (2026-07-26)

- `CmiSyncSendAndFree` (`convcore.cpp:601`) branches on
  `CmiMyNode() == destNode` only — same PROCESS gets a direct `CmiPushPE`,
  and EVERYTHING else goes to `comm_backend::issueAm`. There is no
  physical-node check. In reconverse a "node" is a process, so two processes
  sharing a socket do IB loopback through the adapter (~2.2 us small
  messages, plus the full registration cost above once past eager).
- LCI itself has no shared-memory path at all — no occurrence of `shm`,
  `loopback`, `same_node` or `intra_node` in its source. Do not expect the
  transport layer to notice locality for you.
- `CMK_USE_SHMEM` looks like the switch but is not sufficient: reconverse
  has the CONSUMER (`scheduler.cpp:27` polls `CmiPopIpcBlock`) and the
  implementation (`src/cmishmem.cpp`), but NO producer — nothing in
  reconverse calls `CmiPushIpcBlock`/`CmiAllocIpcBlock`/`CmiMsgToIpcBlock`.
  The only producer is in Charm++ (`ck.h` `_IpcSendImpl`/`_tryIpcSend`,
  under `#if CMK_USE_SHMEM`), so converse-level programs — including the
  reconverse pingpong benchmarks — would not exercise it even with the flag
  on. Enabling it end to end is currently blocked by duplicate symbols
  (charm's `conv-core/shmem/cmishmem.C` vs reconverse's `src/cmishmem.cpp`)
  and by the option not being plumbed between the two build systems.
- Corollary for benchmarking: "intra-node" is three different cases in
  reconverse — same process (shared memory, sub-microsecond), different
  process same node (NIC loopback today), and different node. Always say
  which one a number refers to; they differ by more than an order of
  magnitude.

### Placement beats affinity flags; +setcpuaffinity alone can be a pessimization (2026-07-26)

- Reconverse has NO comm thread (`CommunicationServerThread()` is an empty
  stub) and `CmiStartThreads` creates exactly `+ppn` threads, so unlike
  classic Converse SMP no core needs reserving. The flip side is that
  network progress happens inside worker threads: a PE without a real core
  makes no progress at all, and busy-polling PEs sharing a core produce
  latencies at OS-timeslice scale (milliseconds) that look like transport
  bugs. A size-independent delay of ~10 ms means scheduling, not data
  movement.
- CPU affinity is gated on hwloc via
  `option(RECONVERSE_ENABLE_CPU_AFFINITY ... ${HWLOC_FOUND})`, so a build
  without hwloc SILENTLY has all of `cpuaffinity.cpp` compiled out to empty
  stubs, and `+setcpuaffinity` is not even parsed. Check
  `grep RECONVERSE_ENABLE_CPU_AFFINITY <build>/CMakeCache.txt` before
  concluding anything about pinning. On a RECONFIGURE, supplying hwloc is
  not enough — `option()` only applies its default on the first configure,
  so a stale `OFF` in the cache wins; pass the variable explicitly.
- With affinity available, placement dominates and the automatic policy can
  hurt. Two PEs, 512 B one-way, 128-core dual-socket node: `+pemap 0-1`
  (same NUMA domain) 0.237 us; no affinity 0.828 us; `+setcpuaffinity`
  alone 1.197 us; `+pemap 0,64` (cross-socket) 1.255 us. 5.3x from
  placement, and the automatic spread policy is WORSE than no affinity for
  small PE counts because it distributes workers across sockets. Use
  explicit `+pemap` for latency work and `+showcpuaffinity` to confirm.
- Retraction of a number from earlier the same day: an intra-process
  latency of 0.836 us was reported as healthy. It was ~3.5x pessimistic —
  the two PEs were landing far apart in a wide cpuset. The real figure is
  ~0.24 us. A "reasonable-looking" latency is not evidence of good
  placement.

### A test suite can pass without ever communicating (2026-07-26)

- LCI's LCT needs PMIx to discover job size under `mpirun`. If LCI was built
  without PMIx support (common — it is an optional dependency that fails
  silently), LCT logs "LCT assumes the number of processes of this job is 1"
  and EVERY RANK RUNS AS AN ISOLATED SINGLE-PROCESS JOB. `mpirun -n 2 app
  +ppn 1` then prints "Running in SMP mode on 1 nodes and 1 PEs" twice and
  the test passes, having sent nothing.
- reconverse's ctest suite defaults `RECONVERSE_TEST_LAUNCHER=mpirun`, so on
  such a build every multi-process test is a duplicate of its own
  `-onenode`/`-singlenode` twin. Point the launcher at the resource
  manager's own launcher (`srun --mpi=pmi2` on Slurm) or build with PMIx
  before believing a green suite.
- Sanity check that costs nothing: make multi-process tests assert the
  process/PE count they expect. Any test whose value depends on there being
  N processes should fail loudly when there is one.
- Related discipline: when a suite reports many failures, check the LAUNCH
  before the code. Of 8 failures seen here, 7 were an artifact of nesting
  `mpirun` inside an `srun` step and 1 was a real segfault — and separately,
  the "passes" were not testing what they claimed. Both directions of error
  were in the harness.

## Reading Projections traces: black regions, flush hygiene (2026-07-26)

- Time-profile BLACK = time attributed to neither entries nor idle:
  scheduler-level work — message handling, and notably GROUP/ARRAY
  CREATION (constructors run outside traced entries). A black wedge
  that is per-PE staggered bars in the timeline view is creation
  broadcasts landing at slightly different times. Diagnosed instance:
  UnionFindLib init with htram aggregation cost 60-100 ms of black
  per PE at 480 PEs (tram group creation + per-destination buffer
  allocation, which grows with machine size) — found by decomposing
  the window from the RAW logs, not the GUI.
- Raw-log gap analysis (reusable): zcat the per-PE .log.gz, walk
  BEGIN/END_PROCESSING (types 2/3, time = 4th field) and
  BEGIN/END_IDLE (14/15, time = 2nd field) over the suspect window;
  whatever time is in neither bucket is the black region, and the
  timestamps of the largest gaps line up with what PE 0 was doing at
  that instant. Entry ids map to names via the .sts ENTRY CHARE lines.
- Trace-buffer flush: default +logsize is 1,000,000 entries/PE
  (trace-projections.C DefaultLogBufSize). A mid-run flush CANNOT be
  silent — PE 0 prints a shutdown banner ("Projections log flushed to
  disk N times ... performance data is likely invalid ... larger
  +logsize"). Flushes are also marked IN the log itself:
  flushLogBuffer records a BEGIN_INTERRUPT/END_INTERRUPT pair (event
  types 8/9) bracketing the write — `zcat file | grep -n '^8 '` finds
  them, the 8->9 timestamp delta is the I/O stall, and the line count
  between consecutive markers is the effective buffer size. Banner
  absent + no type-8 lines + line counts under +logsize = trace
  certified flush-clean. Check before attributing any stall to trace
  I/O — and conversely, a trace WITH type-8 lines carries the
  "performance data likely invalid" caveat around each flush.
- Sizing `+logsize` (2026-07-27): the units are ENTRIES, not bytes, the
  flag is `+logsize` (single plus — a runtime arg beside `+ppn`, NOT a
  `++` charmrun arg), and `LogPool::LogPool` **reserves the whole buffer
  up front** via `pool.reserve(CtrLogBufSize)`. So the default costs
  `1e6 * sizeof(LogEntry)` per PE at startup whether or not the trace
  ever fills it. `sizeof(LogEntry)` is 88 bytes without PAPI (four
  doubles, two ints, two shorts, an int, a type byte, then a union whose
  largest member is a std::string) = 83.9 MB/PE, and the PAPI build adds
  `NUMPAPIEVENTS * sizeof(LONG_LONG_PAPI)` on top. Multiply by PEs per
  PROCESS to get the real footprint under SMP. The flush trigger is
  `pool.size() == pool.capacity()` (trace-projections.C), so entries
  written < +logsize is itself proof no flush occurred.
