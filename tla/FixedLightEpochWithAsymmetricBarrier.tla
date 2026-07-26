------------------------------ MODULE FixedLightEpochWithAsymmetricBarrier ------------------------------
(***************************************************************************)
(* FixedLightEpochWithAsymmetricBarrier — reader announce stays a cheap    *)
(*                                                                         *)
(* Models the epoch ENTER path against a per-core store buffer (the x86-TSO *)
(* shape; the same StoreLoad window exists, and is far easier to observe,   *)
(* on ARM64 — see memory-models/ARM64.tla).                                 *)
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

Rd == "Rd"
Rc == "Rc"
Procs == {Rd, Rc}

VARIABLES mem, sb, holds, eRead, gRetire, pcRd, pcRc
vars == <<mem, sb, holds, eRead, gRetire, pcRd, pcRc>>

Max(S) == CHOOSE x \in S : \A y \in S : y <= x
Min(a, b) == IF a < b THEN a ELSE b

\* Load with store forwarding: newest buffered write to f, else memory.
Load(p, f) ==
    LET idxs == { i \in DOMAIN sb[p] : sb[p][i].f = f }
    IN  IF idxs = {} THEN mem[f] ELSE sb[p][Max(idxs)].v

RECURSIVE ApplyAll(_, _)
ApplyAll(m, s) == IF s = <<>> THEN m
                  ELSE ApplyAll([m EXCEPT ![Head(s).f] = Head(s).v], Tail(s))

Init ==
    /\ mem = [ ce |-> 1, lce |-> 0, ret |-> FALSE, freed |-> FALSE ]
    /\ sb = [ p \in Procs |-> <<>> ]
    /\ holds = FALSE
    /\ eRead = 0
    /\ gRetire = 0
    /\ pcRd = "acq"
    /\ pcRc = "retire"

\* Asynchronous store-buffer drain (FIFO): one buffered write becomes visible.
FlushOne(p) ==
    /\ sb[p] # <<>>
    /\ mem' = [mem EXCEPT ![Head(sb[p]).f] = Head(sb[p]).v]
    /\ sb'  = [sb EXCEPT ![p] = Tail(sb[p])]
    /\ UNCHANGED <<holds, eRead, gRetire, pcRd, pcRc>>

\* Reader ---------------------------------------------------------------------
\* Announce (LightEpoch.cs ~530): PLAIN store -> buffered, no fence.
Acq ==
    /\ pcRd = "acq"
    /\ eRead' = Load(Rd, "ce")
    /\ sb' = [sb EXCEPT ![Rd] = Append(sb[Rd], [f |-> "lce", v |-> eRead'])]
    /\ pcRd' = "cap"
    /\ UNCHANGED <<mem, holds, gRetire, pcRc>>

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
    /\ sb' = [sb EXCEPT ![Rd] = Append(sb[Rd], [f |-> "lce", v |-> 0])]
    /\ pcRd' = "done"
    /\ UNCHANGED <<mem, holds, eRead, gRetire, pcRc>>

\* Reclaimer ------------------------------------------------------------------
Retire ==
    /\ pcRc = "retire"
    /\ sb' = [sb EXCEPT ![Rc] = Append(sb[Rc], [f |-> "ret", v |-> TRUE])]
    /\ pcRc' = "bump"
    /\ UNCHANGED <<mem, holds, eRead, gRetire, pcRd>>

\* Interlocked.Increment(CurrentEpoch): a full RMW -> drains Rc's store buffer.
Bump ==
    /\ pcRc = "bump"
    /\ LET m1 == ApplyAll(mem, sb[Rc])
       IN /\ mem' = [m1 EXCEPT !.ce = m1.ce + 1]
          /\ gRetire' = m1.ce
    /\ sb' = [sb EXCEPT ![Rc] = <<>>]
    /\ pcRc' = "compute"
    /\ UNCHANGED <<holds, eRead, pcRd>>

\* ComputeNewSafeToReclaimEpoch scan: reads mem.lce (may still be 0 if the
\* reader's announce is buffered) and, if the retire epoch is safe, FREES.
\* ComputeNewSafeToReclaimEpoch, PRECEDED by a process-wide barrier
\* (FlushProcessWriteBuffers / membarrier) that drains EVERY core's store
\* buffer, so the reader's buffered announce is guaranteed visible to the scan.
\* The reader hot path adds no fence at all.
Compute ==
    /\ pcRc = "compute"
    /\ LET flushed == ApplyAll(mem, sb[Rd])   \* process-wide barrier: drain all buffers
           lceVal  == flushed.lce
           oldest  == IF lceVal > 0 THEN Min(flushed.ce, lceVal) ELSE flushed.ce
           safe    == oldest - 1
       IN IF gRetire <= safe
          THEN /\ mem' = [flushed EXCEPT !.freed = TRUE]
               /\ pcRc' = "done"
          ELSE /\ mem' = flushed
               /\ UNCHANGED pcRc
    /\ sb' = [sb EXCEPT ![Rd] = <<>>]
    /\ UNCHANGED <<holds, eRead, gRetire, pcRd>>

Next == \/ Acq \/ Cap \/ Use \/ Rel
        \/ Retire \/ Bump \/ Compute
        \/ (\E p \in Procs : FlushOne(p))

Spec == Init /\ [][Next]_vars

\* SAFETY: never free while a protected reader still dereferences the object.
NoUseAfterFree == ~ (mem.freed /\ holds)
=============================================================================
