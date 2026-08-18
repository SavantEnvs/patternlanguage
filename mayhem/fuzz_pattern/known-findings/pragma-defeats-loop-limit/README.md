# Finding: `#pragma loop_limit 0` (or `array_limit`/`pattern_limit`/`eval_depth`) disables the
# evaluator's own hang guard from INSIDE the fuzzed pattern source

**Cause.** `PatternLanguage::reset()` (`lib/source/pl/pattern_language.cpp:515-518`) sets four
default evaluator bounds on every run: evaluation depth (32), array element count (0x10000),
total pattern count (0x100000), and while-loop iteration count (0x1000). Each of these is
ALSO settable from inside the pattern-language SOURCE itself via a preprocessor pragma
(`lib/source/pl/lib/std/pragmas.cpp`: `eval_depth`, `array_limit`, `pattern_limit`,
`loop_limit`), through a shared `parseLimit()` helper:

```cpp
std::optional<u64> parseLimit(const std::string &value) {
    ...
    auto limit = std::stoull(value, &index, 0);
    ...
    if (limit == 0)
        return std::numeric_limits<u64>::max();   // <-- "0" means UNLIMITED
    else
        return limit;
}
```

A pattern containing `#pragma loop_limit 0` sets the loop-iteration cap to
`UINT64_MAX` -- effectively unlimited -- before its own `while(true) {}` runs. This is
architecturally the same class of bug as `goja`'s `Runtime.Interrupt()` finding (see
docs/netnew-worker-prompt.md §6b): a language-level execution bound that looks authoritative,
but that untrusted input can simply turn off from the inside.

**Impact.** Any embedder that runs untrusted `.hexpat` patterns and relies on the library's
default loop/array/pattern/depth limits as its ONLY execution-time bound (rather than an
external, input-independent watchdog) is exposed to an unbounded hang from a two-line pattern
-- no dangerous functions, no large data source, nothing beyond ordinary preprocessor/loop
syntax.

**Reproducer** (`repro.hexpat`, this directory -- kept OUT of `testsuite/`: a hang seed would
stall every future Mayhem run, see docs/netnew-worker-prompt.md §6b):

```
#pragma loop_limit 0
while(true) {}
```

The harness arms no timer, so this input never returns on its own; libFuzzer's `-timeout` (or
Mayhem's per-test timeout) ends it and reports a timeout finding.

Without `#pragma loop_limit 0`, the same `while(true) {}` body returns in ~0.05s (rejected by
the library's own default loop_limit=0x1000 via `err::E0007` in
`lib/source/pl/core/ast/ast_node_while_statement.cpp:56-57`) -- confirming the pragma, not the
loop itself, is what defeats the guard.

**Upstream fix sketch.** Either (a) document prominently that `eval_depth`/`array_limit`/
`pattern_limit`/`loop_limit` are attacker-controllable from inside the very source being
bounded, and are therefore NOT a substitute for an external, input-independent execution-time
limit; or (b) let the EMBEDDER clamp an upper ceiling on what these pragmas can raise a limit
to (e.g. `PatternLanguage::setMaximumLoopLimitCeiling(...)`), so a hostile pattern can lower
its own risk tolerance but never disable the host's.

**Why this is not guarded away in the harness.** Per SPEC §6b a hang is a finding, not
something to mask: the harness arms no timer, installs no signal handler and filters no input.
Disabling pragma parsing would lose real coverage of that code path, and the precondition is
not narrow (any of four pragmas, each accepting attacker-chosen values). Execution time is
bounded by libFuzzer's `-timeout` / Mayhem's per-test timeout.
