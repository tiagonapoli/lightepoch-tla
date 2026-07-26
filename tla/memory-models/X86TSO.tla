-------------------------------- MODULE X86TSO --------------------------------
(***************************************************************************)
(* A model of the x86-TSO memory model, exercised with the Store-Buffer    *)
(* (SB) litmus — the exact shape of the LightEpoch enter-path bug.          *)
(*                                                                         *)
(*   Thread t1:  store x := 1 ; [fence?] ; load r1 := y                     *)
(*   Thread t2:  store y := 1 ; [fence?] ; load r2 := x                     *)
(*                                                                         *)
(* x86-TSO (Owens/Sewell/Sarkar): each core has a private FIFO store        *)
(* buffer. A store enters the buffer and drains to shared memory in FIFO    *)
(* order; a load reads the newest matching entry in its own buffer (store   *)
(* forwarding) else shared memory. The ONLY reordering this permits is      *)
(* StoreLoad: a core's own later load can execute while its earlier store   *)
(* is still buffered. That is exactly — and only — the reordering the epoch *)
(* announce bug needs.                                                     *)
(*                                                                         *)
(* Fenced = FALSE : no barrier -> SequentiallyConsistent is VIOLATED        *)
(*                  (both loads may read 0). This is the StoreLoad window.   *)
(* Fenced = TRUE  : an MFENCE (== Interlocked.MemoryBarrier) between store   *)
(*                  and load drains the buffer first -> SC HOLDS.            *)
(*                                                                         *)
(* Note: an x86 RELEASE store is just a plain store (TSO stores already have *)
(* release semantics), and it does NOT order StoreLoad — only MFENCE (or a   *)
(* LOCKed RMW) does. That is why "make it volatile" does not fix the bug.    *)
(***************************************************************************)
EXTENDS Integers, Sequences

CONSTANT Fenced         \* TRUE => an MFENCE sits between each store and load

T1 == "t1"
T2 == "t2"
Procs == {T1, T2}

VARIABLES buf, mem, r1, r2, pc
vars == <<buf, mem, r1, r2, pc>>

Max(S) == CHOOSE x \in S : \A y \in S : y <= x

\* Store forwarding: newest buffered write to f in p's buffer, else memory.
Load(p, f) ==
    LET idxs == { i \in DOMAIN buf[p] : buf[p][i].f = f }
    IN  IF idxs = {} THEN mem[f] ELSE buf[p][Max(idxs)].v

OtherVar(p) == IF p = T1 THEN "y" ELSE "x"
OwnVar(p)   == IF p = T1 THEN "x" ELSE "y"

Init ==
    /\ buf = [p \in Procs |-> <<>>]
    /\ mem = [x |-> 0, y |-> 0]
    /\ r1 = -1
    /\ r2 = -1
    /\ pc = [p \in Procs |-> "store"]

\* FIFO drain: the head of a core's store buffer becomes globally visible.
Flush(p) ==
    /\ buf[p] # <<>>
    /\ mem' = [mem EXCEPT ![Head(buf[p]).f] = Head(buf[p]).v]
    /\ buf' = [buf EXCEPT ![p] = Tail(buf[p])]
    /\ UNCHANGED <<r1, r2, pc>>

DoStore(p) ==
    /\ pc[p] = "store"
    /\ buf' = [buf EXCEPT ![p] = Append(buf[p], [f |-> OwnVar(p), v |-> 1])]
    /\ pc' = [pc EXCEPT ![p] = IF Fenced THEN "fence" ELSE "load"]
    /\ UNCHANGED <<mem, r1, r2>>

\* MFENCE: cannot proceed until this core's store buffer is fully drained.
DoFence(p) ==
    /\ pc[p] = "fence"
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
    \/ \E p \in Procs : DoStore(p) \/ DoFence(p) \/ DoLoad(p) \/ Flush(p)

Spec == Init /\ [][Next]_vars

Done == pc[T1] = "done" /\ pc[T2] = "done"

\* Sequential consistency forbids BOTH loads reading 0. Under TSO this holds
\* ONLY with a fence; without one it is violated (the StoreLoad window).
SequentiallyConsistent == Done => ~(r1 = 0 /\ r2 = 0)
=============================================================================
