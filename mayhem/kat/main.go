// mayhem/kat — known-answer-test probe for mayhem/test.sh.
//
// WHY A SEPARATE BINARY (SPEC §6.3 anti-reward-hacking):
// `go test` links a STATIC binary, so the verify-repo sabotage check (which
// LD_PRELOADs a shim whose constructor calls _exit(0) for non-system executables)
// cannot neuter it — a suite that only runs `go test` is therefore immune to the
// sabotage check and does NOT prove the oracle is behavioral. This probe is built
// with cgo (see cgo_dynamic.go) so it is DYNAMICALLY linked: the shim reaches it,
// the process becomes an instant no-op, it prints nothing, and test.sh's exact
// string assertions fail. That is what makes the oracle sabotage-detecting.
//
// It is also a real KAT, not a liveness check: it asserts VALUES computed by
// caddy's own exported parsers over fixed inputs. A patch that stubs a parser to
// "fix" a crash cannot produce these exact strings, so it fails the oracle.
//
// Prints a series of `KAT_KEY=value` lines, which test.sh matches EXACTLY.
package main

import (
	"fmt"
	"os"

	caddy "github.com/caddyserver/caddy/v2"
	"github.com/caddyserver/caddy/v2/caddyconfig/caddyfile"
)

func die(step string, err error) {
	fmt.Fprintf(os.Stderr, "kat: %s: %v\n", step, err)
	os.Exit(1)
}

func main() {
	// ── 1) caddy.ParseNetworkAddress — the network/host/port-range parser used
	//    for every listener bind address caddy is given (SplitNetworkAddress +
	//    port-range logic in listeners.go). ──────────────────────────────────
	na1, err := caddy.ParseNetworkAddress("tcp/127.0.0.1:8080-8082")
	if err != nil {
		die("ParseNetworkAddress(tcp/127.0.0.1:8080-8082)", err)
	}
	fmt.Printf("KAT_NA1_NETWORK=%s\n", na1.Network)
	fmt.Printf("KAT_NA1_HOST=%s\n", na1.Host)
	fmt.Printf("KAT_NA1_STARTPORT=%d\n", na1.StartPort)
	fmt.Printf("KAT_NA1_ENDPORT=%d\n", na1.EndPort)

	na2, err := caddy.ParseNetworkAddress("unix//run/caddy.sock")
	if err != nil {
		die("ParseNetworkAddress(unix//run/caddy.sock)", err)
	}
	fmt.Printf("KAT_NA2_NETWORK=%s\n", na2.Network)
	fmt.Printf("KAT_NA2_HOST=%s\n", na2.Host)

	// ── 2) caddyfile.Tokenize — the Caddyfile lexer: the entry point for ALL
	//    Caddyfile-format config parsing (quoting, comments, braces). ────────
	src := []byte("example.com {\n\trespond \"Hello, world!\"\n}\n")
	tokens, err := caddyfile.Tokenize(src, "Caddyfile")
	if err != nil {
		die("Tokenize", err)
	}
	fmt.Printf("KAT_TOK_COUNT=%d\n", len(tokens))
	for i, t := range tokens {
		fmt.Printf("KAT_TOK_%d=%s\n", i, t.Text)
	}
}
