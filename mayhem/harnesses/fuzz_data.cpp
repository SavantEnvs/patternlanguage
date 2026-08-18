// mayhem/harnesses/fuzz_data.cpp -- fuzz the DATA a pattern is evaluated over.
//
// The mirror image of fuzz_pattern.cpp: here the pattern SOURCE is FIXED (a small, known-good
// `.hexpat` program compiled into the harness) and the fuzzer bytes become the "binary being
// analyzed" -- exactly the role `std::io::read*`/`@ address` reads play for a real hex editor
// user pointing the pattern language at an arbitrary file. This exercises the evaluator's
// bounds handling (declared-length arrays overrunning the data, struct field reads walking
// off the end, arithmetic on attacker-controlled field values used as sizes/offsets) rather
// than the parser -- a distinct code path from fuzz_pattern's parser/preprocessor focus.
//
// The fixed pattern below deliberately uses an attacker-controlled `count` field (read
// straight from the fuzzed bytes) to size a following array of structs, so a hostile buffer
// can drive the array-bounds-check path (evaluator->getArrayLimit() / "array expanded past
// end of data", ast_node_array_variable_decl.cpp) on every input, in addition to plain
// out-of-range field reads.
//
// Bounding: same as fuzz_pattern.cpp -- dangerous functions stay denied
// (no setDangerousFunctionCallHandler call), no setIncludePaths call, and the harness arms no
// timer (execution time is bounded by libFuzzer's -timeout / Mayhem's per-test timeout).
#include <pl/pattern_language.hpp>

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>

namespace {

    constexpr size_t kMaxInputSize = 1024 * 1024;

    // Fixed, known-good pattern: a header (magic/count/flags) followed by `count` fixed-size
    // entries. `count` comes straight from the fuzzed bytes, so it drives how much of the
    // (also fuzzed) buffer the array-of-structs walk consumes.
    constexpr const char *kFixedPattern = R"pat(
        struct Header {
            char magic[4];
            u32 count;
            u8 flags;
            padding[3];
        };

        struct Entry {
            u16 id;
            float value;
            char name[8];
        };

        Header header @ 0x00;
        Entry entries[header.count] @ sizeof(Header);
    )pat";

}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size == 0 || size > kMaxInputSize)
        return 0;

    try {
        pl::PatternLanguage runtime;

        runtime.setDataSource(0x00, size, [data, size](pl::u64 address, pl::u8 *outBuffer, size_t sz) {
            if (address >= size) {
                std::memset(outBuffer, 0, sz);
                return;
            }
            size_t avail = size - static_cast<size_t>(address);
            size_t toCopy = std::min(sz, avail);
            std::memcpy(outBuffer, data + address, toCopy);
            if (toCopy < sz)
                std::memset(outBuffer + toCopy, 0, sz - toCopy);
        });

        // No setDangerousFunctionCallHandler() call -- dangerous functions (std::file::*)
        // stay denied. No setIncludePaths() call -- the fixed pattern has no #include anyway.
        (void)runtime.executeString(kFixedPattern, "fuzz_data");
    }
    catch (const std::exception &) {
        // Malformed/undersized data rejected by the evaluator (declared array past end of
        // data, etc.) is the expected outcome, not a finding. Sanitizer aborts never unwind
        // as a C++ exception, so real memory-safety/UB findings still surface.
    }

    return 0;
}
