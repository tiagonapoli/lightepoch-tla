#!/usr/bin/env bash
# Model-check every TLA+ spec in this folder and report each result against its
# expectation. Requires Java + tla2tools.jar (see Dockerfile), or set TLA_TOOLS
# to the path of tla2tools.jar.
set -u

JAR="${TLA_TOOLS:-/opt/tla2tools.jar}"
TLC=(java -XX:+UseParallelGC -cp "$JAR" tlc2.TLC -workers auto -deadlock -cleanup)
HERE="$(cd "$(dirname "$0")" && pwd)"
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

echo "================= Memory-model litmus specs ================="
run "$HERE/memory-models" X86TSO X86TSO_NoFence.cfg  VIOLATED "StoreLoad window without a fence"
run "$HERE/memory-models" X86TSO X86TSO_Fence.cfg    HOLDS    "MFENCE closes it"
run "$HERE/memory-models" ARM64  ARM64_None.cfg      VIOLATED "plain store"
run "$HERE/memory-models" ARM64  ARM64_Release.cfg   VIOLATED "release store is not enough"
run "$HERE/memory-models" ARM64  ARM64_Full.cfg      HOLDS    "DMB ISH / seq-cst RMW"

echo ""
echo "================= LightEpoch reclamation specs ================="
run "$HERE" LightEpoch                            LightEpoch.cfg                            VIOLATED "missing announce fence"
run "$HERE" FixedLightEpochWithMemoryBarrier      FixedLightEpochWithMemoryBarrier.cfg      HOLDS    "full StoreLoad barrier"
run "$HERE" FixedLightEpochWithInterlocked        FixedLightEpochWithInterlocked.cfg        HOLDS    "atomic RMW announce"
run "$HERE" FixedLightEpochWithAsymmetricBarrier  FixedLightEpochWithAsymmetricBarrier.cfg  HOLDS    "reclaimer-side barrier"

echo ""
echo "========= Resume+Refresh per-operation API specs (Resume+Refresh+Suspend) ========="
run "$HERE" LightEpochResumeAndRefresh                   LightEpochResumeAndRefresh.cfg                   VIOLATED "both per-op announces unfenced"
run "$HERE" FixedLightEpochResumeAndRefresh              FixedLightEpochResumeAndRefresh.cfg              HOLDS    "fence at both announce sites"
run "$HERE" FixedLightEpochResumeAndRefreshNoAnnounce    FixedLightEpochResumeAndRefreshNoAnnounce.cfg    HOLDS    "fence only Acquire; drop the redundant 2nd announce"

echo ""
if [[ $failures -ne 0 ]]; then
  echo "$failures spec result(s) did not match expectations."
  exit 1
fi

echo "All specs matched expectations."
