// mayhem/harnesses/fuzz_pattern.cpp -- fuzz the pattern-language SOURCE.
//
// A port of upstream's own AFL-style driver (fuzz/source/main.cpp: read a file, call
// pl::PatternLanguage::parseString on its contents) to libFuzzer, extended to run the FULL
// pipeline (preprocess/lex/parse/validate/EVALUATE) against a small, FIXED, in-memory data
// buffer -- not just parse -- so the evaluator (the interpreter proper: array/struct/loop
// handling, arithmetic, std:: builtin functions) gets fuzzed too, not only the lexer/parser.
//
// The fuzzer input IS the untrusted `.hexpat` pattern source. The "binary being analyzed" is
// a small fixed buffer (bytes 0x00..0xFF repeating, same idea as example/source/main.cpp's
// sample data) -- ambient data the pattern can read via `@ address`, but not itself
// attacker-controlled (see fuzz_data.cpp for the complementary target that fuzzes the DATA
// side instead).
//
// Bounding (SPEC 6b): dangerous
// functions (std::file::*) stay DENIED by construction -- PatternLanguage only disables that
// deny-by-default when you call setDangerousFunctionCallHandler(), which this harness never
// does (lib/include/pl/pattern_language.hpp: "If the callback is not set, dangerous functions
// are disabled"). setIncludePaths() is likewise never called, so `#include "..."` can never
// resolve to a real filesystem path (core/resolvers.cpp: FileResolver::resolve() only ever
// checks paths under m_includePaths, which stays empty) -- the harness does no file I/O of
// its own and the library can't be made to do any either. The evaluator's own
// depth/array/pattern/loop limits apply via their library defaults. The harness arms no timer:
// a pattern that turns those limits off with `#pragma loop_limit 0` and then loops is a hang
// finding, bounded by libFuzzer's -timeout / Mayhem's per-test timeout (see
// mayhem/fuzz_pattern/known-findings/pragma-defeats-loop-limit/).
#include <pl/pattern_language.hpp>

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>

namespace {

    constexpr size_t kMaxInputSize = 256 * 1024;
    constexpr size_t kFixedDataSize = 0x100;

    const std::array<pl::u8, kFixedDataSize> &fixedData() {
        static const auto data = [] {
            std::array<pl::u8, kFixedDataSize> buf{};
            for (size_t i = 0; i < buf.size(); i++)
                buf[i] = static_cast<pl::u8>(i);
            return buf;
        }();
        return data;
    }

}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size == 0 || size > kMaxInputSize)
        return 0;

    std::string source(reinterpret_cast<const char *>(data), size);

    try {
        pl::PatternLanguage runtime;

        const auto &fixed = fixedData();
        runtime.setDataSource(0x00, fixed.size(), [&fixed](pl::u64 address, pl::u8 *outBuffer, size_t sz) {
            // Defensive clamp: the library is expected to keep reads within the declared
            // data size on its own (that bounds-checking logic is itself part of what's
            // being fuzzed), but the harness must not overread its own fixed buffer no
            // matter what the library does.
            if (address >= fixed.size()) {
                std::memset(outBuffer, 0, sz);
                return;
            }
            size_t avail = fixed.size() - static_cast<size_t>(address);
            size_t toCopy = std::min(sz, avail);
            std::memcpy(outBuffer, fixed.data() + address, toCopy);
            if (toCopy < sz)
                std::memset(outBuffer + toCopy, 0, sz - toCopy);
        });

        // No setDangerousFunctionCallHandler() call -- dangerous functions (std::file::*)
        // stay denied. No setIncludePaths() call -- #include can't resolve to any real file.
        (void)runtime.executeString(source, "fuzz_pattern");
    }
    catch (const std::exception &) {
        // Compile/eval errors on a mostly-malformed corpus are the expected outcome, not a
        // finding. Sanitizer aborts (ASan/UBSan) never unwind as a C++ exception, so real
        // memory-safety/UB findings still surface.
    }

    return 0;
}
