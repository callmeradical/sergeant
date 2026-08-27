package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/callmeradical/sergeant/internal/mcplock"
)

var (
	buildOnce   sync.Once
	builtBinDir string
	buildErr    error
)

// buildBinaries builds the real sergeant-mcp and sergeant-mcp-client binaries
// once per test run and returns the directory holding both. Integration
// tests exercise the actual mechanism (real processes, real Unix socket, real
// exec of a real script) per this change's own testing mandate, not a mock
// of any of those pieces.
func buildBinaries(t *testing.T) string {
	t.Helper()
	buildOnce.Do(func() {
		dir, err := os.MkdirTemp("", "sergeant-mcp-build")
		if err != nil {
			buildErr = err
			return
		}
		wd, err := os.Getwd()
		if err != nil {
			buildErr = err
			return
		}
		repoRoot := filepath.Join(wd, "..", "..")
		for _, target := range []struct{ out, pkg string }{
			{"sergeant-mcp", "./cmd/sergeant-mcp"},
			{"sergeant-mcp-client", "./cmd/sergeant-mcp-client"},
		} {
			cmd := exec.Command("go", "build", "-o", filepath.Join(dir, target.out), target.pkg)
			cmd.Dir = repoRoot
			if out, err := cmd.CombinedOutput(); err != nil {
				buildErr = fmt.Errorf("build %s: %v: %s", target.pkg, err, out)
				return
			}
		}
		builtBinDir = dir
	})
	if buildErr != nil {
		t.Fatalf("build binaries: %v", buildErr)
	}
	return builtBinDir
}

// fixture is one test's isolated state dir + script dir + built binaries.
type fixture struct {
	t         *testing.T
	binDir    string
	stateDir  string
	scriptDir string
}

// shortTempDir creates a temp directory under a short, test-name-independent
// path and registers its cleanup. testing.T.TempDir() embeds the full test
// (and subtest) name in the path, which for these integration tests'
// deliberately descriptive names easily exceeds the ~104-byte sun_path limit
// on a Unix domain socket -- net.Listen/net.Dial then fail in a way that
// looks like a hung server rather than an obviously-named error. A short,
// fixed prefix plus os.MkdirTemp's random suffix stays well under that limit
// regardless of the test's own name.
func shortTempDir(t *testing.T, prefix string) string {
	t.Helper()
	dir, err := os.MkdirTemp("", prefix)
	if err != nil {
		t.Fatalf("create temp dir: %v", err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return dir
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	f := &fixture{
		t:         t,
		binDir:    buildBinaries(t),
		stateDir:  shortTempDir(t, "sgt-mcp-state-"),
		scriptDir: shortTempDir(t, "sgt-mcp-script-"),
	}
	t.Cleanup(f.killServerIfAlive)
	return f
}

// killServerIfAlive terminates the server this fixture's clients may have
// started, so a detached shared-server process (by design, outliving any one
// client) never leaks past its owning test.
func (f *fixture) killServerIfAlive() {
	lockPath := mcplock.LockPath(f.stateDir)
	rec, err := mcplock.ReadRecord(lockPath)
	if err != nil || rec == nil {
		return
	}
	_ = syscall.Kill(rec.PID, syscall.SIGKILL)
}

func (f *fixture) writeScript(name, body string) {
	f.t.Helper()
	path := filepath.Join(f.scriptDir, name)
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		f.t.Fatalf("write fake script %s: %v", name, err)
	}
}

// echoScript is a fake sgt-* script whose output deterministically reflects
// both its arguments and its own process identity (pid), so tests can tell
// "two calls got the same tool behavior" apart from "two calls happened to
// return the same static string."
const echoScript = `#!/usr/bin/env bash
echo "echo:$*:pid=$$"
`

func (f *fixture) newClientCmd() *exec.Cmd {
	cmd := exec.Command(filepath.Join(f.binDir, "sergeant-mcp-client"))
	cmd.Env = append(os.Environ(),
		"SERGEANT_STATE_DIR="+f.stateDir,
		"SERGEANT_MCP_SCRIPT_DIR="+f.scriptDir,
		"SERGEANT_MCP_SERVER_PATH="+filepath.Join(f.binDir, "sergeant-mcp"),
	)
	return cmd
}

// clientProc drives one real sergeant-mcp-client subprocess over its stdio.
type clientProc struct {
	t      *testing.T
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	lines  chan string
	stderr *bytesCollector
}

// bytesCollector is a concurrency-safe []byte accumulator for a subprocess's
// stderr, kept only for failure diagnostics.
type bytesCollector struct {
	mu  sync.Mutex
	buf []byte
}

func (c *bytesCollector) Write(p []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.buf = append(c.buf, p...)
	return len(p), nil
}

func (c *bytesCollector) String() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return string(c.buf)
}

func (f *fixture) startClient(t *testing.T) *clientProc {
	t.Helper()
	cmd := f.newClientCmd()
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatalf("client stdin pipe: %v", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatalf("client stdout pipe: %v", err)
	}
	stderr := &bytesCollector{}
	cmd.Stderr = stderr

	if err := cmd.Start(); err != nil {
		t.Fatalf("start client: %v", err)
	}

	cp := &clientProc{t: t, cmd: cmd, stdin: stdin, lines: make(chan string, 64), stderr: stderr}
	go func() {
		scanner := bufio.NewScanner(stdout)
		scanner.Buffer(make([]byte, 0, 64*1024), 1<<20)
		for scanner.Scan() {
			cp.lines <- scanner.Text()
		}
		close(cp.lines)
	}()

	t.Cleanup(cp.stop)
	return cp
}

func (c *clientProc) stop() {
	_ = c.stdin.Close()
	done := make(chan struct{})
	go func() { _ = c.cmd.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		_ = c.cmd.Process.Kill()
		<-done
	}
}

// kill terminates the client process itself (not the shared server), to
// simulate one harness instance crashing.
func (c *clientProc) kill() {
	_ = c.cmd.Process.Kill()
}

func (c *clientProc) writeLine(line string) {
	c.t.Helper()
	if _, err := io.WriteString(c.stdin, line+"\n"); err != nil {
		c.t.Fatalf("write to client stdin: %v (stderr so far: %s)", err, c.stderr.String())
	}
}

// readLine blocks for one stdout line, failing the test if none arrives
// before timeout.
func (c *clientProc) readLine(timeout time.Duration) (string, bool) {
	select {
	case line, ok := <-c.lines:
		return line, ok
	case <-time.After(timeout):
		return "", false
	}
}

// callTool sends one tools/call request and returns its single-line
// response, failing the test if no response arrives within timeout.
func (c *clientProc) callTool(id int, name, argsValue string, timeout time.Duration) string {
	c.t.Helper()
	req := fmt.Sprintf(
		`{"jsonrpc":"2.0","id":%d,"method":"tools/call","params":{"name":%q,"arguments":{"args":%q}}}`,
		id, name, argsValue)
	c.writeLine(req)
	line, ok := c.readLine(timeout)
	if !ok {
		c.t.Fatalf("no response for tools/call id=%d within %s (stderr: %s)", id, timeout, c.stderr.String())
	}
	return line
}

// currentServerPID reads the PID this fixture's live shared server is
// recorded under, failing the test if no live record exists.
func (f *fixture) currentServerPID(t *testing.T) int {
	t.Helper()
	rec, err := mcplock.ReadRecord(mcplock.LockPath(f.stateDir))
	if err != nil || rec == nil {
		t.Fatalf("no lock record for %s (err=%v)", f.stateDir, err)
	}
	if !mcplock.PidAlive(rec.PID) {
		t.Fatalf("lock record names dead pid %d", rec.PID)
	}
	return rec.PID
}

// extractResultText pulls the tool result's rendered text out of a raw
// tools/call JSON-RPC response line, for content assertions without a full
// JSON-RPC/MCP type dependency in the test.
func extractResultText(line string) string {
	// Cheap and sufficient for these fixed-shape fake-script responses:
	// {"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"..."}]}}
	const marker = `"text":"`
	idx := strings.Index(line, marker)
	if idx < 0 {
		return ""
	}
	rest := line[idx+len(marker):]
	end := strings.Index(rest, `"}`)
	if end < 0 {
		return ""
	}
	return rest[:end]
}
