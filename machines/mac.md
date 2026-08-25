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
| `~/software/charm-sumdbytes/charm` (build `netlrts-darwin-arm8`) | classic, upstream main | fresh clone for the .sumd message-bytes work (charm#3937); built with `-DTRACING=1` |

**`~/software/recharm` caught up to upstream 2026-08-24; the 2026-08-11
drift warning is RESOLVED.** charm is at origin/reconverse-specific-build
tip `90ef159b9` + one local commit (`e606c3318`, qdbench cliff-diagnosis
knobs — candidate to push); the embedded reconverse is at origin/main tip
`36ab139` + one local commit (`c0d0d9f`, tests/abort_peer probe —
candidate to push/PR). The old "fresh clone does not configure" drift is
gone: reconverse main gained `include/persistent.h` (reconverse#192), and
a from-scratch `./build charm++ reconverse-darwin-arm8 --with-production
--with-fetch-reconverse-dir=$PWD/reconverse` of the upstream tip builds
and passes smoke (hello 1darray + all 19 pingpong phases, single- and
multi-process) on this Mac. Our local trace-summary commit turned out
byte-identical to upstream `90ef159b9` — already upstream, dropped on
rebase. Fallbacks kept until further confidence:
`~/software/recharm/charm/reconverse-darwin-arm8.bak-20260824` (the
pre-catch-up build) and the worktree `~/software/recharm/charm-upstream-test`
(upstream tip + its own fresh build) — delete both when no longer needed.

**Record-replay on reconverse (2026-08-25): WORKS.** Build at
`~/software/recharm/charm/reconverse-darwin-arm8-replay` (charm-on-
reconverse with `--enable-tracing --enable-replay -g`; production build
unchanged). Recording idiom on reconverse REQUIRES per-record flushing --
`./app +pe N +record +recplay-logsize 129` -- because reconverse's exit
path never runs the watcher destructors (classic flushes there); replay
is plain `+replay`. Multi-process record/replay also works (lcrun).
Reconverse-side prerequisites are PR charmplusplus/reconverse#207; the
charm-side record-replay repairs are on reconverse-specific-build.

**Traps in the caught-up tree (2026-08-24):**
- `examples/charm++/hello/1darray/hello.C` was POLLUTED UPSTREAM by
  `9e48ce995` ("merge reconverse changes with lb"): `CkExit()` inside the
  Hello constructor and the init callback commented out, so it prints
  "Hello 0 created" and exits 0 — looks like a runtime break but is the
  example itself. Don't use it as a smoke test until reverted upstream;
  use benchmarks/charm++/pingpong (19 phases, unpolluted).
- Binaries need `DYLD_LIBRARY_PATH=<build>/lib` even SINGLE-process now:
  libreconverse is a dylib and charmc-linked binaries carry no LC_RPATH
  ("Library not loaded: @rpath/libreconverse.dylib" without it).

recharm details: the reconverse checkout lives at
`~/software/recharm/charm/reconverse` and is consumed in place
(`--with-fetch-reconverse-dir`). To update reconverse independently:
pull or switch branches in that checkout, then `make` in the build
directory. Built `--with-production`. `lcrun` is at
`<build>/_deps/lci-src/lcrun`, not in `bin/`.

## Which runtime to build against (Kale, 2026-08-10)

Use **reconverse** by default for paratreet2 laptop work; classic Converse
only as a second opinion when something looks runtime-specific. Anvil and
Frontier both run reconverse, and this project's runtime-specific defects
(the CkWaitQD hang, the array-map race) appeared only there. Validating on
classic and deploying on reconverse leaves that gap open.

Reconverse-side stack on this laptop, already built and consistent:

| path | what |
|---|---|
| `~/software/recharm/charm/reconverse-darwin-arm8` | the charm build (`CHARM_HOME`) |
| `~/software/recharm/{htram,unionfind}` | siblings built against it |
| `~/software/recharm/paratreet2` | the clone that links those siblings |

The sibling libraries are what pin this: paratreet2's Makefile links
`../unionfind` and `../htram` relative to its own directory, so a checkout
under `clusterFinding/` links the CLASSIC-built siblings and cannot simply
be pointed at the reconverse charm. Build in the `recharm/` clone instead.

Easy to drift without noticing, because the run idioms differ and both
"work": classic is `./charmrun ++local ./app +p<total> ++ppn <per-proc>`,
reconverse is `./app +pe <total>` with no charmrun, and multi-process
reconverse is `lcrun -n <procs> env DYLD_LIBRARY_PATH=<build>/lib ./app
+pe <total>` (lcrun lives at `<build>/_deps/lci-src/lcrun`, not `bin/`).

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
