#!/usr/bin/env bash
#
# libunwind/mayhem/build.sh — build libunwind's OSS-Fuzz harness as a sanitized libFuzzer target
# (+ a standalone reproducer), AND build libunwind's own autotools test suite for mayhem/test.sh.
#
# Fuzzed surface (fuzz_libunwind): the harness builds arbitrary stack frames via mutually-recursive
# functions whose recursion/branch decisions are driven by the input bytes, then exercises the
# LOCAL unwinder API (UNW_LOCAL_ONLY) on each frame: unw_getcontext / unw_init_local / unw_step plus
# unw_get_proc_name, unw_get_reg, unw_is_signal_frame and unw_get_save_loc. So the bytes drive the
# unwinder over self-generated stacks — not a file format. Inputs are 12..512 bytes.
#
# The libunwind static libs THEMSELVES are compiled with $SANITIZER_FLAGS so the unwinder code
# (not just the harness) is instrumented. Build contract comes from the org base ENV
# (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/STANDALONE_FUZZ_MAIN/OUT).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
# DEBUG_FLAGS: force DWARF < 4 so Mayhem's triage can read the symbols (clang-19 defaults to DWARF-5).
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${OUT:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS OUT

cd "$SRC"

HARNESS_DIR="$SRC/mayhem/harnesses"

# autoreconf once in the source tree (generates configure); both builds below are OUT-OF-TREE
# (VPATH) so the source dir is never "configured" and the two trees can coexist.
autoreconf -i

# ── 1) Build libunwind (static) WITH sanitizers so the unwinder is instrumented ───────────────────
# Static only (--enable-shared=no) so the harness links self-contained binaries, matching OSS-Fuzz.
# Sanitizer flags flow through CFLAGS/CXXFLAGS into every libunwind object. Out-of-tree VPATH build.
SANBUILD="$SRC/mayhem-build"
mkdir -p "$SANBUILD"
(
  cd "$SANBUILD"
  env CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" CXXFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
    "$SRC/configure" --enable-shared=no --enable-static=yes
  env CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" CXXFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" make -j"$MAYHEM_JOBS"
)

# libunwind's local-unwind harness needs the per-arch lib + the generic lib (as OSS-Fuzz links).
ARCH_LIB="$(ls "$SANBUILD"/src/.libs/libunwind-*.a 2>/dev/null | grep -vE 'libunwind-(coredump|ptrace|setjmp|generic)\.a' | head -1)"
GEN_LIB="$SANBUILD/src/.libs/libunwind.a"
[ -f "$ARCH_LIB" ] || { echo "ERROR: per-arch libunwind static lib not found" >&2; ls -la "$SANBUILD"/src/.libs/ >&2; exit 1; }
echo "linking against: $ARCH_LIB $GEN_LIB"

# Generated public headers (libunwind.h, libunwind-x86_64.h, ...) land in the VPATH build's
# include/ dir; the source include/ has the .in templates and tdep headers.
INC="-I$SANBUILD/include -I$SRC/include"

# ── 2) Build the harness: libFuzzer target (-> $OUT/fuzz_libunwind) + standalone reproducer ───────
# libFuzzer target
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE $INC -c "$HARNESS_DIR/fuzz_libunwind.c" \
    -o "$SRC/mayhem-fuzz_libunwind.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$SRC/mayhem-fuzz_libunwind.o" \
    "$ARCH_LIB" "$GEN_LIB" -lpthread \
    -o "$OUT/fuzz_libunwind"

# standalone reproducer (no libFuzzer runtime, reads one file) -> $OUT/fuzz_libunwind-standalone
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $INC -c "$HARNESS_DIR/fuzz_libunwind.c" \
    -o "$SRC/mayhem-fuzz_libunwind-sa.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$HARNESS_DIR/standalone_main.c" -o "$SRC/mayhem-standalone_main.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS "$SRC/mayhem-fuzz_libunwind-sa.o" "$SRC/mayhem-standalone_main.o" \
    "$ARCH_LIB" "$GEN_LIB" -lpthread \
    -o "$OUT/fuzz_libunwind-standalone"

echo "built fuzz_libunwind (+ standalone)"

# ── 3) Build libunwind's OWN test suite with NORMAL flags in a SEPARATE tree so test.sh only RUNS
#       it. Normal flags (no sanitizers) keep test.sh an honest PATCH oracle and avoid benign-UB /
#       leak noise in the test harnesses. The configure/make here build the check_PROGRAMS. ───────
TESTBUILD="$SRC/mayhem-tests"
mkdir -p "$TESTBUILD"
(
  cd "$TESTBUILD"
  env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
    "$SRC/configure" --enable-shared=no --enable-static=yes
  env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS make -j"$MAYHEM_JOBS"
  # Build the test programs (compile-only; test.sh runs the curated self-contained subset).
  env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS make -j"$MAYHEM_JOBS" check_PROGRAMS -C tests || \
  env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS make -j"$MAYHEM_JOBS" -C tests check_PROGRAMS || true
)
echo "built libunwind test tree in $TESTBUILD"

echo "build.sh complete:"
ls -la "$OUT/fuzz_libunwind" "$OUT/fuzz_libunwind-standalone" 2>&1 || true
