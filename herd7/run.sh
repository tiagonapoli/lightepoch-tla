#!/usr/bin/env bash
# Run every litmus test through herd7 (herdtools7) using the architecture's
# official memory model (Intel-vetted x86tso for X86, ARM's model for AArch64),
# and check each observed outcome against what this bug study predicts.
set -u

HERD="${HERD:-herd7}"

# test file                       expectation  meaning
TESTS=(
  "SB-x86.litmus            Sometimes  x86-TSO allows StoreLoad -> window exists"
  "SB+mfence-x86.litmus     Never      MFENCE closes it on x86"
  "SB+xchg-x86.litmus       Never      XCHG (locked seq-cst RMW) closes it on x86"
  "SB+tsavorite-x86.litmus  Sometimes  Tsavorite per-op double-announce, still SB on x86-TSO"
  "SB-aarch64.litmus        Sometimes  plain announce -> bug is real on AArch64"
  "SB+rel-aarch64.litmus    Sometimes  STLR/release is NOT enough"
  "SB+dmb-aarch64.litmus    Never      DMB ISH (full barrier) closes it"
  "SB+swpal-aarch64.litmus  Never      SWPAL (seq-cst RMW) closes it on AArch64"
  "SB+tsavorite-aarch64.litmus       Sometimes  Tsavorite per-op double-announce -> bug reproduces"
  "SB+tsavorite-dmb-aarch64.litmus   Never      DMB ISH after the announces closes the shipped path"
)

fail=0
printf '%-34s %-10s %-10s %s\n' "TEST" "EXPECT" "OBSERVED" "RESULT"
printf '%.0s-' {1..80}; echo
for row in "${TESTS[@]}"; do
  file=$(awk '{print $1}' <<<"$row")
  expect=$(awk '{print $2}' <<<"$row")
  out=$($HERD "$file" 2>/dev/null)
  # herd7 prints:  Observation <name> Never|Sometimes|Always ...
  observed=$(grep -oE 'Observation [^ ]+ (Never|Sometimes|Always)' <<<"$out" | awk '{print $3}')
  observed=${observed:-?}
  if [[ "$observed" == "$expect" ]]; then res="OK"; else res="MISMATCH"; fail=1; fi
  printf '%-34s %-10s %-10s %s\n' "$file" "$expect" "$observed" "$res"
done

echo
if [[ $fail -eq 0 ]]; then
  echo "All herd7 outcomes match the predicted memory-model behavior."
else
  echo "Some outcomes did not match -- inspect with: $HERD <file>"
fi
exit $fail
