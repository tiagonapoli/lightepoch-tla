--------------------- MODULE CasAnnounceProtectedQueryProbe ---------------------
(***************************************************************************)
(* ThisInstanceProtected() on a MULTI-SLOT table, with the probe window     *)
(* that TryAcquireEntry() actually has.                                    *)
(*                                                                         *)
(* CasAnnounceProtectedQuery checks the same query on ONE slot, and its     *)
(* header states that a false POSITIVE is "structurally impossible and no   *)
(* invariant below looks for one". That is an argument, not a check, and it *)
(* is the direction the fix makes harder to reason about: after the fix,    *)
(* threadId no longer gates entry to the slot, so nothing about it is given *)
(* by the CAS any more. This module checks that direction, and it does so   *)
(* on the only structure that can express it.                              *)
(*                                                                         *)
(* WHY ONE SLOT CANNOT EXPRESS IT. The query is                            *)
(*                                                                         *)
(*     ThisInstanceProtected()                                             *)
(*         == kInvalidIndex != entry && slot[entry].threadId == myThreadId  *)
(*                                                                         *)
(* and `entry` is Metadata.Entries[instanceId] -- thread-private, and       *)
(* written by TryAcquireEntry BEFORE the claim succeeds:                   *)
(*                                                                         *)
(*     entry = Metadata.startOffset1;        <-- thread-private write       *)
(*     if (TryClaimEntry(entry, epoch))      <-- may FAIL                   *)
(*         return true;                                                    *)
(*     ... swap offsets, then circle the table ...                          *)
(*     entry = Metadata.startOffset1;        <-- again, for each candidate  *)
(*                                                                         *)
(* So between the first candidate write and a successful claim, `entry` is  *)
(* NON-INVALID while the thread owns nothing, and it points at slots other  *)
(* threads may own. With a one-slot table there is nothing to probe past,   *)
(* so that window has no states and the false positive is unreachable for   *)
(* a reason that has nothing to do with the algorithm. Two slots and two    *)
(* readers is the smallest table in which a reader is forced to walk past   *)
(* a slot another reader holds.                                            *)
(*                                                                         *)
(* WHAT HOLDS THE FALSE POSITIVE OFF is then exactly one thing: the         *)
(* threadId tag. It is the sole reason the query is not simply              *)
(* `entry != kInvalidIndex`. The QueryKind axis makes that claim falsifiable*)
(* rather than rhetorical -- "indexonly" drops the tag and nothing else,    *)
(* and the false positive appears immediately in the probe window.          *)
(*                                                                         *)
(* AXES                                                                    *)
(*                                                                         *)
(*   QueryKind                                                             *)
(*     "tagged"     production: entry != kInvalidIndex AND tag matches.     *)
(*     "indexonly"  control: entry != kInvalidIndex only. Isolates the TAG. *)
(*                                                                         *)
(*   ReleaseOrder  (as in CasAnnounceProtectedQuery, re-checked here on a   *)
(*                 table where slots are contended and reused)             *)
(*     "release"    the fix: clear the tag, THEN unpublish with a release   *)
(*                  store.                                                 *)
(*     "plain"      the fix's order, plain unpublish. Isolates the FENCE.   *)
(*     "upstream"   unpublish FIRST, clear the tag after. Isolates the      *)
(*                  ORDER; the unpublish is still a release store so the    *)
(*                  fence axis is held fixed.                              *)
(*                                                                         *)
(* THE TWO INVARIANTS ARE GATED DIFFERENTLY, ON PURPOSE.                    *)
(*                                                                         *)
(*   NoFalsePositive is UN-GATED -- checked in every state, including       *)
(*   states inside Acquire() and Release() from which production cannot     *)
(*   actually call the query. That is deliberate. The tag is what makes the *)
(*   query answer safely no matter when it is asked, and that robustness is *)
(*   the property worth having: it is what lets ~130 call sites, four of    *)
(*   which are reached from I/O completion callbacks, use the query without *)
(*   each one having to argue about where it sits relative to a claim.      *)
(*                                                                         *)
(*   NoFalseNegative is GATED to Settled(r). A thread that has CAS-ed the   *)
(*   slot but not yet stored its tag genuinely owns the slot and genuinely  *)
(*   answers "not protected" -- but it is executing inside TryClaimEntry at *)
(*   that moment and cannot call the query. The same is true between the    *)
(*   tag clear and the unpublish in Release(). Un-gating it would report    *)
(*   those two windows as bugs; they are not observable and the gate says   *)
(*   so explicitly rather than by omission.                                *)
(*                                                                         *)
(* EXPECTED                                                                *)
(*                                                                         *)
(*   tagged    release  tso/arm   NoFalsePositive HOLDS                     *)
(*                                NoFalseNegative HOLDS                     *)
(*   indexonly release  tso       NoFalsePositive VIOLATED  <- the tag's job *)
(*   tagged    plain    arm       NoFalsePositive HOLDS                     *)
(*                                NoFalseNegative VIOLATED  <- fence axis    *)
(*   tagged    upstream tso       NoFalsePositive VIOLATED  <- NEW           *)
(*                                NoFalseNegative VIOLATED  <- order axis    *)
(*                                                                         *)
(* The upstream row's false POSITIVE is new here and does not appear in the *)
(* one-slot spec. In upstream order the slot is published free while the    *)
(* departing thread still carries a matching tag and a non-invalid entry    *)
(* index, so for that window the thread's own query claims protection over  *)
(* a slot that another thread is already free to take. It is not reachable  *)
(* from production code -- the window is interior to Release() -- but it is *)
(* the second, independent reason the two stores in Release() have to be in *)
(* the order the fix puts them in.                                         *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANT Model         \* "tso" | "arm"
CONSTANT QueryKind     \* "tagged" (production) | "indexonly" (control: no tag)
CONSTANT ReleaseOrder  \* "release" (the fix) | "plain" | "upstream"

R1 == "R1"
R2 == "R2"
Readers == {R1, R2}
Threads == Readers

\* kInvalidIndex is 0, so slots are numbered from 1 as in production.
kInvalidIndex == 0
Slots == {1, 2}

\* Distinct and non-zero: 0 means "no thread", and managed thread ids of live
\* threads are distinct. That distinctness is the whole content of the tag.
ThreadIdOf == [r \in Readers |-> IF r = R1 THEN 11 ELSE 22]

\* The announced epoch's VALUE is immaterial to the query -- only zero versus
\* non-zero matters, because 0 is the free-slot sentinel the CAS tests against.
\* Fixing one distinct non-zero epoch per reader keeps that structure and keeps
\* the state space finite without a monotone counter.
EpochOf == [r \in Readers |-> IF r = R1 THEN 1 ELSE 2]

VARIABLES memory, storeBuffer, entryIndex, ownedBy, probe, readerPc
vars == <<memory, storeBuffer, entryIndex, ownedBy, probe, readerPc>>

SB == INSTANCE StoreBuffer
Load(p, f) == SB!Load(p, f)

(***************************************************************************)
(* PER-LOCATION COHERENCE                                                  *)
(*                                                                         *)
(* This spec cannot use SB!FlushOne, and the reason is worth stating        *)
(* because it is a property of the shared substrate rather than of this     *)
(* spec.                                                                   *)
(*                                                                         *)
(* MODULE StoreBuffer's "arm" model lets ANY pending store retire next. For *)
(* two stores to DIFFERENT fields that is the StoreStore relaxation it is   *)
(* meant to express. For two stores to the SAME field it is not a           *)
(* relaxation of anything real: every architecture, x86 and AArch64 alike,  *)
(* guarantees coherence -- the writes to a single location form one total   *)
(* order, and one processor's contribution to it is its own program order.  *)
(* A store can never be overtaken by a later store to the same address.     *)
(*                                                                         *)
(* Every other epoch spec in this repo writes each field at most once per   *)
(* thread per round, so the distinction never arose and SB!FlushOne is      *)
(* sound for them. This spec is the first to write one field TWICE in a     *)
(* round -- PublishTag then ClearTag both target slot[entry].threadId --    *)
(* and the unrestricted model promptly retires the clear first, leaving the *)
(* publish pending, and then drains it on top of a slot that has already    *)
(* been freed. The result is a slot whose epoch reads 0 and whose tag still *)
(* reads the departed owner's id, which lets that owner walk back in on a   *)
(* later probe and answer "protected" over a slot it does not hold.         *)
(*                                                                         *)
(* That trace is a resurrection of a dead value, and no machine can produce *)
(* it. Restricting the choice to stores with no older pending store to the  *)
(* same field removes exactly it and nothing else: stores to distinct       *)
(* fields still retire in any order, so the StoreStore relaxation the "arm" *)
(* row exists to test is fully intact -- as the plain/arm row below         *)
(* confirms by still failing.                                              *)
(***************************************************************************)
CoherentFlushOne(p) ==
    /\ storeBuffer[p] # <<>>
    /\ \E i \in DOMAIN storeBuffer[p] :
         \* No older pending store to the same location.
         /\ \A j \in DOMAIN storeBuffer[p] :
              (j < i) => storeBuffer[p][j].f # storeBuffer[p][i].f
         \* TSO additionally drains strictly FIFO, as SB!FlushOne does.
         /\ (Model = "tso") => (i = 1)
         /\ memory' = [memory EXCEPT ![storeBuffer[p][i].f] = storeBuffer[p][i].v]
         /\ storeBuffer' = [storeBuffer EXCEPT ![p] =
                SubSeq(storeBuffer[p], 1, i - 1) \o
                SubSeq(storeBuffer[p], i + 1, Len(storeBuffer[p]))]

\* Flat field names, so MODULE StoreBuffer's record-of-fields shape carries a
\* table rather than a single slot.
EpochF(s) == IF s = 1 THEN "slot1Epoch" ELSE "slot2Epoch"
TidF(s)   == IF s = 1 THEN "slot1Tid"   ELSE "slot2Tid"

Init ==
    /\ memory = [ slot1Epoch |-> 0, slot1Tid |-> 0, slot2Epoch |-> 0, slot2Tid |-> 0 ]
    /\ storeBuffer = [ p \in Threads |-> <<>> ]
    \* Metadata.Entries[instanceId] -- thread-private.
    /\ entryIndex = [ r \in Readers |-> kInvalidIndex ]
    \* Ghost ground truth. Not read by any action; only the invariants use it.
    /\ ownedBy = [ s \in Slots |-> "none" ]
    /\ probe = [ r \in Readers |-> 1 ]
    /\ readerPc = [ r \in Readers |-> "Probe" ]

FlushOne(p) ==
    /\ CoherentFlushOne(p)
    /\ UNCHANGED <<entryIndex, ownedBy, probe, readerPc>>

(***************************************************************************)
(* The query under test                                                    *)
(***************************************************************************)

\* A PLAIN load of the tag, so it is subject to store forwarding exactly as the
\* real one is: the thread sees its own not-yet-drained tag store even while
\* other cores still read the previous owner's value.
TagMatches(r) == Load(r, TidF(entryIndex[r])) = ThreadIdOf[r]

ThisInstanceProtected(r) ==
    /\ entryIndex[r] # kInvalidIndex
    /\ (QueryKind = "indexonly" \/ TagMatches(r))

(***************************************************************************)
(* Reader: Acquire()                                                       *)
(***************************************************************************)

\* TryAcquireEntry writes the candidate into the THREAD-PRIVATE entry index
\* before it knows whether the claim will succeed. This is the probe window.
Probe(r) ==
    /\ readerPc[r] = "Probe"
    /\ entryIndex' = [entryIndex EXCEPT ![r] = probe[r]]
    /\ readerPc' = [readerPc EXCEPT ![r] = "Claim"]
    /\ UNCHANGED <<memory, storeBuffer, ownedBy, probe>>

\* TryClaimEntry: Interlocked.CompareExchange(ref slot.localCurrentEpoch, e, 0).
\* A locked RMW -- drains this core's buffer and acts on globally visible state.
Claim(r) ==
    /\ readerPc[r] = "Claim"
    /\ LET m == SB!Fenced(r)
           s == entryIndex[r]
       IN IF m[EpochF(s)] = 0
          THEN /\ memory' = [m EXCEPT ![EpochF(s)] = EpochOf[r]]
               /\ ownedBy' = [ownedBy EXCEPT ![s] = r]
               /\ readerPc' = [readerPc EXCEPT ![r] = "PublishTag"]
               /\ UNCHANGED probe
          ELSE /\ memory' = m
               /\ ownedBy' = ownedBy
               \* Walk to the next candidate, or start the circuit over. Either
               \* way `entry` keeps the stale candidate until Probe overwrites
               \* it -- which is precisely the window being checked.
               /\ probe' = [probe EXCEPT ![r] = IF probe[r] = 2 THEN 1 ELSE probe[r] + 1]
               /\ readerPc' = [readerPc EXCEPT ![r] = "Probe"]
    /\ storeBuffer' = SB!Drained(r)
    /\ UNCHANGED entryIndex

\* Plain store: the slot is already exclusively ours, so no interlocked write is
\* needed to keep others out. After the fix this store is ALL that threadId is.
PublishTag(r) ==
    /\ readerPc[r] = "PublishTag"
    /\ storeBuffer' = SB!Buffer(r, TidF(entryIndex[r]), ThreadIdOf[r])
    /\ readerPc' = [readerPc EXCEPT ![r] = "Protected"]
    /\ UNCHANGED <<memory, entryIndex, ownedBy, probe>>

\* The protected region. Production would run the critical section here and may
\* call ThisInstanceProtected() at any point in it; the invariants cover that.
Protected(r) ==
    /\ readerPc[r] = "Protected"
    /\ readerPc' = [readerPc EXCEPT ![r] = IF ReleaseOrder = "upstream"
                                           THEN "UnpublishFirst" ELSE "ClearTag"]
    /\ UNCHANGED <<memory, storeBuffer, entryIndex, ownedBy, probe>>

(***************************************************************************)
(* Reader: Release(), in the two orders                                    *)
(***************************************************************************)

\* The fix: clear the tag BEFORE the slot is published as free.
ClearTag(r) ==
    /\ readerPc[r] = "ClearTag"
    /\ storeBuffer' = SB!Buffer(r, TidF(entryIndex[r]), 0)
    /\ readerPc' = [readerPc EXCEPT ![r] = "Unpublish"]
    /\ UNCHANGED <<memory, entryIndex, ownedBy, probe>>

\* Volatile.Write, or a plain store on the control row. "release" drains this
\* thread's pending stores, so the tag clear above cannot be observed after the
\* slot is seen free -- which is what stops it from landing on top of the next
\* owner's tag.
Unpublish(r) ==
    /\ readerPc[r] = "Unpublish"
    /\ \/ /\ ReleaseOrder = "release"
          /\ memory' = SB!FencedStore(r, EpochF(entryIndex[r]), 0)
          /\ storeBuffer' = SB!Drained(r)
       \/ /\ ReleaseOrder = "plain"
          /\ storeBuffer' = SB!Buffer(r, EpochF(entryIndex[r]), 0)
          /\ UNCHANGED memory
    /\ ownedBy' = [ownedBy EXCEPT ![entryIndex[r]] = "none"]
    /\ entryIndex' = [entryIndex EXCEPT ![r] = kInvalidIndex]
    /\ readerPc' = [readerPc EXCEPT ![r] = "Probe"]
    /\ UNCHANGED probe

\* Upstream order: the slot is published free while this thread still holds a
\* matching tag AND a non-invalid entry index. `ownedBy` drops here because this
\* is the instant another thread may take the slot.
UnpublishFirst(r) ==
    /\ readerPc[r] = "UnpublishFirst"
    /\ memory' = SB!FencedStore(r, EpochF(entryIndex[r]), 0)
    /\ storeBuffer' = SB!Drained(r)
    /\ ownedBy' = [ownedBy EXCEPT ![entryIndex[r]] = "none"]
    /\ readerPc' = [readerPc EXCEPT ![r] = "ClearTagLate"]
    /\ UNCHANGED <<entryIndex, probe>>

ClearTagLate(r) ==
    /\ readerPc[r] = "ClearTagLate"
    /\ storeBuffer' = SB!Buffer(r, TidF(entryIndex[r]), 0)
    /\ entryIndex' = [entryIndex EXCEPT ![r] = kInvalidIndex]
    /\ readerPc' = [readerPc EXCEPT ![r] = "Probe"]
    /\ UNCHANGED <<memory, ownedBy, probe>>

Next ==
    \/ \E r \in Readers :
         \/ Probe(r) \/ Claim(r) \/ PublishTag(r) \/ Protected(r)
         \/ ClearTag(r) \/ Unpublish(r)
         \/ UnpublishFirst(r) \/ ClearTagLate(r)
    \/ (\E p \in Threads : FlushOne(p))

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(* Invariants                                                              *)
(***************************************************************************)

Owns(r) == entryIndex[r] # kInvalidIndex /\ ownedBy[entryIndex[r]] = r

\* The direction the fix makes non-obvious, and the one the one-slot spec only
\* argued: the query must never claim protection the thread does not have.
\* Un-gated -- see the header.
NoFalsePositive == \A r \in Readers : ThisInstanceProtected(r) => Owns(r)

\* Points at which production could actually evaluate the query: outside the
\* LightEpoch internals. "Protected" is the critical section; "Probe" is the
\* thread sitting unprotected between acquires.
Settled(r) == readerPc[r] \in {"Probe", "Protected"}

NoFalseNegative == \A r \in Readers : (Settled(r) /\ Owns(r)) => ThisInstanceProtected(r)

\* Sanity: the CAS really is what grants the slot, so an owner's slot always
\* reads as announced in globally visible memory.
OwnedImpliesAnnounced ==
    \A s \in Slots : ownedBy[s] # "none" => memory[EpochF(s)] # 0
=============================================================================
