package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestStartServerTimesOutWhenServerNeverStarts covers the failure path the
// readiness review flagged as untested. Because startServer double-forks the
// server binary via a backgrounded `sh -c "exec ... &"` (so the shell always
// exits 0 regardless of whether the backgrounded exec later succeeds -- see
// the comment on that exec.Command call), a broken server binary manifests
// as "no lock/socket ever appears", not as a cmd.Run() error. This confirms
// startServer converges on the documented timeout error in that case rather
// than hanging indefinitely or returning success.
func TestStartServerTimesOutWhenServerNeverStarts(t *testing.T) {
	stateDir := t.TempDir()
	lockPath := filepath.Join(stateDir, "mcp-server.lock")

	fakeServer := filepath.Join(stateDir, "fake-server-that-never-starts")
	if err := os.WriteFile(fakeServer, []byte("#!/usr/bin/env bash\nexit 0\n"), 0o755); err != nil {
		t.Fatalf("write fake server: %v", err)
	}
	t.Setenv("SERGEANT_MCP_SERVER_PATH", fakeServer)

	_, err := startServer(stateDir, lockPath)
	if err == nil {
		t.Fatal("startServer() returned no error for a server that never publishes a lock, want a timeout error")
	}
	if !strings.Contains(err.Error(), "timed out waiting") {
		t.Fatalf("startServer() error = %q, want it to mention timing out waiting for the server", err.Error())
	}
}
