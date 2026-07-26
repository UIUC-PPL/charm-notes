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

NOTE: an older revision of this profile referred to `$HOME/charm_reconverse`
as "Ritvik's reconverse build used by the FoF sweeps". No such directory is
visible from this account (`x-lkale`) — presumably it is under another
member's home, which is not readable. Do not assume it exists.

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

### Two traps that invalidate timings

1. `salloc -N k` **without** `--exclusive` grants k CPUs *total*, not k nodes'
   worth. Two busy-polling PEs then timeshare one core and every latency is
   garbage (measured 12998 us vs 0.836 us for the same run — ~15,000x).
   Always `--exclusive` or an explicit `--cpus-per-task`.
2. Owning a node is not the same as giving ranks cores. `srun -n 2` binds one
   CPU per task by default regardless of `--exclusive`; pass
   `--cpus-per-task` explicitly.

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
  are useless there; use the `cache:` line or Slurm accounting. (Carried over
  from the original template; NOT re-verified in the 2026-07-26 session.)
- Login nodes are shared: a busy-polling multi-PE run there may *hang* purely
  from core starvation. Never conclude "hang" or read a timing from a login
  node.
