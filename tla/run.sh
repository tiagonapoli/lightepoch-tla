#!/usr/bin/env bash
# Model-check every TLA+ spec in this folder and report each result against its
# expectation. Requires Java + tla2tools.jar (see Dockerfile), or set TLA_TOOLS
# to the path of tla2tools.jar.
set -u

JAR="${TLA_TOOLS:-/opt/tla2tools.jar}"
HERE="$(cd "$(dirname "$0")" && pwd)"
# -DTLA-Library lets specs in epoch/ and epoch/fixes/ resolve the shared
# MODULE StoreBuffer, which lives at the top of this folder.
TLC=(java -XX:+UseParallelGC "-DTLA-Library=$HERE" -cp "$JAR" tlc2.TLC -workers auto -deadlock -cleanup)
failures=0

run() {
  local dir="$1" spec="$2" cfg="$3" expected_result="$4" description="$5"
  local output status
  output="$(mktemp)"
  echo ""
  echo "############################################################"
  echo "# $spec   (config: $cfg)"
  echo "# expected: $expected_result ($description)"
  echo "############################################################"
  if (cd "$dir" && "${TLC[@]}" -config "$cfg" "$spec.tla") >"$output" 2>&1; then
    status=0
  else
    status=$?
  fi
  cat "$output"

  if [[ "$expected_result" == "HOLDS" ]]; then
    if [[ $status -eq 0 ]] && grep -q "Model checking completed. No error has been found." "$output"; then
      echo "# ---- PASS: HOLDS ----"
    else
      echo "# ---- FAIL: expected HOLDS; TLC exit code $status ----"
      failures=$((failures + 1))
    fi
  elif [[ $status -ne 0 ]] && grep -Eq "Error: Invariant .* is violated" "$output"; then
    echo "# ---- PASS: expected invariant violation observed ----"
  else
    echo "# ---- FAIL: expected invariant violation; TLC exit code $status ----"
    failures=$((failures + 1))
  fi

  rm -f "$output"
}

echo "================= Memory-model litmus spec ================="
run "$HERE/memory-models" X86TSO X86TSO_NoFence.cfg  VIOLATED "StoreLoad window without a fence"
run "$HERE/memory-models" X86TSO X86TSO_Fence.cfg    HOLDS    "MFENCE closes it"

echo ""
echo "================= LightEpoch reclamation specs ================="
echo "# Each epoch spec is checked under BOTH memory models (MODULE StoreBuffer):"
echo "#   tso = x86-TSO, FIFO store-buffer drain, only StoreLoad relaxed"
echo "#   arm = additionally relaxes StoreStore (any pending store may drain first)"
echo "# Every tso behavior is also an arm behavior, so VIOLATED under tso implies"
echo "# VIOLATED under arm, and HOLDS under arm implies HOLDS under tso."

run "$HERE/epoch"       LightEpoch                        LightEpoch_tso.cfg                        VIOLATED "missing announce fence (x86-TSO)"
run "$HERE/epoch"       LightEpoch                        LightEpoch_arm.cfg                        VIOLATED "missing announce fence (+StoreStore)"
run "$HERE/epoch/fixes" FixedLightEpochWithMemoryBarrier  FixedLightEpochWithMemoryBarrier_tso.cfg  HOLDS    "full StoreLoad barrier (x86-TSO)"
run "$HERE/epoch/fixes" FixedLightEpochWithMemoryBarrier  FixedLightEpochWithMemoryBarrier_arm.cfg  HOLDS    "full StoreLoad barrier (+StoreStore)"

echo ""
echo "========= Resume+Refresh per-operation API specs (Resume+Refresh+Suspend) ========="
run "$HERE/epoch"       LightEpochResumeAndRefresh       LightEpochResumeAndRefresh_tso.cfg       VIOLATED "both per-op announces unfenced (x86-TSO)"
run "$HERE/epoch"       LightEpochResumeAndRefresh       LightEpochResumeAndRefresh_arm.cfg       VIOLATED "both per-op announces unfenced (+StoreStore)"
run "$HERE/epoch/fixes" FixedLightEpochResumeAndRefresh  FixedLightEpochResumeAndRefresh_tso.cfg  HOLDS    "fence at both announce sites (x86-TSO)"
run "$HERE/epoch/fixes" FixedLightEpochResumeAndRefresh  FixedLightEpochResumeAndRefresh_arm.cfg  HOLDS    "fence at both announce sites (+StoreStore)"

echo ""
echo "========= Tsavorite end-to-end flows (LightEpoch AS TSAVORITE USES IT) ========="
echo "# These answer the objection 'Tsavorite already adds the barrier anyway'."
echo "# Both threads run REAL Tsavorite flows and every interlocked operation"
echo "# Tsavorite actually performs is modelled as a full StoreLoad barrier."
echo "#"
echo "# Each spec is checked under BOTH memory models. The verdict is the same under"
echo "# both in every case: what decides it is the FLOW, not the memory model."
echo "# TsavoriteReadWithBucketLatch and TsavoriteTransactionalRead run the SAME"
echo "# InternalRead code; only the session type differs, and only one of them holds."
echo "# The only difference between the first two specs is whether an interlocked"
echo "# operation happens to sit between the epoch announce and the page dereference."

run "$HERE/tsavorite"       TsavoriteReadAtAddress        TsavoriteReadAtAddress_tso.cfg        VIOLATED "ReadAtAddress derefs the page with no fence after the announce (x86-TSO)"
run "$HERE/tsavorite"       TsavoriteReadAtAddress        TsavoriteReadAtAddress_arm.cfg        VIOLATED "ReadAtAddress derefs the page with no fence after the announce (+StoreStore)"
run "$HERE/tsavorite"       TsavoriteReadWithBucketLatch  TsavoriteReadWithBucketLatch_tso.cfg  HOLDS    "InternalRead's bucket-latch CAS incidentally fences the announce (x86-TSO)"
run "$HERE/tsavorite"       TsavoriteReadWithBucketLatch  TsavoriteReadWithBucketLatch_arm.cfg  HOLDS    "InternalRead's bucket-latch CAS incidentally fences the announce (+StoreStore)"
run "$HERE/tsavorite"       TsavoriteTransactionalRead    TsavoriteTransactionalRead_tso.cfg    VIOLATED "the SAME InternalRead flow, transactional session: no latch, no fence (x86-TSO)"
run "$HERE/tsavorite"       TsavoriteTransactionalRead    TsavoriteTransactionalRead_arm.cfg    VIOLATED "the SAME InternalRead flow, transactional session: no latch, no fence (+StoreStore)"
run "$HERE/tsavorite"       TsavoriteLogScanGetNext       TsavoriteLogScanGetNext_tso.cfg       VIOLATED "TsavoriteLog scan iterator derefs the page with no fence after Resume (x86-TSO)"
run "$HERE/tsavorite"       TsavoriteLogScanGetNext       TsavoriteLogScanGetNext_arm.cfg       VIOLATED "TsavoriteLog scan iterator derefs the page with no fence after Resume (+StoreStore)"
run "$HERE/tsavorite/fixes" FixedTsavoriteReadAtAddress   FixedTsavoriteReadAtAddress_tso.cfg   HOLDS    "fixing LightEpoch closes the flow Tsavorite's barriers miss (x86-TSO)"
run "$HERE/tsavorite/fixes" FixedTsavoriteReadAtAddress   FixedTsavoriteReadAtAddress_arm.cfg   HOLDS    "fixing LightEpoch closes the flow Tsavorite's barriers miss (+StoreStore)"

echo ""
echo "========= CAS-carries-epoch fix (the proposed fix) ========="
echo "# The fix claims the slot WITH the announce -- CAS(localCurrentEpoch, 0 -> epoch)"
echo "# -- instead of CASing threadId and then announcing with a plain store. The"
echo "# locked-RMW count is unchanged; only the word being CASed differs."
echo "#"
echo "# Each configuration is paired with a control that removes the fix, to prove"
echo "# the spec is capable of detecting the bug it reports absent."

echo ""
echo "--- 1 reader + 1 reclaimer (Acquire, ProtectAndDrain, CS, Suspend) ---"
run "$HERE/epoch/fixes" CasAnnounceOneReader  CasAnnounceOneReader_tso.cfg  HOLDS "CAS carries the announce (x86-TSO)"
run "$HERE/epoch/fixes" CasAnnounceOneReader  CasAnnounceOneReader_arm.cfg  HOLDS "CAS carries the announce (+StoreStore)"

echo ""
echo "--- 2 readers contending for one slot + 1 reclaimer ---"
run "$HERE/epoch/fixes" CasAnnounceTwoReaders              CasAnnounceTwoReaders_tso.cfg              HOLDS    "slot reuse is safe (x86-TSO)"
run "$HERE/epoch/fixes" CasAnnounceTwoReaders              CasAnnounceTwoReaders_arm.cfg              HOLDS    "slot reuse is safe (+StoreStore)"
run "$HERE/epoch/fixes" CasAnnounceTwoReadersNoCas         CasAnnounceTwoReadersNoCas_tso.cfg         VIOLATED "control: no CAS on the epoch word (x86-TSO)"
run "$HERE/epoch/fixes" CasAnnounceTwoReadersNoCas         CasAnnounceTwoReadersNoCas_arm.cfg         VIOLATED "control: no CAS on the epoch word (+StoreStore)"
run "$HERE/epoch/fixes" CasAnnounceTwoReadersPlainRelease  CasAnnounceTwoReadersPlainRelease_tso.cfg  HOLDS    "control: plain Release survives TSO's FIFO drain"
run "$HERE/epoch/fixes" CasAnnounceTwoReadersPlainRelease  CasAnnounceTwoReadersPlainRelease_arm.cfg  VIOLATED "control: plain Release lets the next owner's announce be wiped (+StoreStore)"
run "$HERE/epoch/fixes" CasAnnounceTwoReadersNoThreadId       CasAnnounceTwoReadersNoThreadId_tso.cfg       HOLDS    "threadId removed: epoch word alone owns the slot (x86-TSO)"
run "$HERE/epoch/fixes" CasAnnounceTwoReadersNoThreadId       CasAnnounceTwoReadersNoThreadId_arm.cfg       HOLDS    "threadId removed: epoch word alone owns the slot (+StoreStore)"
run "$HERE/epoch/fixes" CasAnnounceTwoReadersNoThreadIdNoCas  CasAnnounceTwoReadersNoThreadIdNoCas_tso.cfg  VIOLATED "control: no threadId AND no CAS -> both readers claim one slot (x86-TSO)"
run "$HERE/epoch/fixes" CasAnnounceTwoReadersNoThreadIdNoCas  CasAnnounceTwoReadersNoThreadIdNoCas_arm.cfg  VIOLATED "control: no threadId AND no CAS -> both readers claim one slot (+StoreStore)"

echo ""
echo "--- 2 symmetric peers: each protects AND reclaims, own slot each ---"
echo "# The configuration Tsavorite actually runs: every session thread does"
echo "# Resume / ProtectAndDrain / critical section / Suspend in a loop, and any"
echo "# of them may also retire an object and run the scan -- while itself protected."
run "$HERE/epoch/fixes" CasAnnounceSymmetricPeers       CasAnnounceSymmetricPeers_tso.cfg       HOLDS    "self-reclaiming peers are safe (x86-TSO)"
run "$HERE/epoch/fixes" CasAnnounceSymmetricPeers       CasAnnounceSymmetricPeers_arm.cfg       HOLDS    "self-reclaiming peers are safe (+StoreStore)"
run "$HERE/epoch/fixes" CasAnnounceSymmetricPeersNoCas  CasAnnounceSymmetricPeersNoCas_tso.cfg  VIOLATED "control: production ordering frees under a live peer (x86-TSO)"
run "$HERE/epoch/fixes" CasAnnounceSymmetricPeersNoCas  CasAnnounceSymmetricPeersNoCas_arm.cfg  VIOLATED "control: production ordering frees under a live peer (+StoreStore)"

echo ""
echo "--- can Entry.threadId be deleted once the CAS owns the slot? ---"
echo "# With the fix, CAS(localCurrentEpoch, 0 -> epoch) both claims and announces,"
echo "# so threadId no longer participates in slot ownership and the scan never read"
echo "# it. These specs delete the field and leave ownership to the claim CAS plus"
echo "# the thread-private entry index (Metadata.Entries[instanceId])."
run "$HERE/epoch/fixes" CasAnnounceNoThreadId            CasAnnounceNoThreadId_tso.cfg            HOLDS    "slot reuse is safe with threadId deleted (x86-TSO)"
run "$HERE/epoch/fixes" CasAnnounceNoThreadId            CasAnnounceNoThreadId_arm.cfg            HOLDS    "slot reuse is safe with threadId deleted (+StoreStore)"
echo "# Two controls on two different axes, so the HOLDS above cannot be an artifact"
echo "# of deleting the field that the invariants were watching."
run "$HERE/epoch/fixes" CasAnnounceNoThreadIdNoCas       CasAnnounceNoThreadIdNoCas_tso.cfg       VIOLATED "control: announce axis -- unfenced claim still detected (x86-TSO)"
run "$HERE/epoch/fixes" CasAnnounceNoThreadIdNoCas       CasAnnounceNoThreadIdNoCas_arm.cfg       VIOLATED "control: announce axis -- unfenced claim still detected (+StoreStore)"
run "$HERE/epoch/fixes" CasAnnounceNoThreadIdStaleIndex  CasAnnounceNoThreadIdStaleIndex_tso.cfg  VIOLATED "control: ownership axis -- a stale entry index now has nothing to disqualify it"
run "$HERE/epoch/fixes" CasAnnounceNoThreadIdStaleIndex  CasAnnounceNoThreadIdStaleIndex_arm.cfg  VIOLATED "control: ownership axis -- a stale entry index now has nothing to disqualify it"
echo "# Deleting threadId also deletes the only unfenced reader stores, so the two"
echo "# runs above explore an identical state space and the 'arm' verdict is not"
echo "# independent evidence. This pair weakens the unpublish to a release store"
echo "# that may linger, which gives the store-order relaxation something to act on."
echo "# It STILL comes out identical, and that is a theorem rather than an oversight:"
echo "# StoreBuffer's 'arm' flush picks any index of the buffer, which differs from"
echo "# TSO's head-only flush only when a thread has two or more stores pending. The"
echo "# fixed reader never has more than one, so store-order relaxation is inert."
run "$HERE/epoch/fixes" CasAnnounceNoThreadIdWeakRelease CasAnnounceNoThreadIdWeakRelease_tso.cfg HOLDS    "release-only unpublish, threadId deleted (x86-TSO)"
run "$HERE/epoch/fixes" CasAnnounceNoThreadIdWeakRelease CasAnnounceNoThreadIdWeakRelease_arm.cfg HOLDS    "release-only unpublish may land late; late is conservative (+StoreStore)"

echo ""
echo "--- the naive fix (barrier after the announce) under slot reuse ---"
run "$HERE/epoch/fixes" NaiveFixTwoReaders  NaiveFixTwoReaders_tso.cfg  HOLDS    "barrier suffices while stores drain in order"
run "$HERE/epoch/fixes" NaiveFixTwoReaders  NaiveFixTwoReaders_arm.cfg  VIOLATED "Release's two unordered plain stores let a stale 0 wipe the next owner's announce"

echo ""
echo "========= reader-side reordering (WeakMemory, per-processor views) ========="
echo "# Everything above uses MODULE StoreBuffer, whose \"arm\" model relaxes STORE"
echo "# visibility only. It is multi-copy atomic and has no load-load reordering, so"
echo "# a load always returns the newest propagated value."
echo "#"
echo "# That is not strong enough. CasAnnounceSymmetricPeers HOLDS under \"arm\" while"
echo "# the same algorithm faults on a Neoverse-N2 in seconds under the Resume+Refresh"
echo "# sequence. MODULE WeakMemory adds the missing dimension: each processor has its"
echo "# own view that catches up per FIELD, in any order, so a reader can observe the"
echo "# bumped epoch while still holding a stale view of the unlink."
echo "#"
echo "# The three RefreshOrder variants mirror the LE_REFRESH_ORDER knob in"
echo "# FixedLightEpochWithCasAnnounce.cs, and these results match the hardware A/B"
echo "# on Neoverse-N2 three for three -- including that a release store is NOT enough."
run "$HERE/epoch/fixes" CasAnnounceResumeRefreshWeak  CasAnnounceResumeRefreshWeak_plain_tso.cfg     HOLDS    "plain refresh announce is safe under TSO"
run "$HERE/epoch/fixes" CasAnnounceResumeRefreshWeak  CasAnnounceResumeRefreshWeak_plain_arm.cfg     HOLDS    "store reordering alone does NOT expose it -- this is the false all-clear"
run "$HERE/epoch/fixes" CasAnnounceResumeRefreshWeak  CasAnnounceResumeRefreshWeak_plain_armlb.cfg   VIOLATED "reader announces E+1 on a stale view and frees the object it is reading"
run "$HERE/epoch/fixes" CasAnnounceResumeRefreshWeak  CasAnnounceResumeRefreshWeak_release_armlb.cfg VIOLATED "a release store publishes the announce but does not refresh the reader's view"
echo "# The hazard is load-side message passing: the reclaimer already orders its unlink"
echo "# before the epoch bump (Interlocked.Increment is a locked RMW), so the reader needs"
echo "# only to observe that ordering. An acquire load of CurrentEpoch supplies it, and is"
echo "# what x86 gives every load for free -- which is why the plain code is safe on x86."
run "$HERE/epoch/fixes" CasAnnounceResumeRefreshWeak  CasAnnounceResumeRefreshWeak_acqload_armlb.cfg HOLDS    "an acquire load of CurrentEpoch is sufficient, and is free on x86"
echo "# Two controls, so that the HOLDS above cannot be an artifact of the model."
echo "# acqloadmp uses a STRICTLY WEAKER acquire that transfers only the two fields the"
echo "# message-passing argument actually claims; it must still hold. acqloadself is a"
echo "# near miss that refreshes only the field being loaded, transferring nothing, and"
echo "# must still fail -- if it ever holds, the check has gone dead and neither HOLDS counts."
run "$HERE/epoch/fixes" CasAnnounceResumeRefreshWeak  CasAnnounceResumeRefreshWeak_acqloadmp_armlb.cfg   HOLDS    "the minimal message-passing guarantee alone is enough"
run "$HERE/epoch/fixes" CasAnnounceResumeRefreshWeak  CasAnnounceResumeRefreshWeak_acqloadself_armlb.cfg VIOLATED "a load that transfers nothing still fails, so the check is alive"
echo "# Minimality of the OTHER half of the fix. The acquire announce and the refresh"
echo "# announce fail in two DIFFERENT shapes and so need two different strengths."
echo "# The refresh is message passing, which acquire/release closes. The acquire announce"
echo "# is store buffering (the reclaimer must observe the reader's store), and SB is the"
echo "# classic shape that release/acquire does NOT close -- it needs a full RMW."
echo "# Both rows below keep the acquire-load fix on the refresh, so any violation they"
echo "# report is attributable to the acquire announce alone."
run "$HERE/epoch/fixes" CasAnnounceResumeRefreshWeak  CasAnnounceResumeRefreshWeak_acqplain_armlb.cfg   VIOLATED "the acquire-load fix alone is NOT enough: the announce still lingers"
run "$HERE/epoch/fixes" CasAnnounceResumeRefreshWeak  CasAnnounceResumeRefreshWeak_acqrelease_armlb.cfg VIOLATED "a release store is not enough either, so the CAS is load-bearing"
run "$HERE/epoch/fixes" CasAnnounceResumeRefreshWeak  CasAnnounceResumeRefreshWeak_fence_armlb.cfg   HOLDS    "a full StoreLoad barrier also closes it, but is strictly more than needed"

echo ""
echo "========= Load->Store: the dereference against the reader's own unpublish ========="
echo "# Every spec above asks what OTHER threads observe of the reader's stores."
echo "# This one asks whether the reader is still using the object when it announces"
echo "# that it is not:  ldr x2,[data]  /  str xzr,[slotEpoch]. AArch64 may make the"
echo "# unpublish visible first, so a scan in that window frees the object under a"
echo "# load that has not been satisfied."
echo "#"
echo "# NEITHER StoreBuffer NOR WeakMemory can express this: both bind a load's value"
echo "# at its program point, so a store may be delayed but a load never can be. And"
echo "# in the other specs the critical section is not a memory access at all --"
echo "# CasAnnounceOneReader's Dereference only flips a flag -- so there would be"
echo "# nothing to reorder even in a substrate that modelled it. This spec splits the"
echo "# dereference into issue and bind, which is the smallest change that makes the"
echo "# reordering expressible. The middle row is the liveness control."
run "$HERE/epoch/fixes" CasAnnounceReleaseLoadStore  CasAnnounceReleaseLoadStore_plain_tso.cfg   HOLDS    "x86-TSO preserves Load->Store, so the plain unpublish is safe there"
run "$HERE/epoch/fixes" CasAnnounceReleaseLoadStore  CasAnnounceReleaseLoadStore_plain_arm.cfg   VIOLATED "the plain unpublish is observed while the dereference is still in flight"
run "$HERE/epoch/fixes" CasAnnounceReleaseLoadStore  CasAnnounceReleaseLoadStore_release_arm.cfg HOLDS    "Volatile.Write -> STLR orders the dereference before the unpublish"

echo ""
if [[ $failures -ne 0 ]]; then
  echo "$failures spec result(s) did not match expectations."
  exit 1
fi

echo "All specs matched expectations."
