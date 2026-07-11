#!/usr/bin/env bash
#
# mayhem/build.sh — build the kdl-rs cargo-fuzz target as a sanitized libFuzzer
# binary (OSS-Fuzz Rust path: cargo-fuzz + ASan via RUSTFLAGS), AND build the kdl
# crate's clean (non-sanitized) test binaries that mayhem/test.sh runs.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The Rust
# toolchain + cargo registry live at $CARGO_HOME=/opt/toolchains/rust/cargo (pinned by
# the Dockerfile ENV — absolute, $HOME-independent).
#
# Base image contract (already exported — use, don't redefine):
#   SANITIZER_FLAGS   ASan+UBSan halting (C/C++ form; for Rust we use -Zsanitizer=address)
#   RUST_DEBUG_FLAGS  -C debuginfo=2 -C force-frame-pointers=yes ...  (threaded into RUSTFLAGS)
#   SRC               /mayhem (the repo source)
#
# AIR-GAPPED CONTRACT (§6.5): the PATCH tier re-runs THIS script OFFLINE. This first
# (online) build populates the cargo registry under $CARGO_HOME; the offline re-run
# resolves crates from that cache. The rlenv runtime sets CARGO_NET_OFFLINE=true for
# the re-run, so do NOT hard-code `--offline` here (it would break this online build).
# Re-runnable on an already-built tree (idempotent).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SRC:=/mayhem}"
: "${MAYHEM_JOBS:=$(nproc)}"
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# Debug-info contract: thread the base's $RUST_DEBUG_FLAGS so the fuzz binary carries
# DWARF symbols, and FORCE DWARF version 3 (< 4) — Mayhem's triage can't read DWARF >= 4,
# and rustc on a 2025 nightly otherwise emits DWARF 4/5. -Zdwarf-version is the reliable
# nightly knob for this (more dependable than -C llvm-args=-gdwarf-N).
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes}"
DWARF_FLAGS="-Zdwarf-version=3"

# OSS-Fuzz Rust libFuzzer+ASan flags. cargo-fuzz sets the ASan flag itself; we pin it.
# --cfg fuzzing matches libfuzzer-sys. We honor $SANITIZER_FLAGS being present in the
# environment (base contract) but for Rust the instrumentation is -Zsanitizer=address.
FUZZ_RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing -Zsanitizer=address ${RUST_DEBUG_FLAGS} ${DWARF_FLAGS}"
echo "SANITIZER_FLAGS (base, informational) = ${SANITIZER_FLAGS:-<unset>}"

FUZZ_DIR="mayhem/fuzz"
TRIPLE="x86_64-unknown-linux-gnu"

# DWARF<4 contract (§6.2 item 10): -Zsanitizer=address statically links the toolchain's
# PREBUILT ASan runtime (compiler-rt), whose objects carry DWARF 5 — and -Zdwarf-version
# only controls code rustc COMPILES (our crate + build-std), not that prebuilt archive.
# Those v5 CUs end up first in the linked binary and fail the DWARF<4 check. The runtime's
# debug info is useless for Mayhem triage, so strip it from the archive once (idempotent;
# re-stripping is a no-op — safe for the offline build.sh re-run). The binary then carries
# only our DWARF-3 CUs (Rust code + build-std) and still has .debug_info.
ASAN_A="$(rustc --print sysroot)/lib/rustlib/${TRIPLE}/lib/librustc-nightly_rt.asan.a"
if [ -f "$ASAN_A" ]; then
  echo "stripping debug info from prebuilt ASan runtime: $ASAN_A"
  objcopy --strip-debug "$ASAN_A" 2>/dev/null || objcopy --remove-section '.debug_*' "$ASAN_A" 2>/dev/null || true
fi

# Discover every target from the crate's fuzz_targets/ dir (one binary per target).
FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
  FUZZ_TARGETS+=("$(basename "${f%.*}")")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }

# The libfuzzer-sys crate compiles its bundled libFuzzer C++ runtime via the `cc` crate,
# which emits DWARF 4 by default (Debian clang 19). The `cc` crate honors CFLAGS/CXXFLAGS,
# so force DWARF 3 there too — otherwise those ~30 C++ CUs land at v4 and can trip the
# DWARF<4 check depending on link order.
export CFLAGS="${CFLAGS:-} -gdwarf-3"
export CXXFLAGS="${CXXFLAGS:-} -gdwarf-3"

echo "=== cargo fuzz build (image nightly, ASan via RUSTFLAGS, DWARF 3) ==="
echo "RUSTFLAGS=$FUZZ_RUSTFLAGS"
echo "CFLAGS=$CFLAGS  CXXFLAGS=$CXXFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

# The fuzz target binary basename in the Mayhemfile cmd is `kdl-rs-parse`; the cargo
# target is `main`. We build `main` and copy it to /mayhem/kdl-rs-parse.
for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  RUSTFLAGS="$FUZZ_RUSTFLAGS" cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
done

# Mayhemfile target name is kdl-rs-parse → /mayhem/kdl-rs-parse (the old AFL integration's target name).
cp "$SRC/$FUZZ_DIR/target/$TRIPLE/release/main" /mayhem/kdl-rs-parse
echo "built /mayhem/kdl-rs-parse"

# --- Build the kdl crate's TEST suite with the project's NORMAL flags (clean, NON-sanitized) ---
# A SEPARATE cargo invocation with a clean RUSTFLAGS so test.sh has an honest oracle binary
# (won't false-fail on benign UB and isn't slowed by ASan). `-p kdl` only builds the kdl
# package — NOT tools/* (kdl-lsp), keeping the build light. --no-run compiles but does not run.
echo "=== cargo test --no-run -p kdl (clean flags, for test.sh) ==="
# kdl uses `#![cfg_attr(test, deny(warnings))]`, so any NEW rustc lint on the pinned
# nightly (e.g. irrefutable_let_patterns in let-chains) becomes a hard test-build error.
# Cap lints to warnings for the test compile so an additive integration never has to edit
# upstream src to silence a toolchain lint. This does not affect runtime behavior — the
# golden assert_eq tests still run and still assert real output.
TEST_RUSTFLAGS="--cap-lints=warn"
echo "TEST RUSTFLAGS=$TEST_RUSTFLAGS"
( cd "$SRC" && RUSTFLAGS="$TEST_RUSTFLAGS" cargo test --no-run -p kdl )
echo "test binaries built"

echo "build.sh complete"
