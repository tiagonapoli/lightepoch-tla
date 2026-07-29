--------------------------- MODULE TsavoriteReadAtAddress ---------------------------
(***************************************************************************)
(* TWO REAL TSAVORITE FLOWS, WITH TSAVORITE'S OWN BARRIERS INCLUDED.       *)
(*                                                                         *)
(* This spec exists to answer one specific objection:                      *)
(*                                                                         *)
(*   "LightEpoch's missing announce fence does not need fixing, because in  *)
(*    the way Tsavorite actually USES LightEpoch, Tsavorite already issues  *)
(*    the required memory barrier anyway."                                  *)
(*                                                                         *)
(* That objection is TRUE for some flows and FALSE for others. This module  *)
(* pins down a pair of flows for which it is false. Every interlocked       *)
(* operation Tsavorite really performs on these two paths is modelled as a  *)
(* FULL StoreLoad barrier, so the reclaimer here is strictly stronger than  *)
(* the hardware requires. The invariant still fails.                        *)
(*                                                                         *)
(* T1 = BasicContext.ReadAtAddress  (BasicContext.cs:167)                  *)
(* -----------------------------------------------------------------------*)
(*   UnsafeResumeThread()                    ClientSession.cs:540          *)
(*     store.epoch.Resume()   -> Acquire()   LightEpoch.cs:515             *)
(*         localCurrentEpoch = CurrentEpoch  LightEpoch.cs:530  PLAIN STORE*)
(*     store.InternalRefresh()               TsavoriteThread.cs:18         *)
(*         epoch.ProtectAndDrain()           LightEpoch.cs:298             *)
(*         localCurrentEpoch = CurrentEpoch  LightEpoch.cs:307  PLAIN STORE*)
(*   ContextReadAtAddress -> InternalReadAtAddress   InternalRead.cs:239   *)
(*     if (readAtAddress < hlogBase.HeadAddress) -> go pending             *)
(*                                           InternalRead.cs:253 PLAIN LOAD*)
(*     // "We're in-memory, so it is safe to get the address now."         *)
(*     hlog.CreateLogRecord(readAtAddress)   InternalRead.cs:269           *)
(*       -> GetPhysicalAddress                                             *)
(*       -> *(pagePointers + pageIndex)      AllocatorBase.cs:674  DEREF   *)
(*   UnsafeSuspendThread() -> epoch.Suspend()                              *)
(*                                                                         *)
(*   THE POINT: there is NO interlocked operation, no volatile access, and *)
(*   no fence of any kind between the two announce stores and the page     *)
(*   dereference. InternalReadAtAddress states this explicitly at          *)
(*   InternalRead.cs:252 -- "We do things in a different order here than    *)
(*   in InternalRead" -- and takes no bucket latch before reading the page.*)
(*   HeadAddress itself is a plain `public long` (AllocatorBase.cs:123).   *)
(*                                                                         *)
(*   Contrast MODULE TsavoriteReadWithBucketLatch, which models the normal  *)
(*   InternalRead path. There, FindTagAndTryEphemeralSLock takes a bucket   *)
(*   latch via Interlocked.CompareExchange (HashBucket.cs:53) BEFORE the    *)
(*   page dereference, and that incidental fence does rescue the flow.      *)
(*                                                                         *)
(* T2 = AllocatorBase.ShiftHeadAddress  (AllocatorBase.cs:1581)            *)
(* -----------------------------------------------------------------------*)
(*   MonotonicUpdate(ref HeadAddress, newHeadAddress, out _)               *)
(*                          Utility.cs:372  Interlocked.CompareExchange    *)
(*                                          -> MODELLED AS A FULL BARRIER  *)
(*   epoch.BumpCurrentEpoch(() => OnPagesClosed(newHeadAddress))           *)
(*                          AllocatorBase.cs:1595                          *)
(*     Interlocked.Increment(ref CurrentEpoch)  LightEpoch.cs:368          *)
(*                                          -> MODELLED AS A FULL BARRIER  *)
(*   ... later drain ...                                                   *)
(*     ComputeNewSafeToReclaimEpoch()        LightEpoch.cs:435             *)
(*     OnPagesClosed -> OnPagesClosedWorker -> _wrapper.FreePage(page)     *)
(*                          AllocatorBase.cs:1544                          *)
(*                                                                         *)
(* WHY THIS IS A GENUINE USE-AFTER-FREE, NOT A CRASH-FREE RACE            *)
(*   FreePage is ClearPage (Array.Clear) plus an optional return to a page *)
(*   pool (SpanByteAllocatorImpl.cs:71). The page is recycled, not         *)
(*   unmapped, so the reader does not fault -- it silently reads zeroed or *)
(*   re-used bytes as though they were a live record. That is exactly the  *)
(*   detection problem QuarantineLitmus was built for.                     *)
(*                                                                         *)
(* Expected: NoUseAfterFree is VIOLATED (both "tso" and "arm").            *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANT Model          \* "tso" | "arm" — see MODULE StoreBuffer

Reader == "Reader"
Reclaimer == "Reclaimer"
Threads == {Reader, Reclaimer}

\* The logical address handed to ReadAtAddress, and the HeadAddress the
\* reclaimer shifts to. ReadAtAddress < NewHeadAddress, so once the shift is
\* visible the address is evicted and the reader must go pending instead of
\* dereferencing the page.
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
(* T1 — BasicContext.ReadAtAddress                                         *)
(***************************************************************************)

\* UnsafeResumeThread step 1: epoch.Resume() -> Acquire().
\* LightEpoch.cs:530 — plain store, so it lands in the reader's store buffer.
Resume ==
    /\ readerPc = "Resume"
    /\ storeBuffer' = SB!Buffer(Reader, "readerLocalCurrentEpoch", Load(Reader, "currentEpoch"))
    /\ readerPc' = "ProtectAndDrain"
    /\ UNCHANGED <<memory, readerDereferencingPage, triggerEpoch, reclaimerPc>>

\* UnsafeResumeThread step 2: InternalRefresh() -> ProtectAndDrain().
\* LightEpoch.cs:307 — a SECOND plain announce store. Still no fence.
ProtectAndDrain ==
    /\ readerPc = "ProtectAndDrain"
    /\ storeBuffer' = SB!Buffer(Reader, "readerLocalCurrentEpoch", Load(Reader, "currentEpoch"))
    /\ readerPc' = "CheckHeadAddress"
    /\ UNCHANGED <<memory, readerDereferencingPage, triggerEpoch, reclaimerPc>>

\* InternalReadAtAddress guard (InternalRead.cs:253): a plain load of the plain
\* field AllocatorBase.HeadAddress. If the address still looks resident the
\* reader proceeds to dereference the page; otherwise it goes pending.
CheckHeadAddress ==
    /\ readerPc = "CheckHeadAddress"
    /\ IF ReadAtAddress < Load(Reader, "headAddress")
       THEN /\ readerPc' = "Suspend"
            /\ UNCHANGED readerDereferencingPage
       ELSE /\ readerDereferencingPage' = TRUE
            /\ readerPc' = "DereferencePage"
    /\ UNCHANGED <<memory, storeBuffer, triggerEpoch, reclaimerPc>>

\* CreateLogRecord -> GetPhysicalAddress -> *(pagePointers + pageIndex).
DereferencePage ==
    /\ readerPc = "DereferencePage"
    /\ readerDereferencingPage' = FALSE
    /\ readerPc' = "Suspend"
    /\ UNCHANGED <<memory, storeBuffer, triggerEpoch, reclaimerPc>>

\* UnsafeSuspendThread() -> epoch.Suspend() -> Release(): slot back to 0.
Suspend ==
    /\ readerPc = "Suspend"
    /\ storeBuffer' = SB!Buffer(Reader, "readerLocalCurrentEpoch", 0)
    /\ readerPc' = "Done"
    /\ UNCHANGED <<memory, readerDereferencingPage, triggerEpoch, reclaimerPc>>

(***************************************************************************)
(* T2 — AllocatorBase.ShiftHeadAddress                                     *)
(***************************************************************************)

\* The thread that retires pages is itself epoch-protected: BumpCurrentEpoch
\* asserts ThisInstanceProtected() (LightEpoch.cs:367), so its slot takes part
\* in the min-scan and clamps the safe epoch.
ResumeReclaimer ==
    /\ reclaimerPc = "ResumeReclaimer"
    /\ storeBuffer' = SB!Buffer(Reclaimer, "reclaimerLocalCurrentEpoch", Load(Reclaimer, "currentEpoch"))
    /\ reclaimerPc' = "MonotonicUpdateHeadAddress"
    /\ UNCHANGED <<memory, readerDereferencingPage, triggerEpoch, readerPc>>

\* MonotonicUpdate(ref HeadAddress, ...) — Interlocked.CompareExchange
\* (Utility.cs:372). A full barrier: the new HeadAddress AND everything else
\* pending on this core become globally visible at once. This is Tsavorite's
\* own barrier, and it is modelled at full strength.
MonotonicUpdateHeadAddress ==
    /\ reclaimerPc = "MonotonicUpdateHeadAddress"
    /\ memory' = [SB!Fenced(Reclaimer) EXCEPT !.headAddress = NewHeadAddress]
    /\ storeBuffer' = SB!Drained(Reclaimer)
    /\ reclaimerPc' = "BumpCurrentEpoch"
    /\ UNCHANGED <<readerDereferencingPage, triggerEpoch, readerPc>>

\* epoch.BumpCurrentEpoch(() => OnPagesClosed(...)) — Interlocked.Increment
\* (LightEpoch.cs:368). Another full barrier. The retire is tagged with the
\* epoch current before the bump (BumpCurrentEpoch's PriorEpoch).
BumpCurrentEpoch ==
    /\ reclaimerPc = "BumpCurrentEpoch"
    /\ LET fencedMemory == SB!Fenced(Reclaimer)
       IN /\ memory' = [fencedMemory EXCEPT !.currentEpoch = fencedMemory.currentEpoch + 1]
          /\ triggerEpoch' = fencedMemory.currentEpoch
    /\ storeBuffer' = SB!Drained(Reclaimer)
    /\ reclaimerPc' = "ProtectAndDrainReclaimer"
    /\ UNCHANGED <<readerDereferencingPage, readerPc>>

\* The reclaimer refreshes its own slot before draining, exactly as a
\* Tsavorite session does between operations. Plain store (LightEpoch.cs:307).
ProtectAndDrainReclaimer ==
    /\ reclaimerPc = "ProtectAndDrainReclaimer"
    /\ storeBuffer' = SB!Buffer(Reclaimer, "reclaimerLocalCurrentEpoch", Load(Reclaimer, "currentEpoch"))
    /\ reclaimerPc' = "ComputeNewSafeToReclaimEpoch"
    /\ UNCHANGED <<memory, readerDereferencingPage, triggerEpoch, readerPc>>

\* ComputeNewSafeToReclaimEpoch (LightEpoch.cs:435) then the drain action
\* OnPagesClosed -> FreePage.
\*
\* The reader's slot is read from shared memory -- a remote core -- so it is
\* still 0 while the reader's announces sit in its store buffer. The scan
\* cannot tell "no reader" from "reader not yet visible", skips the slot, and
\* computes a safe epoch that covers the retire.
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

\* SAFETY: the hybrid-log page must not be recycled while an epoch-protected
\* reader is dereferencing it.
NoUseAfterFree == ~ (memory.pageFreed /\ readerDereferencingPage)
=============================================================================
