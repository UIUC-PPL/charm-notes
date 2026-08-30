# Frontier (OLCF) — manual-run workflow for Kale

Started 2026-08-11, before first hands-on use; verify the two TEST
items on the first login and correct this file. Ritvik has a working
stack and env (see paratreet2 design/fof3-2b-scaling.md for his exact
srun line and env vars) — the fastest bootstrap is to copy his build
script/env rather than rederive them.

## Access model (why the Anvil pattern does not transfer)

- RSA SecurID fob: every ssh needs PIN + a 30-second single-use
  tokencode. SSH multiplexing (ControlMaster) is DISABLED on all OLCF
  user-facing systems — no session reuse, so no laptop-driven
  automated ssh loops. Set `ControlMaster no` for olcf hosts in
  ~/.ssh/config or connections error out.
- Consequence: work happens IN one authenticated session. ssh in once,
  `tmux` immediately; tmux on the login node survives disconnects, so
  one passcode per work session, everything long-running lives in tmux
  panes.

## Getting code there: regular public git clone

Use plain `git clone https://github.com/UIUC-PPL/<repo>` for
paratreet2, unionfind, htram (+ charm). For public repos the https
clone IS read-only-no-credentials; auth is only needed to push, and
pushing from Frontier is not part of the workflow (commits happen on
the laptop; Frontier pulls). This beats tarballs: `git pull` for
updates, branch switching for A/Bs (the unionfind batch-labeling A/B
needs it), and the commit hash in every job log for provenance.
Outbound https from login nodes works in practice (Ritvik builds from
clones there).

## Layout

- Source + builds: the project home area (/ccs/proj/<projid>/...),
  NOT user home (50 GB quota) and not Lustre (purged).
- Inputs + run/output directories: Lustre Orion
  (/lustre/orion/<projid>/proj-shared/...) — the 2B tipsy and all job
  stdout live there; it is PURGED (~90 days), so treat it as scratch
  and copy keeper results off.
- Results back to the laptop: small logs — paste or one scp per
  harvest (one MFA each); bulk (traces) — Globus (authenticate once in
  the browser, transfers then run unattended).

## Project id

csc710. Job submission `#SBATCH -A csc710`; Lustre space under
/lustre/orion/csc710/ (inputs + run outputs; purged ~90 days).

## Build bootstrap (Ritvik's recipe, 2026-08-12; verify on first build)

BEFORE ANY STEP in this file: check whether the folder, clone, or
build product already exists (Kale may have done steps by hand). An
existing clone means verify its remote and branch (`git remote get-url
origin`, `git branch --show-current`) and pull — never re-clone over
it; an existing build directory means check it is current before
rebuilding.

Modules (his list): `module load PrgEnv-gnu cmake hwloc python`.
Python must be >= 3.8 (LCI's binding generator uses the walrus
operator — the Anvil lesson); the module python qualifies.

Layout: clones in ~/software (Kale's choice, mirrors the laptop);
reconverse ONLY — no classic charm on Frontier. The reconverse clone
lives INSIDE the charm checkout and is consumed in place:

    cd ~/software
    git clone https://github.com/charmplusplus/charm
    cd charm && git checkout reconverse-specific-build
    git clone https://github.com/charmplusplus/reconverse   # -> charm/reconverse, stays on main

Build (the "same build command" as Anvil/laptop; -j8 for login-node
etiquette):

    ./build charm++ reconverse-linux-x86_64 \
        --with-fetch-reconverse-dir=$PWD/reconverse --with-production -j8

HWLOC TRAP (silent): reconverse's FindHWLOC has a broken environment
fallback, so a build can SUCCEED with all CPU affinity compiled out
(+setcpuaffinity not even parsed). Keep the gate: after the build,
`grep RECONVERSE_ENABLE_CPU_AFFINITY <build>/CMakeCache.txt` — must be ON.
That gate is only half the job: the capability still has to be ASKED for at
run time. See "CPU affinity at run time" below for the flags.

CORRECTED 2026-08-29 (this section previously prescribed a remedy that
breaks the build; both halves of it were wrong).

- The remedy is NOT `-DHWLOC_ROOT_DIR=$OLCF_HWLOC_ROOT` appended to the
  build command. buildcmake's arg parser has a catch-all that turns any
  unrecognised argument into a COMPILER flag, so the flag never reaches
  cmake; the build then dies at ~39% with charmc reporting
  "-DHWLOC_ROOT_DIR=... -optimize -production: file not recognized: File
  truncated" on every .ci file. The supported spelling is
  `--with-cmake-args="-DHWLOC_ROOT_DIR=$OLCF_HWLOC_ROOT"` (OLCF modules
  export OLCF_<pkg>_ROOT). See the same rule in
  charm_best_practices.md, "Build-system notes".
- The trap does not actually fire on Frontier, so the remedy has never
  been needed here. FindHWLOC's fallback reads $ENV{HWLOC} — not
  HWLOC_ROOT_DIR — and its guard is written `if(NOT HWLOC_ROOT_DIR AND
  ENV{HWLOC})`, missing the `$`, so CMake evaluates a plain false string
  and the fallback never runs at all. Affinity comes on anyway because
  the unguarded `find_path(HWLOC_INCLUDE_DIR hwloc.h)` finds the loaded
  hwloc module. Two builds on this machine confirm it: both show
  RECONVERSE_ENABLE_CPU_AFFINITY:BOOL=ON with HWLOC_ROOT_DIR never passed
  to cmake. Pass it properly anyway — the ON is luck of the module
  environment, which is exactly why the gate stays.

Runtime env (tcsh — Kale uses tcsh on Frontier; guard the unset case):

    if ($?LD_LIBRARY_PATH) then
      setenv LD_LIBRARY_PATH $HOME/software/charm/lib:$LD_LIBRARY_PATH
    else
      setenv LD_LIBRARY_PATH $HOME/software/charm/lib
    endif
    setenv CHARM_HOME $HOME/software/charm/reconverse-linux-x86_64

App stack, in order (exact make variables from the Anvil
build-stack.sh; `make clean` is MANDATORY in unionfind and paratreet2
on every rebuild — no header dependency tracking):

    cd ~/software/htram
    make unionfind_smp CHARMC_SMP=$CHARM_HOME/bin/charmc
    cd ~/software/unionfind      # BOTH vars needed; PROFILE= empty on purpose
    make CHARM_DIR=$CHARM_HOME PARENT_DIR=$HOME/software PROFILE= AGGREGATION=
    cd ~/software/paratreet2/src && make clean; make
    cd ../fof && make clean; make
    cd ../examples/fof3 && make clean; make

(paratreet2 Makefiles read $CHARM_HOME from the environment and link
../unionfind and ../htram relative to the repo — the sibling layout in
~/software is load-bearing. AGGREGATION empty = htram OFF, the default
since 2026-08-05.)

## Submission

Slurm. Partition `batch`, `#SBATCH -A <projid>` (lowercase project
id), walltime limits depend on the node-count bin (small jobs get the
shortest caps — check the Frontier User Guide "Scheduling Policy"
section; a 16-node 2B run needs well under an hour). Template sbatch
for the fof labeling A/B: paratreet2 design/frontier-labeling-ab.md —
adapt the srun line verbatim from Ritvik's recorded command
(cray_shasta, job_vni, pemap, +lci_ndevices 7 = his min(8, ppn/2)
setting on Slingshot, CXI env vars).

## CPU affinity at run time — the flags, and the OS-index trap (2026-08-29)

(READ THE MULTI-PROCESS NOTE FIRST -- the advice below is single-process.)

This file gated the BUILD-time affinity capability
(RECONVERSE_ENABLE_CPU_AFFINITY must be ON) and then never said how to ask
for affinity at RUN time, so every run made here printed
`Charm++> cpu affinity NOT enabled.` with the capability compiled in and
simply unused. Affinity should be ON for any run whose numbers you intend
to quote. It is not needed for correctness — every test here passes either
way — but an unpinned run is not a reproducible one.

reconverse parses exactly three flags (`src/cpuaffinity.cpp`): `+setcpuaffinity`,
`+pemap`, `+showcpuaffinity`. There is NO `+commap` — reconverse has no
communication threads. All of the below verified on Frontier, one node,
reconverse f3f4110, 2026-08-29.

### MULTI-PROCESS FIRST: do NOT pass `+setcpuaffinity` (corrected 2026-08-29)

The rest of this section was written from single-process runs and is right
only there. With one process per GPU -- the supported GPU configuration --
`+setcpuaffinity` makes things WORSE, badly:

    8 processes x 1 PE, srun -n8 -c7 --cpu-bind=cores, same binary, same node

    with +setcpuaffinity       without it (Slurm binding only)
      CPU chunk  19.00 ms        2.04 ms   (requested 2 ms)
      CPU chunk  63.31 ms       40.39 ms   (requested 40 ms)
      kernel     56-69 ms       50.00 ms   (requested 50 ms)
      concurrency   6.71 x         8.00 x  (8 devices)
      "WARNING: Multiple PEs assigned to same core"     no warning

CPU work runs about 10x slow. The warning is telling the truth: with one PE
per process, every process's auto-spread picks the first PU of the list it
sees, and that list is evidently not restricted to the Slurm cpuset -- so all
8 processes land on the same core. Slurm's own binding is already correct
(verified: `--cpu-bind=cores` gives rank 0 `1-7,65-71`, rank 1 `9-15,73-79`,
and so on, disjoint), so charm re-deriving affinity on top of it is both
unnecessary and wrong.

    srun -N1 -n8 -c7 --cpu-bind=cores ... ./app +pe 8      # no affinity flag

Single-process runs are the case the rest of this section covers, and there
`+setcpuaffinity` behaves as described below.

### Multi-process launch also needs PMI_MAX_KVS_ENTRIES

An 8-rank reconverse launch aborts before any application code runs:

    _pmi2_add_kvs:ERROR: The KVS data segment of 30 entries is not large
    enough.  Increase the number of KVS entries by setting env variable
    PMI_MAX_KVS_ENTRIES to a higher value.

`export PMI_MAX_KVS_ENTRIES=1000` clears it. The default 30 is not enough
for 8 processes on a node.

### Single process: use `+setcpuaffinity` by default

It spreads PEs evenly over whatever the job's cpuset actually contains, so it
adapts to the launch shape instead of assuming one. Add `+showcpuaffinity` to
see the result:

    Charm++> cpu affinity enabled.
    Charm++> set PE 0 on node 0 to PU L#0    PE 4 -> L#56
    Charm++> set PE 1 on node 0 to PU L#14   PE 5 -> L#70
    Charm++> set PE 2 on node 0 to PU L#28   PE 6 -> L#84
    Charm++> set PE 3 on node 0 to PU L#42   PE 7 -> L#98

(8 PEs over a 112-PU cpuset: stride 112/8 = 14.)

### `+pemap`: use LOGICAL indices (`L` prefix), not bare OS indices

`+pemap` implies `+setcpuaffinity` (the parser sets the flag when a map is
given), and accepts both range and comma-list syntax. The prefix is what
matters:

    +pemap L0-7                 works — "PE-core map (logical indices): 0-7"
    +pemap L0,2,4,6,8,10,12,14  works — PE i lands on L#2i
    +pemap 1-7                  works — "PE-core map (OS indices): 1-7"
    +pemap 1-8                  ABORTS (core dumped)
    +pemap 0                    ABORTS
    +pemap 8                    ABORTS

THE TRAP: a Frontier job's cpuset EXCLUDES the 8 reserved cores. Observed
inside a job step:

    Cpus_allowed_list: 1-7,9-15,17-23,25-31,33-39,41-47,49-55,57-63

so OS indices 0, 8, 16, 24, 32, 40, 48, 56 are absent. A bare OS index that
is not in the cpuset makes `CmiSetCPUAffinity` resolve
`hwloc_get_pu_obj_by_os_index` to nullptr, and the caller aborts the run.
Any contiguous OS-index map that crosses a multiple of 8 therefore dies.
Logical indices cannot hit this: `CmiSetCPUAffinityLogical` indexes the PU
list positionally (`core % thread_unitcount`), so it always lands inside the
cpuset.

Do not hardcode a PU count either. Two job steps in the same job reported
different cpuset sizes (112 PUs and 56) depending on the srun options used,
so derive any explicit map at run time — `grep Cpus_allowed_list
/proc/self/status`, or `hwloc-ls --restrict binding -p --only pu` — rather
than assuming. `+setcpuaffinity` alone sidesteps the whole question, which
is why it is the default recommendation.

### One measured observation, NOT a recommended map

On qdbench (a ring benchmark), 8 PEs packed onto adjacent logical PUs beat
the auto-spread, consistently across all 10 phases:

    +setcpuaffinity (auto, PE i -> L#14i)   ring 1.28-1.30 ms, settle 0.025, compute ~11.07
    +pemap L0-7     (packed)                ring 1.07-1.08 ms, settle 0.022, compute ~10.29

Packing favours a ring, and adjacent logical PUs may be SMT siblings, which
would hurt compute-bound work. Do not carry this to another application
without measuring it there — the launch-shape section below is explicit that
shape results do not travel outside their operating point. Choosing a real
Frontier map means pairing PEs with each GCD's NUMA domain, which is a
measurement job, not a default.

## Choosing a pemap on Frontier: what a 128-node GPU campaign measured

The section above covers the FLAGS and the cpuset trap. This one covers the
CONSEQUENCES, from the paratreet2/FoF campaign on this machine (2026-08-20 to
08-29, 16 to 128 nodes, up to 7168 PEs). Everything here is measured at scale
and some of it inverts what a single-node benchmark suggests.

### The shipping map, and the launch shape it belongs to

    --nodes=N --ntasks=8N --ntasks-per-node=8 --cpus-per-task=14
    --threads-per-core=2 --gpus-per-node=8 --exclusive
    srun --cpu-bind=none --distribution=block:block ...
      +ppn 7 +pemap 1-7,9-15,17-23,25-31,33-39,41-47,49-55,57-63
      +lci_ndevices 7 +backend_poll_thread 1

That map is exactly the job cpuset the section above reports, and it works
because of `--cpu-bind=none` — Slurm is told not to bind, and the runtime does
it. GATE ON THE READBACK, never on the flag: the application prints where its
threads actually landed, and that print is the only proof.

### THE POINT OF ppn 7: the eighth thread slot is not spare, it is the fix

**Do not fill every hardware thread.** A GPU runtime creates its helper threads
lazily from whichever thread first calls it, and `pthread_create` hands the
child the CREATOR'S affinity mask. Under `+pemap` that creator is a worker PE
pinned to one core, so the helper is born welded to that core and timeslices
against a PE that spins when idle. The general lesson and the remedy are in
`charm_best_practices.md` ("GPU helper threads inherit the pinned PE's affinity
mask"). The MAP-level consequence, which is what belongs here:

**the remedy needs somewhere to put the helper, and the pemap decides whether
that place exists.** At ppn 7 the SMT siblings of the mapped cores are free and
the runtime widens the helper onto them automatically — no Slurm change, no
env var. At ppn 13/14 every sibling is itself a PE, the fix has no landing
zone, and it declines and says so. Measured worth of having that landing zone:
**-22% at 896 PEs and -63% at 7168 PEs**, ranges fully separated at both.

Two follow-ons, both measured, both counter-intuitive:

- **Naming a dedicated core for helpers buys NOTHING** over the SMT siblings
  the runtime derives by itself. Holding the PE count constant and varying only
  whether a spare physical core was named: 860.2 ms against 857.8 ms,
  overlapping ranges. Reserve the explicit route for ppn 13/14, where there is
  no sibling to derive.
- **`--core-spec=0` costs about 1100 SECONDS OF STARTUP PER RUN at 128 nodes**
  and changes the iteration by nothing measurable (1516.9 ms with it against
  1514.9 ms without). It entered as the ppn 13/14 escape hatch and then got
  written down as though it were the fix. It is not. Do not put it in a Slurm
  header above about 16 nodes. This cost sat outside every phase timer and was
  invisible for weeks — REPORT THE WALL NEXT TO THE PHASE TIMER, always.

### SMT: what it is actually worth, so the ppn choice is not guesswork

Four placements, 896 PEs held constant in three of them, 2 billion particles:

    8 proc x  7 PE   896 PEs   56 cores   no SMT    baseline
    4 proc x 14 PE   896 PEs   56 cores   no SMT     +2.6%
    8 proc x 14 PE  1792 PEs   56 cores   SMT        +22%
    8 proc x  7 PE   896 PEs   28 cores   SMT        +79%

Reading the last row: the same PEs on half the cores is 1.787x slower, so
**SMT contributes about 12% of throughput here** (if it gave nothing that would
be 2.0x). Therefore at ppn 14 the extra 896 PEs on the sibling threads cost
more than the 12% they buy. Only 2.6 points of the ppn-14 penalty is
PEs-per-process; the rest is SMT.

### "Is the OS interfering?" — measured, and the answer was no

The natural suspicion when a pemap looks wrong is OS or IRQ noise on the
shared core. It was tested directly and rejected: per-thread runqueue wait from
`/proc/<tid>/schedstat` was 0.10-0.12% of PE cpu time at ppn 14, and LOWEST of
all (0.01-0.02%) in the placement that fills every physical core.

**Keep the method; it is the cheapest way to settle this class of question, and
it comes calibrated.** In the same campaign a PE sharing its core with a GPU
helper thread showed **2.7 SECONDS** of runqueue wait against 0.0 ms for the
same PE unshared. So a real placement problem is three to four orders of
magnitude above the noise. If schedstat says tenths of a percent, the placement
is not your problem and no amount of pemap tuning will help.

### Two things that will waste a day if you do not know them

- **`+lci_ndevices` x `+backend_poll_thread` must equal ppn**, or the run hangs
  at cache-manager initialisation. `+backend_poll_thread` is a poller-per-device
  divisor, not an on/off switch (0 clamps to 1), and ndevices is capped near 7
  per process — 112 domains on a node fails memory registration.
- **Resolution limits are large, so do not chase small pemap deltas.** Across
  allocations this campaign could not resolve better than about 4%. At 128
  nodes, two runs of IDENTICAL code differed by 68.8 ms, which is the
  single-rep noise floor there. At 16 nodes n=1 is about +/-16 ms (0.6%). At
  ppn 14 the spread reaches ~700 ms on a 5.5 s wall. Interleave reps, discard a
  warm-up arm, and compare only within one allocation.

### On carrying the packed-map result forward

The one-node observation above — 8 PEs packed onto adjacent logical PUs beating
the auto-spread on a ring benchmark — is consistent with everything here and
should still not be generalised. A ring is latency-bound and wants neighbours
close; the tree walk is compute- and fetch-bound and wants physical cores and a
free sibling for the GPU helper. Those pull in opposite directions, which is
exactly why that section calls it an observation and not a map.

## Verified 2026-08-12 (first hands-on day, via the on-machine Claude)

- Single-node runs need `srun --network=single_node_vni`; `job_vni`
  only provisions a VNI for multi-node jobs — on one node the CXI
  provider fails (`cxip_gen_auth_key failed: -38` -> fi_domain ENOSYS
  -> an opaque LCI assert). Multi-node keeps `job_vni`.
- Walltime sizing: `sacct -j <id>` on the job ids recorded in
  paratreet2 design notes gives real step times (16-node 2B FoF3 step
  = 52 s; a 9-run 2B campaign = 3m24s total). Size job walls as
  sum(per-step srun -t caps) + ~5 min slack; never hour-scale guesses.
- First run on a cold page cache pays the full input read (36 s for
  the 76.8 GB 2B tipsy vs 18-19 s warm) — treat run 1 as warm-up for
  wall times; phase timings are unaffected.
- Inputs (moved 2026-08-13): use
  /lustre/orion/csc710/proj-shared/cosmo25cmb.768g2_dm.001024 (2B) and
  lambb.00500 (80M) in the same dir. The old copies under
  /lustre/orion/csc710/scratch/rrao/ became unreadable 2026-08-13
  (scratch permissions reset to drwx--S---, killed an overnight
  campaign) and rrao scratch remains closed; Ritvik copied both to
  proj-shared. An 80M fallback also exists at
  /ccs/proj/csc710/rrao/lambb.00500. proj-shared avoids per-user
  scratch permission resets, but Lustre scratch purge policy still
  applies — re-check before relying on it.

## Detached allocations (the Anvil measurement-burst pattern)

TEST on first use, then record the answer here:
1. `salloc -A <projid> -t 60 -N 16 --no-shell` then
   `srun --jobid=<id> ...` from the login shell — standard Slurm,
   works on Anvil, not documented either way by OLCF.
2. Fallback that definitely works: plain `salloc` in a tmux pane gives
   a shell inside the allocation; run srun there repeatedly. tmux
   keeps the allocation usable across ssh disconnects, which is the
   property the detached pattern buys on Anvil.

## Automation status (2026-08-11; cross-session note 2026-08-13)

Cross-session messaging (ListAgents/SendMessage between the laptop and
Frontier Claude Code sessions, replacing the copy-paste relay): checked
from BOTH ends on 2026-08-13 — "No reachable agents" each way. It
requires Remote Control to be connected under the same account, plus
the same OLCF-policy question below (ask help@olcf.ornl.gov). Until
then the git-spec / scp-report relay stands.



No sanctioned unattended-ssh path. OLCF's S3M (token-authenticated
facility API for external systems/agents to trigger jobs) is the
designated future mechanism but is internal-only so far; watch for
external availability. Running Claude Code directly on a login node
inside tmux is plausible (outbound https appears open) and would
restore the assisted workflow without violating the ssh policy.
POLICY CHECK (2026-08-11): OLCF publishes NO explicit rule on AI
tools/agents (policy guide searched and read in full). Governing
general clauses: login nodes are for edit/compile/launch with no
CPU/memory-intensive tasks (the agent process is light; the model is
remote); licensed user-space software is permitted; the substantive
question is code transmission to an external API — moot for this
public Apache-2.0 project, but a facility determination is prudent
(precedent: Clemson Palmetto explicitly requires AI assistants to run
in compute allocations, not login nodes). ASK help@olcf.ornl.gov
before first use; record the answer here.

## tmux on the login node: getting text back out (2026-08-15)

Recurring friction, recorded because it has cost real time ("tmux is a
dumb terminal, cannot paste" — prompt-log 2026-08-14, worked around by
writing temp files). Why it feels dumb: tmux owns the screen, so the
terminal's OWN scrollback stops working (anything scrolled away is in
tmux's buffer, not Terminal.app's), and tmux hard-wraps long lines, so a
drag-select of wrapped output comes back with newlines injected.

### The path that always works, for anything longer than a couple of lines

    tmux capture-pane -pS - > ~/dump.txt     # -S - = the WHOLE scrollback
    tmux capture-pane -pS -2000 > ~/dump.txt # or just the last 2000 lines

then scp it. `-p` prints to stdout, `-J` joins wrapped lines (add it when
you want unwrapped text). This is the same move the Frontier session
already makes when it writes a temp file to paste from — bind it:

    bind-key P run-shell 'tmux capture-pane -pJS - > $HOME/pane-$(date +%H%M%S).txt'

### On-screen selection

tmux's default is `mouse off`, and with it off Terminal.app's native
drag-select + Cmd-C works normally. If mouse mode has been turned ON
(for tmux scrolling/pane clicks) it steals the drag, and then:
- Terminal.app: hold **Fn** while dragging to force a local selection
- iTerm2: hold **Option**
Keep a toggle rather than choosing once:

    bind-key m if -F '#{mouse}' 'set -g mouse off' 'set -g mouse on'

### Copying straight to the Mac clipboard over ssh (OSC 52)

Works in iTerm2 (enable "Applications in terminal may access clipboard"),
NOT in Terminal.app. With it, a tmux copy-mode selection lands in the
local clipboard with no file round-trip:

    set -g set-clipboard on
    set -g allow-passthrough on   # tmux 3.3+; drop the line on older tmux

### Colors/keys

    set -g default-terminal "screen-256color"   # tmux-256color if the
                                                # terminfo entry exists
    set -ga terminal-overrides ",*256col*:Tc"   # truecolor
    set -g history-limit 200000                 # so capture-pane -S - is useful

Check the terminfo entry exists before using tmux-256color:
`infocmp tmux-256color >/dev/null 2>&1 && echo ok` — on a bare login node
it often does not, and a missing entry is itself a cause of "dumb
terminal" behaviour in TUIs.

## Launch shape and leaf size for paratreet2/FoF (final, 2026-08-21, relays 46-65)

Superseding the earlier version of this section (its +17% ppn claim was
measured on a Debug runtime at the GPU arm's leaf size — a relative A/B
at the wrong operating point).

- **Leaf size is a first-order knob with OPPOSITE optima per arm** (full
  sweeps, 2B/16, production builds): **CPU-only -l 32** (shallow U over
  24-48; the default 12 costs +11.5%, the GPU's 128 costs +47%);
  **GPU -l 128** (true interior minimum; 12 costs +28%, 384 +53%). The
  optima differ for a reason: a large leaf is brute-force pair work for
  host phaseA but a better-shaped unit of device work.
- **CPU arm: ppn is a nearly free choice.** At production + leaf 32 the
  ppn-7-vs-14 effect is +0.8% (real, non-overlapping ranges, nearly
  worthless). Best CPU wall 4785-4811 ms (ppn 7, -l 32). The earlier
  SMT decomposition inverts at leaf 32 — do not quote shape results
  outside their operating point.
- **GPU arm: ppn 7 decisive** (2881.9 vs 3991.2 ms with the affinity
  fix; the free SMT siblings are the fix's landing zone). Best GPU wall
  2825-2882 ms (ppn 7, -l 128, fix on).
- piece_pairs_dropped tracks PE count, not set count — do not read it
  as split-deferral cost across shapes.
- Build rules that were worth 25-30% combined: charm --with-production
  ALWAYS (Debug costs 15.6% at 2B), and never link -tracemode into a
  timing binary (7.7% while disabled). --with-production and TRACING=1
  are ORTHOGONAL in buildcmake — an optimized runtime CAN trace; use
  that for traced-but-honest runs (~3% cost, relay65).
