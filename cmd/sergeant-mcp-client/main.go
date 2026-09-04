// cmd/sergeant-mcp-client/main.go — the thin per-instance proxy every
// harness now spawns per mcp.json.
//
// On startup it discovers an already-running shared sergeant-mcp server via
// the PID-recording lock file, or starts one itself if none is live. It then
// proxies this harness instance's stdio JSON-RPC frames to that server over
// a Unix socket, buffering and replaying calls across a server restart. See
// openspec/changes/shared-mcp-server.
//
// The binary must live in the same directory as sergeant-mcp (bin/) so it
// can find the server binary to start. Build with:
//
//	go build -o bin/sergeant-mcp-client ./cmd/sergeant-mcp-client/
package main

import (
	"bytes"
	"context"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"

	"github.com/callmeradical/sergeant/internal/mcplock"
)

// connectPollInterval/connectPollTimeout bound how long a freshly started
// server is given to create its socket before this client gives up on that
// particular start attempt (sendLoop's reconnect loop simply tries again).
const (
	connectPollInterval = 25 * time.Millisecond
	connectPollTimeout  = 5 * time.Second
	requestURL          = "http://sergeant-mcp.local/mcp"
)

var version = "dev"

func main() {
	if len(os.Args) > 1 && (os.Args[1] == "--version" || os.Args[1] == "-v") {
		fmt.Println("sergeant-mcp-client version", version)
		os.Exit(0)
	}

	stateDir := mcplock.StateDir()
	lockPath := mcplock.LockPath(stateDir)

	sockPath, err := discoverOrStart(stateDir, lockPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "sergeant-mcp-client: fatal: %v\n", err)
		os.Exit(1)
	}

	p := newProxy(stateDir, lockPath, sockPath)
	p.stdout = os.Stdout
	p.client = httpClientFor(sockPath)
	p.run(os.Stdin)
}

// liveSocket reads the lock file and returns its socket path only if the
// record names a live PID and that socket actually exists yet -- AcquireServerLock
// publishes the lock record before the winning process finishes its own
// net.Listen, so a live PID alone can momentarily name a socket nothing is
// listening on yet.
func liveSocket(lockPath string) (string, bool) {
	rec, err := mcplock.ReadRecord(lockPath)
	if err != nil || rec == nil || !mcplock.PidAlive(rec.PID) {
		return "", false
	}
	if _, statErr := os.Stat(rec.Socket); statErr != nil {
		return "", false
	}
	return rec.Socket, true
}

// discoverOrStart implements design.md's discovery dance: connect to an
// already-live server named by the lock file, or become the one that starts
// it. Both this function and the racing os.Link inside AcquireServerLock are
// what resolve two clients starting at the same moment to exactly one
// server.
func discoverOrStart(stateDir, lockPath string) (string, error) {
	if sockPath, ok := liveSocket(lockPath); ok {
		return sockPath, nil
	}
	return startServer(stateDir, lockPath)
}

// startServer execs the server binary detached in the background, then polls
// the lock file (which the server, or whichever of two racing server starts
// actually won AcquireServerLock, publishes) until a live socket appears.
func startServer(stateDir, lockPath string) (string, error) {
	serverPath, err := serverExecutablePath()
	if err != nil {
		return "", err
	}

	devnull, err := os.OpenFile(os.DevNull, os.O_RDWR, 0)
	if err != nil {
		return "", fmt.Errorf("cannot open %s: %w", os.DevNull, err)
	}
	defer devnull.Close()

	// Double-fork via a short-lived shell: backgrounding inside `sh -c`
	// orphans the exec'd server the moment this shell exits, reparenting it
	// to init/launchd instead of leaving it a direct child of this client.
	// A server left as this client's direct child would become a zombie the
	// instant it died (Setsid detaches the session/process group, but not
	// parentage) -- and a zombie's PID still answers the standard
	// syscall.Kill(pid, 0) liveness probe as "alive" until its parent reaps
	// it, which this client never does. That silently defeats every later
	// liveness check (mcplock.PidAlive) this design depends on: a killed
	// server would look alive forever, and no client would ever start a
	// replacement.
	cmd := exec.Command("/bin/sh", "-c", `exec "$0" --serve &`, serverPath)
	cmd.Stdin = devnull
	cmd.Stdout = devnull
	cmd.Stderr = devnull
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("cannot start shared server %s: %w", serverPath, err)
	}

	deadline := time.Now().Add(connectPollTimeout)
	for time.Now().Before(deadline) {
		if sockPath, ok := liveSocket(lockPath); ok {
			return sockPath, nil
		}
		time.Sleep(connectPollInterval)
	}
	return "", fmt.Errorf("timed out waiting for shared server to start (lock=%s)", lockPath)
}

// resolveServerExecutablePath memoizes the expensive syscalls (os.Executable,
// EvalSymlinks) needed to find the sibling sergeant-mcp binary.
var resolveServerExecutablePath = sync.OnceValues(func() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", fmt.Errorf("cannot resolve own executable path: %w", err)
	}
	resolved, err := filepath.EvalSymlinks(exe)
	if err != nil {
		resolved = exe
	}
	return filepath.Join(filepath.Dir(resolved), "sergeant-mcp"), nil
})

// serverExecutablePath locates the sibling sergeant-mcp binary next to this
// client binary, the same convention cmd/sergeant-mcp's own scriptDir() uses
// for the bin/sgt-* scripts. SERGEANT_MCP_SERVER_PATH overrides it for tests.
func serverExecutablePath() (string, error) {
	if p := os.Getenv("SERGEANT_MCP_SERVER_PATH"); p != "" {
		return p, nil
	}
	return resolveServerExecutablePath()
}

// httpClientFor returns an *http.Client whose transport always dials
// sockPath over a Unix socket, regardless of the request URL's host --
// requestURL is a fixed placeholder host purely to satisfy net/http's URL
// parser.
func httpClientFor(sockPath string) *http.Client {
	return &http.Client{
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				return (&net.Dialer{}).DialContext(ctx, "unix", sockPath)
			},
		},
	}
}

// sendOverSocket is the real (non-test) implementation of proxy.send: one
// POST per JSON-RPC line against this proxy's current backend connection.
func (p *proxy) sendOverSocket(line string) (*response, error) {
	p.mu.Lock()
	client := p.client
	p.mu.Unlock()

	req, err := http.NewRequest(http.MethodPost, requestURL, bytes.NewReader([]byte(line)))
	if err != nil {
		return nil, fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json, text/event-stream")

	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var body bytes.Buffer
	if _, err := body.ReadFrom(resp.Body); err != nil {
		return nil, fmt.Errorf("read response: %w", err)
	}
	return &response{
		status:      resp.StatusCode,
		contentType: resp.Header.Get("Content-Type"),
		body:        body.Bytes(),
	}, nil
}

// reconnectToSharedServer is the real (non-test) implementation of
// proxy.reconnect: re-run discovery-or-start and swap in a client for
// whichever socket wins.
func (p *proxy) reconnectToSharedServer() bool {
	sockPath, err := discoverOrStart(p.stateDir, p.lockPath)
	if err != nil {
		return false
	}
	p.mu.Lock()
	p.sockPath = sockPath
	p.client = httpClientFor(sockPath)
	p.mu.Unlock()
	return true
}
