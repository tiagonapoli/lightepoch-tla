------------------------ MODULE TsavoriteTransactionalRead ------------------------
(***************************************************************************)
(* THE SAME CODE PATH THAT WAS SAFE, RUN IN A TRANSACTIONAL SESSION.       *)
(*                                                                         *)
(* MODULE TsavoriteReadWithBucketLatch concedes the objection: the ordinary *)
(* BasicContext.Read -> InternalRead flow IS rescued, because               *)
(* BasicSessionLocker.TryLockEphemeralShared takes a hash-bucket latch with *)
(* Interlocked.CompareExchange (HashBucket.cs:53) before the page is        *)
(* dereferenced.                                                           *)
(*                                                                         *)
(* This module runs THE VERY SAME InternalRead code, over the very same     *)
(* allocator, with the very same reclaimer -- but from a transactional      *)
(* session. The rescue disappears, and the invariant fails.                 *)
(*                                                                         *)
(* WHY THE FENCE DISAPPEARS                                                *)
(* -----------------------------------------------------------------------*)
(* TryEphemeralSLock dispatches through ISessionLocker. Transactional       *)
(* sessions bind TransactionalSessionLocker, whose implementation is:       *)
(*                                                                         *)
(*   public bool TryLockEphemeralShared(... ref stackCtx)                   *)
(*   {                                                                     *)
(*       Debug.Assert(store.LockTable.IsLocked(ref stackCtx.hei), ...);     *)
(*       return true;                                                      *)
(*   }                                       ISessionLocker.cs:89-97       *)
(*                                                                         *)
(* There is no Interlocked operation, no lock, and no Thread.MemoryBarrier. *)
(* Debug.Assert is compiled out entirely in Release, so in a shipping build *)
(* this method is literally `return true`. Helpers.cs:236 states the reason *)
(* outright -- "Manual locking already automatically locks the bucket" --   *)
(* the bucket was latched back at BeginTransaction/Lock time, so no CAS is  *)
(* performed per operation.                                                *)
(*                                                                         *)
(* The locks acquired at BeginTransaction do NOT help. TransactionalContext *)
(* calls UnsafeResumeThread on EVERY operation (ClientSession.cs:540), so   *)
(* the announce store happens AFTER those locks were taken. A barrier in    *)
(* the past cannot order a store issued in the future.                      *)
(*                                                                         *)
(* T1 = TransactionalContext.Read -> InternalRead  (InternalRead.cs:55)    *)
(* -----------------------------------------------------------------------*)
(*   UnsafeResumeThread()                       ClientSession.cs:540       *)
(*     epoch.Resume()          -> announce      LightEpoch.cs:530  PLAIN   *)
(*     InternalRefresh()/ProtectAndDrain()      LightEpoch.cs:307  PLAIN   *)
(*   FindTagAndTryEphemeralSLock(...)           Helpers.cs:232             *)
(*     FindTag(ref hei)                         TsavoriteBase.cs:132       *)
(*     TryEphemeralSLock                                                   *)
(*       -> TransactionalSessionLocker.TryLockEphemeralShared              *)
(*          Debug.Assert(...); return true;     ISessionLocker.cs:89  NO-OP*)
(*                                          -> NO BARRIER OF ANY KIND      *)
(*   stackCtx.SetRecordSourceToHashEntry(hlogBase)                         *)
(*   ... HeadAddress check ...                  AllocatorBase.cs:123 PLAIN *)
(*   TryFindRecordInMemory -> hlog.CreateLogRecord                         *)
(*     -> GetPhysicalAddress                                               *)
(*     -> *(pagePointers + pageIndex)           AllocatorBase.cs:674 DEREF *)
(*                                                                         *)
(* T2 = AllocatorBase.ShiftHeadAddress  (AllocatorBase.cs:1581)            *)
(*   Byte-for-byte the same reclaimer as the sibling modules, with          *)
(*   MonotonicUpdate's Interlocked.CompareExchange (Utility.cs:372) and     *)
(*   BumpCurrentEpoch's Interlocked.Increment (LightEpoch.cs:368) both      *)
(*   modelled as FULL StoreLoad barriers.                                   *)
(*                                                                         *)
(* WHAT THIS TRIPLE PROVES                                                 *)
(* -----------------------------------------------------------------------*)
(*   TsavoriteReadWithBucketLatch   basic session, latch CAS  -> HOLDS     *)
(*   TsavoriteTransactionalRead     transactional, no CAS     -> VIOLATED  *)
(*                                                                         *)
(* Identical application code, identical allocator, identical reclaimer.    *)
(* The only variable is which ISessionLocker the session happens to bind.   *)
(* "Tsavorite already adds the barrier" is therefore not a property of the  *)
(* code path at all -- it is a property of the session type chosen by the   *)
(* caller, decided far away and enforced by nothing.                        *)
(*                                                                         *)
(* Expected: NoUseAfterFree is VIOLATED (both "tso" and "arm").            *)
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
(* T1 — TransactionalContext.Read                                          *)
(***************************************************************************)

Resume ==
    /\ readerPc = "Resume"
    /\ storeBuffer' = SB!Buffer(Reader, "readerLocalCurrentEpoch", Load(Reader, "currentEpoch"))
    /\ readerPc' = "ProtectAndDrain"
    /\ UNCHANGED <<memory, readerDereferencingPage, triggerEpoch, reclaimerPc>>

ProtectAndDrain ==
    /\ readerPc = "ProtectAndDrain"
    /\ storeBuffer' = SB!Buffer(Reader, "readerLocalCurrentEpoch", Load(Reader, "currentEpoch"))
    /\ readerPc' = "TryLockEphemeralShared"
    /\ UNCHANGED <<memory, readerDereferencingPage, triggerEpoch, reclaimerPc>>

\* TransactionalSessionLocker.TryLockEphemeralShared (ISessionLocker.cs:89).
\* In Release this is `return true`. The reader's announces stay in its store
\* buffer: nothing here forces them out. Compare the sibling module, where
\* this exact step is SB!Fenced/SB!Drained and that is the whole difference.
TryLockEphemeralShared ==
    /\ readerPc = "TryLockEphemeralShared"
    /\ readerPc' = "CheckHeadAddress"
    /\ UNCHANGED <<memory, storeBuffer, readerDereferencingPage, triggerEpoch, reclaimerPc>>

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
(* T2 — AllocatorBase.ShiftHeadAddress (identical to the sibling specs)    *)
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

Next == \/ Resume \/ ProtectAndDrain \/ TryLockEphemeralShared \/ CheckHeadAddress
        \/ DereferencePage \/ Suspend
        \/ ResumeReclaimer \/ MonotonicUpdateHeadAddress \/ BumpCurrentEpoch
        \/ ProtectAndDrainReclaimer \/ ComputeNewSafeToReclaimEpoch
        \/ (\E p \in Threads : FlushOne(p))

Spec == Init /\ [][Next]_vars

NoUseAfterFree == ~ (memory.pageFreed /\ readerDereferencingPage)
=============================================================================
