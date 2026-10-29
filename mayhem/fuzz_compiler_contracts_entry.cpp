#include <cstddef>
#include <cstdint>
#include <stdexcept>

extern "C" int MgUpstreamContractsOneInput(uint8_t const *data, std::size_t size);

// PatternsCompiler documents std::overflow_error ("Pattern too complex") for oversized patterns
// (planner/test/unittest__vm_compiler.cpp expects it); fuzz_pattern_vm catches it the same way.
extern "C" int LLVMFuzzerTestOneInput(uint8_t const *data, std::size_t size) {
  try {
    return MgUpstreamContractsOneInput(data, size);
  } catch (std::overflow_error const &) {
    return -1;
  }
}
