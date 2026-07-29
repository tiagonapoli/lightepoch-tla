------------------------ MODULE TsavoriteReadWithBucketLatch ------------------------
(***************************************************************************)
(* THE CONTROL EXPERIMENT — the Tsavorite flow where the objection HOLDS.  *)
(*                                                                         *)
(* Same reclaimer (T2 = AllocatorBase.ShiftHeadAddress) as MODULE          *)
(* TsavoriteReadAtAddress. The only difference is T1: instead of           *)
(* ReadAtAddress, this is the ordinary BasicContext.Read path, which takes  *)
(* an ephemeral shared bucket latch before it touches the hybrid log.       *)
(*                                                                         *)
(* T1 = BasicContext.Read -> InternalRead  (InternalRead.cs:55)            *)
(* -----------------------------------------------------------------------*)
(*   UnsafeResumeThread()                                                   *)
(*     epoch.Resume()          -> announce      LightEpoch.cs:530  PLAIN   *)
(*     InternalRefresh()/ProtectAndDrain()      LightEpoch.cs:307  PLAIN   *)
(*   FindTagAndTryEphemeralSLock(...)           Helpers.cs:232             *)
(*     FindTag(ref hei)                         TsavoriteBase.cs:132       *)
(*     TryEphemeralSLock -> BasicSessionLocker.TryLockEphemeralShared      *)
(*                                              ISessionLocker.cs:47       *)
(*       -> LockTable.TryLockShared -> HashBucket.TryAcquireSharedLatch    *)
(*          Interlocked.CompareExchange(ref entry_word, ...)               *)
(*                                              HashBucket.cs:53           *)
(*                                          -> A FULL BARRIER, AND IT      *)
(*                                             LANDS BEFORE THE DEREF      *)
(*   ... HeadAddress check, TryFindRecordInMemory, GetPhysicalAddress ...  *)
(*                                                                         *)
(* Because the bucket latch CAS drains the reader's store buffer BEFORE the *)
(* HeadAddress load and the page dereference, the announce is globally      *)
(* visible by the time the reclaimer's min-scan runs. The scan sees the     *)
(* reader, clamps SafeToReclaimEpoch below the retire epoch, and does not   *)
(* free. The invariant HOLDS.                                              *)
(*                                                                         *)
(* THIS IS THE POINT OF THE PAIR. The two specs differ ONLY in whether an   *)
(* incidental interlocked operation happens to sit between the epoch        *)
(* announce and the protected dereference:                                  *)
(*                                                                         *)
(*   TsavoriteReadAtAddress        latch absent   -> VIOLATED              *)
(*   TsavoriteReadWithBucketLatch  latch present  -> HOLDS                 *)
(*                                                                         *)
(* So "Tsavorite already adds the barrier" is not a property of Tsavorite.  *)
(* It is a property of ONE code path, produced by a lock that exists for    *)
(* unrelated reasons (concurrency control, not reclamation safety), that no *)
(* comment or test enforces, and that several other flows do not take:      *)
(*                                                                         *)
(*   - InternalReadAtAddress       no latch before the deref               *)
(*                                 (InternalRead.cs:252-269)               *)
(*   - TransactionalSessionLocker.TryLockEphemeralShared returns true with  *)
(*     no interlocked operation at all (ISessionLocker.cs:90)              *)
(*   - scan/iterator and eviction-observer paths read pages under epoch     *)
(*     protection with no bucket latch (ScanIteratorBase, MemoryPageScan)   *)
(*                                                                         *)
(* Expected: NoUseAfterFree HOLDS (both "tso" and "arm").                  *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANT Model          \* "tso" | "arm" — see MODULE StoreBuffer

Reader == "Reader"
Reclaimer == "Reclaimer"
Threads == {Reader, Reclaimer}

RecordAddress == 1
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
(* T1 — BasicContext.Read                                                  *)
(***************************************************************************)

Resume ==
    /\ readerPc = "Resume"
    /\ storeBuffer' = SB!Buffer(Reader, "readerLocalCurrentEpoch", Load(Reader, "currentEpoch"))
    /\ readerPc' = "ProtectAndDrain"
    /\ UNCHANGED <<memory, readerDereferencingPage, triggerEpoch, reclaimerPc>>

ProtectAndDrain ==
    /\ readerPc = "ProtectAndDrain"
    /\ storeBuffer' = SB!Buffer(Reader, "readerLocalCurrentEpoch", Load(Reader, "currentEpoch"))
    /\ readerPc' = "TryAcquireSharedLatch"
    /\ UNCHANGED <<memory, readerDereferencingPage, triggerEpoch, reclaimerPc>>

\* HashBucket.TryAcquireSharedLatch (HashBucket.cs:53):
\*   Interlocked.CompareExchange(ref entry_word, expected + kSharedLatchIncrement, expected)
\* A full barrier. It drains the reader's pending announces to shared memory
\* before any of the loads below are performed.
TryAcquireSharedLatch ==
    /\ readerPc = "TryAcquireSharedLatch"
    /\ memory' = SB!Fenced(Reader)
    /\ storeBuffer' = SB!Drained(Reader)
    /\ readerPc' = "CheckHeadAddress"
    /\ UNCHANGED <<readerDereferencingPage, triggerEpoch, reclaimerPc>>

CheckHeadAddress ==
    /\ readerPc = "CheckHeadAddress"
    /\ IF RecordAddress < Load(Reader, "headAddress")
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
(* T2 — AllocatorBase.ShiftHeadAddress (identical to the sibling spec)     *)
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

Next == \/ Resume \/ ProtectAndDrain \/ TryAcquireSharedLatch \/ CheckHeadAddress
        \/ DereferencePage \/ Suspend
        \/ ResumeReclaimer \/ MonotonicUpdateHeadAddress \/ BumpCurrentEpoch
        \/ ProtectAndDrainReclaimer \/ ComputeNewSafeToReclaimEpoch
        \/ (\E p \in Threads : FlushOne(p))

Spec == Init /\ [][Next]_vars

NoUseAfterFree == ~ (memory.pageFreed /\ readerDereferencingPage)
=============================================================================
