package main

import (
	"syscall"
	"testing"
	"time"

	"github.com/callmeradical/sergeant/internal/mcplock"
)

// echoDeterministicScript is a fake sgt-* script whose output depends only
// on its arguments, so two calls through two different clients can be
// asserted byte-identical -- proving "identical tool behavior" (spec.md),
// not merely "both calls succeeded."
const echoDeterministicScript = `#!/usr/bin/env bash
echo "echo:$*"
`

const shortTimeout = 5 * time.Second
const restartTimeout = 15 * time.Second

// TestIntegrationSecondClientConnectsToAlreadyRunningServer covers
// spec.md's "A second instance connects to the first instance's
// already-running server" scenario against the real binaries: a second
// client, started after the first, must reuse the same shared server and see
// identical tool behavior.
func TestIntegrationSecondClientConnectsToAlreadyRunningServer(t *testing.T) {
	f := newFixture(t)
	f.writeScript("sgt-list", echoDeterministicScript)

	c1 := f.startClient(t)
	resp1 := c1.callTool(1, "sgt-list", "hello", shortTimeout)
	text1 := extractResultText(resp1)
	if text1 != "echo:hello" {
		t.Fatalf("first client result = %q, want %q (raw: %s)", text1, "echo:hello", resp1)
	}
	firstServerPID := f.currentServerPID(t)

	c2 := f.startClient(t)
	resp2 := c2.callTool(1, "sgt-list", "hello", shortTimeout)
	text2 := extractResultText(resp2)
	if text2 != text1 {
		t.Fatalf("second client result = %q, want identical to first %q (raw: %s)", text2, text1, resp2)
	}

	secondServerPID := f.currentServerPID(t)
	if secondServerPID != firstServerPID {
		t.Fatalf("second client's server pid = %d, want the same shared server pid %d (a second server was started instead of reusing the first)",
			secondServerPID, firstServerPID)
	}
}

// TestIntegrationTwoInstancesStartingSimultaneously covers spec.md's "Two
// instances starting at the same moment do not both become the server"
// scenario end to end through the real client/server binaries (the
// exclusivity guarantee itself is proven at the lock-race level by
// internal/mcplock's concurrent-goroutine test; this proves the client
// wiring around that guarantee doesn't hang, crash, or diverge on a real
// simultaneous start).
func TestIntegrationTwoInstancesStartingSimultaneously(t *testing.T) {
	f := newFixture(t)
	f.writeScript("sgt-list", echoDeterministicScript)

	// Start both client processes back to back, before either has had a
	// chance to read (let alone win) the lock, so both race discoverOrStart
	// against a state dir with no lock file yet.
	c1 := f.startClient(t)
	c2 := f.startClient(t)

	resp1 := c1.callTool(1, "sgt-list", "race", restartTimeout)
	resp2 := c2.callTool(1, "sgt-list", "race", restartTimeout)

	text1, text2 := extractResultText(resp1), extractResultText(resp2)
	if text1 != "echo:race" || text2 != "echo:race" {
		t.Fatalf("expected both clients to get a working shared server, got %q and %q (raw: %s / %s)",
			text1, text2, resp1, resp2)
	}

	rec, err := mcplock.ReadRecord(mcplock.LockPath(f.stateDir))
	if err != nil || rec == nil {
		t.Fatalf("no lock record after simultaneous start (err=%v)", err)
	}
	if !mcplock.PidAlive(rec.PID) {
		t.Fatalf("lock record names dead pid %d after simultaneous start", rec.PID)
	}
}

// TestIntegrationOneClientCrashDoesNotAffectAnother covers spec.md's "One
// instance closing does not disrupt others" scenario.
func TestIntegrationOneClientCrashDoesNotAffectAnother(t *testing.T) {
	f := newFixture(t)
	f.writeScript("sgt-list", echoDeterministicScript)

	c1 := f.startClient(t)
	c2 := f.startClient(t)

	if got := extractResultText(c1.callTool(1, "sgt-list", "a", shortTimeout)); got != "echo:a" {
		t.Fatalf("c1 first call = %q", got)
	}
	if got := extractResultText(c2.callTool(1, "sgt-list", "b", shortTimeout)); got != "echo:b" {
		t.Fatalf("c2 first call = %q", got)
	}

	c1.kill()

	if got := extractResultText(c2.callTool(2, "sgt-list", "still-fine", shortTimeout)); got != "echo:still-fine" {
		t.Fatalf("c2 call after c1 crashed = %q, want %q", got, "echo:still-fine")
	}
}

// TestIntegrationBufferedCallSurvivesServerRestart covers spec.md's "A call
// made while the server is down is not lost" scenario: the shared server is
// killed out from under a live client, and a subsequent call must still be
// delivered -- via the client's buffer-and-replay-on-reconnect path -- once
// a replacement server comes up, rather than erroring back to the caller.
func TestIntegrationBufferedCallSurvivesServerRestart(t *testing.T) {
	f := newFixture(t)
	f.writeScript("sgt-list", echoDeterministicScript)

	c1 := f.startClient(t)
	if got := extractResultText(c1.callTool(1, "sgt-list", "before", shortTimeout)); got != "echo:before" {
		t.Fatalf("initial call = %q", got)
	}

	oldPID := f.currentServerPID(t)
	if err := syscall.Kill(oldPID, syscall.SIGKILL); err != nil {
		t.Fatalf("kill shared server pid %d: %v", oldPID, err)
	}

	// The client's sendLoop must detect the broken connection, rediscover
	// (starting a replacement server since the old pid is now dead), and
	// retry this exact call rather than erroring it back.
	resp := c1.callTool(2, "sgt-list", "after", restartTimeout)
	if got := extractResultText(resp); got != "echo:after" {
		t.Fatalf("call across restart = %q, want %q (raw: %s)", got, "echo:after", resp)
	}

	newPID := f.currentServerPID(t)
	if newPID == oldPID {
		t.Fatalf("server pid unchanged (%d) -- the old server was not actually killed, so this test proved nothing", oldPID)
	}
}

func TestExtractResultTextRoundTrip(t *testing.T) {
	line := `{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"hello world"}]}}`
	if got := extractResultText(line); got != "hello world" {
		t.Fatalf("extractResultText() = %q, want %q", got, "hello world")
	}
}

func TestExtractResultTextNoMatch(t *testing.T) {
	if got := extractResultText(`not json at all`); got != "" {
		t.Fatalf("extractResultText() = %q, want empty", got)
	}
}
