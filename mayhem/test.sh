#!/usr/bin/env bash
#
# libunwind/mayhem/test.sh — RUN libunwind's OWN test suite (built by mayhem/build.sh with normal
# flags in $SRC/mayhem-tests) and emit a CTRF summary. exit 0 iff no selected test failed.
#
# PATCH-grade oracle (§6.3, anti-reward-hacking): tests are run with -v so they PRINT computed
# values; each test's output is checked against a KNOWN behavioral string that is ONLY produced
# when the program actually executes the unwinder code. A no-op/exit(0) patch yields EMPTY output
# → the grep fails → the test is counted FAILED. The sabotage check in verify-repo.sh LD_PRELOADs
# a constructor that _exit(0)s the binaries — this oracle detects that.
#
# We deliberately run each binary DIRECTLY (not via automake make-check) so we control stdout
# capture and grep for computed values rather than relying on automake's exit-code-only verdict.
# Tests that need a depth argument: Gtest-exc/Ltest-exc get "1" as the first arg.
#
# This script only RUNS the pre-built tree; it never (re)compiles anything.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
cd "$SRC"

BUILDDIR="$SRC/mayhem-tests"
TESTBINDIR="$BUILDDIR/tests"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if [ ! -d "$TESTBINDIR" ]; then
  echo "missing $TESTBINDIR — run mayhem/build.sh first" >&2
  emit_ctrf "libunwind-tests" 0 1 0; exit 2
fi

echo "=== running libunwind behavioral tests in $TESTBINDIR ==="

PASSED=0; FAILED=0; SKIPPED=0

# run_test <label> <expected_pattern> <binary> [args...]
# Runs the binary with -v (forces output of computed values), captures combined stdout+stderr,
# checks exit code AND that the output contains the expected behavioral pattern.
# A sabotaged binary (_exit(0)) produces NO output → pattern match fails → FAIL.
run_test() {
  local label="$1" pattern="$2"; shift 2
  local bin="$TESTBINDIR/$1"; shift
  local args=("$@")
  if [ ! -x "$bin" ]; then
    echo "SKIP: $label ($bin not found or not executable)"
    SKIPPED=$(( SKIPPED + 1 )); return
  fi
  local out rc=0
  out=$("$bin" "${args[@]}" -v 2>&1) || rc=$?
  # Check BOTH exit code AND that output contains the behavioral marker.
  if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qE "$pattern"; then
    echo "PASS: $label"
    PASSED=$(( PASSED + 1 ))
  else
    echo "FAIL: $label (rc=$rc, pattern='$pattern' not found in output)"
    printf '%s\n' "$out" | tail -5 | sed 's/^/  /'
    FAILED=$(( FAILED + 1 ))
  fi
}

# test-strerror: with -v prints "no error" and other unw_strerror() strings (≥16 error codes).
run_test "test-strerror"     "no error"                        test-strerror

# test-proc-info: walks the unwind cursor over its own stack and prints "SUCCESS".
run_test "test-proc-info"    "SUCCESS"                         test-proc-info

# test-static-link: exercises the generic and local static unw APIs; prints function pointer addresses.
run_test "test-static-link"  "funcs\[0\]="                    test-static-link

# test-flush-cache: walks 257 frames through the unwinder cache, prints "First backtrace:".
run_test "test-flush-cache"  "First backtrace:"               test-flush-cache

# Gtest-bt / Ltest-bt: explicit backtrace via unw_step; prints "SUCCESS." at end.
run_test "Gtest-bt"          "SUCCESS\."                       Gtest-bt
run_test "Ltest-bt"          "SUCCESS\."                       Ltest-bt

# Gtest-init / Ltest-init: exercises constructor+atexit() unwinding; prints "do_backtrace() from".
run_test "Gtest-init"        "do_backtrace\(\) from"          Gtest-init
run_test "Ltest-init"        "do_backtrace\(\) from"          Ltest-init

# Gtest-exc / Ltest-exc: C++ exception through unwind frames; needs depth arg "1"; prints "SUCCESS!".
run_test "Gtest-exc"         "SUCCESS!"                        Gtest-exc      1
run_test "Ltest-exc"         "SUCCESS!"                        Ltest-exc      1

# Ltest-varargs: unwinds through varargs frames; prints "SUCCESS." at end.
run_test "Ltest-varargs"     "SUCCESS\."                       Ltest-varargs

# test-setjmp: siglongjmp signal-mask round-trips; prints "SUCCESS" at end.
run_test "test-setjmp"       "SUCCESS"                         test-setjmp

# Gtest-resume-sig / Ltest-resume-sig: resume after signal; prints "SUCCESS".
run_test "Gtest-resume-sig"  "SUCCESS"                         Gtest-resume-sig
run_test "Ltest-resume-sig"  "SUCCESS"                         Ltest-resume-sig

echo "=== done: PASSED=$PASSED FAILED=$FAILED SKIPPED=$SKIPPED ==="
emit_ctrf "libunwind-tests" "$PASSED" "$FAILED" "$SKIPPED"
