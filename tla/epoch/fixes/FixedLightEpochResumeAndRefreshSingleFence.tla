------------------- MODULE FixedLightEpochResumeAndRefreshSingleFence -------------------
(***************************************************************************)
(* FixedLightEpochResumeAndRefreshSingleFence — a PROPOSED CHANGE to        *)
(* Tsavorite, not a description of how it behaves today.                    *)
(*                                                                         *)
(* !! READ THIS FIRST !!                                                    *)
(* Every module whose name starts with "Fixed" models a change that would   *)
(* have to be MADE to Tsavorite. None of them describe shipped behavior.    *)
(* Tsavorite as it exists today is modeled by MODULE                        *)
(* LightEpochResumeAndRefresh, and that spec is VIOLATED — the              *)
(* use-after-free is reachable. Tsavorite needs a fix; the only open        *)
(* question is which of these fixes to apply.                               *)
(*                                                                         *)
(* In particular ProtectAndDrainWithoutAnnounce() DOES NOT EXIST in         *)
(* Tsavorite. It is a new method this proposal would add.                   *)
(*                                                                         *)
(* Tsavorite's default API runs, back-to-back, per operation:              *)
(*   UnsafeResumeThread()  = Resume()/Acquire   (announce lce = CurrentEpoch*)
(*                            + StoreLoad fence)                            *)
(*                           + InternalRefresh() -> ProtectAndDrain()        *)
(*   ... the operation load ...                                            *)
(*   UnsafeSuspendThread() = Suspend()/Release  (reset lce -> 0).           *)
(*                                                                         *)
(* MODULE FixedLightEpochResumeAndRefresh fences BOTH announce sites, so the       *)
(* per-op path pays TWO StoreLoad barriers. This module models the cheaper  *)
(* alternative — ONE barrier per operation, hence "SingleFence":            *)
(* Resume()/Acquire still announces + fences, but the                       *)
(* immediately-following refresh call is ProtectAndDrainWithoutAnnounce()   *)
(* — it performs NO announce store and therefore needs NO fence. It only    *)
(* drives drain/progress on the epoch Acquire already published.            *)
(*                                                                         *)
(* Safety argument the model checks exhaustively:                          *)
(*   - Acquire's announce (lce = E) is drained to memory by its fence       *)
(*     BEFORE the operation's load, so the reclaimer never sees the reader  *)
(*     as "absent" (lce == 0) while it holds the object.                    *)
(*   - Skipping the second announce only means lce stays at E instead of    *)
(*     advancing to a possibly-newer E' >= E. A smaller announced epoch     *)
(*     makes ComputeNewSafeToReclaimEpoch MORE conservative, never less —   *)
(*     so it cannot free an object the reader still protects.               *)
(*   - The dangerous 0 -> E transition happens ONLY in Acquire, which is    *)
(*     fenced; the removed announce was a monotonic E -> E' advance that     *)
(*     never re-opens the absent-reader window.                            *)
(*                                                                         *)
(* The remaining Acquire fence is load-bearing, not decoration: remove it   *)
(* as well and this same spec goes from HOLDS to VIOLATED.                  *)
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
\* store buffer so mem.lce is visible before the operation's load.
Acq ==
    /\ pcRd = "acq"
    /\ eRead' = Load(Rd, "ce")
    /\ LET newbuf == Append(sb[Rd], [f |-> "lce", v |-> eRead'])
       IN /\ mem' = ApplyAll(mem, newbuf)
          /\ sb'  = [sb EXCEPT ![Rd] = <<>>]
    /\ pcRd' = "refresh"
    /\ UNCHANGED <<holds, gRetire, pcRc>>

\* ProtectAndDrainWithoutAnnounce(): NO announce store and NO fence. The epoch
\* Acquire already published (lce = eRead) stays put; this step only models the
\* drain/progress work, leaving all shared memory untouched.
Refresh ==
    /\ pcRd = "refresh"
    /\ pcRd' = "cap"
    /\ UNCHANGED <<mem, sb, holds, eRead, gRetire, pcRc>>

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
