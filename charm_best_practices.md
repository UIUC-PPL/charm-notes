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
- If you need to pass CMake flags to dependent libraries like Reconverse
  and LCI, you must use the `--with-cmake-args` option in the build script;
  otherwise the arg parser in buildcmake will swallow the argument and turn
  it into a compiler flag.
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
badly on a shared device, and IB is not one of them. (Frontier practice,
via Kale 2026-08-11: Ritvik runs +lci_ndevices at about half the worker
threads per process, capped at 8 — min(8, ppn/2), so 8 at ppn 15 — on
Slingshot. Not measured against a control there; the Anvil null result
is InfiniBand-specific, so the two do not contradict.) It remains
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

**Narrowed to multi-peer receive behaviour; whenIdle innocent (2026-08-02,
jobs 19623655 / 19623734 / 19623759 / 19623769).** Pure-Converse probes,
degraded regime, one message in flight unless stated:

- **A single peer is immune at any rate or idle interval.** PE 0 ping-pong
  to one remote PE, gaps of 0 / 100 us / 1 ms / 20 ms: mean 7.8-10.5 us,
  **zero** samples over 1 ms in 5,000 each (and 0 in 20,000 at gap 0).
- **Multiple peers are not, with no burst at all.** Round-robin over N
  remote PEs, still one message outstanding: N=1 -> 0 stalls; **N=8 ->
  mean 19.3 us, 4 of 10,000 over 10 ms (max 13.1 ms); N=32 -> mean
  31.8 us, 15 over 1 ms**. Each connection idles only ~62 us at N=8 —
  far less than the 20 ms that was clean — so it is not coldness either.
- **Simultaneity amplifies but is not required.** Broadcast with R
  repliers: affected fraction 0.2 / 2.7 / 18.7 / 70.6 / 91.2 / 99.8% at
  R = 1 / 8 / 32 / 96 / 240 / 480. The per-sample MINIMUM never moves
  (0.75-1.00 ms at every R) — even 480 simultaneous replies often
  complete at full speed, so it is stochastic, not a capacity limit.
- **whenIdle exonerated by measurement**: direct 18.67 ms vs
  STILL_IDLE-gated 17.40 ms (ratio 0.93). Matches the code —
  `CcdRaiseCondition` dispatches synchronously (conv-conds.cpp:283),
  STILL_IDLE is raised every idle iteration (scheduler.cpp:120,171), and
  the periodic ladder has no 25 ms rung.

**Reproduced in PURE LCI — reconverse and Charm++ both out (2026-08-02,
job 19624352).** `lci_multipeer.cpp` links only LCI (nm: zero Cmi/converse
symbols): 32 ranks x 15 threads, rank 0 thread 0 pings round-robin over K
distinct remote ranks with ONE message outstanding, all other threads
spinning on `lci::progress()`, after a 5 s no-traffic warm-up.
10,000 round trips per point, fraction over 10 ms:

| peers K | 1 device/rank | 15 devices/rank |
|---|---|---|
| 1 | **0.000%** | **0.000%** |
| 2 | **0.000%** | — |
| 8 | 0.070% (max 21.9 ms) | 0.210% (max 23.8 ms) |
| 31 | 0.620% (max 25.6 ms) | 0.430% (max 19.7 ms) |

One peer immune, eight not, in BOTH device configurations — so reconverse's
one-shared-device-per-process default is not the cause, and per-thread
devices are not a workaround. Stall rate grows faster than linearly in peer
count (3.9x peers -> ~9x rate). Caveat: the 15-device MEANS inflate because
each thread polls only its own device, so replies wait for the owning
thread; only the >10 ms column is comparable across those columns.

**Direction, recency and latch settled (2026-08-03, job 19630031).** Pure
LCI, 10,000 samples per arm, measured round trip always to ONE partner:

| arm | stalls >1 ms |
|---|---|
| round-robin K=1 (control) | 0 |
| round-robin K=31 (control) | 52 (33 over 10 ms) |
| fan-IN: 8 / 31 ranks push one-way at rank 0 | **0 / 0** |
| fan-OUT: rank 0 pushes one-way to 8 / 31 | **0 / 0** |
| touch 31 peers once, then 1 partner for 10,000 | **0** |

- **Neither direction alone reproduces it.** Receiving from 31 sources is
  clean; sending to 31 destinations is clean. Only a repeated TWO-WAY
  exchange cycled over many peers stalls. "Receiver receiving from many
  peers" — the phrasing we had been using — is wrong.
- **Not "ever used":** touching 31 peers once leaves no residue.
- **It does not latch.** 52 stalls spread through the run, first at index
  13, rate AFTER the first stall 0.52% (not ~100%), and density decays
  ~35x: 6.00% in iterations 0-100, 2.00% to 500, 0.80% to 2000, 0.17%
  thereafter. Something warms up; the 5 s spin-only warm-up does not
  cover it since no messages flow then.
- **It is a distribution shift, not rare stalls.** Fraction in the 2-8 us
  mode falls 85.2 / 83.8 / 66.5 / 19.7% at K = 1 / 2 / 8 / 31, with mass
  moving into a ~128 us mode plus a small >8 ms tail.

**Resolved (2026-08-04, jobs 19644929 / 19654221):**
- **Ambient traffic suppresses it entirely.** 30,000 samples/cell: at
  K=16 the control gives 75 stalls >10 ms and a 98.3 us mean; keeping the
  PEERS busy gives 0 and 25.6 us; and keeping only UNINVOLVED ranks busy
  while the peers idle exactly as in the control gives **0 and 23.6 us**.
  So it is not the peers' state at all — any background traffic in the
  job prevents it, and restores the mean as well as the tail. That is
  also a practical workaround.
- **It is thread-local.** 15 driver threads each with one dedicated peer:
  0.013% over 10 ms, against 0.010% for the K=1 control and 0.490% for
  K=31. One thread with 15 peers stalls; 15 threads with one peer each do
  not.
- **Correction to an earlier note here:** the 20 ms gap test that seemed
  to contradict a coldness story ran at K=1, which is immune in every
  configuration, so it never bore on multi-peer behaviour. There was no
  contradiction to reconcile.

**WORKAROUND, measured (2026-08-04, job 19661625): one tiny message per
PROCESS to a ring neighbour every ~100 ms.** 30,000 samples/point at
K=16: control 39 stalls >10 ms and 89.1 us mean; with the keep-alive at
200 us / 1 ms / 10 ms / 50 ms / **200 ms** periods, **0 stalls at every
one**, mean back to 24-27 us. At 200 ms that is 160 msg/s across a
32-rank job — free. Recommend 100 ms: onset needs ~1 s of quiet, so that
leaves 10x margin; 1 s would sit on the threshold.
Implementation notes: must be a real INTER-process send (same-process
sends bypass LCI entirely, convcore.cpp:601); one per process, not per
PE; the 100 ms rung of reconverse's periodic ladder (conv-conds.cpp:46)
is the natural hook. Do NOT use a broadcast/reduction cycle for this —
with SPANTREE=OFF the broadcast half is a flat O(P) loop costing ~780 us
of root time at 480 PEs, versus one message per rank for a ring.
Full note for whoever implements it: clusterFinding/lci-handover/WORKAROUND-lci-idle-stall.md

Still unexplained: why a single busy pair is immune while 8 peers at a
SHORTER per-pair idle interval are not, and why the stall rate decays
~35x over a run at fixed configuration.

**FABRIC-SCOPED (2026-08-18, Frontier jobs 5302846 / 5303887 / 5303902):
the bug is an InfiniBand-path (libfabric/IBV provider) behaviour and does
not exist on Slingshot/CXI.** Every measurement above was made on Anvil
over Mellanox InfiniBand. The reproducer rebuilt at the application's own
shape (128 ranks x 14 threads x 7 devices) on Frontier: 220,000 round
trips, 0 over 1 ms, at K = 1..64 and silences of 5..60 s, ring on or off
— while the application-level trigger (2.4-2.8 s per-PE silences ending
in K=48-108 two-way fan-ins) fires three times per FoF run there. FoF's
timings are unchanged with the ring off. Keep the ring where it runs (it
is load-bearing on InfiniBand and costs nothing measurable), but do not
credit it for stall-free runs on CXI, and scope any writeup of this bug
to the fabric.

**reconverse `+backend_poll_thread` is not an on/off switch (read
scheduler.cpp:182, convcore.cpp:351, comm_backend_lci2.cpp:225 before
tuning it).** There is no separate progress thread: ranks with
`rank % backend_poll_thread == 0` call progress() inline in the
scheduler loop, and progress() advances ONLY the caller's own device
(device_id = thread_id / ceil(nthreads/ndevices)). Values below 1 clamp
UP to 1 (= every rank polls, MORE progress, not none). The invariant is
`backend_poll_thread x lci_ndevices = ppn`: at ppn 14 / ndevices 7 the
recommended 2 is the unique value covering every device exactly once;
14 (one poller per process) leaves devices 1-6 unprogressed and
deadlocks at startup, before any input is read. Progress starvation
cannot be tested with this flag — the only reachable states are "every
device covered once" and "twice".

**FI_THREAD_DOMAIN forks: one user thread per libfabric domain, or else
(2026-08-18, Frontier jobs 5305170/5305230).** An LCI fork that downgrades
`domain_attr->threading` from FI_THREAD_SAFE to FI_THREAD_DOMAIN (for cxi)
makes reconverse's thread-to-device mapping unsafe whenever
ceil(ppn/ndevices) > 1: two threads sharing a domain corrupt the CXI
provider's internal queues, presenting as segfault, "double free", OR a
silent whole-walltime hang with no error. The reproducer fails 8/8 with
two threads per domain and is clean with one; production FI_THREAD_SAFE
tolerates both. So the device-mapping rule has TWO clauses: every device
needs a poller (backend_poll_thread stride), AND — under FI_THREAD_DOMAIN
— no device may have more than one user thread, which forces
ndevices = ppn (+backend_poll_thread 1). Related landmine in the same
fork: a dangling `} else` makes setting LCI_OFI_THREADING_HINT to ANY
value also drop FI_PROGRESS_MANUAL — the debugging knob itself causes
provider-default progress.

**Linker trap when A/B-ing two builds of the same shared library:** the
first link of the reproducer against the fork silently resolved to the
PRODUCTION liblci at run time — modern linkers emit RUNPATH, which LOSES
to LD_LIBRARY_PATH, and the other build's lib dir was on it. That would
have "cleared" the fork with the production library's behaviour. Link
with `-Wl,--disable-new-dtags` (forces RPATH, which wins) and gate the
job script on `ldd` showing the intended .so before trusting any A/B.

**GPU helper threads inherit the pinned PE's affinity mask — a class of
bug, not a one-off (Frontier, 2026-08-20, -22% at 2B/896 PEs).** ROCm
(and in general any lazily-initialized runtime) creates helper threads
from whichever thread first calls it; pthread_create hands the child
the CREATOR'S affinity mask. Under +pemap that creator is a PE pinned
to one core, so the helper is born welded to that core and timeslices
against a PE that spins when idle — 16 ms slices, one victim PE with
seconds of runqueue wait, every collective paying one slice to reach
it. Remedy: an RAII scope around the first real GPU call that widens
the calling thread's affinity to CPUs no PE is pinned to (SMT siblings
of the pemap, or explicitly reserved cores), then restores it —
helpers inherit the wide mask, PEs keep their cores
(paratreet2 fof/gpu/FoFDevice.cpp, FOF_HELPER_CPUS). Diagnosis kit
that pinned it: an LD_PRELOAD interposer on pthread_create logging
creator affinity + backtrace, and per-thread runqueue-wait from
/proc/<tid>/schedstat.

**Reading Projections traces programmatically — two traps that
published false results before being written down:** (1) BEGIN_IDLE/
END_IDLE often carry the SAME microsecond (the scheduler re-enters
idle around a poll); records must be read in FILE ORDER — sorting by
(time, kind) inverts the pairs and fabricates phantom overhead. PACK/
UNPACK records NEST inside entry methods; treating their ends as
returns to overhead reclassifies ordinary execution. (2) Each PE's
interval from first record to first BEGIN_IDLE is trace startup, not a
stall — exactly one per PE, and it can be present in one arm and
absent in another (a cold input read pushes it out of the measured
band), silently changing the A/B population.

**Methodology, learned at a cost of thirteen investigation rounds: low
utilisation is imbalance or a critical path BEFORE it is
communication.** Sum busy time per PE first (this campaign's split:
88% straggler tail, 12% dependence chain, 0% communication). A small
reproducer inherits NONE of the embedding runtime's configuration —
diff the runtime attributes each actually sets before believing a
contradiction (an ofi_lock_mode the app set and the reproducer did not
explained 8/8-dead vs 23/23-clean on the same library). And a trace
window is only silent at the layer you are reading: with no entry
methods anywhere, BEGIN/END_IDLE and Converse-level protocols (QD,
CcdRaiseCondition waves) are still in the record.

**Two build defects that inflated every measurement for a week
(Frontier, 2026-08-21, relay49 of the FoF campaign):** (1) reconverse
charm built without `--with-production` gets CMAKE_BUILD_TYPE=Debug —
NOT merely "error checking on" but NO OPTIMIZATION AT ALL in the
runtime: 15.6% at 2B/1792 PEs (+25% whole-run on a laptop netlrts
A/B). (2) An application binary LINKED with `-tracemode projections`
pays for the hooks in the message path even with tracing never enabled
at runtime: 7.7% on a fine-grained workload. Rules: production runtime
for any timing; NEVER link tracing into a timing binary — keep a
separate traced binary. Relative A/Bs survive such defects (same build
both sides); absolutes do not.

**Gate on the artefact, not the environment.** An ldd/LD_LIBRARY_PATH
gate cannot detect running the WRONG BINARY — the SONAME resolves
through the same path and always agrees with the script (a wrong-binary
run passed every environment gate; caught only by checking the
binary's own identity, e.g. `nm | grep -c TraceProjections` = 0 for a
production arm). Slurm companion trap: an srun step that changes
--ntasks INHERITS the batch --cpus-per-task, silently shrinking the
step cpuset (CmiSetCPUAffinity failures at pemap entries outside it) —
revisit --cpus-per-task whenever --ntasks changes.

**SMT on Frontier EPYC for tree-walk workloads: the second hardware
thread returns ~12% throughput** (same 896 PEs on half the physical
cores = 1.787x slower, 2026-08-21 four-placement separation), so
doubling PEs via SMT is a net LOSS when parallel overhead exceeds that
(+17.5% measured); one PE per physical core is the right default shape
for both CPU and GPU arms of this workload family. And a mystery for
the record: a byte-identical binary + runtime + config reproduced a
5.15 s result as 7.69 s two days later (phaseA 2.5x) — suspects are
the loaded libfabric (built vs 1.20.1, runs load 2.3.1) or node
placement; do not trust old absolute baselines across environment
drift without a same-day rerun of the original artefact.

**`sbatch --export` splits on COMMAS — never pass a comma-containing
value (pemap, cpu lists) through it** (Frontier 2026-08-21, cost five
jobs): `--export=ALL,PEMAP=1-7,9-15,...` delivers `PEMAP=1-7` and
silently discards the rest; 56 PEs then pinned to 7 cores ran 8-9x
slow with no error anywhere except one `cpuaffinity PE-core map` line.
Derive such values inside the job script and ASSERT the launch shape
(count the pemap blocks, echo the map actually used) — severe
oversubscription is invisible in every application-level number.

**Poll-stride completeness is shape-dependent and the failure is a
HANG:** at one PE per device (ppn 7 / ndevices 7), backend_poll_thread
2 permanently silences the odd devices (3/3 hangs); the same stride is
harmless at two PEs per device. The rule stays "every device needs a
poller", checked against the ACTUAL shape; stride 1 costs nothing
measurable there.

**Four of our own hypotheses died here, each to a purpose-built test:**
uniform per-message tail (0/20,000 single-peer); receive-side
absorption-rate collapse (predicts 4.4 ms at R=96 vs 12.23 observed, and
cannot yield a 13 ms sample at R=8); cold connection (20 ms idle, 0/5,000);
simultaneous burst (8 SEQUENTIAL peers still stall). What survives is
"receiver talking to several distinct peers". Method lesson: each model
fitted the data that suggested it and died to the next experiment
designed against it — do not ship a mechanism until it survives a test
built to break it. Phenomenology held throughout; mechanism did not.

This also explains why FoF meets it as a QD problem: QD is a chain of
collective rounds over 32 peer processes, so it pays the stall nearly
every round, while a 2-process benchmark never sees it.

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

## Splitting templated chares into their own module (extern module), and two traps (2026-08-03, paratreet2 fof extraction)

Extracting application chares (templated over a Data type) from a core
module into their own module (`module app { extern module core; ... }`)
works cleanly — the app mainmodule externs both modules and keeps its
`extern entry` instantiation declarations unchanged — but three mechanics
matter:

1. **Ship the module's template definitions IN its own headers.** charmxi
   puts `CBase_`/closure/proxy template DEFINITIONS in the def.h
   `CK_TEMPLATES_ONLY` section, with only forward declarations in decl.h.
   Any header whose inline (non-template) code touches a concrete-Data
   chare — e.g. a visitor calling `proxy.ckLocalBranch()->member` —
   requires those definitions at parse time. The reliable idiom: the
   module's main header includes its own `<mod>-templates.h`
   (`#define CK_TEMPLATES_ONLY / #include "<mod>.def.h" / #undef`)
   immediately after `<mod>.decl.h`, exactly as paratreet2's
   Subtree.h/CacheManager.h include templates.h. Diagnosing "implicit
   instantiation of undefined template CBase_X<T>" by theory is slow;
   preprocess a WORKING TU (`clang -E | grep -n 'struct CBase_X :'` plus
   the preceding `# line "file"` marker) to see where the definition
   actually comes from.
2. **PUPable_decl_template breaks under a dependent base.** A templated
   PUPable whose PUP::able ancestry runs through a dependent base
   (`class F<T> : Base<T>` with `Base<T> : PUP::able`) fails to compile:
   the macro's `register_PUP_ID` body calls `register_constructor`
   unqualified, and unqualified lookup does not search dependent bases.
   Hand-expand the macro and qualify `PUP::able::register_constructor`;
   the `my_PUP_ID` static can live in the header as a template definition
   (`template <typename T> PUP::able::PUP_ID F<T>::my_PUP_ID = 0;`).
3. **Registration of a non-main module's templated chares is the app's
   job.** Nothing auto-registers `CkIndex_X<Data>` for extern-module
   templated chares; provide a `registerChares<Data>()` in the module
   (CkIndex __register calls + PUPable_reg of the module's PUPables,
   unique names per instantiation, e.g. via typeid) and have the app's
   registration hook call it. A fully-templated module still needs one
   TU compiling the plain (non-CK_TEMPLATES_ONLY) def.h for
   `_register<mod>()`.

Payoff shape (why bother): the core module carries no app chares, and any
`extern module dep` of the app (e.g. unionFindLib) stops being a link
requirement of every unrelated application.

## A send on a null (default-constructed) group proxy stalls quiescence silently (2026-08-04)

Symptom family: all schedulers idle at empty queues, yet `CkWaitQD` never
returns — looks like a lost message, samples show pure idle polling. One
cause: an entry send through a group/array proxy that was never assigned
(default-constructed, gid 0). It does not crash; the send is counted by
the QD create-counters but is never delivered, so quiescence is
permanently one message short. Found when paratreet2's single-distribution
mode removed the chare array that had been the only place a cross-pointer
proxy (CacheManager -> Resumer) was initialized: installs then "notified"
a null proxy and every multi-process walk hung. Diagnosis pattern that
worked: bracket the pipeline with prints to isolate the stalled barrier,
confirm schedulers idle (sample/gdb), then hunt for sends through proxies
whose initialization lived in a code path that no longer runs. Corollary
for framework surgery: when deleting or making optional a chare type,
grep for every side effect of its constructors/init functions — the
cross-wiring they performed for OTHER actors is the part that breaks
non-locally.

## Reconverse: Ccd periodic ticks SLOW under load; they never stop — do not trust sparse print points (2026-08-04, corrected same day)

CORRECTION of this note's earlier version, which claimed a [threaded]
entry "parks" its rank's scheduler and kills the CcdPERIODIC ladder.
That claim was WRONG, refuted two ways on the same day:

1. Minimal probe (bare charm program: initproc arms a counter on
   CcdPERIODIC_100ms on every rank; the mainchare's threaded entry loops
   on CkWaitQD for 10 s): every rank, INCLUDING the one hosting the
   mainchare and the threaded entry, ticks at the full ~10/s. Threaded
   entries suspend properly; the host pthread returns to CsdScheduler,
   whose every iteration — busy or idle — reaches CcdCallBacks().
2. Full application (paratreet2 FoF, 16M, 2 processes x 2 ranks) with a
   per-rank tick counter printing every 50 ticks, plus macOS `sample` of
   the live pthreads: no rank's ladder ever stops. The busiest rank
   (rank 0: mainchare, driver, reduction roots) stretches to ~250 ms per
   tick (~4/s) during phases dominated by long entry-method executions,
   then recovers to ~10/s. Stack samples show why iterations stretch:
   the rank stays inside CsdScheduler handling messages, and each send
   inside a long handler contends on the network library's endpoint
   lock (libfabric xnet on macOS) against other ranks' progress polls.

What produced the false "goes silent" reading, and the rules it earns:
1. Sparse print points masquerade as silence. The original instrument
   printed at ticks 1, 2, 3, 10, 30 and then a rate line every 100
   ticks; on runs too short (or ranks too slowed) to reach the next
   print point, a live ladder is indistinguishable from a dead one.
   Instrument periodic events with prints at a FIXED tick stride from
   the start, and always report a final count at shutdown.
2. Block-buffered multi-process stdout compounds it: absence of lines
   from one process proves nothing until the run ends and buffers
   flush. (Same afternoon, `grep | head` SIGPIPE truncation caused a
   different false reading — sort or capture whole logs first.)
3. Ground truth for "where is that pthread" is a sampling profiler, not
   inference from prints: on macOS, `sample <pid>` during the run. Ten
   seconds of it identified the real mechanism (slowed, not stopped)
   that two days of print-based instruments mis-read.
4. Placement rule that survives the correction: a periodic sender meant
   to hold a steady rate is best armed on the LEAST loaded rank (last
   rank of the process in the mainchare-plus-driver pattern) — for rate
   fidelity under load, not correctness. Any rank is correct.

## Work-stealing protocols: one authority per decision, and pace every retry (2026-08-07)

Two hangs while bringing up a cross-process work-stealing scheme in a
Charm++ application, both general enough to record:

1. ONE AUTHORITY PER DECISION. Both sides of the protocol carried a
   copy of the admission rule ("grant only if enough work remains"):
   the helper filtered candidate donors before asking, and the donor
   applied the same test on arrival. The duplicate copy stranded work,
   because only the donor knows whether its own threads are still
   draining the remainder — the helper's filter excluded exactly the
   case where help was the ONLY way the work would ever run. Symptom: a
   phase that never completed, every processor idle in the scheduler.
   Rule: the party that owns the state owns the decision; the other
   side may rank, never veto.
2. PACE EVERY RETRY. A denial that triggers an immediate retry creates
   a two-party message storm — the requester re-asks as fast as the
   network delivers refusals. The machine runs at full load with no
   forward progress, and the work being waited on is starved by the
   polling itself. Every retry path needs a timer (CcdCallFnAfter with
   1-2 ms was sufficient here).

Diagnosis note: both presented identically (all processors idle in
CsdScheduler, phase never completing). What separated them was an
env-gated trace of the protocol's own state transitions — remaining
counts, grant/deny reasons, and the completion-gate values — printed
from every participant. Stack sampling alone showed only "everyone is
waiting", which is true of every distributed hang.

## An entry method reachable from several senders must make its terminal step idempotent (2026-08-08)

A worker entry method that drains a queue and, when the queue is empty,
performs a one-time completion step — deposit into a reduction, increment
a "this processor is done" counter, contribute to a barrier — is only
safe if that completion step runs at most once per processor. The trap is
that such a method usually acquires more senders as the design grows, and
nothing in the code marks the moment it stops having exactly one.

The case that produced this note had three senders reaching the same
worker: the method's own hand-off back to the scheduler at the end of a
time slice, a `CcdCallFnAfter` poll it schedules while waiting for work
from elsewhere, and a wake sent by an unrelated processor when work
arrived for the whole process. Two of those could find the queue empty
and both run the completion step. The per-process "all my processors have
finished" counter then reached its target while one processor still held
unsubmitted results, the process moved on to its next stage, and those
results were discarded. The symptom was a small, varying number of
missing merges — one to eleven out of eight million components, never the
same twice, and only when the feature that added the extra senders was
switched on.

What makes it expensive to find is that the symptom points away from the
cause. Everything about the data path can be verified correct — the
serialization, the reconstruction, the computation on the reconstructed
data, the accounting for what was delivered — and all of it will pass,
because nothing in the data path is wrong. The defect is that a correct
result was computed and then thrown away by a stage that had already
decided it was finished.

Rules that follow:

- Guard the completion step with a per-processor flag, not with the
  emptiness of the queue. Emptiness is a property of the queue at one
  instant; having-finished is a property of the processor.
- Guard entry to the method with the same flag. A processor that has
  deposited must not run the loop again, or it will observe state that
  belongs to the next stage.
- Reset the flag where the stage's other per-processor state is reset,
  so a second iteration or a second run in the same job behaves like the
  first.
- When a counter of the form "number of processors that have finished" is
  compared for equality against a processor count, treat every path that
  increments it as a place to prove single execution. Equality comparison
  hides double counting: the count passes through the target and the test
  can also fail to fire at all, which turns a lost result into a hang.

For diagnosis, a cheap check pays for itself: at the moment the stage
declares itself complete, verify that the structures it was draining are
actually empty and print if they are not. That distinguishes "work was
left undone" from "work was done and the result was dropped", which are
indistinguishable from the output alone and have completely different
causes.

## Summary tracing: what `+sumDetail` records, and building for it (2026-08-11)

Working on `.sumd` output for Projections turned up three things worth
keeping.

**Tracing modules are a Debug-only default.** `CMakeLists.txt` sets
`TRACING=1` only when `CMAKE_BUILD_TYPE` is `Debug`, so
`./build charm++ <arch> --with-production` produces **no**
`libtrace-summary.a`. The symptom is indirect: `charmc -tracemode summary`
says "No such tracemode summary", and if you link without it the program
runs fine while `+sumDetail` is *silently ignored* — you get no trace files
and only a "command line argument beginning with a '+' but was not parsed
by the RTS" warning. Fix in an existing build tree:
`cmake . -DTRACING=1 && make -j8`.

**What a `.sumd` actually holds**, per PE, RLE'd EP-major/interval-minor:
`ExeTimePerEPperInterval` (µs) and `EPCallTimePerInterval` — which despite
the name is `getNumExecutions()`, a *count* of entry-method runs, i.e.
messages processed. There are no message sizes (charmplusplus/charm#3937
adds `MsgBytesPerEPperInterval`), no senders, and no record of messages
sent, so no communication matrix can come from a summary trace.
`updateSummaryDetail()` is also called from `endPack`/`endUnpack`, so the
runtime's `dummy_pack_ep`/`dummy_unpack_ep` appear as counted "messages":
on a 1920-PE paratreet2 run they were **65% of all counts but 0.04% of the
recorded time**, which is why no time-based view had ever revealed them.
Anything reporting counts should separate them out.

**Message sizes are alignment-rounded.** `envelope::getTotalsize()` — the
quantity both `.log` and (now) `.sumd` record — includes the envelope and
padding to an alignment boundary. A test that infers per-message overhead
by differencing two payload sizes only works if both payloads round the
same way: with 1000 vs 2000 bytes the difference came out 800 short of
`count * payload`; with 1024 vs 2048 it was exact. Use multiples of 16.

## Trace the protocol's lifetime chain EARLY, small, or on a node subset (2026-08-13, Kale)

Lesson from the S3 stealing campaign: two structural defects — a
serial per-node-malloc rebuild inside one entry method (59-423 ms
while 13 PEs waited to help), and grant-composition problems — sat in
plain sight for days of 16-node 2B jobs, then were obvious within
minutes of looking at ONE Projections overview of a sum-detail trace.
Both would have been visible from a single complete lifetime chain of
one stolen taskset: order -> donor collect/serialize -> ship ->
receiver rebuild -> parallel drain -> return.

Practice, for any new message-driven protocol:
- LOOK AT THE TIMELINE BEFORE SCALING THE CAMPAIGN. Run Projections on
  a small-scale run (laptop or 2-4 nodes) as soon as the protocol
  first works. Correctness gates prove exactness; only a timeline
  shows serialization, entry-method granularity, and who waits on
  whom. "It gates green" and "its entry methods are well-shaped" are
  different facts.
- If the behavior only manifests at scale, trace a SUBSET OF NODES at
  full scale rather than not tracing at all: the interesting unit is
  one complete protocol chain, and any node pair that exchanges one
  grant contains it. (With summary tracing the cost of tracing
  everything is mostly memory/RSS — the 2B traced binary OOMed where
  untraced fit — so subsetting is also what makes full-scale tracing
  affordable.)
- Name the target explicitly before tracing: "observe one complete
  chain of the lifetime of a <unit of the protocol>". Reading a
  timeline without that question invites staring at the bulk phases
  and missing the protocol's own entries — which are small, rare, and
  exactly where the structure hides.

Mechanism for the subset: `+traceprocessors 0,10,20-30` (runtime flag,
src/ck-perf/trace-common.C) restricts which PEs record — so one traced
binary can trace just the straggler's block plus one helper block at
full scale. Whether it also avoids the traced-run RSS penalty (the 2B
OOM above) is untested — check buffer allocation before relying on it.

## Marshalled-parameter serialization: a virtual dtor anywhere in the payload silently costs 10x+ (2026-08-14, S3 campaign)

Charm pups a marshalled parameter's containers per-element unless the
element is trivially copyable. ONE `virtual ~T()` anywhere in the
embedded object graph — even in a base class two levels down (here:
OrientedBox : Shape with a virtual dtor, inside the app's Data, inside
a wire struct) — silently forces field-by-field dispatch: ~15 pup
calls per element, measured ~242 ns/element vs ~8 ns bulk, 87 ms of a
40 MB message's 117 ms send path. The fix is a POD mirror struct on
the wire carrying exactly the fields pup shipped, plus
`static_assert(std::is_trivially_copyable<Wire>::value, ...)` so the
build fails if anyone re-imports a vtable. Two lessons:
- The wire never needs polymorphism if every real object is the same
  concrete subclass — mirror the pupped fields, don't embed the type.
- The static_assert is not decoration: the first attempt at this fix
  embedded the Data type by value and shipped raw vptr bytes without
  any error — exact results (receivers copied fields out, never
  calling through the dead vptr), UB underneath. The assert caught it
  at the next build.
Diagnosis signal: PUP::sizer time. A sizer walk that costs milliseconds
is per-element dispatch; a bulk-pupped array sizes in one addition
(measured 17.1 ms -> 0.0 ms on the same shipment).

## Aggregate counters give correct totals with wrong attributions; validations can be vacuous at the wrong scale (2026-08-13/14, S3 campaign)

Two recurring failure modes from one campaign day, worth naming:
- CORRECT TOTALS, WRONG ATTRIBUTION: timer brackets around a send call
  measured 80 ms and was reported as "donor blocked in send" — the 80
  ms was charm's sizer+pack; the send itself was ~1 ms (event records
  showed the send CREATION at 99.2% through the enclosing block, so
  the question was answerable from traces all along). Same pattern
  earlier with correlations across heterogeneous arms (grant size,
  work-moved) whose mechanisms co-vary. Prefer per-event accounting
  from timelines over fitted trends across arms; when using a timer
  bracket, say what ELSE is inside the bracket.
- VACUOUS VALIDATION: "all gates passed" is meaningless if the code
  under test never executed at gate scale. A 10k gate cannot exercise
  stealing transport (pools drain before helpers match); a
  single-node RDMA probe cannot exercise memory registration (the
  intra-node path never registers). State, for every gate: what code
  path did this scale actually run?

## Assorted cluster-measurement traps (2026-08-13/14)

- A `local a=$1 b=$2` line in bash expands ALL arguments before any
  assignment takes effect ($b cannot reference $a); with `set -u` this
  aborts the job. `bash -n` does not catch it. Smoke-test sbatch logic
  against a stubbed srun before submitting.
- Builds are not byte-reproducible: same commit, same flags, different
  md5. md5 inequality proves nothing; compare symbol sets.
- Fabric bandwidth is not monotone in message size: both classic and
  shmem reconverse builds show a 4.1x cliff between 16 and 32 MB on
  Anvil-class IB (peak ~17 GB/s at 16 MB -> ~4.2 flat above).
  Messages above the cliff may be worth splitting; measure per fabric.

## -march changes floating-point RESULTS via FMA contraction; pair it with -ffp-contract=off (2026-08-15)

Measured at 2B particles on Frontier: adding `-march=znver3` to an
otherwise unchanged build changed a FoF component count from 424897832
to 424897833 — one component over — REPRODUCIBLY, 6 arms of 6 across
two jobs. Not a code bug and not a race.

Mechanism: gcc defaults to `-ffp-contract=fast`, which lets it fuse
a*b+c into an FMA. Baseline SSE2 has NO FMA instruction, so a
no-`-march` binary physically cannot contract; `-march=znver3` makes FMA
available and gcc starts using it. FMA keeps more intermediate precision,
which CHANGES the rounding of a distance test — and a pair sitting
exactly on the linking length then falls the other side of the
comparison. Both answers are defensible IEEE results; the predicate is
simply knife-edge-sensitive at that scale.

Practice:
- Any `-march=`/`-mfma`/`-mavx2` experiment on code with an
  exactness gate must carry **`-ffp-contract=off`**. On this code that
  restored 6/6 exactness while keeping 5479 of 5540 vector references —
  only the 69 FMAs are lost, so the SIMD experiment survives intact.
- `-Ofast`/`-ffast-math` is a different and much bigger hammer
  (reassociation, no-errno, finite-math): it gave 3-4x the speedup here
  but 0/6 exactness. If tempted, split it — `-fno-math-errno` alone is
  semantically safe and may carry most of the win.
- Generally: when a bit-exactness gate fails after a BUILD-ONLY change,
  suspect fp-contraction before suspecting the code.

## RETRACTED: "charmc mis-parses `-march=X -Ofast`" — it was the shell (2026-08-15)

Recorded and withdrawn the same day; kept because the wrong version
briefly reached a standing "read this first" document, and because the
real lesson is the more useful one.

The claim was that charmc joined the two tokens, cc1plus reporting
`bad value 'znver3 -Ofast' for '-march=' switch`. The actual cause: the
probe harness ran under **zsh**, which does NOT word-split an unquoted
`$var`. The flag list expanded to a SINGLE argument, and charmc passed
it through faithfully. From bash, with genuinely separate arguments,
`charmc -g -O3 -march=znver3 -Ofast -c x.C -o x.o` succeeds. Flag order
is free and no build was ever affected.

LESSON: when a compiler rejects a flag VALUE that visibly contains a
space or a second flag, suspect the argument packing in your harness
before the compiler. On zsh specifically, `$flags` is one word — use an
array (`${=flags}` or `"${flags[@]}"`), or write build scripts with a
`#!/bin/bash` shebang.

## A nodegroup branch entry method can run on ANY PE of the process (2026-08-15)

`if (CkMyPe() == 0) CkPrintf(...)` inside a nodegroup entry method
prints on NOBODY unless that branch happens to be delivered on PE 0 — a
diagnostic added this way was silent across an entire 128-process run
and was read as "the feature did not take" when it had. A nodegroup has
exactly ONE branch per process, so the correct guard for a once-per-job
print is `CkMyNode() == 0` alone. Note `CkMyNode()==0 && CkMyRank()==0`
is ALSO wrong for the same reason (verified: it printed at ppn 2 and was
silent at ppn 4). For code that may be built either way, test
`this->isNodeGroup()`.

## A periodic Charm-message heartbeat deadlocks CkWaitQD (2026-08-22)

Any self-rearming cycle of CHARM-LEVEL messages (an entry method that
re-sends itself, or a Ccd timer whose callback sends entry-method
messages every tick) keeps quiescence from EVER being reached: QD needs
two consecutive identical global created/processed counts, and the
heartbeat advances them every period. If the heartbeat's stop condition
is set by code that runs AFTER a CkWaitQD, that is a deadlock by
construction — the run hangs at the QD with the machine near idle.
Measured on a periodic union-find compression wave in paratreet2; the
hang reproduced deterministically at 1M/16 processes.

Three ways out, all used or precedented in that codebase:
1. Send the heartbeat as RAW CONVERSE messages (CmiSyncSend etc.) —
   invisible to QD. Right for keep-alive/monitoring traffic.
2. Make ticks MESSAGE-FREE AT FIXPOINT: keep the timer chain at Ccd
   level (CcdCallFnAfter re-arms are QD-invisible) and gate any
   message-sending work on a local dirty flag that only fresh state
   changes set. When the system settles, ticks still fire but send
   nothing, so QD proceeds and the post-QD code can disarm the chain.
3. Replace the CkWaitQD inside the cycle's scope with user-level
   termination detection carried BY the cycle itself (put global
   created/processed counters in a repeating reduction; two consecutive
   equal rounds = done — the same four-counter scheme QD implements).
   Right when the cycle exists anyway for introspection/control.

Corollary: a periodic mechanism scoped to one phase must have its
disarm reachable WITHOUT quiescence, or use (2)/(3). "Disarm after the
QD" is the exact trap.

## `module load` in a pipeline silently does nothing (2026-08-24)

On Cray/OLCF systems `module` is a SHELL FUNCTION, not a binary. Any
construct that runs it in a subshell — a pipe most commonly —
executes the load in a child process, so every `setenv` it performs is
discarded when the child exits. The command still reports success:

    module load papi/7.1.0 2>&1 | tail -1     # loads NOTHING
    module load papi/7.1.0                    # loads it

Found on Frontier when a PAPI build could not see `papi.h` despite an
apparently successful load. The same piped idiom was in four earlier
build scripts of that campaign, so those module loads had also been
doing nothing; the builds worked anyway because cmake was handed
absolute compiler paths and the login environment already carried the
rest — i.e. the failure is silent AND usually harmless, which is why it
survives.

Check with `module list` or by testing the variable the module sets
(note the name may not be what you expect: the OLCF PAPI module sets
`OLCF_PAPI_ROOT`, not `PAPI_DIR`) — never by the exit status or output
of the load itself.

RELATED, same session: charm's own PAPI feature test does not consult
`CMAKE_PREFIX_PATH` or any `find_package` —
`cmake/detect-features-c.cmake:244` uses a bare `check_c_source_compiles`
with empty `CMAKE_C_FLAGS`, so a module-provided PAPI in a spack tree is
invisible to it. Pass `-DCMAKE_C_FLAGS="-I$PAPI_DIR/include"` and the
matching link flags.

## A smoke test can be sabotaged by the test's own source: diff the example before blaming the runtime (2026-08-24)

Catching a charm tree up 59 commits, the standard smoke test
(examples/charm++/hello/1darray) "failed" deterministically on a build
that was in fact healthy: only "Hello 0 created" printed, then silent
exit 0, at every PE count. The build was innocent — an upstream merge
commit (charm 9e48ce995, "merge reconverse changes with lb") had
committed debug hackery INTO the example itself: `CkExit()` inside the
Hello constructor and the init callback commented out. The binary did
exactly what the source said. Meanwhile the full pingpong benchmark
(19 phases) passed on the same build, which is what localized the
"failure" to the one example.

Rules:
- When a smoke test breaks after a pull, `git diff <trusted-sha> --
  <test source>` BEFORE debugging the runtime — upstream branches
  (especially long-lived feature/merge branches) can carry debug
  pollution in examples and tests.
- Prefer a smoke suite with more than one independent program; one
  passing and one "failing" points at the failing test's source, not
  the runtime.
- Silent early exit 0 is the signature of a stray CkExit, not a crash
  (a crash gives a nonzero status or a signal message).

Same session, for the record: the 2026-08-11 "upstream
reconverse-specific-build does not configure on this Mac" drift
resolved itself once reconverse main gained include/persistent.h
(reconverse#192) — the missing conv-mach-smp.h was never the actual
blocker with the --with-fetch-reconverse-dir invocation. Verified by a
from-scratch build of the upstream tip passing full smoke on macOS.

## Anytime migration vs the reduction tree: every no-obligation state needs a wake path (2026-08-24, #3939)

Root-caused a reduction hang that only heavy anytime migration (migrateMe)
triggers, on classic AND reconverse (shared Ck code). The barren-PE
optimization (ReductionStarting/inactiveList) assumes every tree kid
either self-starts a round (has a local contribution coming) or is on the
parent's inactiveList and gets poked. Migration creates a third state:
POPULATED BUT OBLIGATION-FREE — all elements owing the round left before
contributing, all arrivals already contributed elsewhere (adj(redNo)
balances lcount), lcount never touched 0. Nothing starts the round on
that PE; the whole tree waits on a PE that owes nothing. Fix (ckreduction
9d1177d84): on Leaving/Arriving/Died, if !inProgress && lcount>0 &&
nContrib >= lcount+adj(redNo).lcount, eagerly start+finish (ships the
empty result; late migrants ride LateMigrantMsg). adj only goes negative
via migration, so migration-free programs cannot take the new path.

General lesson: in a collective protocol with a liveness optimization
that prunes "inactive" participants, enumerate every state that cannot
self-start — an optimization that whitelists wake-up paths must prove the
list exhaustive under MIGRATION, not just under static populations.

## The debugging kit that cracked it (reusable workflow)

1. **Randomized msgq amplifies migration races enormously**: the hang went
   from sporadic (needs ~500-2000 steps, often passes) to 6/6 seeds.
   Build option --enable-randomized-msgq (cmake RANDOMIZED_MSGQ=ON;
   classic only). The redmine-era reports (#259/#665/#667) did the same.
2. **Record-replay (classic, +record/+replay) works and is worth
   repairing**: needs a tracing-enabled non-production build
   (--enable-tracing --enable-replay); log files are
   <progname>ckreplay_<pe>.log (traceRoot naming). Three repairs were
   needed (branch recordreplay-fixes / commit 3b5ed5e26, issue #3940):
   +record segfaulted on ANY array broadcast (recorder's pack/unpack
   swaps the envelope under CkArrayBroadcaster's retained pointer — now
   packs only when CRC on); flushLog lacked fflush (a killed hung run
   lost its log tail — use +recplay-logsize 129 for per-record flush);
   replay aborted on truncated/empty logs (now treats truncation as the
   end sentinel; an SMP comm thread's log is legitimately empty).
   **+replay still stalls on array broadcasts** (open); a p2p variant of
   the test (-B) replays deterministically to the recorded hang frontier.
   Reconverse has NO record-replay (_replaySystem=0 stub) — porting it is
   on the list.
3. **Protocol-state tracing beats stack samples for distributed hangs**,
   again: a watchdog dumping each element's (step, gotNbr, contributed)
   isolated the lost mechanism (reductions, not broadcasts/p2p) in one
   run; CMK_DEBUG_REDUCTIONS (#define in ckreduction.C; one DEBR in the
   static reduceMessages needs a memberless print) then gave the exact
   losing ledger on the stuck PE. Record the hang, replay it, read the
   trace — no probabilistic instrumentation runs.
4. Test design that made it findable: neighbor exchange + per-step
   value-checked reduction + exactly-once-checked broadcast, migrateMe as
   the last action AFTER contribute (in-flight redNo path), CkEnforce
   everywhere, deterministic lockstep migration schedule (seeded hash, no
   coordination messages). tests/charm++/anytime_bcastred.

## Replay of SMP node-queue messages: the winner-rank race, and silence as a symptom (2026-08-25, #3940)

Second half of the record-replay repair. `+replay` of any array-broadcast
program stalled silently right after mainchare construction. Mechanism:
`BocBcastMsg`/`ArrayBcastMsg` ride the NODE queue; an arbitrary rank
claims one and performs the within-node fan-out stamped with ITS OWN
(srcPe, event) (`_processBocBcastMsg` -> `_sendMsgBranchWithinNode`).
The recording captures the record-run's winner; in replay a different
rank can claim it, and the replay watcher buffered it there forever —
stranding the original AND suppressing the fan-out every other rank's
log expects. The existing SMP shepherding branch (bounce unclaimed
node-queue messages to the next rank until the recorded owner claims
them) covered only NodeBocInitMsg/ForNodeBocMsg, which predate the
array-broadcast types. Fix: add both to the bounce set. Behind the
stall hid the same envelope-swap crash as the recorder's (unconditional
CkPackMessage round trip vs CkArrayBroadcaster's retained pointer) —
same CRC-gate fix. Both on `recordreplay-fixes` (0da33f5d5); a
2000-step / 10k-migration broadcast run now records and replays to
identical completion.

Lessons:
- In replay-style tools, ANY nondeterministic ownership choice (which
  rank pops a shared queue) must either be shepherded to the recorded
  owner or made deterministic; enumerate every message type that rides a
  shared queue when auditing such a tool — new types added after the
  tool (ArrayBcastMsg here) silently fall outside its model.
- A replay that stalls with NO diagnostics is itself a signature:
  srcPe/event mismatches are silent (only EP/size mismatches print), so
  "no warnings + no progress" means the expected message NEVER EXISTED
  in this run (a producer diverged), not that it was reordered. Enabling
  REPLAYDEBUG and reading the first few getNext-vs-arrival lines
  localized the divergent producer in minutes.
- Debug-print macros referencing member fields (DEBR's AA/AB) break in
  static member functions; keep a memberless variant for those.
