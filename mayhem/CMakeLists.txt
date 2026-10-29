# Mayhem build of the memgraph pieces that carry in-tree fuzz harnesses (planner e-graph/pattern VM and the CSV
# reader) plus the upstream gtest suites for the same code. Upstream's own build needs conan + a full toolchain;
# this project compiles just the sources those harnesses reach, offline, against apt packages and the pinned
# header-only deps under MG_DEPS.
#
# MG_MODE: fuzz       libFuzzer harnesses  -> ${MG_OUT}/<name>
#          standalone run-once reproducers -> ${MG_OUT}/<name>-standalone
#          test       upstream gtest binaries -> ${MG_OUT}/<name>
cmake_minimum_required(VERSION 3.28)
project(memgraph_mayhem LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_SCAN_FOR_MODULES ON)

set(MG_SRC "${CMAKE_CURRENT_SOURCE_DIR}/.." CACHE PATH "memgraph source root")
get_filename_component(MG_SRC "${MG_SRC}" ABSOLUTE)
set(MG_MODE "fuzz" CACHE STRING "fuzz | standalone | test")
set(MG_OUT "${CMAKE_BINARY_DIR}/bin" CACHE PATH "where the executables go")
set(MG_DEPS "/opt/toolchains/deps" CACHE PATH "pinned header-only deps (fmt, spdlog, strong_type)")
set(FUZZ_ENGINE "-fsanitize=fuzzer" CACHE STRING "link item providing main() for the fuzzer binaries")
set(STANDALONE_MAIN_OBJ "" CACHE FILEPATH "object with the run-once driver main()")
set(LSAN_OFF_OBJ "" CACHE FILEPATH "object defining __lsan_is_turned_off()")
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${MG_OUT}")

find_package(Boost REQUIRED COMPONENTS iostreams)
find_package(absl REQUIRED)
find_package(range-v3 REQUIRED)
find_package(gflags REQUIRED)
find_package(CURL REQUIRED)
find_package(ctre REQUIRED)
find_package(nlohmann_json REQUIRED)

# `<ranges>` in libstdc++-14 does not pull in <algorithm>; egraph.cppm uses std::ranges::sort.
include_directories(SYSTEM "${CMAKE_CURRENT_SOURCE_DIR}/shim")

add_library(strong_type INTERFACE)
target_include_directories(strong_type SYSTEM INTERFACE "${MG_DEPS}/strong_type/include")
add_library(fmt::fmt INTERFACE IMPORTED)
target_include_directories(fmt::fmt SYSTEM INTERFACE "${MG_DEPS}/fmt/include")
target_compile_definitions(fmt::fmt INTERFACE FMT_HEADER_ONLY=1)
add_library(spdlog::spdlog INTERFACE IMPORTED)
target_include_directories(spdlog::spdlog SYSTEM INTERFACE "${MG_DEPS}/spdlog/include")
target_compile_definitions(spdlog::spdlog INTERFACE SPDLOG_HEADER_ONLY=1 SPDLOG_FMT_EXTERNAL=1)

# ---- planner -------------------------------------------------------------------------------------------------
set(P "${MG_SRC}/src/planner")
add_library(mg-planner STATIC)
target_sources(mg-planner
  PUBLIC FILE_SET CXX_MODULES BASE_DIRS ${P} FILES
    ${P}/strong_type.cppm ${P}/concepts.cppm ${P}/constants.cppm ${P}/eids.cppm ${P}/union_find.cppm
    ${P}/enode.cppm ${P}/eclass.cppm ${P}/egraph.cppm ${P}/typed_egraph.cppm
  PRIVATE
    ${P}/src/egraph/eclass.cpp ${P}/src/egraph/egraph.cpp ${P}/src/egraph/enode.cpp
    ${P}/src/pattern/match.cpp ${P}/src/pattern/match_index.cpp ${P}/src/pattern/match_storage.cpp
    ${P}/src/pattern/pattern.cpp ${P}/src/pattern/types.cpp
    ${P}/src/pattern/vm/compiled_matcher.cpp ${P}/src/pattern/vm/compiler.cpp ${P}/src/pattern/vm/executor.cpp
    ${P}/src/pattern/vm/instruction.cpp ${P}/src/pattern/vm/state.cpp ${P}/src/pattern/vm/tracer.cpp
    ${P}/src/pattern/vm/types.cpp
    ${P}/src/rewrite/rewriter.cpp ${P}/src/rewrite/rule.cpp ${P}/src/rewrite/rule_context.cpp
    ${P}/src/rewrite/rule_set.cpp)
target_include_directories(mg-planner PUBLIC "${P}/include" "${MG_SRC}/src")
target_link_libraries(mg-planner PUBLIC absl::flat_hash_map range-v3::range-v3 strong_type fmt::fmt Boost::headers)

# ---- CSV reader ----------------------------------------------------------------------------------------------
set(U "${MG_SRC}/src/utils")
add_library(mg-fnv STATIC)
target_sources(mg-fnv PUBLIC FILE_SET CXX_MODULES BASE_DIRS ${U} FILES ${U}/fnv.cppm)

add_library(mg-utils-min STATIC ${U}/memory.cpp ${U}/string.cpp ${U}/logging.cpp ${MG_SRC}/src/requests/requests.cpp)
target_include_directories(mg-utils-min PUBLIC "${MG_SRC}/src")
target_link_libraries(mg-utils-min PUBLIC mg-fnv fmt::fmt spdlog::spdlog gflags Boost::headers strong_type
                      nlohmann_json::nlohmann_json ctre::ctre CURL::libcurl)
target_compile_definitions(mg-utils-min PUBLIC USE_JEMALLOC=0)

# The real memgraph.utils.aws module wraps the AWS SDK, which is not available offline. The CSV harness never
# reaches S3, so a stub module with the same exported names stands in for it.
set(C "${MG_SRC}/src/csv")
add_library(mg-csv STATIC)
target_sources(mg-csv
  PUBLIC FILE_SET CXX_MODULES BASE_DIRS ${C}/include ${CMAKE_CURRENT_SOURCE_DIR}/stubs FILES
    ${C}/include/csv/parsing.cppm ${CMAKE_CURRENT_SOURCE_DIR}/stubs/aws_stub.cppm
  PRIVATE ${C}/parsing.cpp)
target_link_libraries(mg-csv PUBLIC mg-utils-min Boost::iostreams)

# ---- executables ---------------------------------------------------------------------------------------------
function(mg_fuzz name lib)
  if(MG_MODE STREQUAL "fuzz")
    add_executable(${name} ${ARGN})
    target_link_libraries(${name} PRIVATE ${lib} ${LSAN_OFF_OBJ} ${FUZZ_ENGINE})
  elseif(MG_MODE STREQUAL "standalone")
    add_executable(${name}-standalone ${ARGN})
    target_link_libraries(${name}-standalone PRIVATE ${lib} ${LSAN_OFF_OBJ} ${STANDALONE_MAIN_OBJ})
  endif()
endfunction()

if(MG_MODE STREQUAL "test")
  find_package(GTest REQUIRED)
  set(T "${P}/test")
  add_executable(planner_core_tests
    ${T}/unittest__union_find.cpp ${T}/unittest__enode.cpp ${T}/unittest__egraph.cpp
    ${T}/unittest__typed_egraph.cpp ${T}/unittest__extractor.cpp ${T}/unittest__pattern.cpp
    ${T}/unittest__match_arena.cpp ${T}/unittest__vm_matching.cpp ${T}/unittest__rewrite.cpp
    ${T}/unittest__vm_trace.cpp ${T}/unittest__vm_state.cpp ${P}/test_support/instantiations.cpp)
  target_include_directories(planner_core_tests PRIVATE ${T} ${P})
  target_link_libraries(planner_core_tests PRIVATE mg-planner mg-utils-min GTest::gtest GTest::gtest_main)

  add_executable(csv_parsing_tests ${MG_SRC}/tests/unit/csv_csv_parsing.cpp)
  target_link_libraries(csv_parsing_tests PRIVATE mg-csv GTest::gtest GTest::gtest_main)
else()
  mg_fuzz(fuzz_csv mg-csv ${C}/fuzz/fuzz_reader.cpp)
  foreach(t fuzz_egraph fuzz_pattern_vm)
    mg_fuzz(${t} mg-planner ${P}/fuzz/${t}.cpp)
  endforeach()
  # fuzz_compiler_contracts lets the documented std::overflow_error ("pattern too complex") escape; the wrapper
  # TU owns LLVMFuzzerTestOneInput, runs the upstream entry point and rejects those inputs with -1.
  mg_fuzz(fuzz_compiler_contracts mg-planner ${CMAKE_CURRENT_SOURCE_DIR}/fuzz_compiler_contracts_entry.cpp
          ${P}/fuzz/fuzz_compiler_contracts.cpp)
  set_source_files_properties(${P}/fuzz/fuzz_compiler_contracts.cpp PROPERTIES
    COMPILE_DEFINITIONS "LLVMFuzzerTestOneInput=MgUpstreamContractsOneInput")
  foreach(t fuzz_egraph fuzz_pattern_vm fuzz_compiler_contracts)
    foreach(v ${t} ${t}-standalone)
      if(TARGET ${v})
        target_compile_definitions(${v} PRIVATE ASSERT_FUZZ)
      endif()
    endforeach()
  endforeach()
endif()
