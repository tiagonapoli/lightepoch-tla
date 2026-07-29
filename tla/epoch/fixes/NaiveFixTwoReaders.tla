------------------------ MODULE NaiveFixTwoReaders ------------------------
(***************************************************************************)
(* Does the NAIVE FIX still hold once a slot can be REUSED?                *)
(*                                                                         *)
(* The naive fix is the obvious one: keep Tsavorite's structure exactly as  *)
(* it is and just add a StoreLoad barrier straight after the announce.      *)
(*                                                                         *)
(*     CAS(slot.threadId, 0 -> myThreadId)      <- claims the slot         *)
(*     slot.localCurrentEpoch = CurrentEpoch    <- announce                *)
(*     Interlocked.MemoryBarrier()              <- THE NAIVE FIX           *)
(*     ... critical section ...                                            *)
(*     slot.localCurrentEpoch = 0               <- plain store             *)
(*     slot.threadId = 0                        <- plain store             *)
(*                                                                         *)
(* Against a SINGLE reader this is correct, and the repo's                  *)
(* FixedLightEpochWithMemoryBarrier spec confirms it: the barrier closes    *)
(* the announce->load window that causes the use-after-free.                *)
(*                                                                         *)
(* But the single-reader specs can never exercise slot HANDOFF. Release()   *)
(* leaves the slot with TWO plain stores and no ordering between them:      *)
(*                                                                         *)
(*     localCurrentEpoch = 0    (a)                                        *)
(*     threadId = 0             (b)                                        *)
(*                                                                         *)
(* and threadId is the word the next acquirer CASes on. So if (b) becomes   *)
(* visible before (a) — which TSO forbids but a store-order-relaxed machine *)
(* permits — a second reader can win the slot, announce its own epoch, and  *)
(* enter its critical section while the FIRST reader's store (a) is STILL   *)
(* PENDING. When (a) finally lands it overwrites the new owner's announce   *)
(* with 0, the reclaimer's scan reads 0 as "nobody is here", and frees      *)
(* memory the second reader is actively dereferencing.                      *)
(*                                                                         *)
(* Note this failure has NOTHING to do with the announce barrier. The       *)
(* barrier is present and doing its job; the hole is in Release(). Adding   *)
(* the barrier is therefore necessary but not sufficient on a machine that  *)
(* can reorder those two stores.                                            *)
(*                                                                         *)
(* Expected: HOLDS under "tso" (FIFO drain forces (a) out before (b), so a  *)
(* claimant that sees threadId == 0 necessarily also sees the epoch cleared)*)
(* and VIOLATED under "arm".                                                *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANT Model

R1 == "R1"
R2 == "R2"
Reclaimer == "Reclaimer"
Readers == {R1, R2}
Threads == {R1, R2, Reclaimer}

ThreadIdOf == [r \in Readers |-> IF r = R1 THEN 11 ELSE 22]

VARIABLES memory, storeBuffer, inCriticalSection, owns, readerPc, triggerEpoch, reclaimerPc
vars == <<memory, storeBuffer, inCriticalSection, owns, readerPc, triggerEpoch, reclaimerPc>>

SB == INSTANCE StoreBuffer
Load(p, f) == SB!Load(p, f)
Min(a, b)  == SB!Min(a, b)

Init ==
    /\ memory = [ currentEpoch |-> 1, slotEpoch |-> 0, slotThreadId |-> 0,
                  objectUnlinked |-> FALSE, objectFreed |-> FALSE ]
    /\ storeBuffer = [ p \in Threads |-> <<>> ]
    /\ inCriticalSection = [ r \in Readers |-> FALSE ]
    /\ owns = [ r \in Readers |-> FALSE ]
    /\ readerPc = [ r \in Readers |-> "ClaimThreadId" ]
    /\ triggerEpoch = 0
    /\ reclaimerPc = "Unlink"

FlushOne(p) ==
    /\ SB!FlushOne(p)
    /\ UNCHANGED <<inCriticalSection, owns, readerPc, triggerEpoch, reclaimerPc>>

(***************************************************************************)
(* Reader — production structure, plus the naive barrier                   *)
(***************************************************************************)

\* Interlocked.CompareExchange(ref slot.threadId, myThreadId, 0). Locked RMW,
\* so it is a full barrier — but it sits BEFORE the announce, which is the
\* useless side for the announce->scan race.
ClaimThreadId(r) ==
    /\ readerPc[r] = "ClaimThreadId"
    /\ LET m == SB!Fenced(r)
       IN IF m.slotThreadId = 0
          THEN /\ memory' = [m EXCEPT !.slotThreadId = ThreadIdOf[r]]
               /\ owns' = [owns EXCEPT ![r] = TRUE]
               /\ readerPc' = [readerPc EXCEPT ![r] = "Announce"]
          ELSE /\ memory' = m
               /\ owns' = owns
               /\ readerPc' = [readerPc EXCEPT ![r] = "ClaimThreadId"]
    /\ storeBuffer' = SB!Drained(r)
    /\ UNCHANGED <<inCriticalSection, triggerEpoch, reclaimerPc>>

\* The announce, immediately followed by Interlocked.MemoryBarrier(): modelled
\* as a store that is globally visible before this thread's next load.
Announce(r) ==
    /\ readerPc[r] = "Announce"
    /\ memory' = SB!FencedStore(r, "slotEpoch", Load(r, "currentEpoch"))
    /\ storeBuffer' = SB!Drained(r)
    /\ readerPc' = [readerPc EXCEPT ![r] = "ReadObject"]
    /\ UNCHANGED <<inCriticalSection, owns, triggerEpoch, reclaimerPc>>

ReadObject(r) ==
    /\ readerPc[r] = "ReadObject"
    /\ inCriticalSection' = [inCriticalSection EXCEPT ![r] = ~ Load(r, "objectUnlinked")]
    /\ readerPc' = [readerPc EXCEPT ![r] = "Dereference"]
    /\ UNCHANGED <<memory, storeBuffer, owns, triggerEpoch, reclaimerPc>>

Dereference(r) ==
    /\ readerPc[r] = "Dereference"
    /\ inCriticalSection' = [inCriticalSection EXCEPT ![r] = FALSE]
    /\ readerPc' = [readerPc EXCEPT ![r] = "ClearEpoch"]
    /\ UNCHANGED <<memory, storeBuffer, owns, triggerEpoch, reclaimerPc>>

\* Release(), store (a): plain, buffered.
ClearEpoch(r) ==
    /\ readerPc[r] = "ClearEpoch"
    /\ storeBuffer' = SB!Buffer(r, "slotEpoch", 0)
    /\ readerPc' = [readerPc EXCEPT ![r] = "ClearThreadId"]
    /\ UNCHANGED <<memory, inCriticalSection, owns, triggerEpoch, reclaimerPc>>

\* Release(), store (b): plain, buffered. This is the store that hands the slot
\* to the next acquirer, and nothing orders it after (a).
ClearThreadId(r) ==
    /\ readerPc[r] = "ClearThreadId"
    /\ storeBuffer' = SB!Buffer(r, "slotThreadId", 0)
    /\ owns' = [owns EXCEPT ![r] = FALSE]
    /\ readerPc' = [readerPc EXCEPT ![r] = "Done"]
    /\ UNCHANGED <<memory, inCriticalSection, triggerEpoch, reclaimerPc>>

(***************************************************************************)
(* Reclaimer — unchanged from production                                   *)
(***************************************************************************)

Unlink ==
    /\ reclaimerPc = "Unlink"
    /\ storeBuffer' = SB!Buffer(Reclaimer, "objectUnlinked", TRUE)
    /\ reclaimerPc' = "BumpCurrentEpoch"
    /\ UNCHANGED <<memory, inCriticalSection, owns, readerPc, triggerEpoch>>

BumpCurrentEpoch ==
    /\ reclaimerPc = "BumpCurrentEpoch"
    /\ LET fencedMemory == SB!Fenced(Reclaimer)
       IN /\ memory' = [fencedMemory EXCEPT !.currentEpoch = fencedMemory.currentEpoch + 1]
          /\ triggerEpoch' = fencedMemory.currentEpoch
    /\ storeBuffer' = SB!Drained(Reclaimer)
    /\ reclaimerPc' = "ComputeNewSafeToReclaimEpoch"
    /\ UNCHANGED <<inCriticalSection, owns, readerPc>>

ComputeNewSafeToReclaimEpoch ==
    /\ reclaimerPc = "ComputeNewSafeToReclaimEpoch"
    /\ LET slot              == memory.slotEpoch
           oldestOngoingCall == IF slot > 0 THEN Min(memory.currentEpoch, slot) ELSE memory.currentEpoch
           safeToReclaimEpoch == oldestOngoingCall - 1
       IN IF triggerEpoch <= safeToReclaimEpoch
          THEN /\ memory' = [memory EXCEPT !.objectFreed = TRUE]
               /\ reclaimerPc' = "Done"
          ELSE /\ UNCHANGED <<memory, reclaimerPc>>
    /\ UNCHANGED <<storeBuffer, inCriticalSection, owns, readerPc, triggerEpoch>>

Next ==
    \/ \E r \in Readers :
         \/ ClaimThreadId(r) \/ Announce(r) \/ ReadObject(r)
         \/ Dereference(r) \/ ClearEpoch(r) \/ ClearThreadId(r)
    \/ Unlink \/ BumpCurrentEpoch \/ ComputeNewSafeToReclaimEpoch
    \/ (\E p \in Threads : FlushOne(p))

Spec == Init /\ [][Next]_vars

NoUseAfterFree == ~ (memory.objectFreed /\ (\E r \in Readers : inCriticalSection[r]))

SlotExclusive == ~ (owns[R1] /\ owns[R2])

\* The direct statement of the hazard: a reader that owns the slot and is inside
\* its critical section must not see its announce erased to 0 by the previous
\* owner's still-pending store.
AnnounceNotWiped ==
    \A r \in Readers :
        (owns[r] /\ inCriticalSection[r]) => memory.slotEpoch # 0
=============================================================================
