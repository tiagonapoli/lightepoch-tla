#!/usr/bin/env bash
# Dumps the JIT-native disassembly of the epoch methods that carry the fix and
# splits it into one .asm file per variant under $OUT (default /out).
#
# Methods captured (DOTNET_JitDisasm filter):
#   ProtectAndDrain              -> the announce store site (baseline/full/interlocked differ here)
#   ComputeNewSafeToReclaimEpoch -> the reclaimer scan (the asymmetric barrier lives here)
set -uo pipefail

OUT=${OUT:-/out}
mkdir -p "$OUT"
rm -f "$OUT"/*.asm

export DOTNET_TieredCompilation=0                                   # straight to FullOpts
export DOTNET_JitDisasm="ProtectAndDrain ComputeNewSafeToReclaimEpoch"
export DOTNET_JitDisasmDiffable=1                                   # stable, address-free

raw=$(mktemp)
dotnet /app/DisasmDump.dll > "$raw" 2>&1 || true

# Route each "; Assembly listing for method Tsavorite.core.<Class>:..." block to
# the file named after <Class>.
awk -v out="$OUT" '
  /^; Assembly listing for method / {
    cur=""
    if (match($0, /Tsavorite\.core\.[A-Za-z0-9_]+/)) {
      name=substr($0, RSTART+15, RLENGTH-15)   # 15 = length("Tsavorite.core.")
      cur=out"/"name".asm"
    }
  }
  { if (cur!="") print >> cur }
' "$raw"

echo "arch=$(uname -m) -- wrote:"
ls -1 "$OUT"/*.asm 2>/dev/null || { echo "NO DISASSEMBLY PRODUCED"; head -40 "$raw"; exit 1; }
