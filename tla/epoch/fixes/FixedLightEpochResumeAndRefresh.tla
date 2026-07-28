------------------------- MODULE FixedLightEpochResumeAndRefresh -------------------------
(***************************************************************************)
(* FixedLightEpochResumeAndRefresh — the FIX (full StoreLoad barrier)      *)
(* proved against Tsavorite's exact per-operation call sequence.           *)
(*                                                                         *)
(* Same per-operation shape as MODULE LightEpochResumeAndRefresh:          *)
(*   Resume() -> Acquire announce, InternalRefresh() -> ProtectAndDrain    *)
(*   announce, the operation's load, then Suspend() -> Release (slot back  *)
(*   to 0),                                                                *)
(* but now BOTH announce sites carry a full StoreLoad barrier              *)
(* (Interlocked.MemoryBarrier() -> DMB ISH / lock or), exactly as          *)
(* FixedLightEpochWithMemoryBarrier fences LightEpoch.cs:527 (Acquire) and *)
(* :304 (ProtectAndDrain).                                                 *)
(*                                                                         *)
(* Because each announce drains the reader's store buffer before the       *)
(* operation's load, memory.localCurrentEpoch is non-zero whenever the     *)
(* reclaimer's scan runs — the reader is never mistaken for "absent", even *)
(* though Release resets the slot to 0 between operations.                 *)
(*                                                                         *)
(* Reclaimer modelling — deliberately ASYMMETRIC with respect to           *)
(* MODULE LightEpochResumeAndRefresh, and the asymmetry is the             *)
(* conservative direction in both cases:                                   *)
(*                                                                         *)
(*   - The buggy spec models a PROTECTED reclaimer (it owns an epoch slot  *)
(*     that joins the ComputeNewSafeToReclaimEpoch min-scan), because that *)
(*     is what Tsavorite actually does. A bug claim must not be built on   *)
(*     an adversary stronger than production.                              *)
(*                                                                         *)
(*   - This spec models an UNPROTECTED reclaimer (no reclaimer slot). Its  *)
(*     absence can only RAISE oldestOngoingCall, hence raise               *)
(*     SafeToReclaimEpoch, hence reclaim MORE aggressively. Proving the    *)
(*     fix safe here is therefore strictly stronger than proving it under  *)
(*     a protected reclaimer.                                              *)
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

FlushOne(p) ==
    /\ SB!FlushOne(p)
    /\ UNCHANGED <<readerInCriticalSection, readerAnnouncedEpoch, triggerEpoch, readerPc, reclaimerPc>>

\* Reader ---------------------------------------------------------------------
\* Resume() -> Acquire announce + FULL StoreLoad barrier: drain the reader's
\* store buffer so memory.localCurrentEpoch is globally visible before the
\* next store or load.
Acquire ==
    /\ readerPc = "Acquire"
    /\ readerAnnouncedEpoch' = Load(Reader, "currentEpoch")
    /\ memory' = SB!FencedStore(Reader, "localCurrentEpoch", readerAnnouncedEpoch')
    /\ storeBuffer' = SB!Drained(Reader)
    /\ readerPc' = "ProtectAndDrain"
    /\ UNCHANGED <<readerInCriticalSection, triggerEpoch, reclaimerPc>>

\* InternalRefresh() -> ProtectAndDrain announce + FULL StoreLoad barrier: the
\* second announce is also drained before the operation's load.
ProtectAndDrain ==
    /\ readerPc = "ProtectAndDrain"
    /\ memory' = SB!FencedStore(Reader, "localCurrentEpoch", Load(Reader, "currentEpoch"))
    /\ storeBuffer' = SB!Drained(Reader)
    /\ readerPc' = "ReadObject"
    /\ UNCHANGED <<readerInCriticalSection, readerAnnouncedEpoch, triggerEpoch, reclaimerPc>>

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

\* Suspend() -> Release: reset the slot to 0 ("absent").
Release ==
    /\ readerPc = "Release"
    /\ storeBuffer' = SB!Buffer(Reader, "localCurrentEpoch", 0)
    /\ readerPc' = "Done"
    /\ UNCHANGED <<memory, readerInCriticalSection, readerAnnouncedEpoch, triggerEpoch, reclaimerPc>>

\* Reclaimer ------------------------------------------------------------------
\* Unlink the object so new readers cannot reach it.
Unlink ==
    /\ reclaimerPc = "Unlink"
    /\ storeBuffer' = SB!Buffer(Reclaimer, "objectUnlinked", TRUE)
    /\ reclaimerPc' = "BumpCurrentEpoch"
    /\ UNCHANGED <<memory, readerInCriticalSection, readerAnnouncedEpoch, triggerEpoch, readerPc>>

\* Interlocked.Increment(CurrentEpoch) (LightEpoch.cs:365): a full RMW, so it
\* drains the reclaimer's own store buffer.
BumpCurrentEpoch ==
    /\ reclaimerPc = "BumpCurrentEpoch"
    /\ LET fencedMemory == SB!Fenced(Reclaimer)
       IN /\ memory' = [fencedMemory EXCEPT !.currentEpoch = fencedMemory.currentEpoch + 1]
          /\ triggerEpoch' = fencedMemory.currentEpoch
    /\ storeBuffer' = SB!Drained(Reclaimer)
    /\ reclaimerPc' = "ComputeNewSafeToReclaimEpoch"
    /\ UNCHANGED <<readerInCriticalSection, readerAnnouncedEpoch, readerPc>>

\* ComputeNewSafeToReclaimEpoch (LightEpoch.cs:435). The reclaimer is modelled
\* as UNPROTECTED here, so only the reader's slot clamps oldestOngoingCall.
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

Next == \/ Acquire \/ ProtectAndDrain \/ ReadObject \/ Dereference \/ Release
        \/ Unlink \/ BumpCurrentEpoch \/ ComputeNewSafeToReclaimEpoch
        \/ (\E p \in Threads : FlushOne(p))

Spec == Init /\ [][Next]_vars

NoUseAfterFree == ~ (memory.objectFreed /\ readerInCriticalSection)
=============================================================================
