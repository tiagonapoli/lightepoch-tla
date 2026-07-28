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
if [[ $failures -ne 0 ]]; then
  echo "$failures spec result(s) did not match expectations."
  exit 1
fi

echo "All specs matched expectations."
