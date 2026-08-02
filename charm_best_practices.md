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
- **Prove the flag under test actually reached the binary.** A sweep that
  shows "no effect at any setting" is more often a delivery bug than a
  null result. Sharp edge that cost a full invalid sweep (2026-08-01):
  in **zsh**, unquoted `$ARGS` does NOT word-split, so
  `ARGS="+lci_ndevices 2"; ./app $ARGS` passes ONE argv token
  `"+lci_ndevices 2"`, which `CmiGetArgInt` never matches — silently, with
  no error and no warning. bash would have split it. Build flags as an
  ARRAY (`FLAG=(+lci_ndevices 2); ./app "${FLAG[@]}"`), and confirm the
  effect exists at the extremes before trusting the middle of a sweep.
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

## Trace provenance: what the .sts records, and what it does not (2026-07-27)

Provenance lives in the **`.sts`**, not the logs and not the `.projrc`
(which holds only `RC_GLOBAL_START_TIME`/`END_TIME`). Written by
`traceWriteSTS()`, src/ck-perf/trace-common.C. You get: `MACHINE`,
`PROCESSORS`, `SMPMODE <pes-per-process> <processes>`, `USERNAME`,
`HOSTNAME`, `COMMANDLINE`, `TIMESTAMP` (ISO 8601 UTC), `CHARMVERSION`
(= `CmiCommitID`). That is enough to answer who/when/which charm, and
`SMPMODE` recovers the launch shape.

Five gaps worth knowing before you rely on a .sts to identify a run:

- **`PROJECTIONS_ID` is emitted EMPTY.** trace-projections.C: the comment
  says "generate an automatic unique ID for each log" and the next line
  prints `""`. The one field meant to identify a run is unimplemented.
- **`COMMANDLINE` is a POST-STRIPPING snapshot, silently.** `Cmi_argvcopy`
  is taken *after* the SMP args are consumed — mainline parses `+ppn` at
  machine-common-core.C:1227 and `+p` at 1231, snapshots at 1412;
  reconverse parses `+pe/+p/+ppn` at convcore.cpp:278-283 and snapshots at
  296. `CmiCopyArgs` copies the pointer array, so args deleted BEFORE the
  snapshot vanish and args deleted after survive. Observed: a 480-PE .sts
  shows `+traceroot` but NOT `+ppn 15`. `SMPMODE` covers that particular
  loss; anything else parsed that early would disappear with no marker.
- **No application version.** `CHARMVERSION` is charm's own git describe.
  Nothing records the app's commit — so a trace cannot tell you which
  revision of YOUR code produced it. Encode it in the binary name or write
  a sidecar; do not expect to recover it later.
- **No allocation identity.** `HOSTNAME` is only the writing PE's node —
  one of N, no node list, no scheduler job ID. On a machine where
  allocation-to-allocation variation is large (see machines/anvil.md), that
  is exactly the provenance needed before comparing two traces.
- **No environment.** `LD_LIBRARY_PATH` in particular is not captured, so a
  traced binary that resolved to an UNTRACED runtime produces a
  normal-looking .sts. Verify with `ldd` at launch instead.

Practical workaround until upstream changes: have the job script drop a
`provenance.txt` into the traceroot with the app commit, scheduler job id,
node list, and `ldd` of the binary. Filed upstream as
charmplusplus/charm#3933.

## Reconverse at scale: QD and reduction completion latency (2026-07-28)

Measured from a flush-clean 480-PE trace (80M FoF, 4 Anvil nodes),
raw-log event census: after the distributed union-find's message
cascade ended, CkWaitQD took **87.8 ms** to detect quiescence on an
idle system (classic Converse: ~ms); a second ~129 ms gap initially
looked like slow reduction traffic but microscopy CORRECTED it: the
gap core contains zero events of ANY kind (all PEs formally idle,
RecvMsg clusters sit at the boundaries), and the wake is a silent
callback — it is ANOTHER QD, unionFindLib's internal
CkStartQD(postComponentLabelingCb). Net: ~220 ms across two QD
settles around ~15 ms of work, on an idle machine. Application side
audited clean: no entries, no user events, no pack/unpack, no file
or stdout I/O inside the gaps (trace buffers unflushed). Full
investigation note: reconverse-qd-latency.md in this repo. Consequences and uses:
- Any phase whose cost is dominated by barriers/QD (short reductions,
  quiesce waits) inherits large, VARIABLE overhead on reconverse at
  scale — explains uf2-phase variance (0.05-0.5 s) and suspiciously
  inflated barrier-to-barrier stage walls.
- Benchmark to add to any classic-vs-reconverse comparison: QD settle
  time and empty-reduction completion time vs PE count, on an idle
  system. Both should be near-milliseconds.
- App-side mitigations while the runtime path is investigated:
  replace completion reductions over few elements with direct done
  messages; replace QD with counting where message counts are known.

**Substantially revised 2026-08-01** — see "QD settle is fast; the
slowness is a throughput cliff" below. The 87.8/129 ms figures are NOT
the steady-state cost of QD at 480 PEs (that is ~0.3 ms); they are the
signature of an intermittent multi-node collapse.

## `+lci_ndevices`: one LCI device per PE, and where it matters (2026-08-01)

Reconverse's LCI2 comm backend allocates `num_devices = 1` by default
(`src/comm_backend/lci2/comm_backend_lci2.cpp:176`) and partitions worker
PE threads across the devices it has:

    // initThread(), same file, ~line 217
    nthreads_per_device = ceil(num_threads / m_devices.size());
    device_id           = thread_id / nthreads_per_device;

So by default every worker PE in a process shares ONE device. Raise it with
`+lci_ndevices K` on the command line. The useful setting is **K >= ppn**
(worker PEs per process) — one device per PE. K beyond ppn is inert: the
extra devices are allocated but no thread ever maps to them. Not free,
though — when the preposted-receive floor engages, `npackets` becomes
`1024 * K * 2`, so over-provisioning costs pinned memory per process.

Whether this MATTERS is entirely a property of the transport, and the
spread is enormous:

- **macOS laptop, cross-process (libfabric with no shm provider, so TCP
  loopback).** Catastrophic at the default. Mean QD settle, qdbench,
  2 procs x 2 PEs: 240-304 ms at K=1 vs **0.62 ms** at K>=2. At ppn=3 and
  ppn=4, K=1 did not finish at all (>150 s and >600 s for a run that takes
  seconds when healthy). Intermediate K is partially fixed exactly as the
  formula predicts — ppn=3 K=2 leaves two PEs sharing device 0 and costs
  45 ms; ppn=4 K=2 costs 16 ms.
- **Anvil, InfiniBand, production fof shape (8 procs x 15 PEs/node).**
  No effect whatsoever. K in {default,1,2,4,8,15,16,30} on one node: every
  value 0.139-0.233 ms with no trend, the largest value landing at K=15
  rather than at the default. FoF3 on the 80M set (lambb.00500), 12 runs
  across default/K=8/K=15 on 1 and 4 nodes, all returned identical
  23707197 components (jobs 19608513, 19608517).
  Re-measured on the RIGHT metric (job 19608652): `t_uf2`
  (FoFPhase3.h:695 — initUF2 + fireUF2Edges + CkWaitQD + find_components,
  the bracket that actually contains the QD stalls; `phaseA`, the
  phase-1 dual-tree walk, does not and is uselessly stable here).
  12 interleaved reps x {default, 8, 15} at 4 nodes / 480 PEs, medians
  0.185 / 0.136 / 0.275 s. **No pairwise difference is significant**
  (permutation test on medians, 200k resamples: p=0.52, 0.31, and 0.10
  for 8-vs-15). No drift across rep blocks. Note the ordering is
  non-monotonic and, if anything, puts K=15 WORST — the opposite of the
  hypothesis — but p=0.10 is not evidence of that either.
  *Power statement, so this is not over-read:* n=12 per cell against
  this variance failed to resolve even a 2x median difference. What is
  conclusively excluded is a laptop-scale effect (there it was 100-300x
  and turned non-terminating runs into fast ones). A modest effect is
  NOT excluded.

Take-away: **do not carry this flag into cluster run scripts as a
performance fix** — it is a workaround for transports that serialize
badly on a shared device, and IB is not one of them. It remains
mandatory-feeling on the Mac only because the Mac has no shared-memory
path for local cross-process traffic (see the macOS hazards section).
The general lesson underneath is the one worth keeping: a runtime default
of "one of X shared by all PEs" is a contention point to go look for
whenever a transport behaves badly under multi-PE processes.

## QD settle is fast; the slowness is a throughput cliff (2026-08-01)

`qdbench` (charm/tests/charm++/qd — 10 phases, each a ring over all PEs
followed by `CkStartQD`, printing per-phase ring time and settle time) is
the microbenchmark `reconverse-qd-latency.md` asked for. Run on exclusive
Anvil wholenodes at ppn 15, 24 runs across 120/240/480 PEs:

- **20 of 26 runs are clean**, and in those, QD settle is **0.16-0.54 ms
  at every scale including 480 PEs**. Ring time scales as expected with
  PE count (28 / 60 / 120 ms per phase at 120 / 240 / 480). Quiescence
  detection is NOT inherently slow at scale on reconverse.
- **6 of 26 runs fall off a cliff mid-run** (onset phase 3-8 of 10). Ring
  time degrades 20-80x (120 ms -> 2.7-10.3 s per phase) and settle jumps
  to 77-101 ms, and the two degrade TOGETHER, from the same phase onward.
  Once it happens the run does not recover.
- Cliff rate rises steeply with node count: **0 of 14 at 1 node**, 1 of 6
  at 2 nodes, **5 of 6 at 4 nodes**. It needs real inter-node traffic.
- `+lci_ndevices` does not prevent it (cliffed: 2 of 10 at the default,
  4 of 10 at K=15; at 4 nodes, 2 of 3 vs 3 of 3). If anything K=15 looks
  worse, but n=3 per cell cannot support that.

### Root characterization (2026-08-02, jobs 19610112 / 19610179 / 19620654)

Read this before the three consequences below; it supersedes the framing
in them. "Throughput cliff" was the WRONG NAME. The ring is a serialized
token — exactly one message in flight — so `ring_ms` is per-hop LATENCY x
hop count (hops = laps x nPEs). Degraded cost is **~208 us/hop at 480 PEs
and ~250 us/hop at 240 PEs against ~2.4 us clean**: scale-INDEPENDENT, so
a fixed per-message adder, never congestion.

Four facts, each from a controlled sweep on exclusive nodes:

- **The trigger is elapsed TIME, ~0.6-1.1 s.** Onset is ~1 s in every
  cliffed run regardless of payload: 984-1147 ms at 0 B, 942-1195 ms at
  1 KB, 859-1026 ms at 8 KB. A 64x change in bytes and a 100x change in
  message rate barely move it. Bigger payloads only change WHICH PHASE it
  lands in, because phases get longer.
- **It is not traffic at all.** `-d <ms>` busy-waits PE 0 before any
  messaging while the other PEs spin in the scheduler. Phase-0 ring time:
  132/132/134 ms at `-d 0`; **1262/3276/3315 ms at `-d 2000`;
  9899/9060/7760 ms at `-d 5000`**. After a 5 s wait the very first ring
  message is already ~70x degraded. Severity DEEPENS with the wait.
- **It is the transport, not the machine.** A fixed local compute loop
  timed every phase reads **11.142-11.173 ms across every phase of every
  run** (<0.2% spread) while ring goes 142 -> 12941 ms in the same run.
  CPU speed is constant, so power-budget/turbo decay under 480 spinning
  PEs — the obvious alternative at a ~1 s timescale — is excluded.
- **Concurrency does not protect.** 1, 4, 16 and 64 tokens in flight all
  cliff at the same ~0.8 s onset.
- **QD settle leads the ring by a phase.** In job 19620654 settle broke at
  phase 6 (39.5 ms) while ring was still clean at 128 ms; ring broke at
  phase 7. Sparse idle-path messages degrade first — which is why QD, not
  bulk traffic, is where applications feel this.

Not found by inspection: reconverse's scheduler idle path has NO sleep or
backoff (it spins, raising `CcdPROCESSOR_STILL_IDLE`/`LONG_IDLE`,
scheduler.cpp:111-122), and there is no backoff/usleep/nanosleep in LCI's
sources. The behaviour looks exactly like an adaptive polling backoff but
none is visibly implemented in those two layers — so it is below them
(libfabric/IBV provider) or subtler. `LCI_USE_REG_CACHE` is already ON in
this build, so uncached per-message registration is also excluded.

**Localized to the transport, below the progress API (2026-08-02, job
19621991).** Two follow-ups closed this out:

- **Charm++ is exonerated.** A ~130-line PURE CONVERSE reproducer
  (`reconverse/tests/ringbench`, modelled on tests/ring but ringing over
  CmiMyPe() across processes, many laps in timed phases, no per-hop
  printf) shows the identical cliff: 1.9-4.7 us/hop through phase 7,
  then 39.5 and 124.9 us, onset at 948 ms; second rep 75.7/104.9 us at
  1061 ms. With `-d 5000` phase 0 opens already at 259 us/hop and never
  recovers. Only converse.h is used — CmiSyncSendAndFree, one registered
  handler, CmiWallTimer. No chares, no QD, no charm scheduler.
- **It is not the progress path.** Instrumenting
  `CommBackendLCI2::progress()` (duration AND gap-since-last-call, per
  PE, rdtsc, 5.77 BILLION samples over 472 PEs) during a run reaching
  120 us/hop: 80.6% of progress calls return within 26 ns, 99.93% within
  837 ns, and only 1202 samples (0.000021%) exceed 50 us. Gaps between
  calls: 86% under 419 ns, only 1698 (0.000037%) over 50 us. `post_am`
  reported **0 retries in 32,465 sends**.

So while one 0-byte message is in flight for ~120 us, the receiving PE
makes ~300 `lci::progress()` calls that each return "nothing" in ~26 ns.
The PE is polling continuously; LCI's progress is not blocking; the send
never retried. The delay lives between post and delivery, BELOW the
progress API — not in reconverse, not in Charm++, and not reachable by
instrumentation added from outside LCI. Handed to the LCI developer.

**It is a TAIL, and the whenIdle hook is innocent (2026-08-02, job
19623655).** A pure-Converse probe times, in the SAME run and same
degraded state, a p2p ring and a broadcast where all 480 PEs reply --
replying either directly from the handler or from a
`CcdCallOnCondition(CcdPROCESSOR_STILL_IDLE)` callback (how charm QD
gates its hops):

| quantity | clean | degraded |
|---|---|---|
| p2p hop (mean) | 2.1 us | 200 us |
| collective, FIRST of 480 replies | 743-834 us | **742-816 us (unchanged)** |
| collective, LAST of 480 replies | 0.95-1.08 ms | **14.4-22.1 ms** |

- **The fastest responder never changes.** Only the slowest moves; the
  first-to-last spread goes 1.3x -> ~25x. This is not a uniform slowdown.
- **One parameter fits everything.** Stall S = 18.7 ms (from collective
  max) with p = 1.06% of messages affected predicts a mean p2p hop of
  200.3 us — observed 200.3 — and P(>=1 of 480 stalls) = 99.4%, so every
  collective pays it. All 30 degraded collectives measured 14.4-22.1 ms,
  none fast. **~1 message in 100 is delayed ~19 ms; the rest are normal.**
- **This reproduces the FoF 25 ms QD rounds with no Charm++ present**, and
  explains why QD is where applications meet it: QD is a chain of
  collective rounds, so it pays the tail EVERY round while p2p traffic
  only sees a worse mean.
- **whenIdle exonerated by measurement, not inspection.** Degraded means:
  direct 18.67 ms vs idle-gated 17.40 ms (ratio 0.93 — the gated path is
  marginally FASTER, within noise). Consistent with the code:
  `CcdRaiseCondition` dispatches synchronously (conv-conds.cpp:283),
  reconverse raises STILL_IDLE every idle iteration (scheduler.cpp:120,
  171), and the periodic ladder is 1/10/100 ms + 1/5/10/60 s — no 25 ms
  constant anywhere.

Reading note: the collective's FIRST-reply time (~780 us even when clean)
is floor-limited by PE 0 issuing ~480 broadcast sends with SPANTREE=OFF,
not by network latency. It is a control showing local send-issue is
unaffected, not a latency measurement.

**Two traps this cost, both worth internalizing:**
1. The first concurrency sweep held total HOPS constant, so wall time
   varied 40x across it (c=64 ran 31 ms, c=1 ran 88 s). Every high-`-c`
   run finished BEFORE the ~1 s trigger and looked immune. When the
   trigger is temporal, any sweep must hold WALL TIME constant, not work.
   The error survived one correction attempt and had to be caught twice.
2. Reporting a mean across the transition manufactures a fake scaling
   curve — see consequence 2 below.

Three consequences:

1. The 87.8 ms QD settle in `reconverse-qd-latency.md` sits inside the
   post-cliff range (77-101 ms); its ~129 ms instance is just above, and
   that note already flags it as possibly two chained QDs. That
   investigation's open questions are all QD-internal — confirmation
   rounds, timer-paced polling — and this says to look upstream instead,
   at whatever makes inter-node messaging collapse. QD settle there is a
   symptom being measured, not the mechanism.
2. **Never average a metric across a phase transition.** Mean settle over
   10 phases gave 17.4 and 19.1 ms for two 4-node runs and 0.367 ms for a
   third — which reads as a scaling curve and is not one. The runs are
   bimodal; the honest summary is the cliff RATE plus the two modes
   separately. Per-phase output is what made this visible: keep
   per-iteration numbers in any benchmark, never only a summary stat.
3. **The stall is present in the real app in the MAJORITY of runs, and
   this is the number that matters for FoF.** Across 36 interleaved
   4-node/480-PE FoF3 runs on the 80M set (job 19608652), `t_uf2` — the
   bracket containing both QD calls — has a floor of ~0.046 s (14 runs)
   and a median of 0.19 s, ranging to 0.717 s. Real union-find work
   there is ~15 ms. So **a typical production FoF run is carrying
   ~150 ms, and not rarely 300-670 ms, of stall in this one region**,
   and only ~39% of runs escape it. That is the `uf2` variance
   `reconverse-qd-latency.md` reports as 0.05-0.5 s; it is not app-level
   noise, and it is not fixed by `+lci_ndevices`. Unlike qdbench's
   cliff, the distribution here is closer to a continuum than two clean
   modes — consistent with "0, 1, or 2 stalls landed in this bracket"
   rather than a single regime switch.
   **Measurement trap worth internalizing:** the summary metric already
   in the driver scripts was `phaseA` (the phase-1 dual-tree walk), which
   is rock-steady at 0.265-0.288 s and shows none of this. Inheriting a
   neighbouring script's grep pattern is not the same as choosing a
   probe; check that the timer bracket actually spans the region under
   investigation (here: FoFPhase3.h:693-696) before running the sweep.
