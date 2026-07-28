--------------------------- MODULE LightEpochResumeAndRefresh ---------------------------
(***************************************************************************)
(* LightEpochResumeAndRefresh — the BUGGY baseline, modelled through the    *)
(* exact call sequence Tsavorite's default API (BasicContext) uses per      *)
(* operation.                                                              *)
(*                                                                         *)
(* A BasicContext Read/Upsert/RMW wraps every operation in                  *)
(*   UnsafeResumeThread()  = epoch.Resume() (Acquire: slot CAS + announce)  *)
(*                           + InternalRefresh() -> ProtectAndDrain()       *)
(*                             (a SECOND announce + drain)                  *)
(*   ... the operation ...                                                  *)
(*   UnsafeSuspendThread() = epoch.Suspend() (Release: slot back to 0).     *)
(*                                                                         *)
(* So a single operation issues TWO announce stores before the operation's  *)
(* shared-data load, and the following Release resets the slot to 0 —       *)
(* which is why the *next* operation re-opens the 0 -> E "absent reader"    *)
(* window all over again. Neither announce carries a StoreLoad fence in the *)
(* baseline, so both can sit in the reader's store buffer, leaving          *)
(* memory.localCurrentEpoch at 0 ("thread absent") when the reclaimer's     *)
(* scan reads the slot.                                                    *)
(*                                                                         *)
(* This is the same defect as MODULE LightEpoch, but proved against the     *)
(* real per-operation API shape rather than a single bare announce.         *)
(*                                                                         *)
(* The reclaimer is PROTECTED, exactly as in Tsavorite: BumpCurrentEpoch    *)
(* asserts ThisInstanceProtected(), so the retiring thread owns an epoch    *)
(* slot (memory.reclaimerLocalCurrentEpoch) and refreshes it every round.   *)
(* That slot participates in the ComputeNewSafeToReclaimEpoch min-scan and  *)
(* therefore clamps the safe epoch. Modelling the reclaimer as unprotected  *)
(* would leave it out of the scan and widen the window past anything real   *)
(* code can produce.                                                       *)
(*                                                                         *)
(* Expected: NoUseAfterFree is VIOLATED.                                   *)
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
    /\ memory = [ currentEpoch |-> 1, localCurrentEpoch |-> 0, reclaimerLocalCurrentEpoch |-> 0, objectUnlinked |-> FALSE, objectFreed |-> FALSE ]
    /\ storeBuffer = [ p \in Threads |-> <<>> ]
    /\ readerInCriticalSection = FALSE
    /\ readerAnnouncedEpoch = 0
    /\ triggerEpoch = 0
    /\ readerPc = "Acquire"
    /\ reclaimerPc = "AcquireReclaimer"

\* Asynchronous store-buffer drain: one buffered write becomes visible.
FlushOne(p) ==
    /\ SB!FlushOne(p)
    /\ UNCHANGED <<readerInCriticalSection, readerAnnouncedEpoch, triggerEpoch, readerPc, reclaimerPc>>

\* Reader ---------------------------------------------------------------------
\* Resume() -> Acquire announce (LightEpoch.cs:527): PLAIN store -> buffered.
Acquire ==
    /\ readerPc = "Acquire"
    /\ readerAnnouncedEpoch' = Load(Reader, "currentEpoch")
    /\ storeBuffer' = SB!Buffer(Reader, "localCurrentEpoch", readerAnnouncedEpoch')
    /\ readerPc' = "ProtectAndDrain"
    /\ UNCHANGED <<memory, readerInCriticalSection, triggerEpoch, reclaimerPc>>

\* InternalRefresh() -> ProtectAndDrain announce (LightEpoch.cs:304): a SECOND
\* PLAIN announce store, still no StoreLoad fence in the baseline.
ProtectAndDrain ==
    /\ readerPc = "ProtectAndDrain"
    /\ storeBuffer' = SB!Buffer(Reader, "localCurrentEpoch", Load(Reader, "currentEpoch"))
    /\ readerPc' = "ReadObject"
    /\ UNCHANGED <<memory, readerInCriticalSection, readerAnnouncedEpoch, triggerEpoch, reclaimerPc>>

\* The operation loads the object-linked flag; if it still looks linked, the
\* reader enters its critical section and dereferences the object.
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

\* Suspend()/Release: reset the slot to 0 ("absent"), re-opening the window
\* for a subsequent operation.
Release ==
    /\ readerPc = "Release"
    /\ storeBuffer' = SB!Buffer(Reader, "localCurrentEpoch", 0)
    /\ readerPc' = "Done"
    /\ UNCHANGED <<memory, readerInCriticalSection, readerAnnouncedEpoch, triggerEpoch, reclaimerPc>>

\* Reclaimer ------------------------------------------------------------------
\* Resume() -> Acquire on the reclaimer itself: BumpCurrentEpoch asserts
\* ThisInstanceProtected(), so the retiring thread holds its own epoch slot.
\* Same plain announce store as the reader's, so it buffers too.
AcquireReclaimer ==
    /\ reclaimerPc = "AcquireReclaimer"
    /\ storeBuffer' = SB!Buffer(Reclaimer, "reclaimerLocalCurrentEpoch", Load(Reclaimer, "currentEpoch"))
    /\ reclaimerPc' = "Unlink"
    /\ UNCHANGED <<memory, readerInCriticalSection, readerAnnouncedEpoch, triggerEpoch, readerPc>>

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
    /\ reclaimerPc' = "ProtectAndDrainReclaimer"
    /\ UNCHANGED <<readerInCriticalSection, readerAnnouncedEpoch, readerPc>>

\* InternalRefresh() -> ProtectAndDrain on the reclaimer: re-announce its own
\* slot at the new CurrentEpoch before scanning. Plain store, so it may still
\* be buffered when the scan below reads it back (store forwarding applies).
ProtectAndDrainReclaimer ==
    /\ reclaimerPc = "ProtectAndDrainReclaimer"
    /\ storeBuffer' = SB!Buffer(Reclaimer, "reclaimerLocalCurrentEpoch", Load(Reclaimer, "currentEpoch"))
    /\ reclaimerPc' = "ComputeNewSafeToReclaimEpoch"
    /\ UNCHANGED <<memory, readerInCriticalSection, readerAnnouncedEpoch, triggerEpoch, readerPc>>

\* ComputeNewSafeToReclaimEpoch (LightEpoch.cs:435):
\*   oldestOngoingCall = CurrentEpoch;
\*   for each entry: if (e != 0 && e < oldestOngoingCall) oldestOngoingCall = e;
\*   SafeToReclaimEpoch = oldestOngoingCall - 1;
\* The reader's slot is read from memory (a remote core, so still 0 while its
\* announce is buffered); the reclaimer reads its OWN slot with store
\* forwarding. The reclaimer's entry clamps the min but does not close the
\* window: after the bump the reclaimer sits at the new CurrentEpoch, so the
\* safe epoch still covers triggerEpoch.
ComputeNewSafeToReclaimEpoch ==
    /\ reclaimerPc = "ComputeNewSafeToReclaimEpoch"
    /\ LET currentEpochValue  == memory.currentEpoch
           readerSlot         == memory.localCurrentEpoch
           reclaimerSlot      == Load(Reclaimer, "reclaimerLocalCurrentEpoch")
           oldestWithReader   == IF readerSlot > 0 THEN Min(currentEpochValue, readerSlot) ELSE currentEpochValue
           oldestOngoingCall  == IF reclaimerSlot > 0 THEN Min(oldestWithReader, reclaimerSlot) ELSE oldestWithReader
           safeToReclaimEpoch == oldestOngoingCall - 1
       IN IF triggerEpoch <= safeToReclaimEpoch
          THEN /\ memory' = [memory EXCEPT !.objectFreed = TRUE]
               /\ reclaimerPc' = "Done"
          ELSE /\ UNCHANGED <<memory, reclaimerPc>>
    /\ UNCHANGED <<storeBuffer, readerInCriticalSection, readerAnnouncedEpoch, triggerEpoch, readerPc>>

Next == \/ Acquire \/ ProtectAndDrain \/ ReadObject \/ Dereference \/ Release
        \/ AcquireReclaimer \/ Unlink \/ BumpCurrentEpoch \/ ProtectAndDrainReclaimer \/ ComputeNewSafeToReclaimEpoch
        \/ (\E p \in Threads : FlushOne(p))

Spec == Init /\ [][Next]_vars

\* SAFETY: never free while a protected reader still dereferences the object.
NoUseAfterFree == ~ (memory.objectFreed /\ readerInCriticalSection)
=============================================================================
