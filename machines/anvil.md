# Anvil (Purdue RCAC) — environment profile

Machine facts, folder layout, and usage conventions for Anvil.
Applies to Charm++/Converse application and runtime projects. Keep
project status out of this file; it belongs in per-project memory.

Filled in and verified 2026-07-26 (Kale). Everything below was checked by
inspection on the machine, not inferred.

## Machine and access

- Purdue Anvil, allocation `asc050025` (Slurm `-A asc050025`). Login hosts
  are `loginNN.anvil.rcac.purdue.edu` (session was on login05).
- CPU nodes: 2 x AMD EPYC 7763, **128 cores/node**, no SMT (1 thread/core,
  64 cores/socket). Cores **0-63 = socket 0, 64-127 = socket 1**; crossing
  that boundary is expensive, see Run idioms. **8 NUMA domains of 16 cores**
  (node0 0-15, node1 16-31, ... node7 112-127), i.e. 4 per socket — so
  `+pemap` choices should stay inside a 16-core NUMA domain where possible.
  (Verified on a compute node via `srun ... lscpu`. Note the LOGIN nodes are
  different hardware — EPYC 7543, 32 cores, 4 NUMA domains — so never read
  topology, core counts, or timings from a login node.)
- Network: Mellanox InfiniBand HDR, one HCA per node (`mlx5_0`).
  `/usr/include/infiniband/verbs.h` and libibverbs are present, so
  ibverbs microbenchmarks can be built directly.

### Filesystem layout (verified via `myquota`)

| Variable | Path | Quota | Notes |
|---|---|---|---|
| `$HOME` | `/home/$USER` | **25 GB** | Too small for a Charm build. Do not build here. |
| `$PROJECT` = `$WORK` | `/anvil/projects/x-asc050025` | 5 TB, 1M files | Where builds and data belong. |
| `$SCRATCH` = `$RCAC_SCRATCH` = `$CLUSTER_SCRATCH` | `/anvil/scratch/$USER` | 100 TB, 1M files | Purged periodically; use for run output, not installs. |

Convention on this account: work lives in `$PROJECT/$USER/software/`, with
`~/software` a **symlink** to it. So `~/software/...` paths are the same
files as `/anvil/projects/x-asc050025/$USER/software/...`; both appear in
build RPATHs and neither is wrong.

### Module toolchain

`gcc/11.2.0`, `openmpi/4.0.6`, `libfabric/1.12.0`, `numactl`, `zlib` and
`modtree/cpu` are **loaded by default** — a bare login is already a working
toolchain. Two additions are needed for Charm/reconverse and neither
announces itself:

    module load python/3.9.5   # REQUIRED - build fails without it
    module load hwloc          # optional-looking, silently costs CPU affinity

Both hazards are written up below. Also available: `gcc/{8.4.1,10.2.0,14.2.0}`,
`openmpi/{3.1.6,4.1.6}`. Only `hwloc/1.11.13` is offered (fine — reconverse
has an explicit pre-2.0 API branch).

## Charm++ / Converse installations

`$PROJECT/$USER/software/recharm/` — Charm++ on reconverse, built
2026-07-26. **`source recharm/env.sh` sets up everything** (modules,
`$RECHARM`, `$CHARM_DIR`, `LD_LIBRARY_PATH`, `$LCRUN`, `$HWLOC_ROOT`).

| Tree | Runtime | Purpose |
|---|---|---|
| `recharm/charm/` | reconverse | the real Charm++ install; `charm/{bin,lib,include}` are symlinks into `charm/reconverse-linux-x86_64/` |
| `recharm/tracedcharm/` | reconverse | **same commits, tracing enabled** — for Projections runs; see below |
| `recharm/reconverse-tests-build/` | reconverse | standalone reconverse + tests, registration cache **OFF** — the A/B baseline, keep untouched |
| `recharm/reconverse-regcache-build/` | reconverse | same, registration cache **ON** |

Versions: charm branch `reconverse-specific-build` @ `9460a3469`,
reconverse branch `main` @ `9d66483`. Note charm `main` is effectively
frozen (574 commits in 2019 → 5 in 2026), so reconverse work happens on
`reconverse-specific-build`.

Build command (user-installed-reconverse variant, so reconverse itself stays
editable — `charm/reconverse/` is the only copy, no `_deps` duplicate to
drift):

    ./build charm++ reconverse-linux-x86_64 --with-production -j8 \
            --with-fetch-reconverse-dir=$PWD/reconverse

Current options in all three trees: `LCI_NETWORK_BACKENDS=ibv;ofi` (ibv
default), `LCI_PACKET_SIZE_DEFAULT=8192`, `RECONVERSE_ENABLE_CPU_AFFINITY=ON`,
`LCI_USE_REG_CACHE=ON` (OFF only in `reconverse-tests-build`),
`CMK_USE_SHMEM=OFF`.

`charm/reconverse-linux-x86_64` is an ordinary CMake tree (Unix Makefiles,
source = `charm/`), so options can be changed in place without a full
rebuild:

    cmake -S $RECHARM/charm -B $RECHARM/charm/reconverse-linux-x86_64 -D<OPT>=<VAL>
    cmake --build $RECHARM/charm/reconverse-linux-x86_64 -j8

`lcrun` is at `<build>/_deps/lci-src/lcrun`, not in `bin/` (`$LCRUN` in
env.sh). On compute nodes prefer `srun --mpi=pmi2` over `lcrun`.

### tracedcharm — the Projections-enabled twin (built 2026-07-26)

`recharm/tracedcharm/` is a second charm at the SAME commits (local clones of
`recharm/charm` and its reconverse checkout, so identical by construction),
built with tracing on. Script: `recharm/bench/build-tracedcharm.sh`.

    ./build charm++ reconverse-linux-x86_64 --with-production --enable-tracing -j8 \
            --with-fetch-reconverse-dir=$PWD/reconverse \
            --with-cmake-args="-DLCI_USE_REG_CACHE=ON -DRECONVERSE_ENABLE_CPU_AFFINITY=ON -DHWLOC_ROOT_DIR=$HWLOC_ROOT"

Two things about charm's `./build` that are easy to get wrong:

- `--enable-tracing` is the supported flag (`buildcmake:335` -> `-DTRACING=1`).
  `TRACING` is a cache STRING that defaults to **0 for any non-Debug build**
  (`CMakeLists.txt:190-195`), so a `--with-production` build has NO trace
  modules and `charmc -tracemode projections` aborts with "No such tracemode".
- Raw `-D` options must go through **`--with-cmake-args="..."`**. Unrecognised
  arguments are silently appended to the COMPILER flags instead
  (`buildcmake:487-489`), so `-DLCI_USE_REG_CACHE=ON` passed directly becomes a
  preprocessor define and the cmake option stays at its default.

Verified present after the build: `libtrace-projections.a` plus
trace-{summary,simple,counter,memory,utilization,projector,controlPoints,perfReport}.

Why a separate tree rather than flipping the option in place: tracing sets
`CMK_TRACE_ENABLED`, which compiles trace hooks into `libck`. It is
ABI-affecting, so the whole app stack must be rebuilt against whichever charm
it links. Two trees make switching a `CHARM_HOME` change plus an app rebuild,
instead of a charm rebuild each way.

To build the app stack traced, use the same commands as the production stack
with `CHARM=$RECHARM/tracedcharm`, and add `-tracemode projections`. fof3's
Makefile has no tracing target, but `OPTS` includes `$(MAKE_OPTS)`, so:

    cd paratreet2/examples/fof3 && make clean && \
        CHARM_HOME=$RECHARM/tracedcharm make MAKE_OPTS="-tracemode projections"

HAZARD: rebuilding the app in place replaces the production `FoF3` binary with
a traced one, which carries tracing overhead. Never leave the stack traced if
timing runs are queued or expected — rebuild back against `recharm/charm`
afterwards, or keep a separate stack copy.

Better pattern, used here (`clusterfinding/stage-traced-binary.sh`): build
traced, copy the binary to `clusterfinding/traced-bin/FoF3`, then immediately
rebuild the tree back to production. The tree never sits traced while a job
queues, and traced runs just invoke the staged binary. Two things this needs:

- **`LD_LIBRARY_PATH` must point at tracedcharm.** `FoF3` links
  libreconverse/liblci/liblct/liblci-ucx dynamically, and its RPATH covers only
  the gcc runtime — so those come from `LD_LIBRARY_PATH`, which `env.sh` sets to
  the PRODUCTION charm. Without an override the traced binary silently runs on
  the production runtime. Prepend
  `$RECHARM/tracedcharm/lib:$RECHARM/tracedcharm/reconverse-linux-x86_64/lib`.
  (Tracing itself still works either way — the trace machinery is in libck,
  which is static — but the runtime should match the build.)
- **`+traceroot <dir>`** sends the logs somewhere chosen. The default traceroot
  is the EXECUTABLE PATH, not the CWD, so without it traces are written beside
  the binary regardless of where you `cd` first. The dir **must be on
  `$PROJECT` or `$SCRATCH`** — compute-node `/tmp` is node-local, and a
  traceroot there dies at startup with `Cannot open projections sts file for
  writing due to No such file or directory` (2026-07-27).

The RPATH point is worth restating because a script comment in the
clusterfinding tree asserted the opposite for a day: `readelf -d` on FoF3 shows
the RPATH holds ONLY the spack gcc lib dirs
(`/apps/spack/anvil/apps/gcc/11.2.0-.../lib{,64}`). Verify with
`ldd <binary> | grep reconverse` before every traced campaign — it prints the
path actually resolved, so a wrong `LD_LIBRARY_PATH` shows up immediately
instead of silently producing traces of the untraced runtime.

Trace volume: a 120-PE 80M run produced 120 `.log.gz` totalling ~157 MB, plus
`.sts` and `.projrc`. Budget roughly 1.3 MB/PE for a ~4 s iteration. At 4
nodes / 480 PEs the same workload gave 670 MB (with htram aggregation) and
567 MB (without) — aggregation's entry methods are a real fraction of the log.

Trace-buffer sizing at this shape: the default `+logsize` is 1,000,000
entries/PE, and `LogPool` **reserves it up front** (`pool.reserve`), at
`sizeof(LogEntry)` = 88 bytes here (PAPI absent, so no `papiValues` array) =
**83.9 MB/PE**. At 8 procs x 15 PEs that is 1.26 GB/process and ~10.1 GB/node
against 257 GB — so raising `+logsize` several-fold is affordable. Measured
need: the busiest PE wrote ~300-320k entries for an 80M iteration at 480 PEs,
i.e. ~3x headroom on the default. (Flush detection is a general Projections
topic — see charm_best_practices.md.)

NOTE: an older revision of this profile referred to `$HOME/charm_reconverse`
as "Ritvik's reconverse build used by the FoF sweeps". No such directory is
visible from this account (`x-lkale`) — presumably it is under another
member's home, which is not readable. Do not assume it exists.

## Cluster-finding stack (paratreet2 / unionfind / htram)

`$PROJECT/$USER/software/clusterfinding/` — sibling layout mirroring the
laptop, set up 2026-07-26. paratreet2's `src/Makefile.common` derives
`UNION_FIND_DIR`/`HTRAM_DIR` from `BASE_PATH/..`, so the sibling layout is
what makes the build work with no path overrides on the paratreet2 side.

| repo | branch | note |
|---|---|---|
| `htram` | `master` | provides `libhtram_group_unionfind.a` |
| `unionfind` | `fof_with_aggregation` | **must be checked out explicitly** — the repo default is `master`, which is a DIFFERENT commit |
| `paratreet2` | `phase1-grid` | main + the per-chare grid (`-G`) |

`paratreet2` has an uninitialized submodule: run
`git submodule update --init --recursive` (pulls N-BodyShop/utility), then
`cd utility/structures && ./configure && make` for `libTipsy.a`.

Build order and the overrides that are actually needed (CHARM = charm build
root containing `bin/charmc`, CF = the clusterfinding dir):

    cd htram      && make unionfind_smp CHARMC_SMP="$CHARM/bin/charmc"
    cd unionfind/prefixLib && make CHARM_DIR=$CHARM PARENT_DIR=$CF
    cd unionfind  && make clean && make CHARM_DIR=$CHARM PARENT_DIR=$CF PROFILE=
    cd paratreet2/src          && make clean && CHARM_HOME=$CHARM make
    cd paratreet2/examples/fof3 && make clean && CHARM_HOME=$CHARM make

Three override traps, all from hardcoded foreign paths:

- htram's `Makefile.common` sets `CHARMC` to a Cray/`ofi-...-cxi` relative path
  and `CHARMC_SMP` to `/home/x-rrao/charm_reconverse/bin/charmc` (another
  member's home — unreadable). The unionfind library is built by
  **`CHARMC_SMP`**, not `CHARMC`, so that is the variable to override. Also
  `make all` builds histo binaries you do not want; the target is
  `unionfind_smp`.
- unionfind's `Makefile.common` sets `PARENT_DIR = $(HOME)` and
  `CHARM_DIR = $(PARENT_DIR)/charm_reconverse`. Override BOTH: setting only
  `PARENT_DIR` silently redirects `CHARM_DIR` to `$CF/charm_reconverse`.
- paratreet2's `CHARM_HOME ?= $(HOME)/charm_reconverse` — must be set.

`AGGREGATION` defaults ON in both unionfind and paratreet2 `Makefile.common`
and the two MUST match (it changes `unionFindLib.h` class layout — a mismatch
is a silent ABI break). Leaving both at their defaults is consistent. Note
`paratreet2/src/Makefile:12` comments the opposite (`make AGGREGATION= PROFILE=`);
that comment contradicts `Makefile.common` and following it would require
turning aggregation off on BOTH sides.

Building **without htram** therefore means a FULL-STACK rebuild, not just a
paratreet2 one — the unionfind library itself is compiled differently and
cannot be shared between an agg and a noagg binary. The exact overrides
(`clusterfinding/build-stack.sh` takes this as a third arg, `on`/`off`):

    cd unionfind  && make CHARM_DIR=$CHARM PARENT_DIR=$CF PROFILE= AGGREGATION=
    cd paratreet2/{src,examples/fof3} && CHARM_HOME=$CHARM make AGGREGATION=-DUNIONFIND

`-DUNIONFIND` must stay defined on the paratreet2 side: it selects the htram
datatype and is independent of whether aggregation is used, which mirrors
unionfind's own `CHARMC = ... $(UNIONFIND) $(AGGREGATION)`. Verify the result
with `nm -C FoF3 | grep -ci htram` — 0 for a real noagg build, ~730 with
aggregation on. `-lhtram_group_unionfind` stays on the link line either way
(hardcoded in `paratreet2/src/Makefile.common`) but pulls in nothing when
`unionFindLib.h` no longer includes `htram_group.h`.

Measured 2026-07-27 (80M, 4 nodes, 480 PEs): agg and noagg agree to ~0.002 s on
**every phase-1 stage** — aggregation only touches the unionfind phase-3 path,
so for phase-1 work either build is valid and the noagg one just gives a
cleaner timeline. Do NOT read the `uf2` stage from a single pair: it swung
0.158-2.329 across three identical repeats at this configuration.

`make clean` is mandatory in unionfind and paratreet2 — no header-dependency
tracking, and the vertex-storage header layout changed recently, so stale
objects link garbage.

Smoke tests (`paratreet2/examples/fof3`, inputs in `paratreet2/inputs/`),
expected component counts 1k: 390, 10k: 3549, 100k: 33933:

    srun --mpi=pmi2 -n 2 --cpus-per-task=8 ./FoF3 -f ../../inputs/10k.tipsy \
         -d oct -u dist -b 0.2 -c full +ppn 2      # -> FOF3 TEST PASSED: 3549

80M production configuration (8 procs x 15 PEs = 120 cores, so it fits on ONE
exclusive node — no multi-node queue needed):

    srun --mpi=pmi2 --unbuffered -N 1 -n 8 --cpus-per-task=15 \
         ./FoF3 -f /anvil/projects/x-asc050025/x-rrao/globus_shared/lambb.00500 \
         -d oct -u dist -b 0.2 -G 4 +ppn 15

`--cpus-per-task=15` is NOT optional: without it srun gives 8 cores for 120
busy-polling PEs and every timing is meaningless. A full 80M run at this
configuration takes ~8 s wall, so repeats are cheap — use them, phaseA max has
~10% run-to-run spread (see below).

## Slurm idioms

### Getting a whole node — the thing to get right

    salloc -A asc050025 -p shared -N 1 --exclusive -t 120 --no-shell
    # then, using the returned JOBID:
    srun --jobid=<ID> --mpi=pmi2 -N 1 -n <procs> --cpus-per-task=<cores/proc> ./app +ppn <PEs>

`-p shared -N 1 --exclusive` grants in seconds and gives all 128 cores.
Billing is identical to `wholenode` (`TRESBillingWeights=CPU=1.0`), so there
is no reason to queue for `wholenode` for single-node work.

**Per-partition QOS node caps are hard limits, not contention:**

| partition | max nodes/job | max wall | notes |
|---|---|---|---|
| `shared` | **1** | 4 d | `OverSubscribe=NO`, consumable cores; `--exclusive` needed for a whole node |
| `highmem` | **1** | 2 d | often idle, but the cap means it cannot help multi-node |
| `debug` | 2 (cpu=256) | 2 h | only interactive route to 2 exclusive nodes; shares nodes a[000-016] with `shared` |
| `standard` / `wholenode` | 16 | 4 d | `OverSubscribe=EXCLUSIVE` (whole nodes automatic, `--exclusive` redundant) |
| `wide` | 56 | 12 h | same physical nodes as standard |

`-N 2 --exclusive` on `shared` is **rejected outright** by the node=1 cap —
it looks like contention and is not. For multi-node, `sbatch` and let it
queue rather than waiting interactively: `wholenode` has been seen at 643/643
allocated with 22k jobs pending, yet a 2-node 20-minute job still landed in
~10 minutes (short jobs backfill well).

On core-consumable partitions (`debug`, `shared`), an `sbatch` header that
requests only `-N 1` allocates ONE core; an inner `srun -n 8
--cpus-per-task=15` then blocks forever with "Job ... step creation
temporarily disabled, retrying (Requested nodes are busy)" until the job's
wall limit kills it (job 19557989, 2026-07-28 — 20 min of retries, app never
started). Declare `-n` and `--cpus-per-task` in the `#SBATCH` header (or
`--exclusive`); on `wholenode`/`standard` this doesn't arise because
allocation is whole-node.

### Three traps that invalidate timings

1. `salloc -N k` **without** `--exclusive` grants k CPUs *total*, not k nodes'
   worth. Two busy-polling PEs then timeshare one core and every latency is
   garbage (measured 12998 us vs 0.836 us for the same run — ~15,000x).
   Always `--exclusive` or an explicit `--cpus-per-task`.
2. Owning a node is not the same as giving ranks cores. `srun -n 2` binds one
   CPU per task by default regardless of `--exclusive`; pass
   `--cpus-per-task` explicitly.
3. **Never A/B across two allocations.** Node-set-to-node-set variation here
   is far larger than run-to-run variation within one allocation, and it is
   not visible as noise — it is a clean, consistent offset that reads exactly
   like a code effect. Measured 2026-07-27 (80M, 4 nodes, 480 PEs): the SAME
   main-branch code gave phaseA 0.339-0.396 on one allocation and 0.265-0.268
   on another (~25%), with `phase1` 0.67-0.76 vs 0.52-0.55. A phaseB change
   benchmarked cross-job looked like -0.19 s; interleaved in one allocation the
   real effect was -0.10 s. The tell that saved it: the "improvement" also
   appeared in a stage the commit could not touch. **Always sanity-check an
   A/B against a stage the change cannot affect** — if that moves too, the
   comparison is measuring the allocation.

### The protocol that follows from trap 3 — interleave inside one job

Pre-stage each variant as its own binary, then alternate `srun` steps inside a
single `sbatch` allocation. Repeats are ~5 s at 80M/480 PEs, so 3 reps x 3
variants is one ~25-minute job.

    #SBATCH -p wholenode -N 4 -t 00:25:00
    for R in 1 2 3; do
      for V in main pool pool2; do
        srun --mpi=pmi2 -N 4 -n 32 --cpus-per-task=15 ./FoF3.$V ... +ppn 15 \
             > $OUT/${V}.rep$R.log 2>&1
      done
    done

Two properties worth keeping: every variant sees the same node set and the same
neighbours, and because the binaries are pre-staged the job does not depend on
what branch or build state the source tree is in when it finally runs — which
matters, since a 4-node job can sit in the queue while you rebuild for the next
experiment. Poll with `squeue` from a background shell rather than holding an
interactive allocation, and point `-o` at `$PROJECT`.

For single-node work the older `salloc --no-shell` + `srun --jobid=<ID>`
pattern is still the fastest route (grants in seconds on `shared`); use it for
smoke tests, not for anything whose timing you intend to quote.

### `mpirun` vs `srun` — not interchangeable here

Use `srun --mpi=pmi2`. LCI is built without PMIx support (`Could NOT find
PMIx`), while OpenMPI's `mpirun` provides PMIx, so under `mpirun` LCT logs
"LCT assumes the number of processes of this job is 1" and **each rank runs
as an isolated single-process job** — `mpirun -n 2 ... +ppn 1` prints
"Running in SMP mode on 1 nodes and 1 PEs" twice. The same binary under
`srun --mpi=pmi2 -n 2` correctly reports 2 nodes. Also never nest `mpirun`
inside an `srun` step; it fails outright.

Consequence for the test suite: `RECONVERSE_TEST_LAUNCHER` defaults to
`mpirun`, so every multi-process ctest on this machine has been passing
without sending a message between processes. Set it to `srun --mpi=pmi2`
before trusting `ctest`.

## Run idioms

- Reconverse builds are inherently SMP, so multi-process runs need an
  explicit `+ppn` (e.g. `srun ... -n 2 ./app +ppn 1`). `+pe` is the TOTAL PE
  count across processes; `+ppn` is per process.
- **No comm thread.** `CommunicationServerThread()` is an empty stub
  (`convcore.cpp:1382`) and `CmiStartThreads` creates exactly `+ppn` threads.
  Unlike classic Converse SMP there is no core to reserve — all 128 cores can
  be worker PEs. The flip side: network progress happens inside worker
  threads, so a PE without a real core makes no progress at all.
- **Placement matters more than the affinity flag.** Intra-process 2-PE,
  512 B one-way, exclusive node:

  | placement | latency |
  |---|---|
  | `+pemap 0-1` (adjacent, same NUMA domain) | **0.237 us** |
  | no affinity, 128-CPU cpuset | 0.828 us |
  | `+setcpuaffinity` alone, 128-CPU cpuset | 1.197 us |
  | `+pemap 0,64` (across sockets) | 1.255 us |

  5.3x from placement alone, and `+setcpuaffinity` **alone is worse than
  nothing** on a full node because its automatic policy spreads worker PEs
  across sockets. For latency-sensitive runs use explicit `+pemap`.
  `+showcpuaffinity` prints the resulting PE→PU map; use it to confirm.
- Reading output from detached allocations: `salloc --no-shell` then
  `srun --jobid=<ID> --unbuffered ...` streams straight back. For `sbatch`,
  point `-o` at a path under `$PROJECT` (compute-node `/tmp` is node-local
  and invisible from the login node — a binary built in `/tmp` will not even
  execute under `srun`).

## Driving Anvil non-interactively (ssh, agent sessions)

Written 2026-07-27 for sessions that reach Anvil over ssh rather than sitting
on a login shell. All of it was hit in practice.

- **Laptop-side access**: `~/.ssh/config` on Kale's Mac defines
  `Host anvil` -> `anvil.rcac.purdue.edu`, `User x-lkale`, with key auth
  already working — so `ssh anvil '<command>'` and `scp anvil:<path> ...`
  work from any session with no further setup. Different login hosts have
  SEPARATE node-local `/tmp`: never stage files through `/tmp` between an
  `scp` and a later `ssh` (they may land on different login nodes); use
  `$PROJECT` paths for anything a second command must see.

- **Shell state does not persist between commands.** Every command must
  `source $PROJECT/$USER/software/recharm/env.sh` for itself (modules,
  `$RECHARM`, `LD_LIBRARY_PATH`). Putting the source line inside each `sbatch`
  script is the reliable form — a job script starts from the user profile, not
  from whatever the driving session had set.
- **Long work must outlive the session.** Prefer `sbatch` with `-o` under
  `$PROJECT`, and pre-stage binaries so a queued job does not depend on the
  source tree's branch or build state when it finally runs. Then a dropped
  connection costs nothing: the job is identified by its ID and its output is
  on a shared filesystem. Poll with `squeue -j <ID>` from a background shell
  rather than holding an interactive allocation.
- **Leave a resume note in the project dir** (not only in session memory): the
  task, the job IDs, what is already staged, the reference values a result must
  match, and the command to resubmit. A fresh session then continues without
  re-deriving — and without re-running an allocation to rebuild a baseline that
  already exists on disk.
- **Never run, and never time, on a login node.** They are shared AND different
  hardware (EPYC 7543, 32 cores, 4 NUMA domains vs the compute nodes' dual 7763
  / 128 cores / 8 domains). A busy-polling multi-PE run there can hang purely
  from core starvation, and any topology or timing read there is wrong.
- Login-node toolchain gaps to expect: **no `gdb`**. For struct layout
  questions, compile a small probe with the same declarations instead
  (`sizeof(LogEntry)` was resolved that way).
- Anything written to `/tmp` in a job is on the COMPUTE node and invisible
  afterwards — output paths, traceroots and staged binaries all belong on
  `$PROJECT` or `$SCRATCH`.

## Data

- `/anvil/projects/x-asc050025/x-rrao/globus_shared/` — shared datasets
  (readable from this account): `lambb.00500` (80M LAMBS snapshot),
  `cosmo25cmb.768g.00144`, `cosmo25cmb.768g2_dm.001024`, `dwf1.2048.00384`,
  `dwf1.6144.01472`.

## Hazards (machine-specific; general lessons live in charm_best_practices.md)

- **`module load python/3.9.5` is mandatory.** System `python3` is 3.6.8;
  LCI generates `binding.cpp` at cmake configure time using the walrus
  operator (needs >= 3.8). Without it the build emits only *warnings* at the
  real cause and then dies ~400 lines later with the misleading
  `No SOURCES given to target: LCI`.
- **`module load hwloc` fails silently.** reconverse does
  `find_package(HWLOC)` then
  `option(RECONVERSE_ENABLE_CPU_AFFINITY ... ${HWLOC_FOUND})`, so a missing
  hwloc leaves the build *succeeding* with all of `cpuaffinity.cpp` #ifdef'd
  out to empty stubs — no pinning, and `+setcpuaffinity` is not even
  recognised (its argument parsing is inside that ifdef). Two follow-on
  traps: (a) on a *reconfigure* hwloc alone is not enough, because `option()`
  applies its default only on the first configure and the stale `OFF` in
  CMakeCache.txt wins — pass `-DRECONVERSE_ENABLE_CPU_AFFINITY=ON`
  explicitly; (b) `FindHWLOC.cmake` only searches reliably via
  `-DHWLOC_ROOT_DIR=...` (its `$ENV{HWLOC}` fallback is dead code — line 22
  tests `ENV{HWLOC}` without the `$`). Charm meanwhile builds its own
  bundled hwloc 2.10.0 in the same tree, which reconverse cannot see.
- Silently missing optional deps in every build here: HWLOC (above),
  TCMalloc (LCI warns of degraded performance; unquantified), LCW, PAPI,
  PMIx (see mpirun above), JPEG. Only PMIx and HWLOC have bitten so far.
- The reconverse test build needs BOTH `-DRECONVERSE_BUILD_TESTS=ON` and
  `-DRECONVERSE_AUTOFETCH_LCI2=ON`, or it builds with no network backend and
  every rank runs as an isolated 1-PE job.
- `CmiMemoryUsage` returns 0 under reconverse — FOF3STAT `memory_MB` lines
  are useless there; use the `cache:` line or Slurm accounting. (CONFIRMED
  2026-07-26: every 80M run printed `memory_MB: 0.0/0.0/0.0`.)
- Timing spread at the 80M/120-PE configuration is ~10% on phaseA max
  (5 runs of the same binary and flags gave 0.890, 0.906, 0.912, 1.001,
  1.209). Any A/B claiming less than that needs interleaved repeats, not a
  single pair — runs are only ~8 s, so there is no excuse.
- Login nodes are shared: a busy-polling multi-PE run there may *hang* purely
  from core starvation. Never conclude "hang" or read a timing from a login
  node.
- Sum-detail tracing at scale (validated at 2B, jobs 19558722/19559585,
  after the trace-shutdown fix — see reconverse-trace-shutdown.md):
  binary linked `-tracemode summary` from tracedcharm, run with
  `+sumDetail +traceroot <dir>`. Default interval is 1 ms (`+binsize`
  in seconds); at 2B/33 s that made 32,671 intervals x 412 EPs =
  ~180 MB across 1920 PEs. For future runs prefer `+binsize 0.01`
  (Kale, 2026-07-29): 10x fewer intervals, ~20 MB total, plenty for
  phase structure. Load in Projections via the `.sum.sts` file.

## Launch EVERYTHING through srun on compute nodes — even single-process (2026-08-03)

A bare `./FoF3 ... +pe 4` inside an sbatch with `--ntasks=4` hung for its
full 20-minute limit with zero output (job 19649742): under a multi-task
SLURM allocation, the reconverse/LCI PMI bootstrap sees the SLURM_* task
count and waits for ranks that never join. On laptop, running the binary
directly is the single-process idiom; on Anvil compute nodes it is not —
use `srun --mpi=pmi2 -n 1 ./app +pe <PEs>` for single-process runs too
(job 19650252: same binary, 6/6 pass). Corollary: a reconverse job whose
log stops dead right before the first run banner is almost certainly this,
not a crash.

## CPU affinity: our runs never set it; 10 ms scheduling holes observed (2026-08-11)

Every clusterfinding sbatch to date launches without +pemap or
+setcpuaffinity ("Charm++> cpu affinity NOT enabled" in the banner).
Observed consequence in a traced 80M/4-node run: one idle PE's
process-LOCAL stage-trigger message sat unprocessed for 9.9 ms (its
thread descheduled by Linux mid-spin; the general rule from the July
latency work — a size-independent ~10 ms delay means OS scheduling, not
transport), and because the phaseB pool assembly is a process barrier,
that one PE stalled its whole process's phaseB. Fix for future scripts:
an explicit +pemap (Ritvik's Frontier lines are the model; note the
best-practices caution that +setcpuaffinity alone, without a map, can
be a pessimization). 8 procs x 15 PEs on a 128-core node leaves 8
cores free; map workers away from core 0 per socket.

## VALIDATED Anvil pemap (2026-08-11, job 19800045) — use for all future runs

Compute nodes: 2x EPYC 7763, 128 cores, no SMT, NPS4 = eight 16-core
NUMA domains (0-15, 16-31, ..., 112-127). Production configuration for
8 procs x 15 PEs:

    #SBATCH --cpus-per-task=16          # FULL node cgroup — required
    srun --cpu-bind=none --unbuffered ... \
      +pemap 1-15,17-31,33-47,49-63,65-79,81-95,97-111,113-127

Each process = one NUMA domain minus its FIRST core (left free for
OS/interrupts — the cure for the observed 10 ms descheduling holes).
The reconverse pemap pattern wraps by pe % count, so this 120-entry
per-node pattern is correct at any node count (process-major PE
numbering aligns the wrap with node boundaries).

Failure modes found on the way (each cost a test job):
- --cpus-per-task=15 allocates only 120 of 128 cores to the JOB cgroup
  (cores 60-63 and 124-127 excluded); binds to them fail with
  "CmiSetCPUAffinity failed to bind PE #N to PU P#C" and CmiAbort on
  every affected rank — BEFORE any banner reaches a buffered log (use
  --unbuffered to see abort messages at all). --cpu-bind=none does not
  lift the job-level cgroup, only per-task binding.
- Historical runs (cpus-per-task=15, no affinity flags) also had
  Slurm's task cgroups packed from core 0, so half the processes
  STRADDLED two NUMA domains.
- Logical-index pemap (L prefix) renumbers within the cgroup's allowed
  set — scrambles the intended layout (same-core warnings). Use OS
  indices with the full-node cgroup.
- +setcpuaffinity alone auto-spreads with same-core collisions at this
  shape (matches the best-practices caution).
Adopting the pemap changes timing baselines — keep any A/B within one
affinity configuration.

## Pemap A/B verdict (2026-08-12, job 19817502, 9 interleaved 80M runs)

First-core-free (the validated map above) WINS on every metric: walk
0.123-0.134 vs last-core-free 0.134-0.208 (one worker pinned to global
core 0 — the OS/interrupt core — produced the 0.208 outlier, matching
the a priori reasoning) vs unpinned 0.163-0.192 (worst walk AND phaseA
AND skew). RETRACTION: an earlier cross-job comparison suggested
pinning cost ~10% walk — that was allocation-to-allocation variation
masquerading as a configuration effect (the arms were never
interleaved). Recommend first-core-free to Ritvik for Anvil runs; his
last-core-free map differs only in pinning a worker onto core 0.

## Time-of-day fabric degradation — run measurement jobs in the MORNING (2026-08-14, three-for-three)

Anvil's IB fabric enters a degraded mode outside the morning window,
severe enough to invalidate or kill measurement jobs. Signature: one
task is OOM-killed, then its PEERS abort with
`backend_ibv_inline.hpp:poll_comp_impl:118 lci:Assert failed:
wcs[i].status == IBV_WC_SUCCESS` (the assert fires on the victim's
peers when its queue pairs flush). Mechanism, per the paratreet2
windowed-flush fix (aba7833): when the network drains slowly the sender
outruns the wire, untransmitted copies accumulate, and a rank OOMs.

Evidence, all paratreet2 2B/16-node jobs:
| job | when (Anvil local) | outcome |
|---|---|---|
| 19842202 | evening | sum-detail arm OOM-killed, IBV cascade |
| 19860455 | ~10:35 | ALL arms clean; phaseA 1.03 s |
| 19861888 | afternoon | prewire-2 + both traced arms OOM'd |
| 19932506 | evening | ran, but phaseA inflated |
| 19935188 | 23:30 | ALL SIX arms OOM-killed, nothing usable |
| 19979198 | 16:12 | uniform slowdown to the srun limit, rc=143 |

Timing is also visible without a crash: the SAME configuration measured
phaseA 27-39 s in an evening window and 1.03 s at ~10:35 — a ~30x swing
with identical code and inputs. So an evening job that "works" can still
be worthless for timing.

SECOND FAILURE MODE (2026-08-16, job 19979198): the degradation does not
always OOM. It can present as uniform slowness with NO crash and no IBV
cascade — decomposition 10.5 s -> 120.7 s (11.5x), of which the particle
flush alone was 114 s, and tree build 0.57 s -> 91.3 s (160x), running
into the srun time limit with rc=143 and printing nothing usable. So a
job that "just seems slow" in the afternoon is the same fault, not
contention.

PRACTICE: submit measurement jobs with `--begin=<date>T09:30:00` (Anvil
local) rather than letting them run when the queue happens to drain.
Counts/exactness from an evening run are still valid; timings are not.
