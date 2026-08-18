# Finding: `formatLines()` allocates ~4 GiB when a diagnostic's `Location::column == 0`

**Cause.** `pl::core::err::impl::formatLines()` (`lib/source/pl/core/error.cpp:17-52`)
computes the horizontal offset of the `^^^` underline for a compile-error's source-context
printout as:

```cpp
u32 arrowPosition = location.column - 1;
...
const auto arrowSpacing = std::string(lineNumberPrefix.length() + arrowPosition, ' ');
```

`Location::column` is a `u32` (`lib/include/pl/core/location.hpp:15`), and
`Location::Empty()` (same file, line 18) explicitly constructs a **zero-column** sentinel
Location (`{ nullptr, 0, 0, 0 }`). When such a Location (or any other Location with
`column == 0`) reaches `formatLines()`, `location.column - 1` underflows to `0xFFFFFFFF`
(4294967295). That value then sizes a `std::string(count, ' ')` construction --
`lineNumberPrefix.length() + 4294967295`, observed as `malloc(4294967301)` (~4 GiB) --
with no upper bound check anywhere in between.

**Trigger.** A malformed pattern whose lexer/preprocessor error recovery path produces (or
falls back to) a Location with `column == 0` before `PatternLanguage::executeString()`
formats the resulting `CompileError` (`lib/source/pl/pattern_language.cpp:211`, via
`CompileError::format()` -> `formatCompilerError()` -> `formatLines()`). The reproducer here
is a struct declaration with unbalanced braces and a stray `/**` (an unterminated
block-comment opener directly inside an identifier, `Chil/**dStruct`) that confuses the
lexer's brace/identifier tracking badly enough to produce such a Location during error
reporting. The exact upstream code path that first assigns `column = 0` was not traced
further (not required to fix the allocation-side bug -- see below).

**Impact.** A single malformed `.hexpat` file makes the CLI (or any embedder that calls
`getCompileErrors()`/`CompileError::format()` after a failed parse, which is the ordinary way
to report a syntax error to a user) attempt to allocate/zero-fill ~4 GiB just to print an
error message -- resource exhaustion / DoS from untrusted pattern **source** text, with no
data-provider or evaluation step required at all (a compile-time-only trigger).

**Reproducer.** `repro.hexpat` (this directory), replayed as a normal file argument, NOT a
`testsuite/` seed (a seed here would stall every future run -- see
docs/netnew-worker-prompt.md §6b):

```
$ /mayhem/fuzz_pattern -rss_limit_mb=512 -timeout=5 repro.hexpat
==...== ERROR: libFuzzer: out-of-memory (malloc(4294967301))
    ...
    #15 pl::core::err::impl::formatLines[abi:cxx11](pl::core::Location) lib/source/pl/core/error.cpp:49
    #16 pl::core::err::impl::formatCompilerError(...) lib/source/pl/core/error.cpp:108
    #17 pl::core::err::CompileError::format() lib/include/pl/core/errors/error.hpp:124
    #18 pl::PatternLanguage::executeString(...) lib/source/pl/pattern_language.cpp:211
```

`4294967301 == 2^32 + 5`, i.e. `lineNumberPrefix.length()` (a handful of bytes for `"N | "`)
plus the underflowed `arrowPosition == 0xFFFFFFFF` -- confirms `column == 0` reached
`formatLines()` for this input.

Under the `*-standalone` (non-fuzzer) driver the same input does not report as a clean
libFuzzer OOM (no `-rss_limit_mb`/malloc-hook there): the ~4 GiB zero-fill just takes a long
time. Either way, the process does not return promptly with a well-formed diagnostic, which
is itself the bug.

**Upstream fix sketch.** Clamp `arrowPosition` (and `location.length` a few lines below, same
function -- `std::string(location.length, '^')` has the identical unbounded-repeat-count
shape) to the actual `errorLine.length()` before constructing the padding/underline strings,
and/or make `Location::column == 0` an explicit "no column info available" case that skips
the arrow-drawing block entirely instead of feeding it into unsigned arithmetic.

**Why this is not guarded away in the harness.** This is a genuine unbounded-allocation
defect in error-message formatting, not a narrow non-terminating precondition -- masking it
with an input-side guard (e.g. rejecting inputs that produce compile errors) would eliminate
essentially all coverage of the entire error-reporting path, which is itself
attacker-reachable production code. Per the port brief, only genuine *hangs* with a narrow,
documented precondition get guarded in the harness; crashes and OOMs are left for Mayhem to
keep finding.
