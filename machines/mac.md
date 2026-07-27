# Kale's Mac — environment reference (cross-project)

Machine facts, folder layout, and usage conventions for this laptop.
Applies to all Charm++/Converse application and runtime projects. Keep
project status out of this file; it belongs in per-project memory.

## Machine and packages

- Apple Silicon (arm64), 8 cores, macOS (Darwin 24.x).
- Package manager: MacPorts (`/opt/local`), NOT Homebrew. Installs need
  Kale at a real terminal (`sudo` requires a TTY; the `!`-prefix shell in
  a Claude session has no TTY).
- libfabric is installed via MacPorts (needed by reconverse builds).
- `gh` is authenticated as `lvkale`, with push rights to
  charmplusplus/charm and the UIUC-PPL organization repositories.

## Shells (surprising — checked 2026-07-26)

- Account login shell is `/bin/zsh`, BUT Terminal.app has a preference
  override (`defaults read com.apple.Terminal Shell` = `/bin/tcsh`), so
  every Terminal window runs tcsh. Kale's interactive environment
  (PATH, aliases like `proj`) comes from `~/.cshrc`, NOT `~/.zshrc` /
  `~/.zprofile` — edits to zsh files silently do nothing in Terminal
  windows. zsh files DO apply to ssh sessions and Claude Code shells.
  csh/tcsh still ship with macOS.
- `~/.tcshrc` and `~/.bash_profile` are root-owned (conda init run under
  sudo at some point); editing them needs sudo.
- Java: MacPorts openjdk17 (arm64) is the `/usr/libexec/java_home`
  default, so plain `java` resolves to JDK 17 in every shell with no
  JAVA_HOME needed (symlinks exist in /Library/Java/JavaVirtualMachines).
  The old x86_64 Oracle Java 8 (JavaAppletPlugin) is still installed but
  no longer wins.
- Stale entry in `~/.cshrc` path: `~/software/charm/net-darwin-x86-smp/bin`
  (x86 charm, long gone).

## Charm++ / Converse installations

| Path | Runtime | Purpose |
|---|---|---|
| `~/software/clusterFinding/charm` (build `netlrts-darwin-arm8-smp`) | classic Converse, mainline main | paratreet2 laptop builds (`CHARM_HOME` points at the build dir) |
| `~/software/recharm/charm` (build `reconverse-darwin-arm8`) | reconverse, branch `reconverse-specific-build` | local reconverse testing; user-installed reconverse variant |
| `~/software/seedbalancing/charm` (build `reconverse-darwin-arm8`) | reconverse | seed-balancing runtime project |
| `~/software/charm/netlrts-darwin-arm8-smp` | classic | OLD, non-production build — never use for benchmarking |

recharm details: the reconverse checkout lives at
`~/software/recharm/charm/reconverse` and is consumed in place
(`--with-fetch-reconverse-dir`). To update reconverse independently:
pull or switch branches in that checkout, then `make` in the build
directory. Built `--with-production`. `lcrun` is at
`<build>/_deps/lci-src/lcrun`, not in `bin/`.

## Run idioms

- Classic Converse SMP (`netlrts`): `./charmrun ++local ./app +p<total PEs>
  ++ppn <PEs/process>`. `+pN` WITHOUT `++ppn` = N processes x 1 worker
  PE (default ppn is 1), NOT one process with N PEs — single-process
  multi-PE runs need `+pN ++ppn N`. One core PER PROCESS is consumed by a comm
  thread: P processes x N worker PEs occupies P*(N+1) cores. More than
  2 processes x 2 PEs oversubscribes the 8 cores; timings are then
  invalid (counts are fine).
- Reconverse: single process `./app +pe <PEs>`; multi-process
  `lcrun -n <procs> env DYLD_LIBRARY_PATH=<build>/lib ./app +pe <total
  PEs>`. `+pe` is the TOTAL across processes. No comm thread — so
  unlike classic SMP, all 8 cores can be worker PEs: 3 procs x 2
  workers (lcrun -n 3, +pe 6), 4 x 2 (full load, some OS
  interference), or 7-8 procs x 1 worker are all valid TIMING
  configurations on this laptop (Kale, 2026-07-25). Classic netlrts
  remains limited to 2 procs x 2 PEs for timing.
- After any killed or timed-out multi-process run, orphaned node
  processes accumulate: `pkill -9 -f <app>; pkill -9 -f charmrun`, then
  check `uptime` before trusting any timing (load averaged 192 once from
  accumulated orphans).

## macOS platform hazards (details in
~/software/charm-notes/charm_best_practices.md)

- SIP strips DYLD_LIBRARY_PATH under lldb; set it inside lldb via
  `settings set target.env-vars ...`.
- Apple clang defaults to C++98; charm darwin arch files must add
  `-std=gnu++17` (upstreamed for reconverse-darwin-arm8).
- libfabric on macOS has no shared-memory provider: local cross-process
  traffic uses TCP loopback (~45 us one-way). Grainsize conclusions from
  Mac cross-process runs do not transfer to Linux clusters.
- Piped stdout is block-buffered: a crash discards unflushed output; get
  ground truth under lldb, not from what printed.

## Project folders

- `~/software/clusterFinding/` — paratreet2 (public, UIUC-PPL) and
  siblings: `unionfind`, `htram`, old `paratreet` (comparison oracle),
  inputs, design docs.
- `~/software/recharm/` — reconverse-based charm (above) and any
  reconverse-stack clones for local reconverse testing.
- `~/software/seedbalancing/` — seed balancing in reconverse; design doc
  SEEDLB_DESIGN.md.
- `~/software/charm-notes/` — clone of UIUC-PPL/charm-notes (the shared
  practitioner notes + this machine profile); pull before appending,
  push after. Old copies in ~/software/tutorialcharmclaude/notes/ are
  pointer stubs.
- `~/software/DiffusionGraphfiles/` — deeper seed-balancing handoff notes.
