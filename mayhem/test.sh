#!/usr/bin/env bash
#
# mayhem/test.sh — RUN memgraph's OWN gtest suites for the code the fuzz targets cover (planner core and the
# CSV reader; built by mayhem/build.sh with normal flags).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
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


BIN="$SRC/mayhem/build-test/bin"
passed=0; failed=0; skipped=0

# Each gtest binary must print its own summary: a program that exits 0 without running the tests (or a missing
# runner) yields no "ran." line and is counted as a failure rather than a pass.
run_suite() {
  local exe="$BIN/$1" out ran p f s
  if [ ! -x "$exe" ]; then echo "missing test runner $exe (mayhem/build.sh should have built it)" >&2; failed=$((failed + 1)); return; fi
  out="$("$exe" --gtest_color=no 2>&1)"; local rc=$?
  printf '%s\n' "$out" | tail -n 25
  ran="$(printf '%s\n' "$out" | sed -n 's/^\[==========\] \([0-9]\+\) tests\? from .* ran\..*/\1/p' | tail -n1)"
  if [ -z "$ran" ] || [ "$ran" -lt "$2" ]; then
    echo "$1: expected at least $2 tests, summary reports '${ran:-none}'" >&2; failed=$((failed + 1)); return
  fi
  p="$(printf '%s\n' "$out" | sed -n 's/^\[  PASSED  \] \([0-9]\+\) tests\?\./\1/p' | tail -n1)"
  s="$(printf '%s\n' "$out" | sed -n 's/^\[  SKIPPED \] \([0-9]\+\) tests\?, listed below:/\1/p' | tail -n1)"
  f="$(printf '%s\n' "$out" | sed -n 's/^\[  FAILED  \] \([0-9]\+\) tests\?, listed below:/\1/p' | tail -n1)"
  passed=$((passed + ${p:-0})); skipped=$((skipped + ${s:-0})); failed=$((failed + ${f:-0}))
  if [ "$rc" -ne 0 ] && [ -z "$f" ]; then failed=$((failed + 1)); fi
}

run_suite planner_core_tests 200
run_suite csv_parsing_tests 30

emit_ctrf "gtest" "$passed" "$failed" "$skipped"
