package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"

	"github.com/mark3labs/mcp-go/mcp"
)

// concurrencyRecorderScript is a fake sgt-* script that records, via a
// mkdir-based lock (portable POSIX, no flock -- flock is absent from macOS
// system installs, matching this codebase's existing lock-primitive
// convention), the maximum number of concurrent invocations it ever observed
// concurrently in-flight. Each invocation increments a counter on entry,
// updates the max if higher, sleeps briefly so concurrent invocations
// actually overlap, then decrements on exit.
const concurrencyRecorderScript = `#!/usr/bin/env bash
set -euo pipefail
dir="$(dirname "$0")"
lock="$dir/lock.d"
current="$dir/current"
max="$dir/max"

_lock() { until mkdir "$lock" 2>/dev/null; do sleep 0.01; done; }
_unlock() { rmdir "$lock"; }

_lock
n="$(cat "$current" 2>/dev/null || echo 0)"
n=$((n + 1))
printf '%s' "$n" > "$current"
m="$(cat "$max" 2>/dev/null || echo 0)"
if [[ "$n" -gt "$m" ]]; then printf '%s' "$n" > "$max"; fi
_unlock

sleep 0.15

_lock
n="$(cat "$current")"
n=$((n - 1))
printf '%s' "$n" > "$current"
_unlock

echo ok
`

func writeConcurrencyRecorderScript(t *testing.T, dir, name string) {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(concurrencyRecorderScript), 0o755); err != nil {
		t.Fatalf("write fake script: %v", err)
	}
}

// TestRunScriptBoundsConcurrency exercises the real mechanism end to end:
// real cmd.Run() invocations of a real script, not a mock of the semaphore.
// It requires the bound to actually be reached (max == limit), not merely
// never exceeded, so a semaphore that only ever admits 1 (or is otherwise
// vacuously "bounded") cannot pass.
func TestRunScriptBoundsConcurrency(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("SERGEANT_MCP_SCRIPT_DIR", dir)
	writeConcurrencyRecorderScript(t, dir, "fake-concurrent")

	const limit = 2
	const calls = 8
	prevSem := execSemaphore
	execSemaphore = make(chan struct{}, limit)
	defer func() { execSemaphore = prevSem }()

	var wg sync.WaitGroup
	failed := make([]bool, calls)
	for i := 0; i < calls; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			res, err := runScript(context.Background(), "fake-concurrent", "", "")
			if err != nil || res.IsError {
				failed[i] = true
			}
		}(i)
	}
	wg.Wait()

	for i, bad := range failed {
		if bad {
			t.Errorf("call %d: runScript reported failure", i)
		}
	}

	maxBytes, err := os.ReadFile(filepath.Join(dir, "max"))
	if err != nil {
		t.Fatalf("read max: %v", err)
	}
	max, err := strconv.Atoi(strings.TrimSpace(string(maxBytes)))
	if err != nil {
		t.Fatalf("parse max %q: %v", maxBytes, err)
	}
	if max > limit {
		t.Fatalf("observed max concurrency %d, want <= %d (semaphore not bounding execution)", max, limit)
	}
	if max != limit {
		t.Fatalf("observed max concurrency %d, want == %d (semaphore never reached its bound, so the test cannot tell a real limit from no limit at all)", max, limit)
	}
}

// echoArgsScript is a fake sgt-* script that just echoes back the exact
// argv it received, so a test can confirm one MCP caller's explicit flag
// (e.g. --model, --tmux-session) reaches its own script invocation
// unmangled and unaffected by any other concurrently in-flight call.
const echoArgsScript = "#!/usr/bin/env bash\necho \"args:$*\"\n"

// TestRunScriptConcurrentCallsWithDifferentFlagsDoNotCollide covers
// specs/mcp-server/spec.md's "Two instances with different intended policy
// do not collide via a shared server" scenario at the MCP layer: two
// concurrent tool calls, each carrying a distinct explicit flag (mirroring
// sgt-recover --model / sgt-dispatch --tmux-session), must each see only
// their own flag in the resulting script invocation -- proving runScript
// forwards each call's "args" independently rather than the shared server
// process leaking one call's arguments (or environment) into another's.
func TestRunScriptConcurrentCallsWithDifferentFlagsDoNotCollide(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("SERGEANT_MCP_SCRIPT_DIR", dir)
	if err := os.WriteFile(filepath.Join(dir, "fake-policy"), []byte(echoArgsScript), 0o755); err != nil {
		t.Fatalf("write fake script: %v", err)
	}

	const calls = 6
	var wg sync.WaitGroup
	results := make([]string, calls)
	errs := make([]error, calls)
	for i := 0; i < calls; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			args := "--model policy-" + strconv.Itoa(i)
			res, err := runScript(context.Background(), "fake-policy", args, "")
			if err != nil {
				errs[i] = err
				return
			}
			if res.IsError {
				errs[i] = errFromResult(res)
				return
			}
			results[i] = textOf(res)
		}(i)
	}
	wg.Wait()

	for i, err := range errs {
		if err != nil {
			t.Fatalf("call %d failed: %v", i, err)
		}
	}
	for i, got := range results {
		want := "args:--model policy-" + strconv.Itoa(i)
		if got != want {
			t.Errorf("call %d result = %q, want %q (a concurrent call's flag leaked across calls)", i, got, want)
		}
	}
}

func textOf(res *mcp.CallToolResult) string {
	for _, c := range res.Content {
		if tc, ok := mcp.AsTextContent(c); ok {
			return strings.TrimSpace(tc.Text)
		}
	}
	return ""
}

func errFromResult(res *mcp.CallToolResult) error {
	return fmt.Errorf("tool result reported an error: %s", textOf(res))
}
