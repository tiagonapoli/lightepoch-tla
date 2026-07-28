------------------------ MODULE FixedLightEpochWithMemoryBarrier ------------------------
(***************************************************************************)
(* FixedLightEpochWithMemoryBarrier — the validated FIX: a full StoreLoad   *)
(* barrier.                                                                *)
(*                                                                         *)
(* Models the epoch ENTER path against a per-core store buffer (the x86-TSO *)
(* shape; the same StoreLoad window exists, and is far easier to observe,   *)
(* on ARM64).                                                              *)
(*                                                                         *)
(* Two threads share one epoch:                                            *)
(*   Reader (Rd):  announce localCurrentEpoch := CurrentEpoch  (PLAIN store *)
(*                 -> goes into the reader's store buffer),                 *)
(*                 then LOAD the object-linked flag and, if linked, "use"   *)
(*                 (dereference) it.                                        *)
(*   Reclaimer (Rc): unlink + retire the object (store ret := TRUE),        *)
(*                 Interlocked-bump CurrentEpoch (this DRAINS the           *)
(*                 reclaimer's own buffer — it is already fenced), then     *)
(*                 scan the reader slot (ComputeNewSafeToReclaimEpoch): if   *)
(*                 the retire epoch is <= SafeToReclaimEpoch, FREE.          *)
(*                                                                         *)
(* THE DEFECT: the reader's announce store can still be sitting in its      *)
(* store buffer (mem.lce == 0, "thread absent") when the reclaimer's scan   *)
(* reads the slot. The scan then computes a safe epoch past the live reader *)
(* and frees the object the reader is about to dereference.                 *)
(*                                                                         *)
(* Expected: NoUseAfterFree HOLDS (exhaustively verified).                          *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANT Model          \* "tso" | "arm" — see MODULE StoreBuffer

Rd == "Rd"
Rc == "Rc"
Procs == {Rd, Rc}

VARIABLES mem, sb, holds, eRead, gRetire, pcRd, pcRc
vars == <<mem, sb, holds, eRead, gRetire, pcRd, pcRc>>

SB == INSTANCE StoreBuffer
Load(p, f) == SB!Load(p, f)
Min(a, b)  == SB!Min(a, b)

Init ==
    /\ mem = [ ce |-> 1, lce |-> 0, ret |-> FALSE, freed |-> FALSE ]
    /\ sb = [ p \in Procs |-> <<>> ]
    /\ holds = FALSE
    /\ eRead = 0
    /\ gRetire = 0
    /\ pcRd = "acq"
    /\ pcRc = "retire"

\* Asynchronous store-buffer drain: one buffered write becomes visible.
FlushOne(p) ==
    /\ SB!FlushOne(p)
    /\ UNCHANGED <<holds, eRead, gRetire, pcRd, pcRc>>

\* Reader ---------------------------------------------------------------------
\* Announce + FULL StoreLoad barrier (Interlocked.MemoryBarrier): draining the
\* reader's store buffer here makes mem.lce visible before the reader loads
\* anything, so the StoreLoad window is CLOSED.
Acq ==
    /\ pcRd = "acq"
    /\ eRead' = Load(Rd, "ce")
    /\ mem' = SB!FencedStore(Rd, "lce", eRead')
    /\ sb'  = SB!Drained(Rd)
    /\ pcRd' = "cap"
    /\ UNCHANGED <<holds, gRetire, pcRc>>

\* Load the object-linked flag; if it still looks linked, mark that we hold it.
Cap ==
    /\ pcRd = "cap"
    /\ holds' = (~ Load(Rd, "ret"))
    /\ pcRd' = "use"
    /\ UNCHANGED <<mem, sb, eRead, gRetire, pcRc>>

Use ==
    /\ pcRd = "use"
    /\ holds' = FALSE
    /\ pcRd' = "rel"
    /\ UNCHANGED <<mem, sb, eRead, gRetire, pcRc>>

Rel ==
    /\ pcRd = "rel"
    /\ sb' = SB!Buffer(Rd, "lce", 0)
    /\ pcRd' = "done"
    /\ UNCHANGED <<mem, holds, eRead, gRetire, pcRc>>

\* Reclaimer ------------------------------------------------------------------
Retire ==
    /\ pcRc = "retire"
    /\ sb' = SB!Buffer(Rc, "ret", TRUE)
    /\ pcRc' = "bump"
    /\ UNCHANGED <<mem, holds, eRead, gRetire, pcRd>>

\* Interlocked.Increment(CurrentEpoch): a full RMW -> drains Rc's store buffer.
Bump ==
    /\ pcRc = "bump"
    /\ LET m1 == SB!Fenced(Rc)
       IN /\ mem' = [m1 EXCEPT !.ce = m1.ce + 1]
          /\ gRetire' = m1.ce
    /\ sb' = SB!Drained(Rc)
    /\ pcRc' = "compute"
    /\ UNCHANGED <<holds, eRead, pcRd>>

\* ComputeNewSafeToReclaimEpoch scan: reads mem.lce (may still be 0 if the
\* reader's announce is buffered) and, if the retire epoch is safe, FREES.
Compute ==
    /\ pcRc = "compute"
    /\ LET lceVal == mem.lce
           oldest == IF lceVal > 0 THEN Min(mem.ce, lceVal) ELSE mem.ce
           safe   == oldest - 1
       IN IF gRetire <= safe
          THEN /\ mem' = [mem EXCEPT !.freed = TRUE]
               /\ pcRc' = "done"
          ELSE /\ UNCHANGED <<mem, pcRc>>
    /\ UNCHANGED <<sb, holds, eRead, gRetire, pcRd>>

Next == \/ Acq \/ Cap \/ Use \/ Rel
        \/ Retire \/ Bump \/ Compute
        \/ (\E p \in Procs : FlushOne(p))

Spec == Init /\ [][Next]_vars

\* SAFETY: never free while a protected reader still dereferences the object.
NoUseAfterFree == ~ (mem.freed /\ holds)
=============================================================================
