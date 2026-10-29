#!/usr/bin/env bash
#
# mayhem/build.sh — builds the memgraph fuzz harnesses (planner e-graph / pattern VM / compiler contracts, CSV
# reader), their run-once reproducers and the upstream gtest suites for the same code.
#
# Memgraph's own build needs conan, a full C++23-modules toolchain and ~hundreds of packages, so this builds only
# the sources the harnesses reach through mayhem/CMakeLists.txt. Everything resolves offline from the image:
# clang-22 and the -dev packages (mayhem/Dockerfile, apt) and the pinned header-only fmt/spdlog/strong_type under
# /opt/toolchains/deps. clang-22 is needed because the sources are C++23 modules (.cppm), and clang-19 fails on
# libstdc++'s <ranges> module-scan.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MG_DEPS:=/opt/toolchains/deps}"
export SANITIZER_FLAGS DEBUG_FLAGS LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

# The base's clang is 19; the C++23 modules need 22 (by name, via PATH).
CC=clang-22
CXX=clang++-22
export CC CXX

SRC="${SRC:-/mayhem}"
cd "$SRC"
M="$SRC/mayhem"

# Abseil's raw_hash_set trips a UBSan false positive in its own sanitizer-build debug checks; NDEBUG_SANITIZER
# switches those checks off (ASan/UBSan stay on for the fuzzed code).
FLAGS_COMMON=(-O1 -DNDEBUG_SANITIZER)
CMAKE_COMMON=(-G Ninja -DCMAKE_BUILD_TYPE= -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX"
              -DCMAKE_CXX_COMPILER_CLANG_SCAN_DEPS=clang-scan-deps-22
              -DMG_SRC="$SRC" -DMG_DEPS="$MG_DEPS")

# 1) libFuzzer harnesses. The whole build (library + harness) carries -fsanitize=fuzzer-no-link so the fuzzed
#    code reports coverage; only the final link adds the libFuzzer runtime.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$M/lsan_off.cc" -o "$M/build-lsan_off.o"
cmake -S "$M" -B "$M/build-fuzz" "${CMAKE_COMMON[@]}" -DMG_MODE=fuzz -DMG_OUT="$SRC" \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS ${FLAGS_COMMON[*]} -fsanitize=fuzzer-no-link" \
  -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS ${FLAGS_COMMON[*]} -fsanitize=fuzzer-no-link" \
  -DFUZZ_ENGINE="$LIB_FUZZING_ENGINE" -DLSAN_OFF_OBJ="$M/build-lsan_off.o"
cmake --build "$M/build-fuzz" -j"$MAYHEM_JOBS"

# 2) run-once reproducers: same code, no coverage instrumentation, linked against the standalone driver (compiled
#    as C so its LLVMFuzzerTestOneInput reference keeps C linkage).
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$M/build-standalone_main.o"
cmake -S "$M" -B "$M/build-standalone" "${CMAKE_COMMON[@]}" -DMG_MODE=standalone -DMG_OUT="$SRC" \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS ${FLAGS_COMMON[*]}" \
  -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS ${FLAGS_COMMON[*]}" \
  -DSTANDALONE_MAIN_OBJ="$M/build-standalone_main.o" -DLSAN_OFF_OBJ="$M/build-lsan_off.o"
cmake --build "$M/build-standalone" -j"$MAYHEM_JOBS"

# 3) upstream gtest suites (planner core + CSV reader) with normal flags: no sanitizers.
cmake -S "$M" -B "$M/build-test" "${CMAKE_COMMON[@]}" -DMG_MODE=test -DMG_OUT="$M/build-test/bin" \
  -DCMAKE_C_FLAGS="-O1 $COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="-O1 $COVERAGE_FLAGS"
cmake --build "$M/build-test" -j"$MAYHEM_JOBS"
