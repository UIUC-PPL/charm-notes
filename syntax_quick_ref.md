# Charm++ Syntax Quick Reference

Compact lookup for writing new programs. Assumes concepts from `concepts_taught.md`.

---

## File Structure

```
foo.ci       → charmc foo.ci → foo.decl.h + foo.def.h
foo.C        → #include "foo.decl.h" at top, #include "foo.def.h" at bottom
```

## `.ci` File Skeleton

```cpp
mainmodule modulename {

  mainchare Main {
    entry Main(CkArgMsg *m);
    entry void someEntryMethod(int x);
  };

  chare Worker {
    entry Worker(int id, CProxy_Main mainProxy);
    entry void doWork(int n, double data[n]);
  };

};
```

- One `mainmodule` per program; other modules use `module` keyword.
- All constructors must be `entry`.
- Array parameter: size variable must immediately precede the array.

## `.C` File Skeleton

```cpp
#include "modulename.decl.h"

class Main : public CBase_Main {
public:
  Main(CkMigrateMessage *m) {}
  Main(CkArgMsg *m) {
    // program entry point
    delete m;
    CkExit();
  }
  void someEntryMethod(int x) { ... }
};

class Worker : public CBase_Worker {
public:
  Worker(CkMigrateMessage *m) {}
  Worker(int id, CProxy_Main mainProxy) {
    // constructor body
  }
  void doWork(int n, double *data) {
    // array arrives as pointer; valid for duration of this call
  }
};

#include "modulename.def.h"
```

## Creating Chares

```cpp
// Returns proxy; chare created asynchronously on a PE chosen by RTS
CProxy_Worker w = CProxy_Worker::ckNew(id, thisProxy);

// Create and discard proxy (fire-and-forget)
CProxy_Worker::ckNew(id, thisProxy);
```

## Invoking Entry Methods

```cpp
CProxy_Worker w = ...;
w.doWork(n, buf);          // non-blocking; buf is copied into message

// Self-invocation:
thisProxy.someEntryMethod(x);   // enqueued in scheduler — executes later
someEntryMethod(x);             // direct call — executes immediately (synchronous)
```

## Key Runtime Calls

```cpp
CkExit();                  // terminate all PEs (use instead of exit())
CkAbort("msg");            // abort with message
CkMyPe()                   // int: current PE index (0-based)
CkNumPes()                 // int: total PE count
CkWallTimer()              // double: wall-clock seconds
CkPrintf("fmt", ...)       // thread-safe printf
ckout << x << endl;        // thread-safe iostream
```

## Build & Run

```bash
# Build
charmc foo.ci
charmc -c foo.C
charmc -language charm++ -o foo foo.o

# Run — single PE, no charmrun (best for grainsize experiments)
./foo +p1 <args>

# Run — local multicore
./charmrun ++local ./foo +p4 <args>

# SMP mode: N processes, K worker threads each (N*K total PEs + N comm threads)
./charmrun ++local ./foo +p8 ++ppn 4
```

## Makefile Pattern

```makefile
CHARMC=/path/to/charm/bin/charmc $(OPTS)
OBJS = foo.o

all: foo

foo: $(OBJS)
	$(CHARMC) -language charm++ -o foo $(OBJS)

foo.decl.h: foo.ci
	$(CHARMC) foo.ci

foo.o: foo.C foo.decl.h
	$(CHARMC) -c foo.C

clean:
	rm -f *.decl.h *.def.h *.o foo charmrun
```

## Common Patterns

### Counting callbacks (correct termination)
```cpp
class Main : public CBase_Main {
  int pending;
public:
  Main(CkArgMsg *m) {
    int K = ...;
    pending = K;
    for (int i = 0; i < K; i++)
      CProxy_Worker::ckNew(i, thisProxy);
    delete m;
  }
  void done() {                          // entry method
    if (--pending == 0) CkExit();
  }
};
```

### Indexed results without search
```cpp
// At creation: pass index i to each chare
CProxy_Worker::ckNew(i, thisProxy);

// Worker calls back:
mainProxy.result(myIndex, value);

// Main stores directly:
void result(int idx, double val) {
  results[idx] = val;
  if (--pending == 0) { /* print results in order */ CkExit(); }
}
```

### Batched work (grainsize control)
```cpp
// .ci
entry void processBatch(int batchIdx, int n, long data[n], CProxy_Main m);
entry void batchDone(int batchIdx, int n, int results[n]);

// Main: ceil(K/M) chares, each gets M items
int numChares = (K + M - 1) / M;
for (int i = 0; i < numChares; i++) {
  int lo = i * M;
  int sz = (lo + M <= K) ? M : (K - lo);
  CProxy_Worker::ckNew(i, sz, data + lo, thisProxy);
}

// Worker returns batch index for direct indexing (no search)
mainProxy.batchDone(batchIdx, batchSize, results);
```

---

## SDAG (Structured Dagger)

### `.ci` structure with SDAG

Entry method bodies go inside the `.ci` declaration. The method ends with a semicolon
after the closing brace.

```ci
array [1D] Foo {
  entry Foo();
  entry void passValue(int stepDist, int val);   // first int = reference number
  entry void start() {
    for (dist = 1; dist < N; dist <<= 1) {
      if (thisIndex + dist < N) serial {
        proxy[thisIndex + dist].passValue(dist, myVal);
      }
      if (thisIndex >= dist)
        when passValue[dist](int ref, int val) serial {
          myVal += val;
        }
    }
    serial {
      // print, contribute, etc.
    }
  };
};
```

### C++ class with SDAG

```cpp
class Foo : public CBase_Foo {
  int myVal, dist;   // dist = SDAG for-loop variable; must be member
public:
  Foo_SDAG_CODE      // no semicolon; must be inside class body

  Foo() : myVal(thisIndex + 1), dist(0) {}
  Foo(CkMigrateMessage* m) {}
};
```

### Reference number rules

- First `int` param of an entry method is the implicit reference number.
- Send: `proxy[i].recv(step, data)` — first arg is the tag.
- Wait: `when recv[step](int ref, int data)` — `step` is a member variable.
- SDAG buffers messages whose tag doesn't match yet; delivers them when the `for` loop
  reaches that step.

### SDAG `if` with member-variable condition

When the SDAG `if` condition depends on work done in a preceding `serial` block, store
the result in a member variable (local variables don't survive across SDAG constructs):

```ci
serial {
  amLeft  = (thisIndex % 2 == 0) && (thisIndex + 1 < N);
  amRight = (thisIndex % 2 == 1) && (thisIndex > 0);
  if (amLeft)  proxy[thisIndex + 1].send(round, val);
  if (amRight) proxy[thisIndex - 1].send(round, val);
}
if (amLeft || amRight)
  when recv[round](int r, int v) serial { ... }
```

`amLeft` and `amRight` must be declared as class members, not local variables, because the
SDAG `if` evaluates them after the `serial` block has returned.

---

## 2D Chare Arrays and Load Balancing

### 2D array declaration

```ci
array [2D] Foo {
  entry Foo();
  entry void bar(int x);
};
```

Inside the chare: `thisIndex.x`, `thisIndex.y`. Access a neighbor: `proxy(i, j).bar(x)`.

### Creating and broadcasting to 2D arrays

```cpp
CProxy_Foo arr = CProxy_Foo::ckNew(m, n);  // m x n array
arr.bar(x);                                  // broadcast to all elements
arr(i, j).bar(x);                           // single element
```

### pup() for migration

```cpp
void pup(PUP::er& p) {
  p | member1;
  p | member2;
  p | vec;     // std::vector supported
}
```

Every member variable must appear. Called for both pack and unpack; `PUP::er` knows which
direction. Omitting a field causes silent corruption — no error is reported.

### AtSync / ResumeFromSync in SDAG

```ci
// .ci — entry declaration
entry void ResumeFromSync();

// .ci — inside SDAG entry body (call every N iterations, not every iteration)
if (iteration % 10 == 9) serial { AtSync(); }
if (iteration % 10 == 9)
  when ResumeFromSync() serial { }
```

```cpp
// .C — constructor
usesAtSync = true;   // must be set before first AtSync() call
```

```makefile
# Makefile — link LB module
$(CHARMC) -module GreedyRefineLB -module RefineLB -o foo foo.o
```

```bash
# Runtime — select strategy
./charmrun ++local +p4 ++ppn 2 ./foo args +balancer GreedyRefineLB
```

---

## Threaded Entry Methods

### `.ci` declarations

```ci
chare Foo {
  entry Foo(int n, CkFuture parentFut);   // plain constructor (NOT [threaded])
  entry [threaded] void compute();         // threaded work method
  entry [sync] ValMsg* getValue();         // sync: blocks caller, returns message
  entry void sendResult(CkFuture replyTo); // regular: fulfils a future
};
```

`[threaded]` constructors are rejected by charmc. Use a plain constructor that stores
arguments and sends `thisProxy.compute()` to self.

### CkFuture — one-shot channel

```cpp
// Caller (inside a [threaded] method):
CkFuture f = CkCreateFuture();
remoteProxy.method(f);                  // pass future to responder
ValMsg* m = (ValMsg*)CkWaitFuture(f);  // suspend until fulfilled
// use m; delete m;

// Responder (any entry method):
void method(CkFuture replyTo) {
    ValMsg* reply = new ValMsg;
    reply->value = ...;
    CkSendToFuture(replyTo, reply);     // fulfils future, wakes waiting thread
}
```

Use `CkFuture` (struct: id + PE) as the parameter type — NOT `CkFutureID` (unsigned
short only; breaks cross-PE delivery).

**Fire multiple futures before waiting:**
```cpp
CkFuture f1 = CkCreateFuture(), f2 = CkCreateFuture();
proxy.method(n-1, f1);             // both requests sent before either wait
proxy.method(n-2, f2);
ValMsg* m1 = (ValMsg*)CkWaitFuture(f1);
ValMsg* m2 = (ValMsg*)CkWaitFuture(f2);
// m1 and m2 both available here
```

### CthSuspend / CthAwaken — raw thread control

```cpp
// Member variables:
CthThread waitingThread;
int       receivedVal;

// In [threaded] method:
waitingThread = CthSelf();              // capture thread handle
asyncProxy.request(thisIndex);          // non-blocking send
CthSuspend();                           // yield; scheduler runs
// resumes here after CthAwaken
use(receivedVal);

// In regular entry method (the responder):
void notify(int val) {
    receivedVal = val;
    CthAwaken(waitingThread);           // re-queue the suspended thread
}
```

### `[sync]` — blocking request-reply

```ci
// .ci
entry [sync] ValMsg* getValue();
```

```cpp
// Callee (.C):
ValMsg* getValue() {
    ValMsg* r = new ValMsg;
    r->value = value;
    return r;                           // no CkSendToFuture needed
}

// Caller (must be inside a [threaded] method):
ValMsg* m = remoteProxy.getValue();     // blocks until return
use(m->value); delete m;
```

### LB phase pattern with threaded methods

```ci
// .ci — outer SDAG loop
entry void start() {
    for (phase = 0; phase * lbPeriod < maxIter; phase++) {
        serial {
            int s = phase * lbPeriod;
            int e = min(s + lbPeriod, maxIter);
            thisProxy[thisIndex].runPhase(s, e);   // start thread
        }
        when phaseDone() serial { AtSync(); }       // thread has returned; safe
        when resumeFromSync() serial { }
    }
    serial { contribute(allDone); }
};

entry [threaded] void runPhase(int s, int e);
entry void phaseDone();
entry void resumeFromSync();
```

```cpp
// .C — threaded phase
void runPhase(int s, int e) {
    for (int iter = s; iter < e; iter++) {
        CkFuture f = CkCreateFuture();
        neighborProxy.sendValue(f);
        ValMsg* m = (ValMsg*)CkWaitFuture(f);
        // use m; delete m;
    }
    thisProxy[thisIndex].phaseDone();   // signal: thread done, SDAG may AtSync
}

// Bridge from LB framework to SDAG:
void ResumeFromSync() {
    thisProxy[thisIndex].resumeFromSync();
}

// pup() only captures persistent state (thread is gone at AtSync time):
void pup(PUP::er& p) { p | value; p | phase; }
```

---

## Chare Groups (added 2026-07-14, from the seed-balancing project)

```ci
group Stats {
  entry Stats();
  entry void dump();        // plain methods need no entry; call via ckLocalBranch()
};
readonly CProxy_Stats statsProxy;
```

```cpp
/* readonly */ CProxy_Stats statsProxy;

class Stats : public CBase_Stats {   // one branch per PE
  long count_;                        // per-PE state lives HERE, not in globals
public:
  Stats() : count_(0) {}
  void increment() { ++count_; }      // synchronous, local-branch only
  void dump() { CkPrintf("[%d] %ld\n", CkMyPe(), count_); }
};

// create (typically in mainchare ctor):
statsProxy = CProxy_Stats::ckNew();
// local branch, synchronous access:
statsProxy.ckLocalBranch()->increment();
// broadcast to all branches / send to one PE's branch:
statsProxy.dump();
statsProxy[pe].dump();
```

- Groups created in the mainchare constructor (and readonlies set there) are
  guaranteed available on every PE before any other entry method runs.
- PE p's branch of every group lives on PE p: `groupProxy.ckLocalBranch()`
  is the idiomatic per-PE state holder (see best-practices file: never use
  bare globals in Charm++ programs).

## Reductions (group/array members -> one target)

```ci
mainchare Main {
  entry [reductiontarget] void done(long total);   // typed target
};
```

```cpp
// contributor side (each branch/element):
contribute(sizeof(long), &myCount, CkReduction::sum_long,
           CkCallback(CkReductionTarget(Main, done), mainProxy));
// bare synchronization (no data):
contribute(CkCallback(CkReductionTarget(Main, ready), mainProxy));
```

Built-in reducers: sum_/product_/max_/min_ per type, logical_*, bitvec_*,
set, concat, random, statistics. **There is NO minloc/argmin builtin**, and
tuple reductions reduce each element INDEPENDENTLY (cannot carry "the PE of
the min"). For argmin over (value, pe), write a custom reducer:

```ci
initnode void registerMinLoc(void);   // runs once per process at startup
```

```cpp
struct ValLoc { double v; int pe; };
static CkReduction::reducerType minLocType;

static CkReductionMsg* minLoc(int n, CkReductionMsg** msgs) {
  ValLoc best = *(ValLoc*)msgs[0]->getData();
  for (int i = 1; i < n; ++i) {
    ValLoc c = *(ValLoc*)msgs[i]->getData();
    if (c.v < best.v || (c.v == best.v && c.pe < best.pe)) best = c;  // tie-break
  }                       // keep it associative+commutative for any tree shape
  return CkReductionMsg::buildNew(sizeof(ValLoc), &best);
}
void registerMinLoc() { minLocType = CkReduction::addReducer(minLoc); }

// use: contribute(sizeof(ValLoc), &mine, minLocType, cb);
// callback target receives CkReductionMsg*: (ValLoc*)msg->getData(); delete msg;
```

Reduction callback can target the group proxy itself
(`CkCallback(CkIndex_Grp::result(NULL), thisProxy)`) — result is then
broadcast to every branch, no mainchare round-trip.

## Library-style modules: completion via CkCallback

```ci
// library .ci: no compile-time reference to any client chare
entry void build(CkCallback done);
```

```cpp
// library: signal completion (per-branch empty reduction into client's cb)
void Grp::finishedHere(CkCallback done) { contribute(done); }
// client: passes where the signal should go
libProxy.build(CkCallback(CkReductionTarget(Main, ready), thisProxy));
```

Client needs only `extern module Lib;` in its .ci + the library header.

## Misc additions

```cpp
#include <pup_stl.h>   // enables std::vector<T> etc. as entry-method params
entry void recv(int n, std::vector<int> data);   // marshalled by value

// plain-chare divide&conquer: self-destruct after last send
void respond(long v) { parentCB.send(...); delete this; }

// converse-level programs build with:  charmc -language converse++ foo.C
```

---

## Nodegroups (added 2026-07-18, from the paratreet2/FoF project)

```ci
nodegroup NodeCache {          // ONE branch per PROCESS (SMP node), not per PE
  entry NodeCache();
  entry void merge(const CkCallback&);
  entry [exclusive] void update(int k);   // exclusive: one-at-a-time per branch
};
```

- `group` = one branch per PE; `nodegroup` = one branch per OS process
  (in non-SMP builds they coincide). Nodegroup entry methods may execute
  on ANY PE of the process — two non-exclusive entries can run
  concurrently on different PEs, so guard shared state with a mutex or
  declare entries `[exclusive]`.
- `proxy.ckLocalBranch()` on a nodegroup works from any PE of the
  process: the idiomatic home for process-level shared state (caches,
  lookup tables). Group branches may read a nodegroup branch's data
  directly after a synchronization point (reduction/barrier).
- Typical pairing: per-PE `group` for parallel work + per-process
  `nodegroup` for the shared/merged result.

## Templated chares (templated modules)

```ci
// library .ci
template <typename Data> array [1d] Subtree {
  entry void upwardPass(const CkCallback&);
  template <typename Visitor> entry void startDual(Visitor v);
};
```

Client apps must instantiate every (chare, Data[, Visitor]) combination
they use with explicit `extern entry` lines in their own .ci:

```ci
extern module paratreet;
extern entry void Subtree<MyData> upwardPass(const CkCallback&);      // non-templated entry of templated chare: accepted
extern entry void Partition<MyData> startDown<MyVisitor>(...);        // doubly-templated
```

Missing an instantiation line = link errors on the generated code.
Runtime registration of template instantiations uses
`CkIndex_Subtree<T>::__register(name, size)` — **the name `const char*`
is stored by pointer for program lifetime**: never pass `.c_str()` of a
temporary (classic dangling bug); build the string and leak it.

## Misc (2026-07-18)

```cpp
// Block a [threaded] method until an entry/collective completes:
proxy.doWork(CkCallbackResumeThread());        // returns when callback fires
CkReductionMsg* r; proxy.reduceIt(CkCallbackResumeThread((void*&)r)); // with data

// Pass a polymorphic PUP::able functor to an entry method:
entry void apply(CkReference<MyPupableBase>, const CkCallback&);

// .ci files are run through cpp: #ifdef FEATURE / #endif works in them
// (and `unifdef -UFEATURE` cleanly strips such blocks from .ci too).
```
