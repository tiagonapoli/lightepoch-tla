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
(* Reclaimer modeling — deliberately ASYMMETRIC with respect to             *)
(* MODULE LightEpochResumeAndRefresh, and the asymmetry is the conservative *)
(* direction in both cases:                                                 *)
(*                                                                         *)
(*   - The buggy spec models a PROTECTED reclaimer (it owns an epoch slot   *)
(*     that joins the ComputeNewSafeToReclaimEpoch min-scan), because that  *)
(*     is what Tsavorite actually does. A bug claim must not be built on an *)
(*     adversary stronger than production.                                  *)
(*                                                                         *)
(*   - This spec models an UNPROTECTED reclaimer (no reclaimer slot). Its   *)
(*     absence can only RAISE oldest, hence raise SafeToReclaimEpoch, hence *)
(*     reclaim MORE aggressively. Proving the fix safe here is therefore    *)
(*     strictly stronger than proving it under a protected reclaimer.       *)
(*                                                                         *)
(* Expected: NoUseAfterFree HOLDS (exhaustively verified).                 *)
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

FlushOne(p) ==
    /\ SB!FlushOne(p)
    /\ UNCHANGED <<holds, eRead, gRetire, pcRd, pcRc>>

\* Reader ---------------------------------------------------------------------
\* Resume()/Acquire announce + FULL StoreLoad barrier: drain the reader's
\* store buffer so mem.lce is visible before the next store or load.
Acq ==
    /\ pcRd = "acq"
    /\ eRead' = Load(Rd, "ce")
    /\ mem' = SB!FencedStore(Rd, "lce", eRead')
    /\ sb'  = SB!Drained(Rd)
    /\ pcRd' = "refresh"
    /\ UNCHANGED <<holds, gRetire, pcRc>>

\* ProtectAndDrain announce + FULL StoreLoad barrier: the second announce is
\* also drained before the operation's load.
Refresh ==
    /\ pcRd = "refresh"
    /\ mem' = SB!FencedStore(Rd, "lce", Load(Rd, "ce"))
    /\ sb'  = SB!Drained(Rd)
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
    /\ sb' = SB!Buffer(Rd, "lce", 0)
    /\ pcRd' = "done"
    /\ UNCHANGED <<mem, holds, eRead, gRetire, pcRc>>

\* Reclaimer ------------------------------------------------------------------
Retire ==
    /\ pcRc = "retire"
    /\ sb' = SB!Buffer(Rc, "ret", TRUE)
    /\ pcRc' = "bump"
    /\ UNCHANGED <<mem, holds, eRead, gRetire, pcRd>>

Bump ==
    /\ pcRc = "bump"
    /\ LET m1 == SB!Fenced(Rc)
       IN /\ mem' = [m1 EXCEPT !.ce = m1.ce + 1]
          /\ gRetire' = m1.ce
    /\ sb' = SB!Drained(Rc)
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
