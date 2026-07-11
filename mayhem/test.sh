#!/usr/bin/env bash
#
# mayhem/test.sh — RUN the kdl crate's functional test suite (already compiled by mayhem/build.sh
# via `cargo test --no-run -p kdl`). Emits a CTRF (https://ctrf.io) summary. exit 0 = pass.
#
# BEHAVIORAL ORACLE: the kdl suite asserts real output — tests/formatting.rs has golden
# `assert_eq!`s on autoformat() output, tests/compliance.rs diffs each tests/test_cases/*.kdl
# against its golden re-serialization, plus src unit tests. A PATCH that neuters the program to
# exit(0) FAILS these (the golden comparisons no longer match) — so this is not reward-hackable.
#
# Does NOT compile: build.sh already ran `cargo test --no-run -p kdl` with the project's normal
# (clean, non-sanitized) flags. With the test binaries already built and RUSTFLAGS unset (matching
# build.sh), `cargo test -p kdl` here only RUNS them.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
: "${MAYHEM_JOBS:=$(nproc)}"
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

# RUN the suite (test binaries pre-built by build.sh). RUSTFLAGS must MATCH build.sh's test
# compile (--cap-lints=warn) so cargo finds the already-built artifacts and only RUNS them —
# a RUSTFLAGS mismatch would re-key the build cache and trigger a recompile here.
LOG="$(mktemp)"
RUSTFLAGS="--cap-lints=warn" cargo test -p kdl 2>&1 | tee "$LOG"
run_rc=${PIPESTATUS[0]}

# libtest prints one "test result: ok. N passed; M failed; K ignored; ..." line per binary.
# Sum across all binaries.
passed=$(grep -hoE '[0-9]+ passed' "$LOG"  | awk '{s+=$1} END{print s+0}')
failed=$(grep -hoE '[0-9]+ failed' "$LOG"  | awk '{s+=$1} END{print s+0}')
skipped=$(grep -hoE '[0-9]+ ignored' "$LOG" | awk '{s+=$1} END{print s+0}')
rm -f "$LOG"

# Defensive: if cargo errored but printed no summary lines (e.g. a binary failed to even start),
# record a failure so the oracle doesn't pass vacuously.
if [ "$run_rc" -ne 0 ] && [ "$failed" -eq 0 ] && [ "$passed" -eq 0 ]; then
  failed=1
fi

emit_ctrf "cargo-test" "$passed" "$failed" "$skipped"
