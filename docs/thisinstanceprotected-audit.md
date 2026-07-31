# Does moving the claim CAS off `threadId` change `ThisInstanceProtected()`?

Audit and validation record for the `LightEpoch` slot-claim change
(`workstream/lightepoch-x86-minimal`, PR #3).

**Answer: no.** The query's contract is preserved in both directions. This document
sets out why, which call sites would have paid for it if it were not, and the
evidence — model checking on x86-TSO, and an A/B on real x86 silicon with a
forced-failure control.

**Scope note: x86 first.** Every claim below is established on x86-TSO. ARM rows
appear only as secondary controls that separate "needs weak memory" from "already
broken on TSO"; the conclusion for the shipping change rests on the TSO results.

---

## 1. The change

`Entry.threadId` used to be the claim token; it is now derived state.

```csharp
// BEFORE — threadId is the claim; the epoch is announced later, unfenced
if (0 == (tableAligned + entry)->threadId)
    if (0 == Interlocked.CompareExchange(ref (tableAligned + entry)->threadId, Metadata.threadId, 0))
        return true;                                  // slot claimed, epoch NOT yet announced
...
(*(tableAligned + entry)).localCurrentEpoch = CurrentEpoch;   // plain store == the bug

// Release()
(*(tableAligned + entry)).localCurrentEpoch = 0;
(*(tableAligned + entry)).threadId = 0;                       // free token cleared LAST
```

```csharp
// AFTER — localCurrentEpoch is the claim; claiming and announcing are one locked RMW
if (EntryAt(entry).localCurrentEpoch != 0) return false;
if (Interlocked.CompareExchange(ref EntryAt(entry).localCurrentEpoch, epoch, 0) != 0) return false;
EntryAt(entry).threadId = Metadata.threadId;                  // plain; the slot is already ours

// Release()
(*(tableAligned + entry)).threadId = 0;                       // plain, FIRST
Volatile.Write(ref EntryAt(entry).localCurrentEpoch, 0);      // release store, free token LAST
entry = kInvalidIndex;
```

`ThisInstanceProtected()` itself is **untouched**:

```csharp
ref var entry = ref Metadata.Entries.GetRef(instanceId);
return kInvalidIndex != entry && (*(tableAligned + entry)).threadId == Metadata.threadId;
```

The worry is real and worth stating plainly: the field the query reads is no longer
written under a lock, and the arriving owner now writes its tag while the departing
owner's clear of that same field may still be in flight.

---

## 2. Who reads `threadId`

Two reads, cross-thread, neither load-bearing:

| Site | Purpose |
| --- | --- |
| `LightEpoch.ToString()` | diagnostics |
| `LightEpoch.TestHooks.cs:34` `ThreadIdAt()` | test hook |

Everything else reads it through `ThisInstanceProtected()`, which compares against
the **thread-static** `Metadata.threadId` — so the field is only ever consulted by
the thread whose id it holds. `ComputeNewSafeToReclaimEpoch` and `SuspendDrain`, the
two places where a wrong answer would be a memory-safety bug, read only
`localCurrentEpoch` and never look at `threadId` at all.

Note also that `libs/client/LightEpoch.cs` is a **separate, unmodified duplicate**
used by the client; it is not affected.

---

## 3. Call-site classification (~132 sites under `libs/`)

### 3a. Assertions only — ~85 sites, no production behavior

`Debug.Assert(epoch.ThisInstanceProtected())` and friends in
`TransactionalContext.cs` (19), `TransactionalUnsafeContext.cs` (19),
`UnsafeContext.cs` (15), `InternalLock.cs` (5), `HandleOperationStatus.cs` (2), and
singletons in `ClientSession.cs`, `TsavoriteThread.cs`, `AllocatorScan.cs`,
`ConditionalCopyToTail.cs`, `ModifiedBitOperation.cs`, `StateMachineDriver.cs`,
`NetworkWriter.cs`, plus `BumpCurrentEpoch` and `ThisThreadUserWord`.

These compile out of Release. A false negative here is a DEBUG-only spurious assert;
a false positive is a missed assert. Neither reaches a shipping binary.

### 3b. Load-bearing control flow — ~25 sites, two idioms

**Idiom A — suspend around a blocking wait.**

```csharp
bool isProtected = epoch.ThisInstanceProtected();
if (isProtected) epoch.Suspend();
try { blockingWait(); }
finally { if (isProtected) epoch.Resume(); }
```

`StorageDeviceBase.cs:224-235, 295-306, 339-350`, `AllocatorBase.cs:355`.

*Cost of a false negative:* the thread blocks on I/O **while still announcing an
epoch**, pinning `SafeToReclaimEpoch` for the duration. Under a concurrent
checkpoint or page eviction that is a hang, not a slowdown. This is the `SuspendLost`
failure the TLA+ specs already model.

*Cost of a false positive:* `Suspend()` on a thread that holds no slot.

**Idiom B — acquire if not already held.**

```csharp
var taken = epoch.ResumeIfNotProtected();
try { work(); }
finally { if (taken) epoch.Suspend(); }
```

`AllocatorBase.cs:981, 1018, 2382`, `StorageDeviceBase.cs:261`,
`ObjectAllocatorImpl.cs:652`, `LogAccessor.cs:131`.

*Cost of a false negative:* a second `Resume()` on a thread that already holds a
slot — the first slot is orphaned, permanently announcing a stale epoch. Same class
of hang.

*Cost of a false positive:* the caller skips its own `Resume()` and then runs
unprotected, which is the memory-safety direction.

Remaining load-bearing sites: `AllocatorBase.cs:2066`, `TsavoriteLog.cs:450/611/1394/2365/3237`,
`Tsavorite.cs:451/827`, `StateMachineDriver.cs:95/126`, `MallocFixedPageSize.cs:321`,
`IndexCheckpoint.cs:124`, `ScanIteratorBase.cs:105`, `ObjectAllocatorImpl.cs:770`,
`ClientSession.cs:331/352`.

Four of these are reached from I/O completion callbacks, i.e. on threads whose
protection state the caller did not choose. That is why the false-positive invariant
is checked **un-gated** below — the query has to be safe wherever it is asked.

---

## 4. Why a false positive is impossible

A false positive means `table[entry].threadId == Metadata.threadId` while this
thread does not own `entry`.

| Case | Why it cannot happen |
| --- | --- |
| (a) Thread owns nothing | `entry == kInvalidIndex`; the `kInvalidIndex != entry` guard short-circuits before the table is touched. |
| (b) Thread is mid-probe | The entry index is written before the claim can fail, so a stale index is briefly visible — but only to code inside `TryAcquireEntry`, which cannot call the query. `TryAcquireEntry` also resets `entry = kInvalidIndex` on total failure, so `ReserveEntryWait` never loops with a stale index. |
| (c) Stale index from a recycled `instanceId` | Covered by `tla/epoch/fixes/CasAnnounceNoThreadIdStaleIndex.tla` and by `InstanceTests.cs:102`. |
| (d) Another **live** thread wrote our id | Impossible: managed thread ids are unique among live threads, and only the owner ever writes its own id. |
| (e) A **dead** thread's leaked slot whose id is later recycled | The leaked slot has `localCurrentEpoch != 0`, so the claim CAS can never hand that index to the new thread. Holds under both old and new code. |

Case (b) is the one the change creates, and it is why `threadId` must **not** be
deleted along with its CAS — see the `indexonly` control in §6a.

## 5. Why a false negative is harmless

Two windows exist, both interior to `LightEpoch`:

1. Between the claim CAS and `threadId = Metadata.threadId` in `TryClaimEntry`.
2. Between the tag clear and the unpublish in `Release()`.

In both the thread is inside `LightEpoch` and cannot call the query. No production
caller can observe either.

The write-write race on `threadId` between the departing and the arriving owner is
resolved by the pairing: the departing thread's `threadId = 0` is ordered **before**
its release store, the arriving thread's CAS reads-from that release store, and its
`threadId = myTid` cannot hoist above the CAS. Per-location coherence then puts the
arriving thread's write last. **Reversing the two stores in `Release()` breaks
exactly this argument** — which is what makes `upstream` a usable forced-failure
control, and why that reversal is load-bearing rather than cosmetic.

---

## 6. Evidence

### 6a. Model checking — `tla/epoch/fixes/CasAnnounceProtectedQueryProbe.tla`

Two slots, two readers, slot reuse, and `TryAcquireEntry`'s probe window modelled
explicitly. Predecessor `CasAnnounceProtectedQuery.tla` is one slot and *argues*
that a false positive is structurally impossible; one slot cannot express one, so
this spec checks it instead. `NoFalsePositive` is un-gated; `NoFalseNegative` is
gated on the thread being outside `LightEpoch` internals.

| Config | Result | Reading |
| --- | --- | --- |
| `tagged_release_tso` | **HOLDS** | **The x86 result.** The fix answers correctly in both directions on a contended, reused, multi-slot table. |
| `tagged_upstream_fp_tso` | VIOLATED (`NoFalsePositive`) | Upstream's `Release()` order breaks the query on plain x86. |
| `tagged_upstream_fn_tso` | VIOLATED (`NoFalseNegative`) | ...in the other direction too. |
| `indexonly_tso` | VIOLATED (`NoFalsePositive`) | Drop the tag but keep the change: the probe window *is* a false positive. `threadId` stays. |
| `tagged_release_arm` | HOLDS | Secondary control. |
| `tagged_plain_fp_arm` | HOLDS | A plain unpublish cannot manufacture a false positive. |
| `tagged_plain_fn_arm` | VIOLATED (`NoFalseNegative`) | It can lose the next owner's tag. The fence axis is ARM-only and one-sided. |

Wired into `tla/run.sh` with expected verdicts, so a regression fails the suite.

> While writing this spec a defect was found in the shared `StoreBuffer.tla` `"arm"`
> model: it lets a later store to a field overtake an earlier store to the *same*
> field, violating per-location coherence, which no machine does. It had never
> mattered because every prior spec writes each field at most once per thread per
> round; this is the first to write one field twice. `CoherentFlushOne` in the new
> module restricts the choice to stores with no older pending store to the same
> field, leaving the StoreStore relaxation fully intact (confirmed: `tagged_plain_fn_arm`
> still violates).

### 6b. Real x86 hardware — `src/LightEpoch.TidLitmus`

40 threads over a 2-slot table, cross-checking `ThisInstanceProtected()` against
thread-private ground truth (entry index + announced epoch, neither reachable by the
race), sampled repeatedly across each protected region. 20-core x86 dev box:

| Arm | Rounds | False negatives | Verdict |
| --- | --- | --- | --- |
| `upstream` (forced-failure control) | 22.7 M | **44** | detector is live |
| `volatile` (**the fix**) | 136.3 M | **0** | PASS |
| `baseline` (upstream `threadId` CAS) | 134.4 M | **0** | PASS |

The control matters more than either clean row: the harness is capable of catching
this exact defect on this exact machine, at ~2 violations per million rounds. The
fix ran 6x the control's exposure and produced none, where a defect of the same rate
would have yielded ~260. And the baseline row is the direct answer to the original
question — old and new code agree, so the change is behavior-preserving for
`ThisInstanceProtected()`.

A run whose control stays silent exits `INCONCLUSIVE` (3) rather than `PASS`, because
a detector that cannot fire proves nothing.

**Idiom mode** (`--idiom`) replaces the direct query with the two production idioms
from §3b, scored by what each would actually cost rather than by which bit came back:

| Arm | Rounds | Violations | Rate |
| --- | --- | --- | --- |
| `upstream` (control) | 373.9 M | **79,294** | 212 per million |
| `volatile` (**the fix**) | 996.8 M | **0** | — |

At the control's rate the fix's exposure would have produced ~211,000 violations.
It produced none. The control's output names both production failure modes directly:

```
thread 0:  idiom A would block on I/O while announcing epoch 1 in slot 2
thread 31: idiom B would double-acquire and orphan slot 1
```

This is the sharpest instrument of the three, because the query is read immediately
after `Resume()` — exactly where the call sites read it, and before the arriving
owner's own tag store has drained far enough to hide a late-landing clear.

```
# control (must report violations)
LE_RELEASE_ORDER=upstream dotnet run --project src/LightEpoch.TidLitmus -c Release -- \
    --seconds 60 --slots 2 --expect-violation

# the fix
LE_RELEASE_ORDER=volatile dotnet run --project src/LightEpoch.TidLitmus -c Release -- \
    --seconds 60 --slots 2

# either arm, driving the production call-site idioms instead of the raw query
... --idiom
```

An overnight soak (`artifacts/tidlitmus-soak.ps1`) runs the same A/B on a 32-vCPU
Intel Azure VM, sweeping slot spaces 1/2/4/8 and thread counts up to 4x the core
count in both harness modes, and re-runs both controls **every cycle** — a ten-hour
clean run only means something if the harness could still catch the defect at hour
ten. Measured control sensitivity on that machine, per cycle:

| Mode | Rounds | Violations | Rate |
| --- | --- | --- | --- |
| idiom | 905.3 M | 19,062,416 | 2.1% of rounds |
| query | 523.8 M | 703 | 1.3 per million |

At 2.1% per round, a defect of this shape cannot hide in a soak of this length.

### 6c. Architecture-level — `herd/jit-derived/litmus/x86-release-tid-{main,fixed}.litmus`

The hardware A/B says the fix survives on the silicon in front of us. herd7 says the
*architecture* forbids the failure on any x86 implementation. Both new rows isolate
the store **order** in `Release()` from the release store itself — on x86 both stores
are plain `MOV`, so the only difference between the rows is which comes first:

| Test | Result | |
| --- | --- | --- |
| `x86-release-tid-main` (upstream order) | **Sometimes** | 1 positive witness: `lce=1 /\ tid=0` — the slot is owned by the new claimer yet carries no tag. |
| `x86-release-tid-fixed` (shipped order) | **Never** | 0 positive witnesses out of 4. |

This closes a gap in the existing matrix: hazard 3 previously had ARM rows only, so
nothing said the ordering mattered on x86. It does, and not because of a fence —
`Volatile.Write` compiles to a plain `MOV` here. The ordering comes from the pairing:
the clear precedes the unpublish in P0's total store order, P1's claim RMW cannot
succeed until the unpublish is visible, and P1's tag store cannot hoist above its own
locked RMW.

The three layers agree exactly: `tagged_upstream_fn_tso` VIOLATED in TLC,
`x86-release-tid-main` Sometimes in herd7, and 44 / 925 / 79,294 false negatives on
two different x86 machines across three harness modes — with the corresponding fixed
row clean in all three layers.

---

## 7. What is *not* covered

- **ARM is a control here, not a conclusion.** `tagged_release_arm` holds and the ARM
  herd7 rows pass, but no ARM soak was run for this question.
- **`indexonly` is not a shipped configuration.** It is checked only in TLC, to
  establish that `threadId` must survive the removal of its CAS.
- **The `StoreBuffer.tla` coherence defect** was fixed locally in the new module. Other
  specs are believed unaffected because they write each field at most once per thread
  per round, but this was not exhaustively verified.
- **`ToString()` and `ThreadIdAt()`** can observe a transiently stale tag. Both are
  diagnostics; neither is under test.
- **User words** share the `Entry` cache line and inherit across a slot handoff, so
  they depend on the same handover this change rewrites. Analysed separately in
  [`userword-impact.md`](userword-impact.md): unaffected on x86, and the change closes
  two pre-existing ARM holes there.

---

## 8. Conclusion

`threadId` is demoted from claim token to derived state, but it remains **required**:
it is the only thing that distinguishes a claimed slot from one this thread is merely
probing, and removing it turns the probe window into a false positive (`indexonly_tso`).
Kept, and combined with the inverted `Release()` order, the query's contract is
unchanged in both directions — verified by model checking on x86-TSO and by an
A/B on x86 silicon whose forced-failure control demonstrably detects the defect the
fix avoids.
