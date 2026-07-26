# Anvil (Purdue RCAC) — environment profile (TEMPLATE — fill in on first session)

Machine facts, folder layout, and usage conventions for Anvil.
Applies to Charm++/Converse application and runtime projects. Keep
project status out of this file; it belongs in per-project memory.

## Machine and access

- Purdue Anvil, allocation x-asc050025. 128-core AMD nodes.
- Scheduler: Slurm (`srun --mpi=pmi2` launch idiom in existing sweeps).
- TODO: login host, filesystem layout ($HOME vs $PROJECT vs $SCRATCH),
  module loads for compilers/libfabric.

## Charm++ / Converse installations

- $HOME/charm_reconverse — Ritvik's reconverse-based Charm build
  (the build the FoF sweeps use). TODO: record branch/commit and build
  command on first inspection.
- TODO: other builds as they are created.

## Run idioms

- Sweeps: `srun --unbuffered --mpi=pmi2 -n {P} ./FoF3 -f $INPUT -d oct
  -u dist -b $BFACTOR +ppn {PPN}` (15 PEs/proc typical on 128-core
  nodes).
- TODO: interactive-job idiom, node counts, any comm-thread core
  accounting for the runtime in use.

## Data

- /anvil/projects/x-asc050025/x-rrao/globus_shared/ — shared datasets
  (lambb.00500 = 80M LAMBS snapshot).

## Hazards

- CmiMemoryUsage returns 0 under reconverse — FOF3STAT memory_MB lines
  are useless there; use the cache: line or Slurm accounting.
- TODO: accumulate on first sessions.
