#!/usr/bin/env bash
#
# caddy/mayhem/build.sh — build ALL SEVEN of caddy's OWN `//go:build gofuzz`
# targets as sanitized libFuzzer binaries, plus a dynamically-linked KAT probe.
#
# Upstream IS an OSS-Fuzz project (see google/oss-fuzz projects/caddy/build.sh,
# which does `find . -name '*_fuzz.go'` and compile_go_fuzzer's every one of
# them) that ships its OWN legacy go-fuzz harnesses (NOT native `testing.F` —
# the OLD `func FuzzX(data []byte) int` signature, gated behind
# `//go:build gofuzz`). SPEC §6.2 item 12 requires shipping ALL of an upstream
# OSS-Fuzz project's harnesses, so all seven are built here (no harness of our
# own to write — pure reuse):
#   caddyconfig/caddyfile/lexer_fuzz.go     -> FuzzTokenize    -> fuzz_caddyfile_tokenize
#   caddyconfig/caddyfile/formatter_fuzz.go -> FuzzFormat      -> fuzz_caddyfile_format
#   listeners_fuzz.go                       -> FuzzParseNetworkAddress -> fuzz_network_address
#   duration_fuzz.go                        -> FuzzParseDuration -> fuzz_duration
#   replacer_fuzz.go                        -> FuzzReplacer    -> fuzz_replacer
#   caddyconfig/httpcaddyfile/addresses_fuzz.go -> FuzzParseAddress -> fuzz_httpcaddyfile_address
#   modules/caddyhttp/templates/frontmatter_fuzz.go -> FuzzExtractFrontMatter -> fuzz_frontmatter
# None of the seven do any file I/O (all take []byte and call a pure parser), so
# none hit the "harness reads a relative testdata path" trap (§3 of the net-new
# brief) — verified by reading every *_fuzz.go body before wiring these targets.
#
# Targets produced (one Mayhemfile each): /mayhem/fuzz_caddyfile_tokenize,
# /mayhem/fuzz_caddyfile_format, /mayhem/fuzz_network_address, /mayhem/fuzz_duration,
# /mayhem/fuzz_replacer, /mayhem/fuzz_httpcaddyfile_address, /mayhem/fuzz_frontmatter,
# and /mayhem/kat — a dynamically-linked known-answer probe used by mayhem/test.sh
# (see mayhem/kat/main.go).
#
# Because dvyukov/go-fuzz's own build tag machinery ALWAYS adds `-tags gofuzz`
# (and `gofuzz_libfuzzer` in -libfuzzer mode) to both the package-discovery and
# the final `go build` step, we don't need to (and must not) pass -tags
# ourselves — go-fuzz-build finds FuzzTokenize/FuzzParseNetworkAddress in the
# gofuzz-gated files automatically.
#
# Since package "caddyconfig/caddyfile" and root package "." BOTH declare
# multiple FuzzX functions, -func=<Name> is REQUIRED to disambiguate (go-fuzz-
# build errors "multiple fuzz functions in package, use -func" otherwise).
#
# Go path is ASan-only for the libFuzzer link (OSS-Fuzz's Go convention): the
# .a archive carries the Go fuzz code instrumented by go-fuzz-build's own
# SanitizerCoverage-style counters; clang++ then links it against the libFuzzer
# engine + the base's $SANITIZER_FLAGS (ASan+UBSan+halt — inherited from the
# base image ENV, never overridden here).
#
# DWARF gate (SPEC §6.2 item 10): Go's gc compiler always emits DWARF4 with no
# downgrade knob. go-fuzz-build's generated main package uses cgo (a tiny
# `#cgo CFLAGS` block for the SanitizerCoverage counters array) which clang-19
# compiles at DWARF5 by default — so we force it, and the final link, to DWARF3
# via $GO_DEBUG_FLAGS. verify-repo reads the FIRST CU's DWARF version, which is
# this C shim, satisfying the < 4 gate.
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs this script OFFLINE.
# This first (online) build populates $GOMODCACHE under /opt/toolchains; the
# cache doubles as a file proxy, which GOPROXY prefers, so the offline re-run
# resolves from it. Re-running on an already-built tree must also succeed
# (idempotent — go-fuzz-build's own workdir is a fresh temp dir every run, and
# `go get` of an already-present dependency is a no-op).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# ASan-only for the Go libFuzzer link. An explicit empty --build-arg SANITIZER_FLAGS=
# yields a no-sanitizer (natural-crash) build, so default with `=` not `:=` — but
# normally this inherits the base image's ENV (asan+ubsan+halt), which we keep.
: "${SANITIZER_FLAGS=-fsanitize=address}"
: "${MAYHEM_JOBS:=$(nproc)}"
export CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS MAYHEM_JOBS

# DWARF3 for every clang-compiled shim + the final link (see header).
: "${GO_DEBUG_FLAGS:=-g -gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:+$CGO_CFLAGS }$GO_DEBUG_FLAGS"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:+$CGO_CXXFLAGS }$GO_DEBUG_FLAGS"

# Offline-first module resolution. $(go env GOMODCACHE) reads the pinned ENV from
# the Dockerfile, so this path is right under ANY $HOME (CI or the PATCH re-run).
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"

cd "$SRC"
go version

# go-fuzz-build needs the go-fuzz-dep package on the module graph (its generated
# main package imports it for coverage-counter registration). Resolves from the
# module cache offline (no-op if already present — idempotent).
go get github.com/dvyukov/go-fuzz/go-fuzz-dep 2>&1 | tail -3 || true

# Pre-fetch mayhem/test.sh's TEST-ONLY dependencies now, while GOPROXY still has its
# network fallback (this is the online build). go-fuzz-build above only resolves the
# regular (non-test) import graph of the fuzzed packages, which is NOT the same set:
# caddyconfig/httpcaddyfile's _test.go files pull in modules/logging (and its
# github.com/DeRuina/timberjack dep) that the production package never imports.
# Without this, mayhem/test.sh's `go test` — run with a cache-only GOPROXY — fails
# with "module lookup disabled by GOPROXY=off" the first time it touches a
# test-only dependency. `-run=^$` compiles+links each test binary (paying the full
# dependency-resolution/download cost) but executes zero tests, so this is a cheap,
# side-effect-free way to populate $GOMODCACHE for the offline/cache-only re-run.
echo "=== prefetching test-suite module deps for mayhem/test.sh ==="
go test -run='^$' ./caddyconfig/caddyfile/... . ./caddyconfig/httpcaddyfile/... ./modules/caddyhttp/templates/... 2>&1 | tail -20 || true

mkdir -p "$SRC/mayhem-build"

# build_target <output-name> <fuzz-func> <package-dir>
build_target() {
  local target="$1" func="$2" pkgdir="$3"
  echo "=== building $target ($func in $pkgdir, go-fuzz-build -libfuzzer) ==="
  # -preserve filippo.io/bigmod: go-fuzz-build's AST-rewriting instrumentation pass
  # mis-places the `//go:noescape` compiler directive in filippo.io/bigmod@v0.1.0's
  # nat_asm.go (an indirect dep, pulled in transitively e.g. via
  # caddyconfig/httpcaddyfile's TLS-adjacent imports), which then fails to compile
  # ("misplaced compiler directive"). -preserve skips instrumenting (but still
  # clones/builds) that package, which sidesteps the rewriter bug entirely — applied
  # to every target since which package pulls it in transitively can vary.
  go-fuzz-build -libfuzzer -preserve filippo.io/bigmod -func "$func" -o "$SRC/mayhem-build/$target.a" "$pkgdir"
  # shellcheck disable=SC2086  # word-splitting of the flag lists is intended
  $CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS \
      "$SRC/mayhem-build/$target.a" -o "/mayhem/$target"
  echo "built /mayhem/$target"
}

build_target fuzz_caddyfile_tokenize     FuzzTokenize             ./caddyconfig/caddyfile
build_target fuzz_caddyfile_format       FuzzFormat               ./caddyconfig/caddyfile
build_target fuzz_network_address        FuzzParseNetworkAddress  .
build_target fuzz_duration               FuzzParseDuration        .
build_target fuzz_replacer               FuzzReplacer             .
build_target fuzz_httpcaddyfile_address  FuzzParseAddress         ./caddyconfig/httpcaddyfile
build_target fuzz_frontmatter            FuzzExtractFrontMatter   ./modules/caddyhttp/templates

# ── The KAT probe used by mayhem/test.sh (NORMAL flags — it is a functional oracle,
#    not a triage artifact, so no sanitizer/fuzz instrumentation here). ───────────
# CGO_ENABLED=1 + the `import "C"` file force EXTERNAL linking so the probe is
# DYNAMICALLY linked and therefore reachable by verify-repo's LD_PRELOAD sabotage
# shim (SPEC §6.3). Assert that, so a toolchain change can't silently turn the
# probe static and weaken the oracle to a `go test`-only pass.
echo "=== building /mayhem/kat (KAT probe, cgo => dynamically linked) ==="
CGO_ENABLED=1 CGO_CFLAGS="$GO_DEBUG_FLAGS" go build -o /mayhem/kat ./mayhem/kat
if ! file /mayhem/kat | grep -q 'dynamically linked'; then
  echo "FATAL: /mayhem/kat is not dynamically linked — the sabotage check could not" >&2
  echo "       neuter it, which would make mayhem/test.sh a reward-hackable oracle." >&2
  file /mayhem/kat >&2
  exit 1
fi
echo "built /mayhem/kat (dynamically linked)"

# Go's `go test` compiles on demand, so there is no separate test-suite build step;
# mayhem/test.sh runs `go test` (scoped to the packages our targets fuzz) with the
# project's normal flags.

echo "build.sh complete:"
ls -la /mayhem/fuzz_caddyfile_tokenize /mayhem/fuzz_caddyfile_format \
       /mayhem/fuzz_network_address /mayhem/fuzz_duration /mayhem/fuzz_replacer \
       /mayhem/fuzz_httpcaddyfile_address /mayhem/fuzz_frontmatter /mayhem/kat
