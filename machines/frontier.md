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

HWLOC TRAP (silent): reconverse's FindHWLOC only works reliably when
HWLOC_ROOT_DIR is passed; its ENV fallback is broken. Without it the
build SUCCEEDS but all CPU affinity is compiled out (+setcpuaffinity
not even parsed). After the build, check
`grep RECONVERSE_ENABLE_CPU_AFFINITY reconverse-linux-x86_64/CMakeCache.txt`
— must be ON; if OFF, re-run the build command with
`-DHWLOC_ROOT_DIR=$OLCF_HWLOC_ROOT` appended (OLCF modules export
OLCF_<pkg>_ROOT).

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

## Launch shape for paratreet2/FoF (measured 2026-08-21, relays 46/47)

**ppn 7 (one PE per physical core, no SMT) beats ppn 14 by 16.5-17.2%
at 2B/16 nodes, on BOTH the CPU and GPU arms** — two independent 3-rep
jobs each, non-overlapping ranges. Different mechanisms per arm, so
state them that way: GPU arm because the free SMT siblings give ROCm's
helper threads somewhere to land (the affinity fix exploits exactly
that headroom); CPU arm because the phase-3 walk is SMT-hostile
(pointer-chasing traversal, -42% when siblings share a core) while
phaseA is SMT-neutral (-3%). Not an artifact of the AUTO PE-set
default (set effect isolated at +0.4%, inside spread). ppn 14 works;
it is just slower here. Note piece_pairs_dropped tracks PE count, not
set count — do not read it as split-deferral cost across shapes.
