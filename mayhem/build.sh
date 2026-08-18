#!/usr/bin/env bash
#
# patternlanguage/mayhem/build.sh -- build two libFuzzer harnesses over the PatternLanguage
# (ImHex's `.hexpat` DSL) lexer/parser/validator/EVALUATOR (+ standalone reproducers), AND
# upstream's own test suite (pattern_language_tests via ctest + the plcli CLI integration
# test) for mayhem/test.sh.
#
#   fuzz_pattern -- fuzzes the pattern SOURCE (the untrusted `.hexpat` text), evaluated
#                   against a small FIXED in-memory data buffer. Ports upstream's own
#                   fuzz/source/main.cpp driver to libFuzzer and runs the FULL pipeline
#                   (preprocess/lex/parse/validate/evaluate), not just parseString.
#   fuzz_data    -- the mirror image: a FIXED, known-good pattern (a header + a
#                   count-prefixed array of structs) evaluated over FUZZER-CONTROLLED data,
#                   exercising the evaluator's bounds handling against hostile bytes.
#
# See mayhem/harnesses/{fuzz_pattern,fuzz_data}.cpp for the harness/bounding rationale (SPEC §6b:
# the harnesses arm no timer; a pattern-source-controlled `#pragma loop_limit 0` hang is left
# to libFuzzer's -timeout / Mayhem's per-test timeout and recorded as a finding).
#
# THREE separate CMake build trees (a Ninja/ExternalProject-quality reason to keep them
# apart, not a workaround): the FUZZ tree links PatternLanguage's `libpl`/`libpl-gen`
# OBJECT-library targets with $SANITIZER_FLAGS+$DEBUG_FLAGS via a small wrapper project we
# own (mayhem/harnesses/CMakeLists.txt) that add_subdirectory()s the upstream tree --
# libpl is an OBJECT library (LIBPL_SHARED_LIBRARY=OFF, upstream's own default), so this is
# the natural way to reuse it outside upstream's own CMakeLists.txt without ever editing it.
# The FUZZ tree builds all four executables (fuzz_pattern/fuzz_data + their *-standalone
# siblings) in one configure, since both flavors share the identically-sanitized libpl
# objects and differ only in their final link step. The ORACLE tree is upstream's OWN
# CMakeLists.txt (LIBPL_ENABLE_TESTS=ON, LIBPL_ENABLE_CLI=ON), built with the project's
# NORMAL flags -- exactly what .github/workflows/tests.yml itself does
# (`ninja unit_tests && ninja plcli`, then `ctest` + `python tests/integration/integration.py`)
# -- so it stays an honest, non-triage functional oracle.
#
# `-fsanitize=fuzzer-no-link` is appended to $SANITIZER_FLAGS UNCONDITIONALLY (independent of
# whether the caller passed a non-default value, including an explicit empty
# `--build-arg SANITIZER_FLAGS=`) so libpl's SanitizerCoverage instrumentation is always
# present -- otherwise Mayhem would see 0 edges from the parser/evaluator despite the harness
# translation unit itself being instrumented via $LIB_FUZZING_ENGINE at the final link.
#
# Submodules (external/{fmt,cli11,libwolv,throwing_ptr}, +libwolv's own jthread submodule)
# and the vendored (non-submodule) external/nlohmann_json are the FULL dependency closure --
# no FetchContent/ExternalProject network fetch anywhere in the CMake tree itself (verified:
# cli11's own `FetchContent_Declare` calls live only under its tests/examples subdirectories,
# which are never added -- CLI11_BUILD_TESTS/EXAMPLES default OFF when included as a
# non-top-level project, which is how PatternLanguage's CMakeLists.txt includes it).
# mayhem.yml's checkout step sets `submodules: recursive`, so the normal commit-image build
# context already has everything; the one place this build.sh itself touches the network is
# the submodule fallback fetch just below (ONLINE-only, mirroring podofo's build.sh), which
# only fires when the build context lacks submodule content in the first place -- see there
# for why that path exists and why it never runs at the air-gapped PATCH re-run.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) -- must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
case "$SANITIZER_FLAGS" in
  *fuzzer-no-link*) ;;  # already present
  *) SANITIZER_FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link" ;;
esac
# DWARF <= 3 (SPEC 6.2 item 10): clang-19's plain -g emits DWARF-5; be explicit.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS:=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE STANDALONE_FUZZ_MAIN MAYHEM_JOBS
: "${SRC:=/mayhem}"
cd "$SRC"

# The submodule closure (external/{fmt,cli11,libwolv,throwing_ptr}, +libwolv's own nested
# jthread submodule) must be present before configuring. mayhem.yml's checkout already sets
# `submodules: recursive`, so the normal commit-image build never needs this -- but
# verify-repo.sh's CI-parity check builds from a PLAIN `git clone` of HEAD (gitlinks only, no
# submodule content; see docs/netnew-worker-prompt.md and PORTING.md field notes on
# CI-parity/connectedhomeip), and a future `git submodule update` misconfiguration anywhere
# upstream of this build.sh shouldn't be a hard, confusing failure. Fetch them here if
# missing (exactly like podofo/mayhem/build.sh does for its own extern/resources submodule):
# this only ever runs ONLINE (this build step, not the later air-gapped re-run -- once
# fetched, the content is baked into the image layer, so `docker run --network none ...`
# finds it already present and never reaches this branch).
if [ ! -d external/fmt/include ] || [ -z "$(ls -A external/fmt/include 2>/dev/null)" ]; then
  echo "submodules not populated -- fetching them once (online build only) ..."
  git submodule update --init --recursive
fi
for sub in external/fmt/include external/cli11/include external/libwolv/libs/types/include external/throwing_ptr/include; do
  [ -d "$sub" ] && [ -n "$(ls -A "$sub" 2>/dev/null)" ] || { echo "FATAL: $sub is still empty after 'git submodule update --init --recursive'" >&2; exit 1; }
done

BUILD_ROOT="$SRC/mayhem-build"
mkdir -p "$BUILD_ROOT"
printf "*\n" > "$BUILD_ROOT/.gitignore"   # build tree ignores itself (the mirror .gitignore is off-limits)

# ── 1) FUZZ tree: fuzz_pattern/fuzz_data + their *-standalone siblings, all against a
#       sanitized+DWARF-3 libpl/libpl-gen (via mayhem/harnesses/CMakeLists.txt). ──────────────
FUZZ_BUILD="$BUILD_ROOT/fuzz"
cmake -S "$SRC/mayhem/harnesses" -B "$FUZZ_BUILD" \
  -G Ninja \
  -DCMAKE_C_COMPILER="$CC" \
  -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
  -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
  -DPL_ROOT="$SRC" \
  -DMAYHEM_FUZZER_LINK_FLAGS="$LIB_FUZZING_ENGINE" \
  -DMAYHEM_LSAN_OFF_SRC="$SRC/mayhem/harnesses/lsan_off.cc" \
  -DSTANDALONE_FUZZ_MAIN="$STANDALONE_FUZZ_MAIN"
cmake --build "$FUZZ_BUILD" -j"$MAYHEM_JOBS" \
  --target fuzz_pattern fuzz_data fuzz_pattern-standalone fuzz_data-standalone

for bin in fuzz_pattern fuzz_data fuzz_pattern-standalone fuzz_data-standalone; do
  found="$FUZZ_BUILD/bin/$bin"
  [ -x "$found" ] || { echo "FATAL: expected fuzz binary not built: $found" >&2; exit 1; }
  install -m 0755 "$found" "/mayhem/$bin"
done
echo "built fuzz_pattern, fuzz_data (+ standalone siblings)"

# ── 2) ORACLE tree: upstream's OWN CMakeLists.txt, NORMAL flags, LIBPL_ENABLE_TESTS +
#       LIBPL_ENABLE_CLI ON -- exactly what .github/workflows/tests.yml itself builds
#       (`ninja unit_tests && ninja plcli`). A SEPARATE build dir, so this coexists with the
#       FUZZ tree above with no make-clean/stash dance needed. ────────────────────────────────
ORACLE_BUILD="$BUILD_ROOT/oracle"
cmake -S "$SRC" -B "$ORACLE_BUILD" \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_RUNTIME_OUTPUT_DIRECTORY="$ORACLE_BUILD/bin" \
  -DLIBPL_ENABLE_TESTS=ON \
  -DLIBPL_ENABLE_CLI=ON \
  -DLIBPL_BUILD_CLI_AS_EXECUTABLE=ON \
  ${COVERAGE_FLAGS:+-DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"}
cmake --build "$ORACLE_BUILD" -j"$MAYHEM_JOBS" --target unit_tests plcli

TEST_BIN="$ORACLE_BUILD/bin/pattern_language_tests"
CLI_BIN="$ORACLE_BUILD/bin/plcli"
[ -x "$TEST_BIN" ] || { echo "FATAL: $TEST_BIN was not produced by 'cmake --build --target unit_tests'" >&2; exit 1; }
[ -x "$CLI_BIN" ]  || { echo "FATAL: $CLI_BIN was not produced by 'cmake --build --target plcli'" >&2; exit 1; }

# Both MUST be dynamically linked so verify-repo's LD_PRELOAD sabotage shim can neuter them --
# a statically-linked oracle binary would survive sabotage and make mayhem/test.sh a
# reward-hackable oracle (SPEC 6.3). Plain clang/clang++ links dynamically by default; assert
# it so a toolchain change can't silently flip this.
for bin in "$TEST_BIN" "$CLI_BIN"; do
  if ! file "$bin" | grep -q 'dynamically linked'; then
    echo "FATAL: $bin is not dynamically linked -- the sabotage check could not neuter it" >&2
    file "$bin" >&2
    exit 1
  fi
done
echo "built pattern_language_tests + plcli (dynamically linked oracle binaries) at $ORACLE_BUILD/bin"

echo "build.sh complete:"
ls -la /mayhem/fuzz_pattern /mayhem/fuzz_data \
       /mayhem/fuzz_pattern-standalone /mayhem/fuzz_data-standalone \
       "$TEST_BIN" "$CLI_BIN" 2>&1 || true
