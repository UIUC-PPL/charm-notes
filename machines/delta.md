# NCSA Delta — machine reference (cross-project)

Machine facts, module recipe, and Slurm idioms for building and running
Charm++/reconverse on NCSA Delta. Keep project status out of this file.
First recorded 2026-09-15 from a CUDA (charm-on-reconverse) build and GPU runs.

## Machine

Cray Shasta, Slingshot-11 interconnect, RHEL 9. Login nodes
`dt-loginNN.delta.ncsa.illinois.edu`. CPU nodes are AMD Milan; GPU nodes are
64 cores with 4 GPUs each. Two GPU families:

| partition | GPU | arch | nodes | max nodes/job | max wall | priority |
|---|---|---|---|---|---|---|
| `gpuA100x4` | A100-SXM4-40GB | sm_80 | 99 (`gpua[002-100]`) | unlimited | 2 d | tier 100 |
| `gpuA100x4-interactive` | same | sm_80 | 100 | **4** | **1 h** | **tier 10000** |
| `gpuA40x4` | A40 | sm_86 | 98 (`gpub*`) | unlimited | 2 d | tier 100 |
| `gpuA40x4-interactive` | same | sm_86 | 100 | **4** | **1 h** | **tier 10000** |

**The interactive partitions are the practical route for validation work.**
On 2026-09-15 both production GPU partitions had ~1750 jobs pending while the
interactive ones had 2, and every interactive job started within seconds. They
take up to 4 nodes and 1 hour, which covers single-node and multi-node
correctness runs; their QOS allows **1 running and 2 submitted jobs per user**,
so chain jobs rather than submitting a batch of them. `DefMemPerCPU=1000`, so
pass an explicit `--mem` (e.g. `--mem=32g`) for anything that needs host memory.

`sinfo -p <partition> -o "%T %D"` plus `squeue -p <partition> -t PD -h | wc -l`
is the check worth doing before choosing A100 vs A40; build for the one you
get (`CUDA_ARCH=sm_80` A100, `sm_86` A40).

## Access model (Duo two-factor)

Every new connection to `login.delta.ncsa.illinois.edu` needs a Duo push, so an
agent session cannot open one on its own. The working arrangement is an SSH
control master that a human opens once interactively and that everything else
reuses. In the laptop's `~/.ssh/config`:

    Host delta
        HostName login.delta.ncsa.illinois.edu
        User <your-ncsa-username>
        ControlMaster auto
        ControlPath ~/.ssh/cm-%r@%h:%p
        ControlPersist 12h

**Password rejected although correct (2026-09-24):** pasting the NCSA
password from 1Password into the ssh prompt added extra characters, and every
attempt failed as "Permission denied" with nothing pointing at the paste.
Type it, or check what the password manager inserts. `kinit lkale@NCSA.EDU`
tests the Kerberos password on its own and names the failure (incorrect /
expired / revoked), which ssh does not. The identity portal accepting an
ACCESS (CILogon) login proves nothing about the NCSA Kerberos password; they
are separate. Note each ssh attempt allows 3 password tries, so a few failed
attempts can trip an account lockout.

The human runs `ssh delta` once and answers Duo; after that `ssh delta '<cmd>'`
and `scp delta:...` multiplex over the master with no prompt. Check with
`ssh -O check delta` ("Master running (pid=...)"); if it reports no master,
stop and ask the human to reopen it rather than triggering a Duo prompt.

## Accounts and storage

`accounts` prints the allocations and remaining hours, e.g.

    Account                        Balance(Hours)   Deposited(Hours)  Project
    <proj>-delta-cpu                        60508             69579   ...
    <proj>-delta-gpu                          922              2943   ...

GPU jobs must use the `-gpu` account; CPU jobs the `-cpu` one. GPU hours are
billed per GPU (`TRESBillingWeights` charges GRES/gpu=2000 on A100), so a
2-GPU 25-minute job is under one GPU-hour — cheap enough to re-run, but not to
leave idle in an interactive allocation.

Writable space: `/projects/<alloc>/<user>` (persistent, where builds belong)
and `/work/hdd/<alloc>/<user>` (scratch). Home is small.

## Module recipe (CUDA build)

The login default environment already carries most of it: `PrgEnv-gnu/8.7.0`
(`gcc-native/14`, gcc 14.2.1), `cudatoolkit/26.5_13.2` (CUDA 13.2, which sets
`CUDA_HOME` and `CUDATOOLKIT_HOME` to the hpc_sdk prefix), `libfabric/2.3.1`,
`craype-network-ofi`, `craype-accel-nvidia80`. The one thing to add is cmake —
the system cmake is 3.26.5:

    module load cmake/3.31.8

There is **no hwloc module and none is needed**: hwloc 2.x is installed system
wide (`/usr/include/hwloc.h`, `/usr/lib64/libhwloc.so`, with a `.pc` file) and
reconverse's `find_package(HWLOC)` picks it up with no cmake arguments, giving
`RECONVERSE_ENABLE_CPU_AFFINITY:BOOL=ON`. PMI1, PMI2 and PMIx libraries are all
present in `/usr/lib64` and LCT builds all three backends.

Also export, per charm's `tests/reconverse-site-run.sh` case `delta`:

    export FI_PROVIDER=cxi
    export LCI_NETWORK_BACKENDS=ofi

## Build command that works

From a fresh `git clone --recurse-submodules` of charm, on the login node:

    ./build charm++ reconverse-linux-x86_64 cuda -j8 --with-production

No `--with-cmake-args` needed. ~6 minutes; build dir
`reconverse-linux-x86_64-cuda`. Put `$CBUILD/lib` and `$CUDA_HOME/lib64` on
`LD_LIBRARY_PATH`. CUDA examples build in the build tree (its example
directories are symlinks to the sources) with, e.g.,
`make -C $CBUILD/examples/charm++/cuda/gpudirect/jacobi3d CUDA_ARCH=sm_80`.

Keep the module loads and exports in an `env-cuda.sh` sourced by both the login
shell and every batch script; `module` is not defined in a non-login shell, so
guard it with
`[ -z "$LMOD_CMD" ] && source /usr/share/lmod/lmod/init/bash`.

## Standalone reconverse build: ask for the LCI backend explicitly

Configuring reconverse on its own (not through charm's `./build`) with just

    cmake -S . -B build -DCMAKE_BUILD_TYPE=Release

builds it with **no LCI backend** on Delta. `RECONVERSE_TRY_ENABLE_COMM_LCI2`
is ON by default, but LCI2 is not installed site wide and
`RECONVERSE_AUTOFETCH_LCI2` defaults to OFF, so the LCIv2 backend is skipped
without an error. Every rank then initializes as its own one-process job and
all multi-process tests pass vacuously — the same false pass as the
`--mpi=pmi2` trap below, from a different cause. Configure instead with

    cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
          -DRECONVERSE_AUTOFETCH_LCI2=ON

and confirm the startup banner reports the expected process count
(`Reconverse> Starting Reconverse with N processes`) before believing any
multi-process result. Observed 2026-09-16; it invalidated job 22124061.

## The launcher trap: use `--mpi=pmix`, not `--mpi=pmi2`

**`srun --mpi=pmi2` does not bootstrap a multi-process reconverse job on
Delta, and it fails silently.** Each rank initializes as its own job —
`Reconverse> Starting Reconverse with 1 process` printed once per rank — so a
2-process test runs as two isolated 1-process runs and a test that only checks
exit status false-passes. Forcing `LCT_PMI_BACKEND=pmi2` does not change it.
The cause is LCT's default backend order `pmix;pmi2;pmi1;...`: without the
pmix plugin the site's `libpmix` still initializes as a singleton of size 1.

    srun --mpi=pmix -N 2 --ntasks-per-node=1 -c 8 --gpus-per-task=1 ./app +pe 2
    # -> Reconverse> Starting Reconverse with 2 processes, 2 PEs, 1 PE per process

`--mpi=pmix` prints two harmless lines per step,
`PMIX ERROR: PMIX_ERR_FILE_OPEN_FAILURE in file gds_shmem2.c at line 1056`;
they are not a failure. Always confirm the "N processes" line before believing
a multi-process result. `srun --mpi=list` gives `none pmix pmi2 cray_shasta`.

charm's `tests/reconverse-site-run.sh` on the reviewed line now defaults
`SITE=delta` to `srun --mpi=pmix` (PR #3982, merged 2026-09-16), so
`LAUNCHER=` no longer has to be set there.

Unlike Frontier, Delta does **not** need `--network=single_node_vni`:
single-node steps under the cxi provider work without it.

Reconverse rejects `+pe` and `+ppn` together ("Error: only one of +pe, +ppn and
+p may be specified"), so a Frontier-style `+pe 2 +ppn 1` becomes plain
`+pe 2` — `+pe` is the total PE count across processes and the per-process
split follows the launcher's rank count.

## sbatch recipe (GPU)

    #SBATCH -A <alloc>-delta-gpu
    #SBATCH -p gpuA100x4-interactive
    #SBATCH -N 1
    #SBATCH --ntasks=2
    #SBATCH --cpus-per-task=8
    #SBATCH --gpus-per-node=2
    #SBATCH --mem=32g
    #SBATCH -t 00:25:00

    source <workspace>/env-cuda.sh
    unset SLURM_CPUS_PER_TASK
    export SLURM_CPU_BIND=none SRUN_CPU_BIND=none
    nvidia-smi -L
    srun --mpi=pmix -n 2 -c 4 --gpus-per-task=1 ./app +pe 2

`--cpus-per-task` in the header and an explicit `-c` on each `srun` are both
needed; `unset SLURM_CPUS_PER_TASK` keeps the header value from colliding with
the per-step `-c`. Wrap each step in `timeout <s> stdbuf -o0 -e0` and follow it
with `echo "RESULT <name> exit=$?"` so a hang shows as exit 124 with its output
flushed instead of silently eating the whole allocation. A step that asks for
fewer nodes or tasks than the allocation is fine, so one allocation can hold
both a 1-node and a 2-node shape (allocate `-N 2 --ntasks-per-node=2
--gpus-per-node=2` and use `srun -N 1 -n 2` / `srun -N 2 --ntasks-per-node=1`).

**Reconverse's own ctest suite does not run inside an allocation.** It
launches its single-process tests as bare binaries, with no `srun`, and
inside a Slurm allocation those hang: LCI bootstraps from the inherited job
environment and waits for peers that never start. Split the suite — run the
bare-binary single-process tests on the login node and only the
`srun`-launched multi-process ones inside an allocation. Observed 2026-09-16
(job 22125300 hung this way).

## Classic Charm++ (ofi, Slingshot) build and launch (2026-09-23)

Target that works: `./build charm++ ofi-crayshasta smp cxi -j16 --with-production`
(main @ 163833d2d; startup prints "OFI CXI extensions enabled"). The `cxi`
option's script runs `module load cray-libpals cray-pmi libfabric`; Delta has
no `cray-libpals` module, so Lmod loads NOTHING from that line and the build
dies at `pmi_cray.h: No such file` / CrayNid.c `#error "Load the cray-pmi
module"`. Fix: before `./build`, `module load cray-pmi` and add
`/opt/cray/pals/1.8/lib/pkgconfig` to `PKG_CONFIG_PATH` and
`/opt/cray/pals/1.8/lib` to `LD_LIBRARY_PATH`. The Lmod "unknown module
cray-libpals" errors still print and are harmless.

Launch with `srun --mpi=cray_shasta` (not pmix) and `+ppn <workers>`; one
core per process goes to the comm thread, so `-c 8` fits `+ppn 7`. After a
segfault in one rank, srun did not tear down the step: wrap classic runs in
`timeout`. Reconverse CPU build (no cuda) is plain
`./build charm++ reconverse-linux-x86_64 -j16 --with-production`, run with
`srun --mpi=pmix`. Worked example: /projects/mzu/lkale/nokeep-audit
(env.sh, env-classic.sh, run.sbatch).

## Multi-process runs (reconverse/LCI over cxi) (2026-09-27)

From the ChaNGa node-cache campaign (lambb.00500, 1-8 nodes, account
mzu-delta-cpu; job script `audit.sbatch` in
/projects/mzu/lkale/software/changa-cache/audit).

- **cxi environment for more than one process per node.** With the
  default libfabric MR-cache monitor, every run with more than one
  process per node aborted at the first load-balancing migration with
  `cxil_map: write error` and LCI `backend_ofi.cpp register_memory_impl:394`
  `fi_mr_regattr` "Invalid argument" / "Bad address". Working setting,
  in addition to the existing `FI_PROVIDER=cxi` and
  `LCI_NETWORK_BACKENDS=ofi`:
  ```sh
  export FI_MR_CACHE_MONITOR=userfaultfd FI_CXI_RX_MATCH_MODE=hybrid
  ```
  `FI_MR_CACHE_MONITOR=disabled` or `FI_MR_CACHE_MAX_COUNT=0` removes the
  registration error but then aborts with "LE resources not recovered
  during flow control. FI_CXI_RX_MATCH_MODE=[hybrid|software] is
  required", and is slow. `memhooks` fails like the default; `kdreg2` +
  hybrid timed out. (Triage jobs 22456361, 22456454.)
- **Put `ulimit -c 0` in job scripts.** Aborted ranks wrote 7-24 GB core
  files each into the working directory and filled the mzu 500 GB project
  quota once.
- **8-node hang with log flood.** At 8 nodes (8x64), two runs hung after
  the last "Big step" line until the timeout, with LCI printing
  `refill_recvs:172 ... Deadlock alert! The device does not have any
  posted recvs. (current packet pool size 19)` at about 70k lines/s
  (19.7 GB and 11.2 GB logs). Cap log growth: a watchdog on the login
  node cancelled any step whose log passed 1 GB. Treat 8-node timings as
  suspect until this is understood.
- **Partitions.** `cpu-preempt` preempted two jobs mid-campaign (one
  after 15 runs, one by another of our own jobs); `cpu-interactive` ran
  the short reruns; the main jobs used `cpu`.
- **Core map for the 128-core nodes** (NUMA domains are 16 contiguous
  cores; core 0 of each domain left free):
  - 64 PEs/node: `+pemap 1-8,17-24,33-40,49-56,65-72,81-88,97-104,113-120`
  - 120 PEs/node: `+pemap 1-15,17-31,33-47,49-63,65-79,81-95,97-111,113-127`

  Launch: `srun --mpi=pmix --cpu-bind=none -N<nodes> -n<np> -c<128/procs-per-node>
  ./ChaNGa +pe <total> +pemap <map> +showcpuaffinity` (the script also
  exports `SLURM_CPU_BIND=none SRUN_CPU_BIND=none`). Reconverse maps PE
  to core[globalPE mod list length], so the processes on a node take
  disjoint domains.
- **Moving large inputs.** Anvil to Delta, a 2.9 GB file (2902376480 B)
  streamed as `ssh anvil cat <f> | ssh delta 'cat > <f>'` through the
  laptop's shared ssh connections took 144 s; check md5 on both ends.
