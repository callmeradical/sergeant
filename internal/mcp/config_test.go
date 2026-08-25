package mcp

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// mcp.json is the file a client reads to start a server. Every entry in it must
// name something that exists, or the tools behind that entry are unreachable no
// matter how well they work.
//
// This is a regression test for a real defect. mcp.json declared exactly one
// server, ./bin/sergeant-mcp, and that binary was absent from the tree: a client
// loading the documented config started nothing at all. The native tools were
// verified by running the binary directly, which is why the gap survived — the
// binary worked, the configuration did not. Assert against the configuration.
func TestEveryServerDeclaredInMCPConfigIsBuildable(t *testing.T) {
	root := repoRoot(t)

	raw, err := os.ReadFile(filepath.Join(root, "mcp.json"))
	if err != nil {
		t.Fatalf("reading mcp.json: %v", err)
	}

	var cfg struct {
		MCPServers map[string]struct {
			Command string   `json:"command"`
			Args    []string `json:"args"`
		} `json:"mcpServers"`
	}
	if err := json.Unmarshal(raw, &cfg); err != nil {
		t.Fatalf("parsing mcp.json: %v", err)
	}
	if len(cfg.MCPServers) == 0 {
		t.Fatal("mcp.json declares no servers")
	}

	// Map each declared command to the package that produces it. A binary is a
	// build artifact and is gitignored, so its absence from a fresh checkout is
	// expected; what must hold is that something in this repository can produce
	// it. Asserting the source package exists catches a command path that no
	// build target will ever satisfy.
	sources := map[string]string{
		"./bin/sergeant": "cmd/sergeant",
	}

	for name, spec := range cfg.MCPServers {
		if spec.Command == "" {
			t.Errorf("server %q declares no command", name)
			continue
		}
		src, known := sources[spec.Command]
		if !known {
			t.Errorf("server %q names command %q, which maps to no known source package; "+
				"add it here so the config cannot point at something unbuildable",
				name, spec.Command)
			continue
		}
		dir := filepath.Join(root, src)
		if fi, err := os.Stat(dir); err != nil || !fi.IsDir() {
			t.Errorf("server %q needs %s, which does not exist (err=%v)", name, src, err)
			continue
		}
		if !hasMainPackage(t, dir) {
			t.Errorf("server %q needs %s to be a main package that can build a binary", name, src)
		}
	}
}

// The native server must expose the tools that let a caller follow a run. They
// are the reason an agent can dispatch work without guessing a sleep interval.
func TestNativeServerExposesTheRunFollowingTools(t *testing.T) {
	got := map[string]bool{}
	for _, tool := range Tools() {
		got[tool.Name] = true
	}
	for _, want := range []string{"sergeant_run_status", "sergeant_run_wait"} {
		if !got[want] {
			t.Errorf("the native MCP server does not expose %q; a client cannot follow a run", want)
		}
	}
}

func hasMainPackage(t *testing.T, dir string) bool {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil {
		return false
	}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".go") {
			continue
		}
		b, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			continue
		}
		if strings.HasPrefix(strings.TrimSpace(string(b)), "package main") ||
			strings.Contains(string(b), "\npackage main\n") {
			return true
		}
	}
	return false
}

// repoRoot locates the repository from this file rather than the working
// directory, so the test reads the same mcp.json regardless of which package
// `go test` was invoked from.
func repoRoot(t *testing.T) string {
	t.Helper()
	_, thisFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller(0) failed, cannot locate the repository")
	}
	// <root>/internal/mcp/config_test.go
	return filepath.Dir(filepath.Dir(filepath.Dir(thisFile)))
}
