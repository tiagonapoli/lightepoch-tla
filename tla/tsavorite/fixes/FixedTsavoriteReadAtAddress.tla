------------------------ MODULE FixedTsavoriteReadAtAddress ------------------------
(***************************************************************************)
(* MODULE TsavoriteReadAtAddress with the LightEpoch fix applied.          *)
(*                                                                         *)
(* Identical to TsavoriteReadAtAddress in every respect -- same two real    *)
(* Tsavorite flows, same reclaimer, same Tsavorite-side interlocked         *)
(* barriers -- except that the epoch ANNOUNCE stores in Acquire() and       *)
(* ProtectAndDrain() carry a StoreLoad barrier, as in                       *)
(* FixedLightEpochWithMemoryBarrier.                                        *)
(*                                                                         *)
(* This is the whole argument in one diff:                                  *)
(*                                                                         *)
(*   TsavoriteReadAtAddress        (Tsavorite's barriers only)  VIOLATED   *)
(*   FixedTsavoriteReadAtAddress   (+ fence in LightEpoch)      HOLDS      *)
(*                                                                         *)
(* The fix belongs in LightEpoch because that is the only place that covers *)
(* every caller. Fixing it in Tsavorite would mean auditing and annotating  *)
(* each individual flow -- ReadAtAddress, transactional contexts, scan      *)
(* iterators, eviction observers -- and keeping that audit correct forever. *)
(*                                                                         *)
(* Expected: NoUseAfterFree HOLDS (both "tso" and "arm").                  *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANT Model          \* "tso" | "arm" — see MODULE StoreBuffer

Reader == "Reader"
Reclaimer == "Reclaimer"
Threads == {Reader, Reclaimer}

ReadAtAddress == 1
NewHeadAddress == 2

VARIABLES memory, storeBuffer, readerDereferencingPage, triggerEpoch, readerPc, reclaimerPc
vars == <<memory, storeBuffer, readerDereferencingPage, triggerEpoch, readerPc, reclaimerPc>>

SB == INSTANCE StoreBuffer
Load(p, f) == SB!Load(p, f)
Min(a, b)  == SB!Min(a, b)

Init ==
    /\ memory = [ currentEpoch                |-> 1
                , readerLocalCurrentEpoch     |-> 0
                , reclaimerLocalCurrentEpoch  |-> 0
                , headAddress                 |-> 0
                , pageFreed                   |-> FALSE ]
    /\ storeBuffer = [ p \in Threads |-> <<>> ]
    /\ readerDereferencingPage = FALSE
    /\ triggerEpoch = 0
    /\ readerPc = "Resume"
    /\ reclaimerPc = "ResumeReclaimer"

FlushOne(p) ==
    /\ SB!FlushOne(p)
    /\ UNCHANGED <<readerDereferencingPage, triggerEpoch, readerPc, reclaimerPc>>

(***************************************************************************)
(* T1 — BasicContext.ReadAtAddress, on a FIXED LightEpoch                  *)
(***************************************************************************)

\* THE FIX: the announce is a fenced store, so it is globally visible before
\* the reader performs any subsequent load.
Resume ==
    /\ readerPc = "Resume"
    /\ memory' = SB!FencedStore(Reader, "readerLocalCurrentEpoch", Load(Reader, "currentEpoch"))
    /\ storeBuffer' = SB!Drained(Reader)
    /\ readerPc' = "ProtectAndDrain"
    /\ UNCHANGED <<readerDereferencingPage, triggerEpoch, reclaimerPc>>

\* The refresh announce is fenced for the same reason: ProtectAndDrain
\* re-publishes the slot and every later load must be ordered after it.
ProtectAndDrain ==
    /\ readerPc = "ProtectAndDrain"
    /\ memory' = SB!FencedStore(Reader, "readerLocalCurrentEpoch", Load(Reader, "currentEpoch"))
    /\ storeBuffer' = SB!Drained(Reader)
    /\ readerPc' = "CheckHeadAddress"
    /\ UNCHANGED <<readerDereferencingPage, triggerEpoch, reclaimerPc>>

CheckHeadAddress ==
    /\ readerPc = "CheckHeadAddress"
    /\ IF ReadAtAddress < Load(Reader, "headAddress")
       THEN /\ readerPc' = "Suspend"
            /\ UNCHANGED readerDereferencingPage
       ELSE /\ readerDereferencingPage' = TRUE
            /\ readerPc' = "DereferencePage"
    /\ UNCHANGED <<memory, storeBuffer, triggerEpoch, reclaimerPc>>

DereferencePage ==
    /\ readerPc = "DereferencePage"
    /\ readerDereferencingPage' = FALSE
    /\ readerPc' = "Suspend"
    /\ UNCHANGED <<memory, storeBuffer, triggerEpoch, reclaimerPc>>

Suspend ==
    /\ readerPc = "Suspend"
    /\ storeBuffer' = SB!Buffer(Reader, "readerLocalCurrentEpoch", 0)
    /\ readerPc' = "Done"
    /\ UNCHANGED <<memory, readerDereferencingPage, triggerEpoch, reclaimerPc>>

(***************************************************************************)
(* T2 — AllocatorBase.ShiftHeadAddress (unchanged from the buggy spec)     *)
(***************************************************************************)

ResumeReclaimer ==
    /\ reclaimerPc = "ResumeReclaimer"
    /\ storeBuffer' = SB!Buffer(Reclaimer, "reclaimerLocalCurrentEpoch", Load(Reclaimer, "currentEpoch"))
    /\ reclaimerPc' = "MonotonicUpdateHeadAddress"
    /\ UNCHANGED <<memory, readerDereferencingPage, triggerEpoch, readerPc>>

MonotonicUpdateHeadAddress ==
    /\ reclaimerPc = "MonotonicUpdateHeadAddress"
    /\ memory' = [SB!Fenced(Reclaimer) EXCEPT !.headAddress = NewHeadAddress]
    /\ storeBuffer' = SB!Drained(Reclaimer)
    /\ reclaimerPc' = "BumpCurrentEpoch"
    /\ UNCHANGED <<readerDereferencingPage, triggerEpoch, readerPc>>

BumpCurrentEpoch ==
    /\ reclaimerPc = "BumpCurrentEpoch"
    /\ LET fencedMemory == SB!Fenced(Reclaimer)
       IN /\ memory' = [fencedMemory EXCEPT !.currentEpoch = fencedMemory.currentEpoch + 1]
          /\ triggerEpoch' = fencedMemory.currentEpoch
    /\ storeBuffer' = SB!Drained(Reclaimer)
    /\ reclaimerPc' = "ProtectAndDrainReclaimer"
    /\ UNCHANGED <<readerDereferencingPage, readerPc>>

ProtectAndDrainReclaimer ==
    /\ reclaimerPc = "ProtectAndDrainReclaimer"
    /\ storeBuffer' = SB!Buffer(Reclaimer, "reclaimerLocalCurrentEpoch", Load(Reclaimer, "currentEpoch"))
    /\ reclaimerPc' = "ComputeNewSafeToReclaimEpoch"
    /\ UNCHANGED <<memory, readerDereferencingPage, triggerEpoch, readerPc>>

ComputeNewSafeToReclaimEpoch ==
    /\ reclaimerPc = "ComputeNewSafeToReclaimEpoch"
    /\ LET currentEpochValue  == memory.currentEpoch
           readerSlot         == memory.readerLocalCurrentEpoch
           reclaimerSlot      == Load(Reclaimer, "reclaimerLocalCurrentEpoch")
           oldestWithReader   == IF readerSlot > 0 THEN Min(currentEpochValue, readerSlot) ELSE currentEpochValue
           oldestOngoingCall  == IF reclaimerSlot > 0 THEN Min(oldestWithReader, reclaimerSlot) ELSE oldestWithReader
           safeToReclaimEpoch == oldestOngoingCall - 1
       IN IF triggerEpoch <= safeToReclaimEpoch
          THEN /\ memory' = [memory EXCEPT !.pageFreed = TRUE]
               /\ reclaimerPc' = "Done"
          ELSE /\ UNCHANGED <<memory, reclaimerPc>>
    /\ UNCHANGED <<storeBuffer, readerDereferencingPage, triggerEpoch, readerPc>>

Next == \/ Resume \/ ProtectAndDrain \/ CheckHeadAddress \/ DereferencePage \/ Suspend
        \/ ResumeReclaimer \/ MonotonicUpdateHeadAddress \/ BumpCurrentEpoch
        \/ ProtectAndDrainReclaimer \/ ComputeNewSafeToReclaimEpoch
        \/ (\E p \in Threads : FlushOne(p))

Spec == Init /\ [][Next]_vars

NoUseAfterFree == ~ (memory.pageFreed /\ readerDereferencingPage)
=============================================================================
