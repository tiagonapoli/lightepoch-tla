--------------------------- MODULE LightEpochResumeAndRefresh ---------------------------
(***************************************************************************)
(* LightEpochResumeAndRefresh — the BUGGY baseline, modeled through the exact call *)
(* sequence Tsavorite's default API (BasicContext) uses per operation.       *)
(*                                                                         *)
(* A BasicContext Read/Upsert/RMW wraps every operation in                  *)
(*   UnsafeResumeThread()  = epoch.Resume()  (Acquire: slot CAS + announce) *)
(*                           + InternalRefresh() -> ProtectAndDrain()        *)
(*                             (a SECOND announce + drain)                   *)
(*   ... the operation ...                                                  *)
(*   UnsafeSuspendThread() = epoch.Suspend() (Release: reset lce -> 0).      *)
(*                                                                         *)
(* So a single operation issues TWO announce stores before the operation's  *)
(* shared-data load, and the following Release resets the slot to 0 —       *)
(* which is why the *next* operation re-opens the 0 -> E "absent reader"     *)
(* window all over again. Neither announce carries a StoreLoad fence in the  *)
(* baseline, so both can sit in the reader's store buffer (mem.lce == 0,     *)
(* "thread absent") when the reclaimer's scan reads the slot.                *)
(*                                                                         *)
(* This is the same defect as MODULE LightEpoch, but proved against the     *)
(* real per-operation API shape rather than a single bare announce.         *)
(*                                                                         *)
(* Expected: NoUseAfterFree is VIOLATED.                                   *)
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
\* Resume()/Acquire announce (LightEpoch.cs ~527): PLAIN store -> buffered.
Acq ==
    /\ pcRd = "acq"
    /\ eRead' = Load(Rd, "ce")
    /\ sb' = [sb EXCEPT ![Rd] = Append(sb[Rd], [f |-> "lce", v |-> eRead'])]
    /\ pcRd' = "refresh"
    /\ UNCHANGED <<mem, holds, gRetire, pcRc>>

\* InternalRefresh() -> ProtectAndDrain announce (LightEpoch.cs ~304): a SECOND
\* PLAIN announce store, still no StoreLoad fence in the baseline.
Refresh ==
    /\ pcRd = "refresh"
    /\ sb' = [sb EXCEPT ![Rd] = Append(sb[Rd], [f |-> "lce", v |-> Load(Rd, "ce")])]
    /\ pcRd' = "cap"
    /\ UNCHANGED <<mem, holds, eRead, gRetire, pcRc>>

\* The operation loads the object-linked flag; if it still looks linked, hold it.
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

\* Suspend()/Release: reset the slot to 0 ("absent"), re-opening the window
\* for a subsequent operation.
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
\* reader's announce(s) are buffered) and, if the retire epoch is safe, FREES.
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

Next == \/ Acq \/ Refresh \/ Cap \/ Use \/ Rel
        \/ Retire \/ Bump \/ Compute
        \/ (\E p \in Procs : FlushOne(p))

Spec == Init /\ [][Next]_vars

\* SAFETY: never free while a protected reader still dereferences the object.
NoUseAfterFree == ~ (mem.freed /\ holds)
=============================================================================
