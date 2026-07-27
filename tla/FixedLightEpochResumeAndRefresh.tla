------------------------- MODULE FixedLightEpochResumeAndRefresh -------------------------
(***************************************************************************)
(* FixedLightEpochResumeAndRefresh — the FIX (full StoreLoad barrier) proved       *)
(* against Tsavorite's exact per-operation call sequence.                   *)
(*                                                                         *)
(* Same per-operation shape as MODULE LightEpochResumeAndRefresh:                  *)
(*   Resume()/Acquire announce  -> ProtectAndDrain announce -> operation    *)
(*   load -> Suspend()/Release (reset lce -> 0),                            *)
(* but now BOTH announce sites carry a full StoreLoad barrier               *)
(* (Interlocked.MemoryBarrier() -> DMB ISH / lock or), exactly as           *)
(* FixedLightEpochWithMemoryBarrier fences LightEpoch.cs ~527 (Acquire) and *)
(* ~304 (ProtectAndDrain).                                                  *)
(*                                                                         *)
(* Because each announce drains the reader's store buffer before the        *)
(* operation's load, mem.lce is visible (non-zero) whenever the reclaimer's  *)
(* scan runs — the reader is never mistaken for "absent", even though        *)
(* Suspend()/Release resets the slot to 0 between operations.               *)
(*                                                                         *)
(* Expected: NoUseAfterFree HOLDS (exhaustively verified).                 *)
(***************************************************************************)
EXTENDS Naturals, Sequences

Rd == "Rd"
Rc == "Rc"
Procs == {Rd, Rc}

VARIABLES mem, sb, holds, eRead, gRetire, pcRd, pcRc
vars == <<mem, sb, holds, eRead, gRetire, pcRd, pcRc>>

Max(S) == CHOOSE x \in S : \A y \in S : y <= x
Min(a, b) == IF a < b THEN a ELSE b

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

FlushOne(p) ==
    /\ sb[p] # <<>>
    /\ mem' = [mem EXCEPT ![Head(sb[p]).f] = Head(sb[p]).v]
    /\ sb'  = [sb EXCEPT ![p] = Tail(sb[p])]
    /\ UNCHANGED <<holds, eRead, gRetire, pcRd, pcRc>>

\* Reader ---------------------------------------------------------------------
\* Resume()/Acquire announce + FULL StoreLoad barrier: drain the reader's
\* store buffer so mem.lce is visible before the next store or load.
Acq ==
    /\ pcRd = "acq"
    /\ eRead' = Load(Rd, "ce")
    /\ LET newbuf == Append(sb[Rd], [f |-> "lce", v |-> eRead'])
       IN /\ mem' = ApplyAll(mem, newbuf)
          /\ sb'  = [sb EXCEPT ![Rd] = <<>>]
    /\ pcRd' = "refresh"
    /\ UNCHANGED <<holds, gRetire, pcRc>>

\* ProtectAndDrain announce + FULL StoreLoad barrier: the second announce is
\* also drained before the operation's load.
Refresh ==
    /\ pcRd = "refresh"
    /\ LET newbuf == Append(sb[Rd], [f |-> "lce", v |-> Load(Rd, "ce")])
       IN /\ mem' = ApplyAll(mem, newbuf)
          /\ sb'  = [sb EXCEPT ![Rd] = <<>>]
    /\ pcRd' = "cap"
    /\ UNCHANGED <<holds, eRead, gRetire, pcRc>>

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

Bump ==
    /\ pcRc = "bump"
    /\ LET m1 == ApplyAll(mem, sb[Rc])
       IN /\ mem' = [m1 EXCEPT !.ce = m1.ce + 1]
          /\ gRetire' = m1.ce
    /\ sb' = [sb EXCEPT ![Rc] = <<>>]
    /\ pcRc' = "compute"
    /\ UNCHANGED <<holds, eRead, pcRd>>

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

NoUseAfterFree == ~ (mem.freed /\ holds)
=============================================================================
