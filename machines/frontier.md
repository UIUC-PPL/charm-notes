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

## Submission

Slurm. Partition `batch`, `#SBATCH -A <projid>` (lowercase project
id), walltime limits depend on the node-count bin (small jobs get the
shortest caps — check the Frontier User Guide "Scheduling Policy"
section; a 16-node 2B run needs well under an hour). Template sbatch
for the fof labeling A/B: paratreet2 design/frontier-labeling-ab.md —
adapt the srun line verbatim from Ritvik's recorded command
(cray_shasta, job_vni, pemap, +lci_ndevices 7 = his min(8, ppn/2)
setting on Slingshot, CXI env vars).

## Detached allocations (the Anvil measurement-burst pattern)

TEST on first use, then record the answer here:
1. `salloc -A <projid> -t 60 -N 16 --no-shell` then
   `srun --jobid=<id> ...` from the login shell — standard Slurm,
   works on Anvil, not documented either way by OLCF.
2. Fallback that definitely works: plain `salloc` in a tmux pane gives
   a shell inside the allocation; run srun there repeatedly. tmux
   keeps the allocation usable across ssh disconnects, which is the
   property the detached pattern buys on Anvil.

## Automation status (2026-08-11)

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
