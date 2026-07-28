------------------------ MODULE FixedLightEpochWithMemoryBarrier ------------------------
(***************************************************************************)
(* FixedLightEpochWithMemoryBarrier — the validated FIX: a full StoreLoad   *)
(* barrier on the reader's own core, between the announce and the first    *)
(* load.                                                                   *)
(*                                                                         *)
(* Identical to MODULE LightEpoch except for one step: Acquire publishes   *)
(* the announce with SB!FencedStore instead of SB!Buffer, modelling the    *)
(* plain announce store at LightEpoch.cs:527 followed by                   *)
(*                                                                         *)
(*     Interlocked.MemoryBarrier();                                        *)
(*                                                                         *)
(* The barrier drains the reader's store buffer, so localCurrentEpoch is   *)
(* globally visible before the reader can load the object-linked flag. The *)
(* reclaimer's scan therefore always observes the live reader, clamps      *)
(* SafeToReclaimEpoch below the retire epoch, and does not free.           *)
(*                                                                         *)
(* Note the fix must sit on the READER's core. A barrier on the reclaimer  *)
(* cannot help: a fence drains only the buffer of the core that executes   *)
(* it, and the stale value is sitting in the reader's buffer.              *)
(*                                                                         *)
(* Checked under both "tso" and "arm" (see MODULE StoreBuffer). It holds   *)
(* under "arm" with the same state count as "tso", because the barrier     *)
(* leaves the reader's buffer empty — there is never more than one pending *)
(* store for the StoreStore relaxation to reorder. The fix does not depend *)
(* on FIFO drain order.                                                    *)
(*                                                                         *)
(* Expected: NoUseAfterFree HOLDS (exhaustively verified).                 *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANT Model          \* "tso" | "arm" — see MODULE StoreBuffer

Reader == "Reader"
Reclaimer == "Reclaimer"
Threads == {Reader, Reclaimer}

VARIABLES memory, storeBuffer, readerInCriticalSection, readerAnnouncedEpoch, triggerEpoch, readerPc, reclaimerPc
vars == <<memory, storeBuffer, readerInCriticalSection, readerAnnouncedEpoch, triggerEpoch, readerPc, reclaimerPc>>

SB == INSTANCE StoreBuffer
Load(p, f) == SB!Load(p, f)
Min(a, b)  == SB!Min(a, b)

Init ==
    /\ memory = [ currentEpoch |-> 1, localCurrentEpoch |-> 0, objectUnlinked |-> FALSE, objectFreed |-> FALSE ]
    /\ storeBuffer = [ p \in Threads |-> <<>> ]
    /\ readerInCriticalSection = FALSE
    /\ readerAnnouncedEpoch = 0
    /\ triggerEpoch = 0
    /\ readerPc = "Acquire"
    /\ reclaimerPc = "Unlink"

\* Asynchronous store-buffer drain: one buffered write becomes visible.
FlushOne(p) ==
    /\ SB!FlushOne(p)
    /\ UNCHANGED <<readerInCriticalSection, readerAnnouncedEpoch, triggerEpoch, readerPc, reclaimerPc>>

\* Reader ---------------------------------------------------------------------
\* Announce + FULL StoreLoad barrier (Interlocked.MemoryBarrier). Draining the
\* reader's store buffer here makes memory.localCurrentEpoch globally visible
\* before the reader loads anything, so the StoreLoad window is CLOSED.
Acquire ==
    /\ readerPc = "Acquire"
    /\ readerAnnouncedEpoch' = Load(Reader, "currentEpoch")
    /\ memory' = SB!FencedStore(Reader, "localCurrentEpoch", readerAnnouncedEpoch')
    /\ storeBuffer' = SB!Drained(Reader)
    /\ readerPc' = "ReadObject"
    /\ UNCHANGED <<readerInCriticalSection, triggerEpoch, reclaimerPc>>

\* Load the object-linked flag; if it still looks linked, mark that we hold it.
ReadObject ==
    /\ readerPc = "ReadObject"
    /\ readerInCriticalSection' = (~ Load(Reader, "objectUnlinked"))
    /\ readerPc' = "Dereference"
    /\ UNCHANGED <<memory, storeBuffer, readerAnnouncedEpoch, triggerEpoch, reclaimerPc>>

Dereference ==
    /\ readerPc = "Dereference"
    /\ readerInCriticalSection' = FALSE
    /\ readerPc' = "Release"
    /\ UNCHANGED <<memory, storeBuffer, readerAnnouncedEpoch, triggerEpoch, reclaimerPc>>

Release ==
    /\ readerPc = "Release"
    /\ storeBuffer' = SB!Buffer(Reader, "localCurrentEpoch", 0)
    /\ readerPc' = "Done"
    /\ UNCHANGED <<memory, readerInCriticalSection, readerAnnouncedEpoch, triggerEpoch, reclaimerPc>>

\* Reclaimer ------------------------------------------------------------------
Unlink ==
    /\ reclaimerPc = "Unlink"
    /\ storeBuffer' = SB!Buffer(Reclaimer, "objectUnlinked", TRUE)
    /\ reclaimerPc' = "BumpCurrentEpoch"
    /\ UNCHANGED <<memory, readerInCriticalSection, readerAnnouncedEpoch, triggerEpoch, readerPc>>

\* Interlocked.Increment(CurrentEpoch): a full RMW -> drains Reclaimer's store buffer.
BumpCurrentEpoch ==
    /\ reclaimerPc = "BumpCurrentEpoch"
    /\ LET fencedMemory == SB!Fenced(Reclaimer)
       IN /\ memory' = [fencedMemory EXCEPT !.currentEpoch = fencedMemory.currentEpoch + 1]
          /\ triggerEpoch' = fencedMemory.currentEpoch
    /\ storeBuffer' = SB!Drained(Reclaimer)
    /\ reclaimerPc' = "ComputeNewSafeToReclaimEpoch"
    /\ UNCHANGED <<readerInCriticalSection, readerAnnouncedEpoch, readerPc>>

\* ComputeNewSafeToReclaimEpoch (LightEpoch.cs:435): reads the reader's slot
\* and frees if the retire epoch is at or below SafeToReclaimEpoch. With the
\* barrier in Acquire the slot is never spuriously 0, so the live reader always
\* clamps oldestOngoingCall and the object is not freed underneath it.
ComputeNewSafeToReclaimEpoch ==
    /\ reclaimerPc = "ComputeNewSafeToReclaimEpoch"
    /\ LET readerSlot         == memory.localCurrentEpoch
           oldestOngoingCall  == IF readerSlot > 0 THEN Min(memory.currentEpoch, readerSlot) ELSE memory.currentEpoch
           safeToReclaimEpoch == oldestOngoingCall - 1
       IN IF triggerEpoch <= safeToReclaimEpoch
          THEN /\ memory' = [memory EXCEPT !.objectFreed = TRUE]
               /\ reclaimerPc' = "Done"
          ELSE /\ UNCHANGED <<memory, reclaimerPc>>
    /\ UNCHANGED <<storeBuffer, readerInCriticalSection, readerAnnouncedEpoch, triggerEpoch, readerPc>>

Next == \/ Acquire \/ ReadObject \/ Dereference \/ Release
        \/ Unlink \/ BumpCurrentEpoch \/ ComputeNewSafeToReclaimEpoch
        \/ (\E p \in Threads : FlushOne(p))

Spec == Init /\ [][Next]_vars

\* SAFETY: never free while a protected reader still dereferences the object.
NoUseAfterFree == ~ (memory.objectFreed /\ readerInCriticalSection)
=============================================================================
