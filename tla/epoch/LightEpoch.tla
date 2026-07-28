------------------------------ MODULE LightEpoch ------------------------------
(***************************************************************************)
(* LightEpoch epoch-protection model — the BUGGY baseline.                 *)
(*                                                                         *)
(* Models the epoch ENTER path against a per-core store buffer (the x86-TSO *)
(* shape; the same StoreLoad window exists, and is far easier to observe,  *)
(* on ARM64).                                                             *)
(*                                                                         *)
(* Names follow the production identifiers in LightEpoch.cs so the trace   *)
(* can be read against the source:                                         *)
(*                                                                         *)
(*   memory.currentEpoch        LightEpoch.CurrentEpoch                    *)
(*   memory.localCurrentEpoch   Entry.localCurrentEpoch, the reader's slot *)
(*                              AS THE REST OF THE MACHINE SEES IT         *)
(*   memory.objectUnlinked      the object has been unlinked/retired       *)
(*   memory.objectFreed         the drain action ran and released it       *)
(*   triggerEpoch               drainList[i].epoch — the retire epoch      *)
(*   readerAnnouncedEpoch       the value the reader copied into its slot  *)
(*   readerInCriticalSection    the reader is dereferencing the object     *)
(*                                                                         *)
(* Two threads share one epoch:                                            *)
(*   Reader     Acquire: announce localCurrentEpoch := CurrentEpoch as a   *)
(*              PLAIN store (so it lands in the reader's store buffer),    *)
(*              then load the object-linked flag and, if it still looks    *)
(*              linked, dereference the object.                            *)
(*   Reclaimer  unlink the object, Interlocked-bump CurrentEpoch (a full   *)
(*              RMW, so this DRAINS the reclaimer's own buffer — that side *)
(*              is already correctly fenced), then run the                 *)
(*              ComputeNewSafeToReclaimEpoch scan: if the retire epoch is  *)
(*              <= SafeToReclaimEpoch, FREE.                               *)
(*                                                                         *)
(* THE DEFECT: the reader's announce store can still be sitting in its     *)
(* store buffer — so memory.localCurrentEpoch is still 0, "thread absent"  *)
(* — when the reclaimer's scan reads the slot. The scan skips the slot,    *)
(* computes a safe epoch past the live reader, and frees the object the    *)
(* reader is about to dereference.                                         *)
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

\* The per-core store buffer, store forwarding, and fences live in one shared
\* module so every epoch spec is checked against the same hardware substrate.
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
\* Resume() -> Acquire announce (LightEpoch.cs:527): a PLAIN store, so it is
\* buffered and carries no StoreLoad fence.
Acquire ==
    /\ readerPc = "Acquire"
    /\ readerAnnouncedEpoch' = Load(Reader, "currentEpoch")
    /\ storeBuffer' = SB!Buffer(Reader, "localCurrentEpoch", readerAnnouncedEpoch')
    /\ readerPc' = "ReadObject"
    /\ UNCHANGED <<memory, readerInCriticalSection, triggerEpoch, reclaimerPc>>

\* Load the object-linked flag; if it still looks linked, enter the critical
\* section (the reader is now dereferencing the object).
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

\* Suspend() -> Release (LightEpoch.cs:548): reset the slot to 0 ("absent").
Release ==
    /\ readerPc = "Release"
    /\ storeBuffer' = SB!Buffer(Reader, "localCurrentEpoch", 0)
    /\ readerPc' = "Done"
    /\ UNCHANGED <<memory, readerInCriticalSection, readerAnnouncedEpoch, triggerEpoch, reclaimerPc>>

\* Reclaimer ------------------------------------------------------------------
\* Unlink the object so new readers cannot reach it (the repro's curPage = 0).
Unlink ==
    /\ reclaimerPc = "Unlink"
    /\ storeBuffer' = SB!Buffer(Reclaimer, "objectUnlinked", TRUE)
    /\ reclaimerPc' = "BumpCurrentEpoch"
    /\ UNCHANGED <<memory, readerInCriticalSection, readerAnnouncedEpoch, triggerEpoch, readerPc>>

\* Interlocked.Increment(CurrentEpoch) (LightEpoch.cs:365): a full RMW, so it
\* drains the reclaimer's own store buffer. The retire is tagged with the epoch
\* that was current before the bump (BumpCurrentEpoch's PriorEpoch).
BumpCurrentEpoch ==
    /\ reclaimerPc = "BumpCurrentEpoch"
    /\ LET fencedMemory == SB!Fenced(Reclaimer)
       IN /\ memory' = [fencedMemory EXCEPT !.currentEpoch = fencedMemory.currentEpoch + 1]
          /\ triggerEpoch' = fencedMemory.currentEpoch
    /\ storeBuffer' = SB!Drained(Reclaimer)
    /\ reclaimerPc' = "ComputeNewSafeToReclaimEpoch"
    /\ UNCHANGED <<readerInCriticalSection, readerAnnouncedEpoch, readerPc>>

\* ComputeNewSafeToReclaimEpoch (LightEpoch.cs:435):
\*   oldestOngoingCall = currentEpoch;
\*   for each entry: if (entry != 0 && entry < oldestOngoingCall) oldestOngoingCall = entry;
\*   SafeToReclaimEpoch = oldestOngoingCall - 1;
\* The reader's slot is read from memory, so it is still 0 while the reader's
\* announce is buffered — the scan cannot distinguish "no reader" from "reader
\* not yet visible", skips it, and frees.
ComputeNewSafeToReclaimEpoch ==
    /\ reclaimerPc = "ComputeNewSafeToReclaimEpoch"
    /\ LET readerSlot        == memory.localCurrentEpoch
           oldestOngoingCall == IF readerSlot > 0 THEN Min(memory.currentEpoch, readerSlot) ELSE memory.currentEpoch
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
