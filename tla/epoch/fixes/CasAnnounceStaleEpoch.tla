--------------------------- MODULE CasAnnounceStaleEpoch ---------------------------
(***************************************************************************)
(* Does a thread that announces a STALE epoch break reclamation?           *)
(*                                                                         *)
(* Raised in review of the CAS-announce change. Acquire() reads            *)
(* CurrentEpoch and then probes the epoch table for a free slot; the read  *)
(* and the claiming CAS are not atomic, so the announced value may already *)
(* be behind CurrentEpoch by the time it lands. The worry:                 *)
(*                                                                         *)
(*   1. Reclaimer unlinks M and bumps CurrentEpoch, retiring M at epoch e. *)
(*   2. Reclaimer scans the table, sees the entering thread's slot as 0,   *)
(*      computes SafeToReclaimEpoch >= e, and FREES M.                     *)
(*   3. The entering thread now announces a stale E' <= e -- reclamation   *)
(*      has "gone back in time".                                           *)
(*   4. Does the entering thread then dereference the freed M?             *)
(*                                                                         *)
(* This spec makes the sample and the announce two separate steps, so TLC  *)
(* explores every placement of the bump/scan/free between them -- which is *)
(* exactly the interleaving above. Note that widening or narrowing the     *)
(* instruction gap (reading CurrentEpoch once per Acquire vs. once per     *)
(* claim attempt) is NOT expressible here: both are "sample, then later    *)
(* announce", so both admit the same behaviours. Narrowing the gap changes *)
(* the probability, not the possibility.                                   *)
(*                                                                         *)
(* Names follow the production identifiers in LightEpoch.cs:               *)
(*                                                                         *)
(*   memory.currentEpoch          LightEpoch.CurrentEpoch                  *)
(*   memory.slotEpoch             Entry.localCurrentEpoch AS THE REST OF   *)
(*                                THE MACHINE SEES IT                      *)
(*   memory.safeToReclaimEpoch    LightEpoch.SafeToReclaimEpoch            *)
(*   memory.objectUnlinked        M has been retired from the structure    *)
(*   memory.objectFreed           the drain action ran and released M      *)
(*   triggerEpoch                 drainList[i].epoch -- M's retire epoch   *)
(*   readerSampledEpoch           the CurrentEpoch value read by Acquire   *)
(*                                before probing, i.e. what WILL be        *)
(*                                announced -- possibly stale by then      *)
(*                                                                         *)
(* AnnounceIsCas selects how the announce is published:                    *)
(*   TRUE   Interlocked.CompareExchange -- a locked RMW, so it is a full   *)
(*          barrier: it drains the reader's store buffer AND no later load *)
(*          may be satisfied from before it. This is the shipped fix.      *)
(*   FALSE  a plain store, as in the baseline. The liveness control: it    *)
(*          must fail, otherwise the check has gone dead.                  *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANT Model              \* "tso" | "arm" -- see MODULE StoreBuffer
CONSTANT AnnounceIsCas      \* TRUE = locked RMW announce, FALSE = plain store

Reader == "Reader"
Reclaimer == "Reclaimer"
Threads == {Reader, Reclaimer}

VARIABLES memory, storeBuffer, readerInCriticalSection, readerSampledEpoch,
          triggerEpoch, readerPc, reclaimerPc
vars == <<memory, storeBuffer, readerInCriticalSection, readerSampledEpoch,
          triggerEpoch, readerPc, reclaimerPc>>

SB == INSTANCE StoreBuffer
Load(p, f) == SB!Load(p, f)
Min(a, b)  == SB!Min(a, b)

Init ==
    /\ memory = [ currentEpoch |-> 1, slotEpoch |-> 0, safeToReclaimEpoch |-> 0,
                  objectUnlinked |-> FALSE, objectFreed |-> FALSE ]
    /\ storeBuffer = [ p \in Threads |-> <<>> ]
    /\ readerInCriticalSection = FALSE
    /\ readerSampledEpoch = 0
    /\ triggerEpoch = 0
    /\ readerPc = "SampleEpoch"
    /\ reclaimerPc = "Unlink"

FlushOne(p) ==
    /\ SB!FlushOne(p)
    /\ UNCHANGED <<readerInCriticalSection, readerSampledEpoch, triggerEpoch, readerPc, reclaimerPc>>

\* Reader ---------------------------------------------------------------------
\* Acquire(): read CurrentEpoch. Everything the reclaimer does may happen
\* between here and the announce, which is the whole point of this spec.
SampleEpoch ==
    /\ readerPc = "SampleEpoch"
    /\ readerSampledEpoch' = Load(Reader, "currentEpoch")
    /\ readerPc' = "Announce"
    /\ UNCHANGED <<memory, storeBuffer, readerInCriticalSection, triggerEpoch, reclaimerPc>>

\* TryClaimEntry: CAS localCurrentEpoch from 0 to the sampled epoch. The reader
\* is the only claimer here, so the CAS always succeeds; what matters is that it
\* is a locked RMW and therefore a full barrier.
Announce ==
    /\ readerPc = "Announce"
    /\ IF AnnounceIsCas
       THEN /\ memory' = SB!FencedStore(Reader, "slotEpoch", readerSampledEpoch)
            /\ storeBuffer' = SB!Drained(Reader)
       ELSE /\ storeBuffer' = SB!Buffer(Reader, "slotEpoch", readerSampledEpoch)
            /\ UNCHANGED memory
    /\ readerPc' = "ReadObject"
    /\ UNCHANGED <<readerInCriticalSection, readerSampledEpoch, triggerEpoch, reclaimerPc>>

\* Load the retire flag; if M still looks linked, dereference it. On a real
\* machine this load cannot be hoisted above a locked RMW, which is what makes
\* the stale announce harmless -- the reader is forced to observe the unlink.
ReadObject ==
    /\ readerPc = "ReadObject"
    /\ readerInCriticalSection' = (~ Load(Reader, "objectUnlinked"))
    /\ readerPc' = "Dereference"
    /\ UNCHANGED <<memory, storeBuffer, readerSampledEpoch, triggerEpoch, reclaimerPc>>

Dereference ==
    /\ readerPc = "Dereference"
    /\ readerInCriticalSection' = FALSE
    /\ readerPc' = "Release"
    /\ UNCHANGED <<memory, storeBuffer, readerSampledEpoch, triggerEpoch, reclaimerPc>>

Release ==
    /\ readerPc = "Release"
    /\ memory' = SB!FencedStore(Reader, "slotEpoch", 0)
    /\ storeBuffer' = SB!Drained(Reader)
    /\ readerPc' = "Done"
    /\ UNCHANGED <<readerInCriticalSection, readerSampledEpoch, triggerEpoch, reclaimerPc>>

\* Reclaimer ------------------------------------------------------------------
Unlink ==
    /\ reclaimerPc = "Unlink"
    /\ storeBuffer' = SB!Buffer(Reclaimer, "objectUnlinked", TRUE)
    /\ reclaimerPc' = "BumpCurrentEpoch"
    /\ UNCHANGED <<memory, readerInCriticalSection, readerSampledEpoch, triggerEpoch, readerPc>>

\* Interlocked.Increment(CurrentEpoch): a full RMW, so the unlink is globally
\* visible from here on.
BumpCurrentEpoch ==
    /\ reclaimerPc = "BumpCurrentEpoch"
    /\ LET fencedMemory == SB!Fenced(Reclaimer)
       IN /\ memory' = [fencedMemory EXCEPT !.currentEpoch = fencedMemory.currentEpoch + 1]
          /\ triggerEpoch' = fencedMemory.currentEpoch
    /\ storeBuffer' = SB!Drained(Reclaimer)
    /\ reclaimerPc' = "Scan"
    /\ UNCHANGED <<readerInCriticalSection, readerSampledEpoch, readerPc>>

\* ComputeNewSafeToReclaimEpoch + Drain. Left permanently enabled so that the
\* recomputation can be seen running BOTH before and after a stale announce
\* lands -- that is how SafeToReclaimEpoch is observed moving backwards.
Scan ==
    /\ reclaimerPc = "Scan"
    /\ LET slot              == memory.slotEpoch
           oldestOngoingCall == IF slot > 0 THEN Min(memory.currentEpoch, slot) ELSE memory.currentEpoch
           safe              == oldestOngoingCall - 1
       IN memory' = [memory EXCEPT !.safeToReclaimEpoch = safe,
                                   !.objectFreed = memory.objectFreed \/ (triggerEpoch <= safe)]
    /\ UNCHANGED <<storeBuffer, readerInCriticalSection, readerSampledEpoch, triggerEpoch, readerPc, reclaimerPc>>

Next == \/ SampleEpoch \/ Announce \/ ReadObject \/ Dereference \/ Release
        \/ Unlink \/ BumpCurrentEpoch \/ Scan
        \/ (\E p \in Threads : FlushOne(p))

Spec == Init /\ [][Next]_vars

\* SAFETY: the question actually being asked. Never free M while the reader is
\* dereferencing it, however stale the reader's announcement was.
NoUseAfterFree == ~ (memory.objectFreed /\ readerInCriticalSection)

\* COVERAGE, not safety. Expected to be VIOLATED, and a violation is the proof
\* that TLC really does reach the reviewer's interleaving: M has already been
\* freed and only THEN does an announcement appear whose epoch is old enough
\* that it would have prevented the free. If this ever HOLDS, the spec has
\* stopped exercising the scenario and the NoUseAfterFree result above is
\* worthless.
NoAnnounceAfterFree ==
    ~ (memory.objectFreed /\ memory.slotEpoch > 0 /\ memory.slotEpoch <= triggerEpoch)

\* ACCOUNTING, not safety. Also expected to be VIOLATED: a stale announce can
\* leave SafeToReclaimEpoch sitting at or above an epoch a thread is currently
\* announcing, until the next scan pulls it back down. Harmless -- a lower safe
\* epoch only delays future frees, and drain entries that already fired are
\* CAS'd to MaxValue-1 so nothing re-fires -- but it does mean SafeToReclaim-
\* Epoch is not monotonic. The same is true of the unfixed baseline, which
\* likewise reads CurrentEpoch and stores it non-atomically.
SafeBelowLiveAnnounce ==
    (memory.slotEpoch = 0) \/ (memory.safeToReclaimEpoch < memory.slotEpoch)
=============================================================================
