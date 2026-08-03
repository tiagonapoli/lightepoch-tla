------------------------ MODULE TsavoriteLogScanGetNext ------------------------
(***************************************************************************)
(* THE SAME DEFECT ON A PUBLIC, HOT, EVERYDAY API.                         *)
(*                                                                         *)
(* MODULE TsavoriteReadAtAddress uses ReadAtAddress, which a sceptic can    *)
(* dismiss as an exotic entry point. This module shows the identical shape  *)
(* on TsavoriteLog's scan iterator -- the API Garnet drives for AOF reads   *)
(* and replication, and the one Log.Scan/compaction sit on top of.          *)
(*                                                                         *)
(* This flow is in fact WEAKER than ReadAtAddress: the scan iterator does   *)
(* not even call InternalRefresh, so there is a single unfenced announce    *)
(* and then a straight line to the page dereference.                        *)
(*                                                                         *)
(* T1 = TsavoriteLogScanIterator.GetNext  (TsavoriteLogScanIterator.cs:232)*)
(* -----------------------------------------------------------------------*)
(*   epoch.Resume()      -> Acquire()           LightEpoch.cs:515          *)
(*     localCurrentEpoch = CurrentEpoch         LightEpoch.cs:530  PLAIN   *)
(*   GetNextInternal(...)          TsavoriteLogScanIterator.cs:740         *)
(*     var _headAddress = allocator.HeadAddress;                           *)
(*                                 TsavoriteLogScanIterator.cs:759         *)
(*                                 AllocatorBase.cs:123  PLAIN public long *)
(*     if (currentAddress < _headAddress)  -> BufferAndLoad from disk      *)
(*     else                                                               *)
(*         physicalAddress = allocator.GetPhysicalAddress(currentAddress); *)
(*                                 TsavoriteLogScanIterator.cs:817         *)
(*         -> *(pagePointers + pageIndex)  AllocatorBase.cs:674     DEREF  *)
(*     entryLength = tsavoriteLog.GetLength(physicalAddress);             *)
(*                                 TsavoriteLogScanIterator.cs:821  DEREF  *)
(*   Buffer.MemoryCopy(headerSize + physicalAddress, ...)                  *)
(*                                 TsavoriteLogScanIterator.cs:297  DEREF  *)
(*   epoch.Suspend()                                                       *)
(*                                                                         *)
(*   No Interlocked operation, no lock, and no Thread.MemoryBarrier runs    *)
(*   between the announce at LightEpoch.cs:530 and the dereference at       *)
(*   TsavoriteLogScanIterator.cs:817. Utility.MonotonicUpdate does appear   *)
(*   in GetNextInternal, but only inside the `currentAddress <              *)
(*   allocator.BeginAddress` and `allocator.IsNullDevice` branches, neither *)
(*   of which is taken on the ordinary path -- so it cannot be relied on as *)
(*   a barrier. There is no hash bucket here at all, hence no bucket latch  *)
(*   to rescue the flow the way it rescues InternalRead.                    *)
(*                                                                         *)
(*   The same shape recurs in five further GetNext/GetNextRaw overloads on  *)
(*   this class (TsavoriteLogScanIterator.cs:337, 401, 488, 580, 685), each *)
(*   opening with epoch.Resume() and reaching GetNextInternal unfenced.     *)
(*                                                                         *)
(* THE MAIN-STORE ITERATOR HAS THE SAME SHAPE, AND SAYS SO                 *)
(* -----------------------------------------------------------------------*)
(* SpanByteScanIterator (and ObjectScanIterator), which back Log.Scan and   *)
(* compaction, carry this comment immediately above their epoch.Resume():   *)
(*                                                                         *)
(*   // Acquire the epoch BEFORE sampling Initializing / TailAddress /     *)
(*   // HeadAddress / pagePointers, so that any allocator state we read is *)
(*   // consistent with the epoch we hold.                                 *)
(*                                        SpanByteScanIterator.cs:102-105  *)
(*                                                                         *)
(* That comment states precisely the guarantee this module refutes. Source  *)
(* order does not imply visibility order. Because the announce store is     *)
(* unfenced, the CPU is free to perform the HeadAddress and pagePointers    *)
(* loads while the announce is still sitting in the store buffer -- so the  *)
(* allocator state read is NOT consistent with the epoch held, and the      *)
(* reclaimer's min-scan does not see the iterator at all.                   *)
(*                                                                         *)
(* T2 = AllocatorBase.ShiftHeadAddress  (AllocatorBase.cs:1581)            *)
(*   Identical reclaimer to the sibling modules, with MonotonicUpdate's     *)
(*   Interlocked.CompareExchange (Utility.cs:372) and BumpCurrentEpoch's    *)
(*   Interlocked.Increment (LightEpoch.cs:368) modelled as FULL barriers.   *)
(*                                                                         *)
(* Expected: NoUseAfterFree is VIOLATED (both "tso" and "arm").            *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANT Model          \* "tso" | "arm" — see MODULE StoreBuffer

Reader == "Reader"
Reclaimer == "Reclaimer"
Threads == {Reader, Reclaimer}

\* The address the iterator is positioned at, and the HeadAddress the
\* reclaimer shifts to. CurrentAddress < NewHeadAddress, so once the shift is
\* visible the record is evicted and the iterator must load from disk via
\* BufferAndLoad instead of dereferencing the page.
CurrentAddress == 1
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
(* T1 — TsavoriteLogScanIterator.GetNext                                   *)
(***************************************************************************)

\* epoch.Resume() -> Acquire() (LightEpoch.cs:530). A single plain store; the
\* scan path never calls InternalRefresh, so this is the only announce.
Resume ==
    /\ readerPc = "Resume"
    /\ storeBuffer' = SB!Buffer(Reader, "readerLocalCurrentEpoch", Load(Reader, "currentEpoch"))
    /\ readerPc' = "ReadHeadAddress"
    /\ UNCHANGED <<memory, readerDereferencingPage, triggerEpoch, reclaimerPc>>

\* var _headAddress = allocator.HeadAddress (TsavoriteLogScanIterator.cs:759),
\* then the residency test at :798. Stale-resident means the iterator commits
\* to reading the page in memory.
ReadHeadAddress ==
    /\ readerPc = "ReadHeadAddress"
    /\ IF CurrentAddress < Load(Reader, "headAddress")
       THEN /\ readerPc' = "Suspend"
            /\ UNCHANGED readerDereferencingPage
       ELSE /\ readerDereferencingPage' = TRUE
            /\ readerPc' = "DereferencePage"
    /\ UNCHANGED <<memory, storeBuffer, triggerEpoch, reclaimerPc>>

\* allocator.GetPhysicalAddress(currentAddress) at :817, then GetLength and
\* Buffer.MemoryCopy read through that pointer.
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

Next == \/ Resume \/ ReadHeadAddress \/ DereferencePage \/ Suspend
        \/ ResumeReclaimer \/ MonotonicUpdateHeadAddress \/ BumpCurrentEpoch
        \/ ProtectAndDrainReclaimer \/ ComputeNewSafeToReclaimEpoch
        \/ (\E p \in Threads : FlushOne(p))

Spec == Init /\ [][Next]_vars

NoUseAfterFree == ~ (memory.pageFreed /\ readerDereferencingPage)
=============================================================================
