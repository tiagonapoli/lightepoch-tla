-------------------------------- MODULE X86TSO --------------------------------
(***************************************************************************)
(* Calibration of MODULE StoreBuffer against the canonical Store-Buffer     *)
(* (SB) litmus test — the exact shape of the LightEpoch enter-path bug.     *)
(*                                                                         *)
(*   Thread t1:  store x := 1 ; [fence?] ; load r1 := y                     *)
(*   Thread t2:  store y := 1 ; [fence?] ; load r2 := x                     *)
(*                                                                         *)
(* WHY THIS SPEC EXISTS                                                    *)
(*                                                                         *)
(* The epoch specs all sit on the shared harness in MODULE StoreBuffer, so  *)
(* every claim they make inherits that harness's assumptions. If the        *)
(* harness were too WEAK, the epoch bug would be a modelling artifact; if   *)
(* it were too STRONG, the fixes would look sound for the wrong reason.     *)
(* Neither failure is visible from inside the epoch specs.                  *)
(*                                                                         *)
(* This spec pins the harness to a published, independently known result.   *)
(* SB is the textbook x86-TSO litmus (Owens/Sewell/Sarkar, "A Better x86    *)
(* Memory Model: x86-TSO"): r1 = r2 = 0 is architecturally ALLOWED without  *)
(* a fence and FORBIDDEN with one. Reproducing exactly that outcome — no    *)
(* more, no less — is what licenses the epoch results. It deliberately      *)
(* instantiates StoreBuffer rather than restating it, so it tests the same  *)
(* operators the epoch specs run on.                                       *)
(*                                                                         *)
(* x86-TSO (Model = "tso"): each core has a private FIFO store buffer. A    *)
(* store enters the buffer and drains to shared memory in FIFO order; a     *)
(* load reads the newest matching entry in its own buffer (store            *)
(* forwarding) else shared memory. The ONLY reordering this permits is      *)
(* StoreLoad: a core's own later load can execute while its earlier store   *)
(* is still buffered. That is exactly — and only — the reordering the epoch *)
(* announce bug needs.                                                     *)
(*                                                                         *)
(* Fenced = FALSE : no barrier -> SequentiallyConsistent is VIOLATED        *)
(*                  (both loads may read 0). This is the StoreLoad window.  *)
(* Fenced = TRUE  : an MFENCE (== Interlocked.MemoryBarrier) between store  *)
(*                  and load drains the buffer first -> SC HOLDS.           *)
(*                                                                         *)
(* Note: an x86 RELEASE store is just a plain store (TSO stores already     *)
(* have release semantics), and it does NOT order StoreLoad — only MFENCE   *)
(* (or a LOCKed RMW) does. That is why "make it volatile" does not fix the  *)
(* bug.                                                                    *)
(***************************************************************************)
EXTENDS Integers, Sequences

CONSTANT Fenced         \* TRUE => an MFENCE sits between each store and load
CONSTANT Model          \* "tso" | "arm" -- see MODULE StoreBuffer

T1 == "t1"
T2 == "t2"
Procs == {T1, T2}

VARIABLES memory, storeBuffer, r1, r2, pc
vars == <<memory, storeBuffer, r1, r2, pc>>

\* Implicit substitution: this module declares memory and storeBuffer, so the shared
\* harness binds to them directly.
SB == INSTANCE StoreBuffer

OwnVar(p)   == IF p = T1 THEN "x" ELSE "y"
OtherVar(p) == IF p = T1 THEN "y" ELSE "x"

Init ==
    /\ memory = [x |-> 0, y |-> 0]
    /\ storeBuffer = [p \in Procs |-> <<>>]
    /\ r1 = -1
    /\ r2 = -1
    /\ pc = [p \in Procs |-> "store"]

\* Asynchronous propagation of one pending store.
FlushOne(p) == SB!FlushOne(p) /\ UNCHANGED <<r1, r2, pc>>

DoStore(p) ==
    /\ pc[p] = "store"
    /\ storeBuffer' = SB!Buffer(p, OwnVar(p), 1)
    /\ pc' = [pc EXCEPT ![p] = IF Fenced THEN "fence" ELSE "load"]
    /\ UNCHANGED <<memory, r1, r2>>

\* MFENCE: everything this core has pending becomes globally visible at once.
DoFence(p) ==
    /\ pc[p] = "fence"
    /\ memory' = SB!Fenced(p)
    /\ storeBuffer' = SB!Drained(p)
    /\ pc' = [pc EXCEPT ![p] = "load"]
    /\ UNCHANGED <<r1, r2>>

DoLoad(p) ==
    /\ pc[p] = "load"
    /\ LET v == SB!Load(p, OtherVar(p))
       IN IF p = T1 THEN r1' = v /\ UNCHANGED r2
                    ELSE r2' = v /\ UNCHANGED r1
    /\ pc' = [pc EXCEPT ![p] = "done"]
    /\ UNCHANGED <<memory, storeBuffer>>

Next ==
    \/ \E p \in Procs : DoStore(p) \/ DoFence(p) \/ DoLoad(p) \/ FlushOne(p)

Spec == Init /\ [][Next]_vars

Done == pc[T1] = "done" /\ pc[T2] = "done"

\* Sequential consistency forbids BOTH loads reading 0. Under TSO this holds
\* ONLY with a fence; without one it is violated (the StoreLoad window).
SequentiallyConsistent == Done => ~(r1 = 0 /\ r2 = 0)
=============================================================================
