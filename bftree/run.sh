#!/usr/bin/env bash
# Prove the Bf-Tree CPR handshake bug is real, then prove the SeqCst fix removes
# it. Each tool runs twice: once against the upstream Release/Acquire orderings,
# where it must reproduce the bug, and once against the fix, where it must come
# back clean. See the Dockerfile for the toolchain; outside the container, set
# STOCK_GENMC / RUSTMC_GENMC to the two genmc binaries.
#
#   ./run.sh [all|miri|genmc|rustmc]
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

STOCK_GENMC="${STOCK_GENMC:-/root/genmc/RelWithDebInfo/genmc}"
RUSTMC_GENMC="${RUSTMC_GENMC:-/usr/local/bin/genmc}"
WHICH="${1:-all}"

failures=0
bug_rows=()
fix_rows=()
ctl_rows=()

banner() {
  echo ""
  echo "############################################################"
  echo "# $1"
  echo "# expected: $2"
  echo "############################################################"
}

# verdict <kind> <label> <expected> <pattern> <file> <status>
verdict() {
  local kind="$1" label="$2" expected="$3" pattern="$4" file="$5" status="$6"
  local good bad row
  case "$kind" in
    bug)     good="REPRODUCED" ; bad="NOT REPRODUCED" ;;
    fix)     good="CLEAN"      ; bad="STILL BROKEN"   ;;
    control) good="OK"         ; bad="UNEXPECTED"     ;;
  esac

  if grep -Eq "$pattern" "$file"; then
    echo "# ---- $good: $expected ----"
    row="$(printf '%-15s %s' "$good" "$label")"
  else
    echo "# ---- $bad: expected /$pattern/, exit status $status ----"
    row="$(printf '%-15s %s' "$bad" "$label")"
    failures=$((failures + 1))
  fi

  case "$kind" in
    bug)     bug_rows+=("$row") ;;
    fix)     fix_rows+=("$row") ;;
    control) ctl_rows+=("$row") ;;
  esac
}

# check <kind> <label> <expected> <pattern> <cmd...>
check() {
  local kind="$1" label="$2" expected="$3" pattern="$4"
  shift 4
  local out status
  out="$(mktemp)"
  banner "$label" "$expected"
  if "$@" >"$out" 2>&1; then status=0; else status=$?; fi
  cat "$out"
  verdict "$kind" "$label" "$expected" "$pattern" "$out" "$status"
  rm -f "$out"
}

# check_saved <kind> <label> <expected> <pattern> <file>
check_saved() {
  local kind="$1" label="$2" expected="$3" pattern="$4" file="$5"
  banner "$label" "$expected"
  verdict "$kind" "$label" "$expected" "$pattern" "$file" "n/a"
}

run_miri() {
  echo ""
  echo "================= Miri (weak-memory emulation) ================="
  check bug "Miri   sb_handshake   phase transition" \
        "store-buffering violation" "VIOLATION at iteration" \
        cargo +nightly miri run -q --bin sb_handshake
  check fix "Miri   sb_handshake   phase transition" \
        "no violation in 300 iterations" "no violation observed in" \
        cargo +nightly miri run -q --bin sb_handshake -- fix
  check bug "Miri   uaf_sweep      use-after-free" \
        "UB: dangling reference" "Undefined Behavior|dangling reference" \
        cargo +nightly miri run -q --bin uaf_sweep
  check fix "Miri   uaf_sweep      use-after-free" \
        "no use-after-free in 300 iterations" "no use-after-free observed in" \
        cargo +nightly miri run -q --bin uaf_sweep -- fix
}

run_genmc() {
  echo ""
  echo "================= GenMC (C, RC11, exhaustive) ================="
  check bug "GenMC  cpr_handshake.c  (RC11, exhaustive)" \
        "safety violation" "Error: Safety violation" \
        "$STOCK_GENMC" -- genmc/cpr_handshake.c
  check fix "GenMC  cpr_handshake.c  (RC11, exhaustive)" \
        "no errors over the whole state space" "No errors were detected" \
        "$STOCK_GENMC" -- -DFIX genmc/cpr_handshake.c

  # The harness has teeth: the same store-buffering shape under SC is not a bug,
  # so a violation has to come from the weak orderings and not from the model.
  check control "GenMC  sb_sc.c   (negative control: SC forbids store-buffering)" \
        "no errors" "No errors were detected" \
        "$STOCK_GENMC" -- genmc/sb_sc.c
}

run_rustmc() {
  echo ""
  echo "================= RustMC (Rust, RA+RLX, exhaustive) ================="
  local out norm
  out="$(mktemp)"
  norm="$(mktemp)"
  banner "RustMC cargo rustmc test" "handshake and sweep both fault"
  cargo rustmc test --test handshake --test uaf >"$out" 2>&1
  cat "$out"

  # Pair each result line with the error reported underneath it.
  awk '/^[[:space:]]+(ok|FAILED)[[:space:]]/ { name = $2; next }
       /Error:/ { print name " :: " $0 }' "$out" >"$norm"

  check_saved bug "RustMC handshake_upstream  (on the Rust itself)" \
              "Attempt to access non-allocated memory" \
              "handshake_upstream.*Attempt to access non-allocated memory" "$norm"
  check_saved bug "RustMC sweep_upstream      (on the Rust itself)" \
              "Attempt to access freed memory" \
              "sweep_upstream.*Attempt to access freed memory" "$norm"
  rm -f "$out" "$norm"

  # Not a bug in the code under test: this build of genmc ships only the RA
  # driver, under which SeqCst is not strengthened. That is why the *_seqcst
  # tests above also fault, and why RustMC cannot certify the fix -- GenMC does
  # that job instead. See README section 9.6.
  check control "RustMC has no SC/RC11 driver -> cannot certify the fix" \
        "DriverFactory failure on --sc" "BUG: Failure at src/DriverFactory.hpp" \
        "$RUSTMC_GENMC" -- genmc/sb_sc.c
}

section() {
  local title="$1"
  shift
  echo ""
  echo "$title"
  if [[ $# -eq 0 ]]; then
    echo "  (not run)"
  else
    printf '  %s\n' "$@"
  fi
}

case "$WHICH" in
  all)    run_miri; run_genmc; run_rustmc ;;
  miri)   run_miri ;;
  genmc)  run_genmc ;;
  rustmc) run_rustmc ;;
  *)      echo "usage: run.sh [all|miri|genmc|rustmc]" >&2; exit 2 ;;
esac

echo ""
echo "================================ Summary ================================"
section "PROOF THE BUG IS REAL   -- upstream Release/Acquire, must reproduce" "${bug_rows[@]}"
section "PROOF THE FIX WORKS     -- same code with SeqCst, must be clean" "${fix_rows[@]}"
section "CONTROLS                -- properties of the tools, not of the code" "${ctl_rows[@]}"
echo "========================================================================="

if [[ $failures -ne 0 ]]; then
  echo ""
  echo "INCONCLUSIVE: $failures check(s) did not report what they should have."
  exit 1
fi

echo ""
echo "VERDICT"
echo "  Bug: reproduced on the upstream orderings by every tool that ran."
echo "  Fix: no tool that can certify SeqCst found anything wrong with it."
echo "       GenMC's is a proof -- the whole RC11 state space, exhaustively."
echo "       Miri's is evidence, not proof: it samples weak-memory behaviours."
