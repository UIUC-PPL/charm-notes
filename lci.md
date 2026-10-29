# LCI — practitioner reference (API, protocols, launch, sharp edges)

Reference for LCI (Lightweight Communication Interface,
github.com/uiuc-hpc/lci), the transport under Reconverse. Written 2026-10-29
from LCI's docs (`docs/quickstart.md`, `tutorial.md`, `faq.md`,
`gpu_direct_rdma.md`) and a review of the source at master **`1287c59c`
(2026-10-23)**, version string `2.0.0-dev`.

Evidence labels used below:
- **[ran]** — confirmed by a probe program on a local OFI build
  (libfabric 1.17, provider `tcp;ofi_rxm`, `lcrun -n 2`, 2026-10-29).
- **[code]** — read from the source at the commit above; not exercised.
- **[docs]** — LCI's own documentation, not independently checked.

Line numbers drift. Reconverse builds its own pinned LCI under
`<build>/_deps/lci-src`, so check claims against that tree, not master.
Reconverse-side LCI lessons (`+lci_ndevices`, registration cost, the
eager/rendezvous cliff, idle stalls) live in `charm_best_practices.md`. This
file covers LCI itself.

## Contents

1. Mental model
2. Build
3. Bootstrap and launch
4. Resources, and what must be collective
5. Posting operations: status, retry, and the done-is-not-signalled trap
6. Protocol selection and size thresholds
7. Completion objects
8. Receive-side buffer ownership
9. Tags, rcomps and their limits
10. RMA and put-with-signal
11. Progress, threading, and the packet pool
12. GPU buffers
13. Failure handling
14. Configuration and diagnostics
15. Where LCI's own docs are wrong or stale
16. Source map

## 1. Mental model

- **Four parts.** The API (`lci.hpp`, namespace `lci`) has resource
  management, communication posting, completion checking, and explicit
  progress. Nothing moves unless someone calls `lci::progress()` on the
  right device. **[docs]**
- **Posting never blocks.** Every post returns a `status_t` that is *done*,
  *posted*, or *retry*. Completion is reported later through a completion
  object (`comp_t`): a synchronizer, counter, completion queue, handler, or
  graph. **[docs]**
- **Optional arguments.** Every function has an `_x` variant (the "OFF"
  idiom) for setting optional arguments by name, for example
  `lci::post_send_x(rank, buf, size, tag, comp).device(dev).mr(mr)()`.
  The trailing `()` performs the call; forgetting it compiles and silently
  does nothing. **[docs]**
- **Primitives.** Send/recv with tag matching, active messages (`post_am`,
  delivered to a remote completion object addressed by an `rcomp_t`), and
  RMA put/get. A put can carry a remote notification.
- **Generated header.** The public header is generated from Python specs in
  `src/binding/input/*.py` (`basic.py`, `comm.py`, `comp.py`, `network.py`,
  `collective.py`). Those files are the most readable statement of every
  argument and its default. **[code]**

## 2. Build

- **Toolchain.** C++17 compiler, Python ≥ 3.8, and CMake. The binding
  generator uses the walrus operator, and a missing
  `src/binding/generated/binding.cpp` at configure time means the Python
  is too old. The docs say CMake ≥ 3.12, but the vendored UCX code needs
  ≥ 3.21 (see `machines/anvil.md`, "LCI pin b5d9ea97"). **[docs]**
- **Backends.** `-DLCI_NETWORK_BACKENDS=ibv,ofi` (the default) builds every
  backend found; at run time the first available in that order wins.
  Override at run time with `LCI_ATTR_BACKEND=ofi|ibv`. Hosts with both
  stacks where only libfabric works (NCSA Delta, per the docs) need
  `-DLCI_NETWORK_BACKENDS=ofi`. **[docs+code]**
- **Compile-time options that matter (all [code], `CMakeLists.txt`):**
  - `LCI_DEBUG=OFF`. `LCI_Assert` is always active, but `LCI_DBG_Assert`
    and debug logging exist only in debug builds.
  - `LCI_USE_PERFORMANCE_COUNTER` defaults to the value of `LCI_DEBUG`, so
    production builds have no counters.
  - `LCI_USE_REG_CACHE=OFF`. Without it, every zero-copy or rendezvous
    message registers and deregisters memory. It cannot be enabled on
    macOS. See the registration sections of `charm_best_practices.md`.
  - `LCI_WITH_SHM=OFF`. The experimental intra-node shared-memory transport
    (§11) needs this switch.
  - `LCI_OPTIMIZE_FOR_NATIVE` is **ON** whenever the compiler accepts
    `-march=native`. A library built on a login node can die with SIGILL on
    compute nodes that have a different CPU. Turn it off for shared
    installs. Note too that `-march` can change floating-point results; see
    the FMA entry in `charm_best_practices.md`.
  - `LCI_USE_TCMALLOC=ON` only warns if tcmalloc is missing.
  - `LCI_PACKET_SIZE_DEFAULT=8192`, `LCI_PACKET_NUM_DEFAULT=65536`,
    `LCI_BACKEND_MAX_SENDS_DEFAULT=64`, `LCI_BACKEND_MAX_RECVS_DEFAULT=4096`,
    `LCI_BACKEND_MAX_CQES_DEFAULT=65536`. All can be overridden at run time
    (§14).
  - `LCI_USE_CUDA` / `LCI_USE_HIP` (mutually exclusive), and
    `LCT_PMI_BACKEND_ENABLE_MPI` for MPI bootstrap.
- **What an installed library was built with:** run `lci_info -v`. It
  prints the version (with commit hash), enabled backends, and the full
  CMake cache, so it answers "is the reg cache on?" without the build
  tree. **[ran]**

## 3. Bootstrap and launch

- **Backend order.** LCT tries PMI backends in order: by default
  `pmix,pmi2,pmi1,mpi,tcp,file,local` (CMake `LCT_PMI_BACKEND_DEFAULT`,
  overridden at run time by `LCT_PMI_BACKEND`). `pmi1` and `pmi2` (a
  vendored SLURM client), `tcp`, `file` and `local` are always compiled.
  `pmix` is compiled if found; `mpi` only on request. **[docs]**
- **Failure signature.** Every process reports rank 0 of 1: bootstrap fell
  through to `local`. Check with `LCT_LOG_LEVEL=info`, which logs each
  backend tried and the one chosen. **[docs+ran]**
- **Launchers.** Use `srun` on Slurm and `mpirun` with the matching PMI
  client (`PMI_ROOT` / `PMI2_ROOT` / `PMIx_ROOT`), or build with
  `LCT_PMI_BACKEND_ENABLE_MPI=ON` as a last resort. TACC Frontera's docs
  recommend the MPI backend with `ibrun`. **[docs]**
  - **Machine profiles override the generic docs on `--mpi=`.** LCI's docs
    suggest `srun --mpi=pmi2`. `machines/delta.md` says to use
    `--mpi=pmix`, not `pmi2`, and `machines/frontier.md` says plain `srun`,
    never `--mpi=pmi2`.
  - On Cray systems, `module load cray-pmi` *before configuring LCI*.
- **lcrun.** `lcrun -n N prog` uses the `file` backend
  (`LCT_PMI_BACKEND=file,local`).
  - **Since LCI #203 (`b5d9ea97`, 2026-09-20), each invocation gets a
    private `mktemp -d` directory** (`LCT_PMI_FILE_DIR`, `lcrun:14`) and
    removes it on exit. **[code+ran: nothing was created under `~/.tmp`]**
  - The shared-directory hazards in `charm_best_practices.md` ("lcrun
    bootstraps through one shared directory...") apply only to LCI pins
    older than that, or to the file backend used by hand.
  - With the file backend and no `LCT_PMI_FILE_DIR`, the directory is still
    `~/.tmp/lct_pmi_file-<SLURM_JOBID or 0>`
    (`lct/pmi/pmi_wrapper_file.cpp`), and the old rules hold.
- **Debugging without a launcher.** In separate terminals (or under gdb)
  set `LCT_PMI_BACKEND=file LCT_PMI_FILE_NRANKS=2` and run the program in
  each. **[docs]**
- **`tcp` backend.** For launchers that export rank variables but no PMI,
  such as torchrun. It needs `LCT_PMI_BACKEND=tcp`, `RANK`, `WORLD_SIZE`,
  and a matched `{LCT_,LCI_,}MASTER_ADDR`/`_PORT` pair. With torchrun, give
  LCI its own port. The timeout is `LCT_PMI_TCP_TIMEOUT_SEC` (default
  60). **[docs]**
- **Aborts.** `LCT_pmi_abort` (#209, 2026-10-20) aborts through the process
  manager for every PMI backend. **[code]**

## 4. Resources, and what must be collective

The hierarchy is runtime → net_context (one NIC / libfabric domain) →
device (queue pair(s) and completion queue) → endpoint. A packet pool and a
matching engine hang off the runtime. `g_runtime_init()` creates a default
of each. Pass `.runtime(rt)` to everything if a library needs its own
runtime alongside an application's.

- **Device allocation is collective and ordered.** **[code]**
  - `alloc_device` exchanges addresses with every rank during
    construction: an alltoall for IBV, an allgather for OFI.
  - It asserts that the peer's device uid matches its own
    (`backend_ibv.cpp:512`, `backend_ofi.cpp:334`). The uid is the creation
    order within the process.
  - So every rank must allocate devices in the same order and the same
    number. Device *k* on one rank talks only to device *k* on the others.
  - IBV creates one queue pair per peer per device, so QP memory grows as
    ranks × devices.
- **Remote completion handles (`rcomp_t`) are per-runtime indices.**
  - `register_rcomp(comp)` returns the next free slot of a per-runtime
    counter.
  - The runtime registers its own handlers first, so **the first user
    rcomp is 9** at this commit. **[ran]**
  - A sender uses its own number to address the receiver's object. This
    works only if every rank registers the same objects in the same order.
  - **Barrier after registering, before anyone sends.** A message that
    arrives before its slot exists trips
    `"Invalid remote handler ... Chances are that you didn't put a barrier
    after all processes registering their rcomps"`
    (`rhandler_registry.hpp:67`). **[code]**
  - To pin numbers explicitly, use `reserve_rcomps(n)` followed by
    `register_rcomp_x(comp).rcomp(slot)()`.
- **Free in the reverse order of allocation:** `free_comp`,
  `deregister_memory`, `free_device`, then `g_runtime_fina()`.
  `wait_drained()` blocks until a device has no pending posted
  operations. **[code]**

## 5. Posting operations: status, retry, and the done-is-not-signalled trap

```cpp
lci::status_t st;
do { st = lci::post_send(rank, buf, n, tag, comp); lci::progress(); }
while (st.is_retry());
if (st.is_done())        { /* finished NOW: comp will NOT be signalled */ }
else /* is_posted() */   { /* comp will be signalled later */ }
```

- **`done` means the operation finished during the call and the completion
  object is never signalled.** **[ran+code]**
  - Probe: an 8-byte `post_send` returned `done`, and `sync_test` on its
    synchronizer was still false after 1000 `progress()` calls.
  - The completion object is signalled only when the result is *posted*,
    or when `allow_done(false)` is set (`communicate.cpp:628`).
  - Small sends, small AMs and buffer-copy puts usually return `done`; a
    `post_recv` that matches an already-arrived eager message does too.
  - Code that always waits on the completion object therefore hangs, but
    only for small messages, which makes it look size-dependent.
  - Either branch on the status (as in the snippet above), or post with
    `.allow_done(false)` so that every completion goes through the
    completion object.
- **`retry`** means a resource was temporarily unavailable. Nothing was
  posted, and the caller still owns the buffer. **[code]**
  - The sub-codes are `retry_lock`, `retry_nopacket` (packet pool empty),
    `retry_nomem` (network send queue full; `net_max_sends` defaults to
    64), and `retry_backlog`.
  - `retry_backlog` means this endpoint already has queued operations to
    that rank. It preserves ordering: a new post is refused until the queue
    drains.
  - **Call `progress()` inside the retry loop.** Retries are cleared by
    progress, so a loop without it can spin forever.
- **Special completion values.** **[code]**
  - `COMP_NULL` makes the post block: retries go to the backlog queue
    instead of returning, and LCI spins `progress()` until the operation
    completes.
  - `COMP_NULL_RETRY` blocks until done but can still return `retry`.
  - The flags behind these are `allow_retry`, `allow_posted` and
    `allow_done`.
- **`done_backlog` / `posted_backlog`.** With `allow_retry(false)`, a full
  network queue pushes the operation into the endpoint backlog. The status
  is still in the done or posted category, so `is_done()` and `is_posted()`
  behave as usual. **[code]**
- **`comp_semantic`** (default `memory`): the completion means the local
  buffer may be reused. `network` means the network operation finished,
  which also disables the inject fast path. **[code]**

## 6. Protocol selection and size thresholds

From `set_protocol()` in `src/core/communicate.cpp`. **[code]**

- **inject:** outgoing, ≤ `max_inject_size` (default 64 B), memory
  semantic, host memory, and tag/rcomp fit the fast path (§9). Completes
  in the call.
- **eager_bcopy:** host memory, size ≤ `max_bcopy_size`. Copies into a
  packet, then returns `done` (memory semantic).
- **eager_zcopy:** a put/get with a registered `mr`, or anything past the
  conditions above that is not a send or AM. Registers on the fly if no
  `mr` was given.
- **rdv_zcopy:** a send or AM larger than `max_bcopy_size`, or any send or
  AM of GPU memory. RTS → RTR → RDMA write → FIN. Returns `posted`.
- **Size limits.**
  - `max_bcopy_size` = packet payload − `sizeof(tag_t)` − `sizeof(rcomp_t)`
    = **8116 B at the default 8192-byte packet**. **[ran]**
  - `LCI_ATTR_PACKET_SIZE=16384` raises it to 16308. **[ran]**
  - Query it with `lci::get_max_bcopy_size()`.
  - Converse's header comes out of this budget; see the 8096/8097 cliff in
    `charm_best_practices.md`.
- **Rendezvous completion** (`LCI_ATTR_RDV_PROTOCOL`): `auto_select` picks
  `writeimm` when the network supports put-with-immediate, else `write`
  plus a separate FIN message. **[code]**

## 7. Completion objects

All are `comp_t`, created with `alloc_*` and released with `free_comp`.
**[docs+code]**

- **Synchronizer (`alloc_sync`).** Like an MPI request.
  `alloc_sync_x().threshold(k)()` becomes ready after *k* signals.
  - `sync_test(comp, p_out)` / `sync_wait(comp, p_out)`: `p_out` must point
    to an array of `threshold` statuses, or be `nullptr`.
  - `sync_wait` calls `progress()` on the default device unless given
    `.device()` or `.do_progress(false)`. Waiting on a non-default device
    without passing it never completes.
- **Counter (`alloc_counter`).** `counter_get` / `counter_set`.
- **Completion queue (`alloc_cq`).** Lock-free LCRQ by default, default
  length 65536. `cq_pop` is non-blocking and returns `retry` when empty.
- **Handler (`alloc_handler(fn)`).** `fn(status_t)` runs *inside*
  `progress()`, on whichever thread called it. Keep it short. It must not
  block waiting for further progress on the same device; it can post (not
  wait).
- **Graph (`alloc_graph`).** A DAG of callbacks and operations: add nodes
  and edges, `graph_start`, then `graph_test`. A successful test resets the
  graph for reuse. Used to build non-blocking collectives; see
  `examples/nonblocking_barrier.cpp`.
- **Custom.** Subclass `comp_impl_t` and override `signal(status_t)`.
- **Status fields.** A `status_t` carries `error`, `rank`, `buffer`,
  `size`, `tag` and `user_context`; `.user_context(p)` on the post is
  echoed back.

## 8. Receive-side buffer ownership

- **Active messages, default.** The receiver gets a buffer from the
  runtime allocator (`malloc` by default) and owns it. Free it with the
  same allocator. `set_allocator()` swaps the allocator; Reconverse plugs
  in `CmiAlloc`, which is why pool lifetime matters there (see "Per-PE
  memory pools must outlive every network completion" in
  `charm_best_practices.md`). **[code]**
- **Active messages with `zero_copy_am(true)` deliver two kinds of buffer,
  and nothing in the status says which.** **[ran+code]**
  - An eager AM arrives **in a packet**: return it with
    `lci::put_upacket(buf)`.
  - A rendezvous AM (larger than `max_bcopy_size`, or GPU memory) arrives
    **in allocator memory** (`rendezvous.hpp:108`): `free` it.
  - Probe: a 16-byte AM landed inside the packet pool and a 100 KB AM on
    the heap; returning each the matching way ran clean.
  - Calling `put_upacket` on a heap buffer is undefined behaviour. Decide by
    size against `get_max_bcopy_size()`, keeping in mind that large tags or
    rcomps add 12 bytes on the sender side (§9) and that GPU sends always
    use rendezvous.
- **Sends with your own packet.** Get a buffer with `get_upacket()`, fill
  it, and send it; LCI returns the packet to the pool. Sending from a
  packet skips one copy. **[code]**
- **`post_recv` with an undersized buffer.** **[code]**
  - Eager path (≤ `max_bcopy_size`): the incoming payload is `memcpy`'d
    into the posted buffer **with no size check** (`rendezvous.hpp:33`),
    which silently corrupts the heap.
  - Rendezvous path: `LCI_Assert(rdv_ctx->size >= rts->size)` aborts.
  - Always post receives at least as large as the largest possible message.
  - `status.size` reports the actual size received.
- **`ANY_SOURCE` / `ANY_TAG`** are honoured by switching the matching
  policy to `tag_only`, `rank_only` or `none`. Senders choose a
  `matching_policy` too, and it must agree with what receivers post.
  **[code]**

## 9. Tags, rcomps and their limits

Run [ran] at the defaults:

- **`max_tag` = 2³²−1** even though `tag_t` is `uint64_t`.
- **`max_imm_tag` = 65535** and **`max_imm_rcomp` = 32767.** Query these
  with `get_g_runtime().get_attr_max_tag()` and the related attributes.
- **Fast path.** If the tag fits in 16 bits and the rcomp (or the matching
  engine's internal handle) in 15, both ride in the 32-bit immediate field.
- **Slow path.** Otherwise they are appended to the payload (12 bytes).
  That disqualifies the inject path and shrinks the usable eager
  size. **[code]**
- **Put with remote notification** requires the tag and rcomp to fit the
  immediate limits. **[code, per attribute docs]**

## 10. RMA and put-with-signal

- **Setup.** **[docs+code]**
  - `mr_t mr = register_memory(buf, size)` (per device;
    `.device(d)`), then `rmr_t r = get_rmr(mr)`.
  - Exchange `rmr_t` values out of band, for example with
    `lci::allgather`.
  - Then `post_put(rank, lbuf, n, comp, remote_disp, rmrs[rank])` or
    `post_get(...)`.
  - The displacement is relative to the remote region's base.
- **Put with signal.** `post_put_x(...).remote_comp(rc)()` signals the
  receiver's completion object through `rc`.
- **Get with signal is not implemented** (`communicate.cpp:142`
  asserts). **[code]**
- **Native put-with-immediate on Slingshot (CXI) needs all three of
  these:** **[code, `backend_ofi.cpp:220-228`]**
  - `LCI_ATTR_OFI_PROVIDER_NAME=cxi`, set explicitly. Auto-selecting cxi
    is not enough.
  - `FI_CXI_ENABLE_WRITEDATA=1`.
  - libfabric ≥ 2.5.
- **Without them, `support_putimm` is false and LCI falls back:**
  - The fallback is an RDMA write followed, on local completion, by a
    separate zero-byte send carrying the notification
    (`endpoint_inline.hpp:217`).
  - That costs an extra message per signalled put, and makes rendezvous
    auto-select `write` rather than `writeimm`.
  - The TCP provider with libfabric < 1.12 also disables putimm, with a
    warning.

## 11. Progress, threading, and the packet pool

- **What `progress()` does.** It drains the endpoints' backlog queues,
  polls *that device's* completion queue (up to `LCI_BACKEND_MAX_POLLS`=32
  entries), runs completion handlers inline, and re-posts receive
  packets. It returns `done` if it did anything, `retry` if idle. Traffic
  arriving on device *k* completes only through progress on device *k*.
  **[code]**
- **Threads and devices.** The usual pattern is one device per thread,
  each progressing its own device (`examples/pingpong_am_mt.cpp`). Several
  threads may share a device. **[docs+code]**
  - IBV uses a thread domain per QP by default.
  - OFI asks for `FI_THREAD_SAFE`, and can add its own trylocks via
    `LCI_NET_LOCK_MODE=send,recv,poll,mr,all`.
- **Packet pool budget.** **[code; the arithmetic is mine, not measured]**
  - By default every device shares one pool of 65,536 packets of 8 KB,
    registered at startup (about 512 MB pinned).
  - Each device keeps `net_max_recvs` (4096) receives pre-posted and
    refills below 80%.
  - Pre-posted receives alone therefore take about 4096 packets per
    device: **16 devices on the default pool leave nothing for sends,
    unexpected messages, or AM delivery.**
  - Unexpected eager sends also hold a packet each until matched.
  - Symptoms: `retry_nopacket` on senders, and the warning `"Deadlock
    alert! The device failed to refill the recvs"`
    (`device_inline.hpp:156`).
  - Relevant to large `+lci_ndevices` values; raise `LCI_ATTR_NPACKETS` or
    lower `LCI_ATTR_NET_MAX_RECVS`.
- **Shared memory.** An experimental intra-node transport has existed since
  #176 (2026-07-18), with registered eager sends routed through it since
  #204 (2026-09-20). **[code]**
  - It needs `LCI_WITH_SHM=ON` at build time and is controlled per device
    by `LCI_ATTR_SHM_ENABLE`.
  - It covers only messages that fit a slot (`shm_slot_size`, default
    128 B).
  - Default builds have none, so same-node traffic goes through the NIC
    (loopback).

## 12. GPU buffers

**[docs+code]**

- **Build.** `-DLCI_USE_CUDA=ON` or `-DLCI_USE_HIP=ON`, with
  `LCI_CUDA_ARCH` / `LCI_HIP_ARCH` (e.g. `gfx90a` for MI250X). The two are
  mutually exclusive.
- **Marking device memory.** Either register the buffer
  (`register_memory` detects device memory), or post with
  `.mr(lci::MR_DEVICE)`, or with `.mr(lci::MR_UNKNOWN)` to let LCI query
  the pointer on every call.
- **Device buffers always use zero-copy.** A send or AM of device memory
  always takes rendezvous; there is no eager path for it.
- **AMs cannot land in GPU memory.** Receive buffers come from the host
  packet pool or allocator, so you need a GPU-aware allocator for that.
- **Registration lifetime.** Charm's per-message device registration and
  release issues are in `charm_best_practices.md` (GPU zerocopy, and "A
  registration cache masks a missing deregister").

## 13. Failure handling

**[docs+code]**

- **Peer failures.** The OFI and IBV backends report asynchronous peer
  failures from `progress()` as `lci::peer_failure_error` (a
  `std::runtime_error`; `failed_rank()` names the peer). Other failures
  throw plain `std::runtime_error`, so catch both.
- **Batches.** `progress()` processes the whole batch of completions before
  throwing.
- **Teardown after a failure.** The device is marked failed, and endpoint
  teardown then becomes abortive: in-flight operations may never signal
  their completion objects.
- **No recovery.** Nothing repairs membership.

## 14. Configuration and diagnostics

- **Every runtime, device, net-context and completion attribute with a
  default can be set from the environment as `LCI_ATTR_<NAME>`**
  (`generate_binding.py:164`). Booleans accept textual values since #198.
  **[code+ran]**
- **Attributes most often useful:**
  - `LCI_ATTR_PACKET_SIZE`, `LCI_ATTR_NPACKETS`
  - `LCI_ATTR_NET_MAX_SENDS`, `LCI_ATTR_NET_MAX_RECVS`,
    `LCI_ATTR_NET_MAX_CQES`
  - `LCI_ATTR_RDV_PROTOCOL=auto_select|write|writeimm`
  - `LCI_ATTR_OFI_PROVIDER_NAME`
  - `LCI_ATTR_DEVICE_NAME` (verbs device or libfabric domain)
  - `LCI_ATTR_IBV_GID_IDX` (RoCE)
  - `LCI_ATTR_USE_REG_CACHE` (only if compiled)
  - `LCI_ATTR_SHM_ENABLE`
  - `LCI_ATTR_MAX_INJECT_SIZE`
- **Other environment variables:**
  - `LCI_ATTR_BACKEND=ofi|ibv` selects the backend.
  - `LCI_NET_LOCK_MODE` adds OFI locking.
  - `LCI_INIT_ATTACH_DEBUGGER=1` (or `sigstop`) pauses each process at
    init for gdb.
- **Logging.** `LCT_LOG_LEVEL=info` covers bootstrap and PMI.
  `LCI_LOG_LEVEL=info` prints every attribute value, the OFI provider
  chosen, and the rendezvous protocol selected. Narrow it with
  `LCI_LOG_WHITELIST` / `LCI_LOG_BLACKLIST`, and send it to a file with
  `LCI_LOG_OUTFILE`. **[ran]**
- **Performance counters** (needs `LCI_USE_PERFORMANCE_COUNTER=ON`).
  - `LCT_PCOUNTER_AUTO_DUMP=stderr` (or a filename; `%` becomes the rank)
    dumps them at exit, and `LCT_PCOUNTER_MODE=on-the-fly` records
    periodically.
  - The `communicate_retry_*`, `retry_due_to_backlog_queue`,
    `net_*_post_retry` and `shm_*` counters show where retries come from.
  - Parse the output with `tools/lct_parse_pcounter.py`.

## 15. Where LCI's own docs are wrong or stale (as of 1287c59c)

- **Rank queries.** The tutorial's resource-management snippet calls
  `lci::g_rank_me()` / `g_rank_n()`. Those are internal globals; the public
  functions are `get_rank_me()` / `get_rank_n()`. **[code]**
- **lcrun cleanup.** The FAQ and tutorial still say to clear
  `~/.tmp/lct_pmi_file-*` when lcrun hangs. Current lcrun does not use that
  directory (§3).
- **OFI provider variable.** An OFI warning tells you to set
  `LCI_OFI_PROVIDER_HINT_DEFAULT`, which is a CMake cache variable. The
  run-time knob is `LCI_ATTR_OFI_PROVIDER_NAME`.
- **CMake version.** The docs say 3.12, but 3.21 is needed (§2).
- **srun options.** The `srun --mpi=pmi2` advice conflicts with the Delta
  and Frontier profiles here (§3).

## 16. Source map

| Path | What is there |
|---|---|
| `src/binding/input/*.py` | Every API call, argument and default; the generated header comes from these |
| `src/api/lci.hpp` | Hand-written types: `status_t`, `errorcode_t`, `MR_*`, `COMP_NULL*`, `ANY_*`, allocator |
| `src/core/communicate.cpp` | `post_comm`: protocol selection, packets, immediate data, exit handling |
| `src/core/progress.cpp` | `progress()`, receive/send/write/read completion dispatch, failure batches |
| `src/core/rendezvous.hpp` | Matched send/recv, RTS/RTR/FIN, on-the-fly registration |
| `src/network/{ibv,ofi}/` | Backends; bootstrap exchange; provider and putimm detection |
| `src/network/endpoint_inline.hpp` | Backlog queue, putimm fallback |
| `src/network/device_inline.hpp` | Receive refill, the "Deadlock alert" warnings |
| `src/rhandler_registry/` | rcomp slots |
| `src/shm/` | Experimental shared-memory transport |
| `lct/pmi/` | Bootstrap backends (file, tcp, pmi1/2/x, mpi) |
| `examples/` | hello_world(_am), distributed_array (RMA), nonblocking_barrier (graph), pingpong_am_mt (device per thread) |
| `tests/unit/accelerator` | GPU-direct usage |
