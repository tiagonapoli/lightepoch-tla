#!/usr/bin/env bash
# Model-check every TLA+ spec in this folder and report each result against its
# expectation. Requires Java + tla2tools.jar (see Dockerfile), or set TLA_TOOLS
# to the path of tla2tools.jar.
set -u

JAR="${TLA_TOOLS:-/opt/tla2tools.jar}"
TLC="java -XX:+UseParallelGC -cp $JAR tlc2.TLC -workers auto -deadlock -cleanup"
HERE="$(cd "$(dirname "$0")" && pwd)"

run() {
  local dir="$1" spec="$2" cfg="$3" expect="$4"
  echo ""
  echo "############################################################"
  echo "# $spec   (config: $cfg)"
  echo "# expected: $expect"
  echo "############################################################"
  ( cd "$dir" && $TLC -config "$cfg" "$spec.tla" )
  echo "# ---- TLC exit code: $? ----"
}

echo "================= Memory-model litmus specs ================="
run "$HERE/memory-models" X86TSO X86TSO_NoFence.cfg  "VIOLATED (StoreLoad window without a fence)"
run "$HERE/memory-models" X86TSO X86TSO_Fence.cfg    "HOLDS (MFENCE closes it)"
run "$HERE/memory-models" ARM64  ARM64_None.cfg      "VIOLATED (plain store)"
run "$HERE/memory-models" ARM64  ARM64_Release.cfg   "VIOLATED (release store is not enough)"
run "$HERE/memory-models" ARM64  ARM64_Full.cfg      "HOLDS (DMB ISH / seq-cst RMW)"

echo ""
echo "================= LightEpoch reclamation specs ================="
run "$HERE" LightEpoch                            LightEpoch.cfg                            "VIOLATED (missing announce fence)"
run "$HERE" FixedLightEpoch                       FixedLightEpoch.cfg                       "HOLDS (full StoreLoad barrier)"
run "$HERE" FixedLightEpochWithInterlocked        FixedLightEpochWithInterlocked.cfg        "HOLDS (atomic RMW announce)"
run "$HERE" FixedLightEpochWithAsymmetricBarrier  FixedLightEpochWithAsymmetricBarrier.cfg  "HOLDS (reclaimer-side barrier)"

echo ""
echo "========= Tsavorite per-operation API specs (Resume+Refresh+Suspend) ========="
run "$HERE" LightEpochTsavorite                   LightEpochTsavorite.cfg                   "VIOLATED (both per-op announces unfenced)"
run "$HERE" FixedLightEpochTsavorite              FixedLightEpochTsavorite.cfg              "HOLDS (fence at both announce sites)"
run "$HERE" FixedLightEpochTsavoriteNoAnnounce    FixedLightEpochTsavoriteNoAnnounce.cfg    "HOLDS (fence only Acquire; drop the redundant 2nd announce)"

echo ""
echo "All specs complete."
