# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile — RUST target (cargo / cargo-fuzz) for kdl-rs. Builds ON
# TOP of the org C/C++ base, adding a pinned Rust nightly + cargo-fuzz under
# /opt/toolchains/rust, then runs mayhem/build.sh.
#
# The cargo registry the FIRST (online) build populates must be found again — by the
# SAME absolute CARGO_HOME — when the air-gapped PATCH re-run runs build.sh offline.

FROM ghcr.io/mayhemheroes/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (never an ENV — an empty ENV breaks clang). build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH
# Undefaulted (no '=') so the base ENV default flows through unless --build-arg overrides it.
ARG SANITIZER_FLAGS

# ── Rust toolchain @ a FIXED, lockable, $HOME-independent prefix ───────────────
# kdl 6.7.1 declares rust-version 1.95 (edition 2024). rustc 1.95 nightly lands ~Nov 2025,
# so a mid-Nov-2025 nightly satisfies it AND provides -Zsanitizer=address + -Zdwarf-version
# (used by build.sh to force DWARF < 4 for Mayhem triage).
ARG RUST_CHANNEL=nightly-2026-01-20
ARG CARGO_FUZZ_VERSION=0.12.0

ENV RUSTUP_HOME=/opt/toolchains/rust/rustup \
    CARGO_HOME=/opt/toolchains/rust/cargo \
    PATH=/opt/toolchains/rust/cargo/bin:${PATH}

# A pinned STABLE toolchain used ONLY to compile the cargo-fuzz CLI. The 1.95 nightly's
# bundled lld / gcc-14 collect2 intermittently SEGFAULTS while compiling cargo-fuzz under
# QEMU (cross-arch emulated build); the stable toolchain links it reliably. cargo-fuzz is
# a standalone CLI — it need not match the project's toolchain. (On native x86_64 CI this
# is moot, just an extra small toolchain.)
ARG RUST_STABLE=1.84.0

USER root
RUN install -d /opt/toolchains/rust \
 && curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh \
 && sh /tmp/rustup-init.sh -y --no-modify-path --profile minimal \
        --default-toolchain "${RUST_CHANNEL}" \
 && rustup component add rust-src --toolchain "${RUST_CHANNEL}" \
 && rustup toolchain install "${RUST_STABLE}" --profile minimal \
 # Build cargo-fuzz with the reliable stable toolchain (serialized to be gentle on QEMU).
 && cargo "+${RUST_STABLE}" install -j1 cargo-fuzz --version "${CARGO_FUZZ_VERSION}" --locked \
 && rm -f /tmp/rustup-init.sh \
 # The commit build AND the air-gapped PATCH re-run run as `mayhem` (2000): it must
 # read the toolchain and read/refresh the cargo registry cache, so hand the whole
 # prefix to 2000.
 && chown -R 2000:2000 /opt/toolchains/rust

# Source enters from the build CONTEXT (CI checkout): the FULL repo (incl. .git) → /mayhem.
USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# Populates $CARGO_HOME (online, this first build) and builds the sanitized fuzz target(s)
# plus the clean (non-sanitized) test binaries that test.sh runs.
RUN bash mayhem/build.sh

# Run the project's functional suite at build time (a failing suite fails the build).
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
