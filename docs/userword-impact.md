# Does the slot-claim change affect `AllocateUserWord` and the user-word feature?

Companion to `thisinstanceprotected-audit.md`, for the same change
(`workstream/lightepoch-x86-minimal`, PR #3).

**Answer: on x86, no — nothing changes in either direction. On ARM the change
*closes two pre-existing holes* in the user-word handoff, one of which was a
memory-safety bug rather than a performance one.** The direction is never worse.

---

## 1. Why the question is a good one

User words are not a separate structure. They live in the **same `Entry` cache line**
as `localCurrentEpoch` and `threadId`:

| Offset | Field |
| --- | --- |
| 0 | `localCurrentEpoch` — now the claim word |
| 8 | `threadId` — now a plain trailing store |
| 16–56 | `userWord0` … `userWord5` |

And crucially, the column belongs to the **entry**, not the thread:

> *After allocation, the application owns the slot contents — LightEpoch does not
> automatically reset slots on epoch Acquire/Release.*
> — `LightEpoch.AllocateUserWord` doc comment

So the next owner of a slot inherits whatever the previous owner left there. That
makes the *slot handoff* — precisely what this change rewrites — part of the
user-word contract, even though no user-word code was touched.

## 2. What the diff actually touches

Blob-to-blob diff against the merge base (the file was moved, so a path diff shows
it as new):

```
git diff 0ad0a08e:libs/.../core/Epochs/LightEpoch.cs HEAD:libs/.../epoch/LightEpoch.cs
 1 file changed, 47 insertions(+), 43 deletions(-)
```

Filtering that diff for `userWord`, `UserWord`, `FieldOffset`, `kCacheLineBytes`,
`GetMin` returns **zero lines**. `AllocateUserWord`, `ReleaseUserWord`,
`ThisThreadUserWord`, `GetMinUserWord`, `UserWordRef` and the `Entry` layout are
byte-identical. The user-word API predates the PR — it is upstream Garnet, not
something this branch introduced.

So the question is entirely about ordering, not about code.

## 3. The one production consumer

`TsavoriteLog` (`TsavoriteLog.cs:258, 295, 306, 401, 649`) uses a user word for the
in-flight enqueue publish protocol behind `SafeTailAddress`:

```csharp
inflightWord = epoch.AllocateUserWord(InflightInactive);          // long.MaxValue

void BeginInflightEnqueue() => Volatile.Write(ref epoch.ThisThreadUserWord(inflightWord), allocator.GetTailAddress());
void EndInflightEnqueue()   => Volatile.Write(ref epoch.ThisThreadUserWord(inflightWord), InflightInactive);

long minInflight = epoch.GetMinUserWord(inflightWord);
long computed = minInflight < tail ? minInflight : tail;          // SafeTailAddress
```

`SafeTailAddress` decides which log range iterators may read. Getting it **too low**
stalls readers. Getting it **too high** lets a reader read a slot whose payload has
not been written — a torn read. The asymmetry matters, and both directions turn out
to be reachable across a slot handoff.

---

## 4. Two hazards, modelled

`herd/jit-derived/litmus/*userword*` — six new rows, all matching expectation, in a
suite where all 26 rows now pass.

### 4a. Stale inherited value (benign direction)

The arriving owner reads a user word still holding the departing owner's live
in-flight address.

| Test | Result |
| --- | --- |
| `x86-userword-handoff-main` (upstream) | **Never** |
| `x86-userword-handoff-fixed` | **Never** |
| `arm64-userword-handoff-main` (upstream) | **Sometimes** |
| `arm64-userword-handoff-fixed` | **Never** |

Consequence if it happened: `GetMinUserWord` folds a value that is too low, so
`SafeTailAddress` lags and iterators stall. Conservative — and self-healing, because
the arriving owner's own `BeginInflightEnqueue` overwrites it.

### 4b. Lost in-flight publish (the dangerous direction)

The departing owner's `InflightInactive` sentinel and the arriving owner's live
publish are a **write-write race on the same user word** — structurally the same race
as the one on `threadId`. If the sentinel lands last, a live in-flight enqueue is
erased.

| Test | Result |
| --- | --- |
| `x86-userword-lostpublish-main` (upstream) | **Never** |
| `arm64-userword-lostpublish-main` (upstream) | **Sometimes** |
| `arm64-userword-lostpublish-fixed` | **Never** |

Consequence if it happened: `GetMinUserWord` folds a neutral value where a live one
belongs, `SafeTailAddress` advances past a slot whose payload has not been written,
and an iterator reads it. **That is a torn read, not a stall.**

### Why x86 is unaffected either way

On x86 both handover stores are plain `MOV`, and TSO does not reorder store-store.
The departing owner's user-word write therefore precedes its handover store in the
total store order; the arriving owner cannot claim until the handover store is
visible; so the arriving owner's own publish is necessarily later. TSO supplies for
free exactly the ordering that the release store has to supply on ARM. Upstream was
already safe on x86, and the fix does not take that away.

### Why the fix closes it on ARM

Release store on `localCurrentEpoch` → claim CAS reads-from it → acquire. Everything
the departing thread did before unpublishing — user words included — is carried
across the handoff, and the arriving owner's own publish cannot hoist above its own
CAS. Upstream had no writer-side release at all: the handover was a plain store to
`threadId`, so the pairing was broken on the writer's side even though
`Interlocked.CompareExchange` gives the claimer a full barrier.

**This is a side effect of the fix, not a design goal.** It falls out of making
`localCurrentEpoch` the ownership word and unpublishing it with a release store.

---

## 5. The other surfaces, checked

| Surface | Verdict |
| --- | --- |
| `ThisThreadUserWord`'s `Debug.Assert(ThisInstanceProtected())` | DEBUG-only, and the query is proven correct in both directions — see `thisinstanceprotected-audit.md`. |
| `GetMinUserWord` | Reads only user words; never touches `localCurrentEpoch` or `threadId`. Structurally independent of the change. |
| `AllocateUserWord`'s column initialization | Guarded by its own `userWordMask` CAS, and the index is not published to any consumer until the loop completes. Orthogonal. |
| `Entry` layout / `kCacheLineBytes` | Unchanged — zero diff lines. |
| Hot-path contention | The claim CAS moved from offset 8 to offset 0 — **same cache line**, so no change in contention with the per-enqueue user-word writes at 16–56. No locked operation was added to the steady state. |
| Free-slot test (`threadId == 0` → `localCurrentEpoch == 0`) | The two disagree only *transiently*, inside `Release()`. After `Release()` both are zero; after `Acquire()` both are non-zero. No stable disagreement, so entry assignment is unchanged. |

## 6. Test evidence

All green on `workstream/lightepoch-x86-minimal`, net8.0 and net10.0:

| Project | Tests | Result |
| --- | --- | --- |
| `Garnet.LightEpoch.test` (includes `UserWordTests.cs`) | 47 × 2 | pass |
| `Tsavorite.test.hlog` (SafeTail, Scan, ShiftTail stress, FastCommit, ReadAsync) | 546 × 2, 93 skipped (Azure) | pass |
| `Tsavorite.test.recovery` (includes `LogResumeTests`) | 201 × 2 | pass |

1,494 tests, 0 failures. Note this is x86 hardware, where §4 predicts no difference —
the suites confirm no regression rather than exercising the ARM hazard.

## 7. Conclusion

The user-word feature is unaffected on x86 and strictly better off on ARM. Nothing in
`AllocateUserWord`, `ThisThreadUserWord`, `GetMinUserWord` or the `Entry` layout
changed, and the one ordering property the feature silently depends on — that a
departing owner's last user-word write is visible to the next owner of the slot — went
from *unordered* to *release/acquire paired*.

Worth noting for the PR description: `arm64-userword-lostpublish-main` is a latent
**memory-safety** bug in upstream Garnet on ARM, independent of the epoch-announce bug
this branch set out to fix, and this change happens to fix it too.
