#!/usr/bin/env bash
#
# caddy/mayhem/test.sh — RUN caddy's OWN Go test suite (scoped to the four packages
# our seven fuzz targets cover) and a known-answer probe, and emit a CTRF summary.
# exit 0 iff nothing failed.
#
# PATCH-grade oracle (SPEC §6.3). Two parts, and the SECOND is the load-bearing one:
#
#  1) `go test` over the root package `.`, `./caddyconfig/caddyfile/...`,
#     `./caddyconfig/httpcaddyfile/...` and `./modules/caddyhttp/templates/...` —
#     upstream's own known-answer suites: lexer_test.go/formatter_test.go/parse_test.go
#     assert exact token streams and formatted golden output for the Caddyfile
#     parser (fuzz_caddyfile_tokenize/_format); listeners_test.go's
#     TestParseNetworkAddress/TestSplitNetworkAddress table-test dozens of exact
#     (Network, Host, StartPort, EndPort) tuples (fuzz_network_address);
#     caddy_test.go's TestParseDuration (fuzz_duration) and replacer_test.go's
#     TestReplacer* (fuzz_replacer); addresses_test.go's TestParseAddress
#     (fuzz_httpcaddyfile_address); tplcontext_test.go's TestSplitFrontMatter
#     (fuzz_frontmatter). Together these cover every one of the seven fuzz
#     targets' underlying functions, so this asserts BEHAVIOUR of the fuzzed
#     surface, not "exits 0".
#
#  2) The KAT probe /mayhem/kat — because `go test` links a STATIC binary, the
#     verify-repo sabotage check (LD_PRELOAD a shim whose constructor _exit(0)s
#     every non-system executable) CANNOT neuter it. A `go test`-only oracle
#     therefore survives sabotage while proving nothing, which is exactly the
#     reward-hackable case the spec forbids. /mayhem/kat is built with cgo =>
#     DYNAMICALLY linked, so the shim DOES neuter it; it then prints nothing and
#     the exact-match assertions below fail. The probe asserts VALUES computed by
#     caddy.ParseNetworkAddress and caddyfile.Tokenize over fixed inputs, so a
#     patch that stubs a parser to silence a crash cannot satisfy it either.
#
# This script only RUNS things — mayhem/build.sh did the building.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

export PATH="/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:$PATH"
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"
export GOMODCACHE="${GOMODCACHE:-/opt/toolchains/go-path/pkg/mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE 2>/dev/null || echo /opt/toolchains/go-path/pkg/mod)/cache/download,off}"
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

if ! command -v go >/dev/null 2>&1; then
  echo "go not available — cannot run the test suite" >&2
  emit_ctrf "go-test+kat" 0 1 0; exit 2
fi

# ── 1) upstream's own suite, scoped to the two fuzzed packages ──────────────────
mkdir -p "$SRC/mayhem-build"
# SETUPFAILS counts PACKAGE-level failures (a compile/vet/module-resolution error
# for the whole package) that carry NO per-test "Test" field — e.g. a missing
# module dependency. These would otherwise be COUNTED NOWHERE: count_act only
# tallies events with a "Test" field, so a package that fails before running any
# test contributes zero to both passed AND failed, and — as long as at least one
# of the OTHER scoped packages has passing tests — the overall `[ $(( PASSED+
# FAILED+SKIPPED )) -eq 0 ]` guard below never trips either. A real instance:
# GOPROXY=off + an un-cached test-only dependency ("module lookup disabled by
# GOPROXY=off") failed caddyconfig/httpcaddyfile's package-level setup while the
# other 3 packages' tests still passed — silently dropping that package's
# coverage from the oracle. Fixed at the source (mayhem/build.sh now prefetches
# every scoped package's test deps), but this counts the failure mode loudly on
# any regression instead of re-degrading silently.
SETUPFAILS=0
run_pkg() {
  local pkg="$1" jf="$2"
  echo "=== running: go test -json $pkg ==="
  go test -json "$pkg" > "$jf" 2>"$jf.err"; local rc=$?
  go test "$pkg" 2>&1 | tail -20 || true
  [ -s "$jf.err" ] && { echo "--- stderr ($pkg) ---"; tail -20 "$jf.err"; }
  if [ "$rc" -ne 0 ] && ! grep -q '"Test":' "$jf" 2>/dev/null; then
    echo "FAIL: $pkg — package-level failure with NO per-test events (build/vet/module-resolution error)" >&2
    SETUPFAILS=$(( SETUPFAILS + 1 ))
  fi
}
run_pkg ./caddyconfig/caddyfile/...          "$SRC/mayhem-build/gotest-caddyfile.json"
run_pkg .                                    "$SRC/mayhem-build/gotest-root.json"
run_pkg ./caddyconfig/httpcaddyfile/...      "$SRC/mayhem-build/gotest-httpcaddyfile.json"
run_pkg ./modules/caddyhttp/templates/...    "$SRC/mayhem-build/gotest-templates.json"

# Count test-level events only (lines carrying a non-empty "Test" field); package-level
# pass/fail lines have no "Test" field. Subtests count — they are real asserted cases.
count_act() {
  local action="$1"; shift
  grep "\"Action\":\"$action\"" "$@" 2>/dev/null | grep -c "\"Test\":"
}
JS="$SRC/mayhem-build/gotest-caddyfile.json $SRC/mayhem-build/gotest-root.json $SRC/mayhem-build/gotest-httpcaddyfile.json $SRC/mayhem-build/gotest-templates.json"
# shellcheck disable=SC2086
PASSED=$(count_act pass $JS); FAILED=$(count_act fail $JS); SKIPPED=$(count_act skip $JS)
: "${PASSED:=0}" "${FAILED:=0}" "${SKIPPED:=0}"
FAILED=$(( FAILED + SETUPFAILS ))

if [ "$(( PASSED + FAILED + SKIPPED ))" -eq 0 ]; then
  echo "FAIL: no test events parsed — the suite did not run" >&2
  emit_ctrf "go-test+kat" 0 1 0; exit 1
fi

# ── 2) the KAT probe (sabotage-detecting; see header) ────────────────────────────
# UNCONDITIONAL by design: a missing binary is a FAILURE, never a skip. A `[ -f ... ]`
# guard here is how a probe silently stops running and the oracle quietly degrades
# to the go-test-only (reward-hackable) case.
echo "=== KAT probe: /mayhem/kat (dynamically linked; asserts parsed VALUES) ==="
KAT_OUT="$(/mayhem/kat 2>&1)"; kat_rc=$?
echo "$KAT_OUT"

# Expected values, computed by caddy's own exported parsers over the fixed inputs
# in mayhem/kat/main.go:
#   caddy.ParseNetworkAddress("tcp/127.0.0.1:8080-8082")  -> tcp / 127.0.0.1 / 8080-8082
#   caddy.ParseNetworkAddress("unix//run/caddy.sock")     -> unix / /run/caddy.sock
#   caddyfile.Tokenize("example.com {\n\trespond \"Hello, world!\"\n}\n", "Caddyfile")
#     -> 5 tokens: example.com , { , respond , Hello, world! , }
kat_expect() {
  local label="$1" line="$2"
  if printf '%s\n' "$KAT_OUT" | grep -qxF "$line"; then
    echo "KAT PASS: $label"
    PASSED=$(( PASSED + 1 ))
  else
    echo "KAT FAIL: $label — expected exact line: $line" >&2
    FAILED=$(( FAILED + 1 ))
  fi
}

if [ "$kat_rc" -ne 0 ]; then
  echo "KAT FAIL: /mayhem/kat exited $kat_rc (neutered, missing, or parser broken)" >&2
  FAILED=$(( FAILED + 1 ))
fi
kat_expect "ParseNetworkAddress tcp port range: network" 'KAT_NA1_NETWORK=tcp'
kat_expect "ParseNetworkAddress tcp port range: host"    'KAT_NA1_HOST=127.0.0.1'
kat_expect "ParseNetworkAddress tcp port range: start"   'KAT_NA1_STARTPORT=8080'
kat_expect "ParseNetworkAddress tcp port range: end"     'KAT_NA1_ENDPORT=8082'
kat_expect "ParseNetworkAddress unix socket: network"    'KAT_NA2_NETWORK=unix'
kat_expect "ParseNetworkAddress unix socket: host"       'KAT_NA2_HOST=/run/caddy.sock'
kat_expect "Tokenize: token count"                       'KAT_TOK_COUNT=5'
kat_expect "Tokenize: token 0 (host)"                    'KAT_TOK_0=example.com'
kat_expect "Tokenize: token 1 (open brace)"               'KAT_TOK_1={'
kat_expect "Tokenize: token 2 (directive)"                'KAT_TOK_2=respond'
kat_expect "Tokenize: token 3 (quoted arg, unquoted)"      'KAT_TOK_3=Hello, world!'
kat_expect "Tokenize: token 4 (close brace)"               'KAT_TOK_4=}'

emit_ctrf "go-test+kat" "$PASSED" "$FAILED" "$SKIPPED"
