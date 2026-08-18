#!/usr/bin/env bash
#
# patternlanguage/mayhem/test.sh -- RUN (never build) PatternLanguage's own suites plus direct
# KAT probes through the `plcli` CLI, and emit a CTRF summary. exit 0 iff nothing failed.
#
# THREE layers; the SECOND and THIRD are the load-bearing ones for anti-reward-hacking
# (SPEC §6.3):
#
#  1) `pattern_language_tests` via ctest (mayhem/build.sh's oracle tree, `unit_tests` target,
#     ~50 AVAILABLE_TESTS entries, real assertions in tests/source/tests.cpp against
#     tests/include/test_patterns/*.hpp). Informational -- like PEGTL's ctest suite (see
#     docs/netnew-worker-prompt.md §4 / checkouts/pegtl/mayhem/test.sh), every one of these is
#     the SAME binary judged purely by ctest's exit code, and the gate's LD_PRELOAD sabotage
#     shim _exit(0)s that binary's constructor before main() runs -- so ctest alone would
#     report a clean pass on a neutered binary. Real coverage, but not sabotage-proof alone.
#
#  2) `plcli`'s own upstream integration test (tests/integration/integration.py), run exactly
#     as .github/workflows/tests.yml itself runs it: `python3 tests/integration/integration.py
#     <plcli>`. This IS sabotage-detecting: plcli is a dynamically linked executable (asserted
#     by build.sh), so the shim neuters IT (not python3, which lives under /usr/bin and is
#     shim-exempt) -- a neutered plcli exits 0 WITHOUT ever writing its --output file.
#     integration.py's `success_run()` only checks the exit code (0, same as a real success),
#     but then unconditionally opens that output file to compare it against the expected JSON
#     -- which raises an uncaught Python exception when the file was never created, crashing
#     integration.py with a non-zero exit and no trailing "Tests successful" line. That is
#     exactly what this script checks for below.
#
#  3) Direct KAT probes against `plcli` itself (SPEC §4: required in addition to an
#     exit-code-only runner) -- fixed pattern + fixed data -> asserted exact values, using the
#     SAME upstream fixtures integration.py uses (tests/integration/test.hexpat /
#     test_data / test.hexpat.json), so a neutered plcli is caught here too, independent of
#     the python script.
#
# This script only RUNS things; mayhem/build.sh did all the building.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

PASSED=0; FAILED=0; SKIPPED=0
ORACLE_BUILD="$SRC/mayhem-build/oracle"
CLI_BIN="$ORACLE_BUILD/bin/plcli"

# ── 1) ctest (informational -- see header). UNCONDITIONAL: a missing build tree is a
#       FAILURE, never a skip -- that is exactly how build.sh dropping the suite would go
#       unnoticed. ─────────────────────────────────────────────────────────────────────────
if [ ! -d "$ORACLE_BUILD" ]; then
  echo "FAIL: $ORACLE_BUILD missing -- mayhem/build.sh did not build the oracle tree" >&2
  FAILED=$(( FAILED + 1 ))
else
  echo "=== running: ctest (pattern_language_tests, $ORACLE_BUILD) ==="
  CTEST_LOG="$SRC/mayhem-build/ctest.log"
  if ( cd "$ORACLE_BUILD" && ctest --output-on-failure -j"$(nproc)" ) >"$CTEST_LOG" 2>&1; then
    ctest_rc=0
  else
    ctest_rc=$?
  fi
  tail -60 "$CTEST_LOG" || true

  summary="$(grep -E '^[0-9]+% tests passed, [0-9]+ tests? failed out of [0-9]+' "$CTEST_LOG" || true)"
  if [ -z "$summary" ]; then
    echo "FAIL: could not parse a ctest summary line -- the suite did not run (rc=$ctest_rc)" >&2
    FAILED=$(( FAILED + 1 ))
  else
    ct_failed="$(printf '%s\n' "$summary" | sed -E 's/^[0-9]+% tests passed, ([0-9]+) tests? failed out of ([0-9]+)$/\1/')"
    ct_total="$(printf '%s\n' "$summary" | sed -E 's/^[0-9]+% tests passed, ([0-9]+) tests? failed out of ([0-9]+)$/\2/')"
    ct_passed=$(( ct_total - ct_failed ))
    echo "ctest: $ct_passed passed, $ct_failed failed, $ct_total total"
    PASSED=$(( PASSED + ct_passed ))
    FAILED=$(( FAILED + ct_failed ))
  fi
fi

# ── 2) plcli's own upstream integration test (sabotage-DETECTING; see header). UNCONDITIONAL:
#       a missing plcli binary is a FAILURE, never a skip. ─────────────────────────────────────
echo "=== running: python3 tests/integration/integration.py $CLI_BIN ==="
if [ ! -x "$CLI_BIN" ]; then
  echo "FAIL: $CLI_BIN missing or not executable" >&2
  FAILED=$(( FAILED + 1 ))
else
  INTEG_OUT="$(python3 tests/integration/integration.py "$CLI_BIN" 2>&1)"; integ_rc=$?
  printf '%s\n' "$INTEG_OUT"
  if [ "$integ_rc" -eq 0 ] && printf '%s\n' "$INTEG_OUT" | grep -qxF "Tests successful"; then
    echo "PASS: plcli integration test"
    PASSED=$(( PASSED + 1 ))
  else
    echo "FAIL: plcli integration test -- rc=$integ_rc, expected exact line 'Tests successful'" >&2
    FAILED=$(( FAILED + 1 ))
  fi
fi

# ── 3) Direct KAT probes against plcli (required in addition to (2) -- see header). All
#       UNCONDITIONAL: a missing binary/fixture is a FAILURE, never a skip. ────────────────────
KAT_TMP="$(mktemp -d /tmp/plcli-kat-XXXXXX)"
trap 'rm -rf "$KAT_TMP"' EXIT

kat_expect() {
  local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    echo "KAT PASS: $label"
    PASSED=$(( PASSED + 1 ))
  else
    echo "KAT FAIL: $label -- got '$got', want '$want'" >&2
    FAILED=$(( FAILED + 1 ))
  fi
}

if [ ! -x "$CLI_BIN" ]; then
  echo "FAIL: $CLI_BIN missing -- skipping direct KAT probes (counted as failures above)" >&2
  FAILED=$(( FAILED + 3 ))
else
  # KAT A: `plcli format` on the real upstream fixtures (tests/integration/test.hexpat over
  # tests/integration/test_data) must produce EXACTLY tests/integration/test.hexpat.json --
  # a parsed u64/u8/u48 struct decoded from 26 fixed input bytes, byte-for-byte.
  OUT_JSON="$KAT_TMP/out.json"
  rm -f "$OUT_JSON"
  "$CLI_BIN" format --input tests/integration/test_data --pattern tests/integration/test.hexpat --output "$OUT_JSON" >"$KAT_TMP/fmt.log" 2>&1
  fmt_rc=$?
  if [ "$fmt_rc" -eq 0 ] && [ -f "$OUT_JSON" ] && diff -q "$OUT_JSON" tests/integration/test.hexpat.json >/dev/null 2>&1; then
    got="match"
  else
    got="no-match(rc=$fmt_rc)"
    cat "$KAT_TMP/fmt.log" >&2 || true
  fi
  kat_expect "plcli format output matches test.hexpat.json exactly" "$got" "match"

  # KAT B: an invalid pattern (tests/integration/invalid.hexpat -- plain English text, not
  # pattern-language source) MUST be rejected: nonzero exit AND no output file written.
  SHOULD_NOT_EXIST="$KAT_TMP/should_not_exist.json"
  rm -f "$SHOULD_NOT_EXIST"
  "$CLI_BIN" format --input tests/integration/test_data --pattern tests/integration/invalid.hexpat --output "$SHOULD_NOT_EXIST" >"$KAT_TMP/invalid.log" 2>&1
  invalid_rc=$?
  if [ "$invalid_rc" -ne 0 ] && [ ! -e "$SHOULD_NOT_EXIST" ]; then
    got="rejected"
  else
    got="accepted(rc=$invalid_rc,file_exists=$([ -e "$SHOULD_NOT_EXIST" ] && echo yes || echo no))"
  fi
  kat_expect "plcli format rejects invalid.hexpat without writing output" "$got" "rejected"

  # KAT C: `plcli --version` prints the exact literal version string baked into
  # cli/source/main.cpp (`fmt::print("{}", "v1.0.0")`, no trailing newline).
  VERSION_OUT="$("$CLI_BIN" --version 2>&1 || true)"
  kat_expect "plcli --version prints exact string" "$VERSION_OUT" "v1.0.0"
fi

emit_ctrf "patternlanguage-ctest+plcli-kat" "$PASSED" "$FAILED" "$SKIPPED"
