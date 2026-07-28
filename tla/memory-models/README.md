# Memory-model litmus tests

This directory contains a small, executable TLA+ model used to explain one
specific ordering problem: a processor stores an announcement and then loads
shared data, while another processor stores an update and then loads that
announcement.

The model answers a deliberately narrow question:

> Can both processors perform their store, continue to their load, and still
> read the old value written by the other processor?

It is a didactic **Store-Buffering (SB) litmus test**, not a complete
formalization of the architecture. Its value comes from reducing the
LightEpoch race to the smallest execution that still contains the relevant
StoreLoad ordering.

## Table of contents

- [The common Store-Buffering test](#the-common-store-buffering-test)
- [The four memory-order pairs](#the-four-memory-order-pairs)
  - [Why StoreLoad matters to LightEpoch](#why-storeload-matters-to-lightepoch)
  - [Architecture and compiler differences](#architecture-and-compiler-differences)
- [TLA+ representation](#tla-representation)
  - [Store forwarding](#store-forwarding)
  - [Asynchronous propagation](#asynchronous-propagation)
- [x86-TSO](#x86-tso)
  - [FIFO store buffers](#fifo-store-buffers)
  - [What "StoreLoad reordering" means here](#what-storeload-reordering-means-here)
  - [Violating execution without `MFENCE`](#violating-execution-without-mfence)
  - [Reproducing the behavior with threads](#reproducing-the-behavior-with-threads)
    - [Pending-buffer trace for the minimal SB test](#pending-buffer-trace-for-the-minimal-sb-test)
    - [Pending-buffer trace for the LightEpoch bug](#pending-buffer-trace-for-the-lightepoch-bug)
  - [`MFENCE`](#mfence)
  - [Locked read-modify-write operations](#locked-read-modify-write-operations)
  - [Why a release store is insufficient](#why-a-release-store-is-insufficient)
  - [Scope of the x86 model](#scope-of-the-x86-model)
- [Connection to LightEpoch](#connection-to-lightepoch)
- [Running the models](#running-the-models)
- [Appendix: asymmetric barriers in RCU, GCs, and runtimes](#appendix-asymmetric-barriers-in-rcu-gcs-and-runtimes)
  - [The recurring optimization](#the-recurring-optimization)
  - [Linux `membarrier`](#linux-membarrier)
  - [Userspace RCU](#userspace-rcu)
  - [.NET garbage collection and runtime synchronization](#net-garbage-collection-and-runtime-synchronization)
  - [HotSpot safepoints and handshakes](#hotspot-safepoints-and-handshakes)
  - [Windows `FlushProcessWriteBuffers`](#windows-flushprocesswritebuffers)
  - [Relationship to the asymmetric LightEpoch model](#relationship-to-the-asymmetric-lightepoch-model)
  - [Correctness requirements and traps](#correctness-requirements-and-traps)

## The common Store-Buffering test

The module executes the following program, starting with `x = 0` and `y = 0`:

| Processor `t1` | Processor `t2` |
|---|---|
| `x := 1` | `y := 1` |
| optional barrier | optional barrier |
| `r1 := y` | `r2 := x` |

Under sequential consistency, every operation participates in one global order
that preserves each processor's program order. Consequently, `r1 = 0` and
`r2 = 0` cannot both occur:

1. If `t1`'s store is globally before `t2`'s load, then `r2` must read `1`.
2. Otherwise, `t2`'s load is before `t1`'s store.
3. Applying the same reasoning on the other side requires `t1`'s load to be
   before `t2`'s store.
4. Combining those requirements produces an impossible cycle:

   ```text
   t1 store x < t2 load x < t2 store y < t1 load y < t1 store x
   ```

Real processors do not generally provide sequential consistency for ordinary
loads and stores. A processor may place a store in a private buffer and continue
executing before that store is visible to other processors. Its own subsequent
load can therefore pass the buffered store when the load addresses a different
location.

The invariant named `SequentiallyConsistent` in this module checks only this
one SC-forbidden outcome:

```tla
Done => ~(r1 = 0 /\ r2 = 0)
```

It does **not** claim that every behavior admitted by the module is
sequentially consistent.

## The four memory-order pairs

Memory-order names describe two operations in **program order**. For example,
StoreLoad means the source program performs a store and then a load:

```text
STORE A
LOAD  B
```

A reordering means that other processors can observe an outcome that would
require those operations to occur in the opposite order under sequential
consistency. It does not necessarily mean the CPU literally swaps the
instructions. Store buffers, speculative execution, cache propagation, and
other implementation details can produce the same externally visible result.

There are four load/store pairs:

| Ordering | Program order | Meaning of the relaxation |
|---|---|---|
| **LoadLoad** | `LOAD A; LOAD B` | The value loaded from `B` can reflect an event that is not yet reflected by the load from `A`. |
| **LoadStore** | `LOAD A; STORE B` | Other processors can observe the store to `B` without the ordering implied by the earlier load from `A`. |
| **StoreStore** | `STORE A; STORE B` | Another processor can observe the store to `B` before it observes the store to `A`. |
| **StoreLoad** | `STORE A; LOAD B` | The load from `B` can complete while the store to `A` is still not visible to other processors. |

These names describe ordering guarantees, not every possible interaction.
Same-address accesses, dependencies, atomic operations, memory types, and cache
coherence add further rules. The clearest examples therefore use distinct
ordinary memory locations `A` and `B`.

### Why StoreLoad matters to LightEpoch

The LightEpoch reader performs this pair:

```text
STORE localCurrentEpoch := CurrentEpoch   // announce reader
LOAD  objectPointer                       // begin protected access
```

If StoreLoad ordering is absent, the pointer load can proceed while the epoch
announcement remains buffered. A reclaimer on another processor can scan the
reader's slot, still observe `0`, conclude that the reader is absent, and free
the object that the reader is about to use.

A release store does not close this window. Release semantics order operations
that precede the release before the store; they do not order the release store
before a later load. LightEpoch needs a full StoreLoad barrier, a suitable
sequentially consistent atomic operation, or a correctly implemented
process-wide barrier on the reclaimer side.

### Architecture and compiler differences

For ordinary cacheable memory, x86-TSO preserves the principal LoadLoad,
LoadStore, and StoreStore orderings but permits the StoreLoad outcome through
its store-buffer behavior. ARM64 has a weaker model and can admit all four
classes when no dependency, atomic operation, or appropriate barrier supplies
the missing order.

CPU memory ordering is separate from compiler or JIT reordering. A compiler may
move, combine, or remove memory operations unless the programming language
requires them to remain observable. Correct concurrent code must therefore
provide both:

1. **language/compiler ordering**, through the appropriate volatile or atomic
   primitives; and
2. **hardware ordering**, through primitives whose generated instructions
   provide the required architectural guarantee.

## TLA+ representation

The module uses these principal state variables:

| Variable | Meaning |
|---|---|
| `buf[p]` | Processor `p`'s private sequence of buffered stores |
| `mem` | Memory visible to the other processors |
| `r1`, `r2` | Results of the two loads; `-1` means not executed yet |
| `pc[p]` | Program counter for processor `p` |

A buffered store is represented by a record:

```tla
[f |-> "x", v |-> 1]
```

Here, `f` is the memory field and `v` is the value to write. `Init` gives each
processor an empty buffer, initializes both memory locations to zero, and puts
both program counters at `"store"`.

### Store forwarding

Loads are defined as follows:

```tla
Load(p, f) ==
    LET idxs == { i \in DOMAIN buf[p] : buf[p][i].f = f }
    IN  IF idxs = {} THEN mem[f] ELSE buf[p][Max(idxs)].v
```

This captures an essential property of real store buffers:

- If the processor has no pending store to `f`, it reads shared `mem[f]`.
- If it has pending stores to `f`, it reads its own newest pending value.

The second case is called **store-to-load forwarding**. A processor does not
have to wait for its own store to become globally visible before reading that
same address.

The processors in this particular litmus load the *other* processor's
variable, so neither can forward the store that matters to its load. For
example, `t1` buffers a store to `x` but loads `y`.

### Asynchronous propagation

`Flush(p)` represents a buffered store becoming visible in shared memory.
Flushes are separate `Next` actions, so TLC explores executions in which they
happen early, late, or between any two program instructions for which they are
enabled.

This nondeterminism is important. The model does not assume that buffers are
slow, fast, or likely to drain at a particular moment. If the architecture
allows the load to run before the required flush, TLC explores that execution
regardless of how rarely comparable timing might occur on hardware.

## x86-TSO

The x86 module is [`X86TSO.tla`](X86TSO.tla). It models ordinary, aligned loads
and stores to normal write-back cacheable memory using the standard x86-TSO
operational abstraction.

### FIFO store buffers

An x86-TSO processor's stores become globally visible in program order. The
module represents that rule by flushing only the head of the processor's
buffer:

```tla
Flush(p) ==
    /\ buf[p] # <<>>
    /\ mem' = [mem EXCEPT ![Head(buf[p]).f] = Head(buf[p]).v]
    /\ buf' = [buf EXCEPT ![p] = Tail(buf[p])]
```

Suppose one processor executes:

```text
store a := 1
store b := 1
```

The buffer becomes:

```text
<< [a |-> 1], [b |-> 1] >>
```

The model must publish `a := 1` before it can publish `b := 1`. This is the
FIFO property and is why ordinary x86 stores are not observed in the opposite
order by another processor.

### What "StoreLoad reordering" means here

`DoStore(p)` appends a store to the buffer and immediately advances the program
counter toward the load:

```tla
buf' = [buf EXCEPT ![p] =
    Append(buf[p], [f |-> OwnVar(p), v |-> 1])]
```

Without a fence, nothing requires `Flush(p)` to happen before `DoLoad(p)`.
Program order still says that the processor issued the store first, but another
processor cannot see that store until it is flushed. This difference between
local execution and global visibility is the StoreLoad relaxation.

For ordinary write-back memory, the FIFO buffer abstraction preserves the
other principal x86-TSO orderings:

- a later load does not pass an earlier load;
- a later store does not become visible before an earlier load;
- stores become visible in FIFO order;
- a processor reads its own newest pending store to the same address.

The phrase "x86 permits StoreLoad reordering" is therefore shorthand for a
specific externally observable effect. It does not mean that instructions must
literally be reordered in the instruction stream.

### Violating execution without `MFENCE`

With `Fenced = FALSE`, TLC can execute:

```text
1. t1 buffers x := 1       mem = [x |-> 0, y |-> 0]
2. t2 buffers y := 1       mem = [x |-> 0, y |-> 0]
3. t1 loads y from mem     r1 = 0
4. t2 loads x from mem     r2 = 0
5. either buffer may flush afterward
```

Each processor sees its own store as pending, but neither store is visible to
the other processor at the time of its load. The state with `r1 = 0` and
`r2 = 0` therefore violates the invariant.

This is architecturally allowed. Store-buffer latency affects how frequently a
similar execution is observed on physical hardware, not whether software may
rely on it being absent.

### Reproducing the behavior with threads

Yes: the SB behavior needs only two concurrently executing worker threads and
ordinary shared memory. It does not require processes, explicit cache
management, non-temporal instructions, or a deliberately weak memory type.
Each worker must run the store followed by the load without a full fence
between them.

Conceptually, a managed-code test can execute:

```csharp
// Initially: x = 0, y = 0

// Worker t1                         // Worker t2
Volatile.Write(ref x, 1);            Volatile.Write(ref y, 1);
r1 = Volatile.Read(ref y);           r2 = Volatile.Read(ref x);
```

`Volatile.Write` is useful here to keep the source-level release store and
prevent an optimizing compiler from deleting or moving it in ways unrelated to
the hardware test. It is not a full StoreLoad fence. Similarly,
`Volatile.Read` supplies an acquire load but does not retroactively turn the
preceding store into a StoreLoad-ordered operation. On x86, this pair can still
produce `r1 = 0` and `r2 = 0`.

A practical test normally repeats this sequence many times because the allowed
window is short. It also needs iteration coordination:

1. Reset `x`, `y`, `r1`, and `r2`.
2. Release both workers to begin the iteration.
3. Let each worker perform its store and load with no synchronization between
   those two operations.
4. Wait until both workers finish.
5. Record whether both result registers contain zero.

Synchronization before the stores and after the loads is acceptable. A lock,
barrier, `Interlocked` operation, log statement, or thread rendezvous placed
**between** a worker's store and load can close or perturb the window and
invalidate the test. Reusing long-running workers is generally better than
creating new threads for each iteration.

The logical execution requires two threads. A test harness may use the main
thread as a coordinator, but that third thread is not part of the memory-order
cycle. Pinning the workers to different physical cores is not necessary for the
architectural argument, but it makes a hardware experiment easier to interpret
and avoids migration and scheduling effects that can greatly reduce the chance
of observing the outcome.

#### Pending-buffer trace for the minimal SB test

Listing the pending buffers makes the execution especially clear. The following
table shows one allowed trace. The leftmost item in a buffer is the next store
that may flush.

| Step | Action | `buf[t1]` | `buf[t2]` | Shared `mem` | Results |
|---|---|---|---|---|---|
| 0 | Initialize | `<< >>` | `<< >>` | `x=0, y=0` | `r1=-1, r2=-1` |
| 1 | `t1` executes `x := 1` | `<< x:=1 >>` | `<< >>` | `x=0, y=0` | unchanged |
| 2 | `t2` executes `y := 1` | `<< x:=1 >>` | `<< y:=1 >>` | `x=0, y=0` | unchanged |
| 3 | `t1` executes `r1 := y` | `<< x:=1 >>` | `<< y:=1 >>` | `x=0, y=0` | `r1=0` |
| 4 | `t2` executes `r2 := x` | `<< x:=1 >>` | `<< y:=1 >>` | `x=0, y=0` | `r1=0, r2=0` |
| 5 | `t1` flushes | `<< >>` | `<< y:=1 >>` | `x=1, y=0` | unchanged |
| 6 | `t2` flushes | `<< >>` | `<< >>` | `x=1, y=1` | unchanged |

At steps 3 and 4, each processor's own store has executed but remains private.
The load addresses a different variable, so store forwarding does not apply:
`t1` has a pending value for `x` but is loading `y`, while `t2` has a pending
value for `y` but is loading `x`.

The later flushes cannot change values already captured in `r1` and `r2`.
Memory eventually becoming `x=1, y=1` therefore does not undo the forbidden
observation.

These buffers are conceptual architectural state. Ordinary software cannot
portably inspect a physical core's store-buffer entries while the test is
running. Instrumenting the critical path to print them would itself add calls,
locks, and memory traffic that perturb the execution. The table is reconstructed
from the allowed architectural execution and corresponds directly to the TLA+
variables.

#### Pending-buffer trace for the LightEpoch bug

The larger [`../LightEpoch.tla`](../LightEpoch.tla) model uses the same mechanism
with names from the reclamation algorithm:

- `lce` is the reader's published local epoch;
- `ret` says that the object has been unlinked and retired;
- `ce` is the current global epoch;
- `freed` says that reclamation has run;
- `holds` says that the reader observed the object as linked and may
  dereference it.

The initial shared state is:

```text
mem = [ce=1, lce=0, ret=FALSE, freed=FALSE]
buf[Rd] = << >>
buf[Rc] = << >>
holds = FALSE
```

One violating execution is:

| Step | Model action | Reader buffer `buf[Rd]` | Reclaimer buffer `buf[Rc]` | Shared state and consequence |
|---|---|---|---|---|
| 1 | `Rd.Acq` | `<< lce:=1 >>` | `<< >>` | `mem.lce` remains `0` |
| 2 | `Rd.Cap` | `<< lce:=1 >>` | `<< >>` | Reader loads `ret=FALSE`; `holds=TRUE` |
| 3 | `Rc.Retire` | `<< lce:=1 >>` | `<< ret:=TRUE >>` | The retire store is initially pending |
| 4 | `Rc.Bump` | `<< lce:=1 >>` | `<< >>` | Locked bump publishes `ret=TRUE`, changes `ce` to `2`, and records retire epoch `1` |
| 5 | `Rc.Compute` | `<< lce:=1 >>` | `<< >>` | Scan still reads `lce=0`, computes safe epoch `1`, and sets `freed=TRUE` |
| 6 | safety check | `<< lce:=1 >>` | `<< >>` | `freed=TRUE` and `holds=TRUE`: `NoUseAfterFree` is violated |
| 7 | optional late reader flush | `<< >>` | `<< >>` | `lce=1` becomes visible, but reclamation was already unsafe |

Step 4 is important. The reclaimer's locked epoch increment orders and drains
the reclaimer's own earlier retire store. It does not drain the reader's
independent store buffer. Thus the reclaimer can correctly publish `ret=TRUE`
and advance the global epoch while still reading the stale reader announcement
`lce=0`.

Only two participating threads are needed:

1. The reader thread publishes its epoch and accesses the object.
2. The reclaimer thread unlinks, advances the epoch, scans, and frees.

The use-after-free requires more algorithmic state than the generic `x/y`
litmus, but it does not require a third racing thread. Runtime GC threads and
the operating system may exist in a real process, yet they are not necessary
to form the modeled cycle.

This trace demonstrates possibility, not deterministic timing. On x86, the
reader's pending store will usually propagate before the reclaimer completes
all of its work, so an executable reproduction may need many iterations,
careful affinity, and a very small critical path. Failure to observe the bug in
a finite run is not evidence that the execution is forbidden.

### `MFENCE`

With `Fenced = TRUE`, `DoStore` sends each processor to `"fence"` instead of
directly to `"load"`. `DoFence(p)` is enabled only when that processor's buffer
is empty:

```tla
DoFence(p) ==
    /\ pc[p] = "fence"
    /\ buf[p] = <<>>
    /\ pc' = [pc EXCEPT ![p] = "load"]
```

Consequently, the processor cannot advance to its load until `Flush(p)` has
published its earlier store. Once both processors reach their loads, at least
one load must observe `1`, and the forbidden `0/0` result is unreachable.

Treating `MFENCE` as waiting for an empty abstract buffer is an operational way
to encode its ordering guarantee. Software should reason about the guaranteed
ordering, rather than about a particular microarchitecture's physical cache or
store-buffer implementation.

### Locked read-modify-write operations

A locked operation such as `lock cmpxchg` or `lock xadd` also provides the
StoreLoad ordering needed by this litmus when it is placed **between** the
announcement store and the later load. For that narrow purpose it can be
abstracted like the fence.

The module does not model a locked RMW as a separate operation. A complete RMW
model would additionally need:

- an atomic read and write of one location;
- the value returned by the read;
- failure and retry behavior where applicable;
- ordering among competing atomic operations.

Those details are unnecessary for deciding whether a prior plain store is
ordered before a later plain load.

A locked instruction that occurs **before** the announcement store does not
provide the needed ordering. It may order older operations, but the new store
can enter the buffer after the locked instruction and still be passed by the
later load.

### Why a release store is insufficient

A release operation orders accesses that precede the release before the
release itself. It does not, by itself, order the release store before a load
that follows it:

```text
earlier operations -> release store -> later load
                     ^ release orders the left side, not the right side
```

Ordinary x86 stores already have the ordering needed to implement a release
store for normal write-back memory. Changing the announcement from an ordinary
store to a release store therefore does not close the StoreLoad window. The
required ordering point must be after the store and before the load, such as an
`MFENCE` or suitable locked operation.

### Scope of the x86 model

This is a faithful SB-litmus abstraction, not a model of every x86 memory
operation. In particular, it does not cover:

- non-temporal or streaming stores;
- write-combining or device memory;
- cache-maintenance instructions;
- mixed-size, overlapping, unaligned, or tearing accesses;
- instruction fetch and self-modifying code;
- same-address coherence litmus tests;
- a distinct global order for locked operations;
- compiler or .NET JIT transformations;
- liveness or a guarantee that an enabled flush eventually occurs.

These omissions do not affect the SB result for the ordinary field accesses
modeled here.

## Connection to LightEpoch

The SB variables correspond to the relevant LightEpoch operations:

| SB litmus operation | LightEpoch meaning |
|---|---|
| `t1: x := 1` | reader publishes `localCurrentEpoch` |
| `t1: r1 := y` | reader loads a shared pointer or linked state |
| `t2: y := 1` | reclaimer unlinks or retires the object |
| `t2: r2 := x` | reclaimer scans the reader's epoch slot |

The dangerous conceptual result is:

```text
reader sees object still usable
AND
reclaimer sees reader as absent
```

That is the LightEpoch analogue of both SB loads reading the old value.

The standalone module establishes that x86-TSO allows this StoreLoad window
without the required ordering. It does not by itself prove a use-after-free.
The larger `LightEpoch*.tla` modules add the epoch bump, safety computation,
and free/use state needed to turn the ordering window into the
`NoUseAfterFree` property.

## Running the models

From the repository root:

```bash
docker build -f tla/Dockerfile -t lightepoch-tla tla
docker run --rm lightepoch-tla
```

The memory-model configurations are:

| Module | Configuration | Expected invariant result |
|---|---|---|
| `X86TSO` | `X86TSO_NoFence.cfg` | violated |
| `X86TSO` | `X86TSO_Fence.cfg` | holds |

An invariant violation in the unfenced configurations is the expected evidence:
TLC prints a concrete state trace showing how both loads can read zero. A
successful check in a fenced configuration means that no reachable state in
this finite litmus abstraction contains the forbidden completed result.

## Appendix: asymmetric barriers in RCU, GCs, and runtimes

The asymmetric-barrier idea used by the LightEpoch experiment is not unique to
epoch reclamation. It is an established systems technique used by userspace
RCU libraries, garbage collectors, safepoint implementations, thread
suspension machinery, and runtime metadata management.

### The recurring optimization

Many concurrent algorithms have two very unequal sides:

| Side | Frequency | Typical work |
|---|---:|---|
| Fast side | millions of times | publish a small per-thread state change |
| Slow side | occasionally | inspect every thread and reclaim or change global state |

A symmetric design puts a hardware fence on every fast-side operation:

```text
reader 1: publish -> local full fence -> access
reader 2: publish -> local full fence -> access
reader 3: publish -> local full fence -> access
...
writer:   scan all publications
```

This is straightforward but can be expensive because the common path pays for
the fence repeatedly.

An asymmetric design moves that cost to the rare side:

```text
reader 1: publish -> compiler-ordered access
reader 2: publish -> compiler-ordered access
reader 3: publish -> compiler-ordered access
...
writer:   process-wide barrier -> scan all publications
```

The slow-side operation causes every relevant thread or processor to pass
through a memory-ordering point before the scan proceeds. The result is not a
free fence; it is a deliberate exchange:

- remove a small cost from a very frequent reader path;
- add a much larger syscall, IPI, or thread-coordination cost to a rare writer
  or collector path.

Linux's [`membarrier(2)` documentation](https://man7.org/linux/man-pages/man2/membarrier.2.html)
describes exactly this fast-side/slow-side transformation and explicitly names
RCU libraries and garbage collectors as intended users.

### Linux `membarrier`

`membarrier` asks the kernel to establish memory ordering on a set of threads.
For an in-process runtime, the most relevant command is usually:

```c
MEMBARRIER_CMD_PRIVATE_EXPEDITED
```

Before using it, the process registers with:

```c
MEMBARRIER_CMD_REGISTER_PRIVATE_EXPEDITED
```

On successful return from the expedited call, every running sibling thread in
the process has passed through a state in which its user-space memory accesses
are ordered across the call. Threads that are not running are already in a
quiescent state for this purpose.

This is stronger in scope than executing `mfence` or `dmb ish` only on the
calling thread:

```text
local fence:
    order the caller's accesses

private expedited membarrier:
    make every thread in this process pass through an ordering point
```

The kernel can implement the expedited operation using mechanisms such as
interprocessor interrupts and scheduler participation. Applications rely on
the syscall's ordering contract, not on one specific kernel implementation.

`MEMBARRIER_CMD_GLOBAL` has broader system-wide scope and is generally more
expensive. Production runtimes normally prefer the private expedited operation
when it is supported and registration succeeds.

### Userspace RCU

Read-Copy-Update is the canonical example of an asymmetric algorithm:

```text
read side:
    enter read-side critical section
    load and use current object
    leave critical section

update side:
    publish replacement object
    wait for a grace period
    reclaim the old object
```

RCU performance depends on keeping the read side extremely cheap. Requiring
every reader to execute a full hardware barrier can erase much of its benefit.
The updater, however, already performs expensive grace-period work and is a
natural place to pay for global coordination.

The [`userspace-rcu`](https://github.com/urcu/userspace-rcu) implementation
detects and registers for `MEMBARRIER_CMD_PRIVATE_EXPEDITED`. Its writer-side
`smp_mb_master()` issues the syscall when available. The same operation is used
while the writer:

1. publishes or switches the current grace-period phase;
2. examines per-reader counters;
3. waits for old readers to become quiescent;
4. establishes ordering before declaring the grace period complete.

The relevant implementation is
[`src/urcu.c`](https://github.com/urcu/userspace-rcu/blob/master/src/urcu.c).
The source comment captures the problem directly: a non-cooperative reader may
not have committed its active-reader counter to memory, so the slow side must
force the required ordering before trusting the scan.

This resembles LightEpoch:

| Userspace RCU | LightEpoch |
|---|---|
| reader publishes active/grace-period state | reader publishes local epoch |
| updater starts and waits for grace period | reclaimer computes safe epoch |
| updater checks reader counters | reclaimer scans epoch slots |
| old object is reclaimed after grace period | retired object is drained after safe epoch |

The algorithms are not identical, but both must prevent the slow side from
missing a fast-side publication and reclaiming too early.

Kernel RCU should not be described as merely calling the userspace
`membarrier` syscall. Kernel RCU has its own scheduler, interrupt, quiescent
state, and grace-period machinery. The direct example here is **userspace RCU**;
the shared idea is asymmetric coordination.

### .NET garbage collection and runtime synchronization

.NET exposes an internal process-wide barrier through
`minipal_memory_barrier_process_wide()`. The current implementation is in
[`src/native/minipal/memorybarrierprocesswide.c`](https://github.com/dotnet/runtime/blob/main/src/native/minipal/memorybarrierprocesswide.c).

Its platform strategies include:

- Windows: call `FlushProcessWriteBuffers()`;
- Linux with support: register and call
  `MEMBARRIER_CMD_PRIVATE_EXPEDITED`;
- Unix fallback: change protection on a locked helper page so the resulting
  TLB shootdown/IPIs create the required process-wide ordering;
- Apple platforms: interact with every task thread through Mach APIs.

CoreCLR uses this facility in several GC-related paths. Two concrete examples
are:

- [`softwarewritewatch.cpp`](https://github.com/dotnet/runtime/blob/main/src/coreclr/gc/softwarewritewatch.cpp),
  where the collector makes recent per-thread dirty-state changes visible
  before inspecting software write-watch state;
- [`card_table.cpp`](https://github.com/dotnet/runtime/blob/main/src/coreclr/gc/card_table.cpp),
  where process-wide ordering participates in safely changing card-table and
  write-barrier metadata.

The same primitive also appears in thread suspension, allocation-state
transitions, profiling, and NativeAOT thread-store coordination. These are
closely related to GC correctness because a collector must reliably determine
whether mutator threads have observed a state transition, entered a safepoint,
or published metadata before memory is scanned or reclaimed.

This does not mean every GC synchronization point uses a process-wide barrier.
Collectors combine many mechanisms:

- stop-the-world suspension;
- safepoint polls and handshakes;
- per-object or per-region write barriers;
- card tables and remembered sets;
- local acquire/release operations;
- locks and atomic RMWs;
- process-wide barriers where asymmetry makes them worthwhile.

The process-wide barrier is one specialized tool used when the collector or
runtime needs ordering from many mutator threads without putting a full fence
on every corresponding fast-path operation.

### HotSpot safepoints and handshakes

OpenJDK HotSpot has a `SystemMemoryBarrier` abstraction used by safepoint,
thread-handshake, and sampling code. The safepoint implementation uses it to
order publication of global safepoint state before reading per-thread state.
Safepoints are central to operations such as garbage collection, stack
walking, and runtime code maintenance.

The platform implementations demonstrate the same cross-platform pairing:

- Linux
  [`systemMemoryBarrier_linux.cpp`](https://github.com/openjdk/jdk/blob/master/src/hotspot/os/linux/systemMemoryBarrier_linux.cpp)
  queries, registers, and invokes `MEMBARRIER_CMD_PRIVATE_EXPEDITED`;
- Windows
  [`systemMemoryBarrier_windows.cpp`](https://github.com/openjdk/jdk/blob/master/src/hotspot/os/windows/systemMemoryBarrier_windows.cpp)
  calls `FlushProcessWriteBuffers()`.

Call sites include
[`safepoint.cpp`](https://github.com/openjdk/jdk/blob/master/src/hotspot/share/runtime/safepoint.cpp)
and
[`handshake.cpp`](https://github.com/openjdk/jdk/blob/master/src/hotspot/share/runtime/handshake.cpp).
HotSpot treats failure to issue an initialized Linux system barrier as fatal
rather than silently substituting a caller-only fence.

### Windows `FlushProcessWriteBuffers`

Microsoft documents
[`FlushProcessWriteBuffers`](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-flushprocesswritebuffers)
as flushing the write queue of each processor running a thread of the current
process. The function generates interprocessor interrupts for processors in the
process affinity and guarantees visibility of writes between those processors.

Its role is analogous to a private process-wide `membarrier`:

```text
rare coordinator calls FlushProcessWriteBuffers()
    -> relevant processors receive an ordering event
    -> coordinator may inspect state published by process threads
```

It is intentionally expensive and should not be placed on an ordinary hot
path. That cost profile is exactly why it can be useful for asymmetric
algorithms.

### Relationship to the asymmetric LightEpoch model

[`../FixedLightEpochWithAsymmetricBarrier.tla`](../FixedLightEpochWithAsymmetricBarrier.tla)
models the slow-side barrier by applying the reader's pending buffer to shared
memory before the reclaimer scans `lce`:

```text
reader:
    buffer lce := current epoch
    continue to protected access

reclaimer:
    publish retirement
    advance epoch
    process-wide barrier
    scan lce
    reclaim only if safe
```

Conceptually, the process-wide barrier turns this state:

```text
buf[Rd] = << lce:=1 >>
mem.lce = 0
```

into:

```text
buf[Rd] = << >>
mem.lce = 1
```

before the scan is allowed to use `mem.lce`.

Real operating-system APIs specify ordering rather than exposing or literally
copying a TLA+ buffer. Applying the entire buffer is the model's operational
representation of the guarantee needed by this algorithm.

### Correctness requirements and traps

Using this technique correctly requires more than inserting a syscall:

1. **Compiler ordering is still required on the fast side.** A kernel barrier
   cannot repair a compiler or JIT transformation that moved the publication
   after the protected access. The fast path needs compiler ordering appropriate
   to its language and runtime.
2. **The slow-side barrier must occur before the scan.** Calling it after the
   scan cannot validate values already read.
3. **The API's scope must include every relevant reader.** A process-private
   barrier cannot synchronize a reader in another process.
4. **Registration and capability checks matter.** Private expedited
   `membarrier` must be supported and registered before it is invoked.
5. **Failure cannot become a local-fence fallback.** A local `mfence`,
   `dmb ish`, or `Interlocked.MemoryBarrier()` orders only the caller. It does
   not satisfy a proof that assumes every reader crossed an ordering point.
6. **Fallbacks must preserve semantics.** CoreCLR's Unix fallback deliberately
   uses page protection changes and TLB shootdowns to generate process-wide
   effects; it does not silently replace the operation with a caller-only
   fence.
7. **Thread lifecycle must be covered.** Registration, thread creation, exit,
   migration, and suspension must not allow a relevant reader to escape the
   barrier protocol.
8. **The cost must remain asymmetric.** If reclamation is frequent, repeated
   IPIs and syscalls may cost more than reader-side fences.

This final point is a design tradeoff rather than a correctness condition. The
process-wide approach is most attractive when reads or entries are extremely
frequent and reclamation or global-state changes are comparatively rare.
