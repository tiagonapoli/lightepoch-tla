-------------------------------- MODULE ARM64 --------------------------------
(***************************************************************************)
(* A model of the ARMv8-A (AArch64) relaxed memory model, exercised with    *)
(* the Store-Buffer (SB) litmus and contrasted with x86-TSO.                *)
(*                                                                         *)
(*   Thread t1:  store x := 1 ; [barrier?] ; load r1 := y                   *)
(*   Thread t2:  store y := 1 ; [barrier?] ; load r2 := x                   *)
(*                                                                         *)
(* ARM is WEAKER than TSO. Two differences matter here:                     *)
(*                                                                         *)
(*  1. Store buffers drain in ANY order (StoreStore reordering is allowed;  *)
(*     TSO forbids it). Modelled by Flush picking any buffered entry, not   *)
(*     just the head.                                                       *)
(*                                                                         *)
(*  2. The plain announce store gets NO ordering vs. a later load, and even  *)
(*     a RELEASE store (STLR) does not create StoreLoad order — release      *)
(*     orders earlier accesses BEFORE the store, not a later load AFTER it.  *)
(*     Only a full barrier (DMB ISH, == Interlocked.MemoryBarrier) or a      *)
(*     seq-cst RMW (SWPAL / LDAXR-STLXR) drains the buffer before the load.  *)
(*                                                                         *)
(* Barrier \in {"none", "release", "full"} :                                *)
(*   "none"    plain STR              -> SC VIOLATED (StoreLoad window open)  *)
(*   "release" STLR (Volatile.Write)  -> SC VIOLATED (release != StoreLoad)   *)
(*   "full"    DMB ISH / seq-cst RMW  -> SC HOLDS                            *)
(*                                                                         *)
(* This is why, on ARM64, LightEpoch's plain announce store admits the      *)
(* use-after-free and why only the full barrier (not a volatile write)       *)
(* closes it. On x86 the same StoreLoad window exists but its store buffer   *)
(* drains so quickly that it is effectively never observed.                 *)
(***************************************************************************)
EXTENDS Integers, Sequences

CONSTANT Barrier        \* "none" | "release" | "full"

T1 == "t1"
T2 == "t2"
Procs == {T1, T2}

VARIABLES buf, mem, r1, r2, pc
vars == <<buf, mem, r1, r2, pc>>

Max(S) == CHOOSE x \in S : \A y \in S : y <= x

Load(p, f) ==
    LET idxs == { i \in DOMAIN buf[p] : buf[p][i].f = f }
    IN  IF idxs = {} THEN mem[f] ELSE buf[p][Max(idxs)].v

OtherVar(p) == IF p = T1 THEN "y" ELSE "x"
OwnVar(p)   == IF p = T1 THEN "x" ELSE "y"

\* Only a full barrier forces the store buffer to drain before the load.
DrainsBeforeLoad == Barrier = "full"

Init ==
    /\ buf = [p \in Procs |-> <<>>]
    /\ mem = [x |-> 0, y |-> 0]
    /\ r1 = -1
    /\ r2 = -1
    /\ pc = [p \in Procs |-> "store"]

\* Non-FIFO drain: ANY buffered entry may become visible (StoreStore reorder).
Flush(p) ==
    /\ buf[p] # <<>>
    /\ \E i \in DOMAIN buf[p] :
         /\ mem' = [mem EXCEPT ![buf[p][i].f] = buf[p][i].v]
         /\ buf' = [buf EXCEPT ![p] = SubSeq(buf[p], 1, i-1) \o SubSeq(buf[p], i+1, Len(buf[p]))]
    /\ UNCHANGED <<r1, r2, pc>>

DoStore(p) ==
    /\ pc[p] = "store"
    /\ buf' = [buf EXCEPT ![p] = Append(buf[p], [f |-> OwnVar(p), v |-> 1])]
    /\ pc' = [pc EXCEPT ![p] = IF DrainsBeforeLoad THEN "barrier" ELSE "load"]
    /\ UNCHANGED <<mem, r1, r2>>

\* DMB ISH: blocks the load until this core's store buffer is fully drained.
DoBarrier(p) ==
    /\ pc[p] = "barrier"
    /\ buf[p] = <<>>
    /\ pc' = [pc EXCEPT ![p] = "load"]
    /\ UNCHANGED <<buf, mem, r1, r2>>

DoLoad(p) ==
    /\ pc[p] = "load"
    /\ LET v == Load(p, OtherVar(p))
       IN IF p = T1 THEN r1' = v /\ UNCHANGED r2
                    ELSE r2' = v /\ UNCHANGED r1
    /\ pc' = [pc EXCEPT ![p] = "done"]
    /\ UNCHANGED <<buf, mem>>

Next ==
    \/ \E p \in Procs : DoStore(p) \/ DoBarrier(p) \/ DoLoad(p) \/ Flush(p)

Spec == Init /\ [][Next]_vars

Done == pc[T1] = "done" /\ pc[T2] = "done"

\* Sequential consistency forbids BOTH loads reading 0. On ARM this holds only
\* with a FULL barrier; "none" and "release" both leave the window open.
SequentiallyConsistent == Done => ~(r1 = 0 /\ r2 = 0)
=============================================================================
