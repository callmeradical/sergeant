package ui

// Coverage for specs/embedded-terminal/spec.md. Per design.md's "Rejected
// alternatives" these spawn real shell PTYs and drive them through the real
// WebSocket upgrade path rather than mocking terminalManager — a real
// process is cheap here and is the actual mechanism this feature needs
// verified.

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/callmeradical/sergeant/internal/store"
)

func newTerminalTestServer(t *testing.T) (*Server, *httptest.Server) {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatalf("opening store: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })

	srv := NewServer(st, 0)
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	return srv, ts
}

// startTerminal calls POST /api/terminal-start and decodes the response.
func startTerminal(t *testing.T, ts *httptest.Server, body string) map[string]interface{} {
	t.Helper()
	resp, err := http.Post(ts.URL+"/api/terminal-start", "application/json", strings.NewReader(body))
	if err != nil {
		t.Fatalf("POST /api/terminal-start: %v", err)
	}
	defer resp.Body.Close()

	var out map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decoding /api/terminal-start response: %v", err)
	}
	out["__status"] = resp.StatusCode
	return out
}

// wsFrame is one message read from a termClient's background reader.
type wsFrame struct {
	mt   int
	data []byte
	err  error
}

// termClient wraps a WebSocket connection with a background goroutine that
// continuously calls ReadMessage and forwards frames over a channel. Gorilla
// websocket connections cannot tolerate a SetReadDeadline timeout followed by
// another ReadMessage call — the connection is considered broken after the
// first deadline trip — so tests select on this channel with their own
// timeout instead of looping ReadMessage with per-call deadlines.
type termClient struct {
	conn   *websocket.Conn
	frames chan wsFrame
}

func (c *termClient) writeBinary(t *testing.T, data []byte) {
	t.Helper()
	if err := c.conn.WriteMessage(websocket.BinaryMessage, data); err != nil {
		t.Fatalf("writing binary frame: %v", err)
	}
}

func (c *termClient) writeText(t *testing.T, data []byte) {
	t.Helper()
	if err := c.conn.WriteMessage(websocket.TextMessage, data); err != nil {
		t.Fatalf("writing text frame: %v", err)
	}
}

// readUntil consumes frames until accumulated binary data contains want, a
// text frame arrives (returned in textFrames), or timeout elapses.
func (c *termClient) readUntil(want string, timeout time.Duration) (data string, textFrames []string) {
	deadline := time.After(timeout)
	for {
		select {
		case f, ok := <-c.frames:
			if !ok {
				return data, textFrames
			}
			if f.err != nil {
				return data, textFrames
			}
			switch f.mt {
			case websocket.BinaryMessage:
				data += string(f.data)
			case websocket.TextMessage:
				textFrames = append(textFrames, string(f.data))
				return data, textFrames
			}
			if want != "" && strings.Contains(data, want) {
				return data, textFrames
			}
		case <-deadline:
			return data, textFrames
		}
	}
}

// waitClosed reports whether the connection's reader observed a close
// (channel closed with a final error) within timeout.
func (c *termClient) waitClosed(timeout time.Duration) bool {
	deadline := time.After(timeout)
	for {
		select {
		case f, ok := <-c.frames:
			if !ok || f.err != nil {
				return true
			}
		case <-deadline:
			return false
		}
	}
}

// dialTerminalSocket opens the real WebSocket upgrade for a started session.
func dialTerminalSocket(t *testing.T, ts *httptest.Server, id string) *termClient {
	t.Helper()
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/api/terminal-socket?id=" + id
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("dialing terminal socket for %q: %v", id, err)
	}
	t.Cleanup(func() { _ = conn.Close() })

	frames := make(chan wsFrame, 64)
	go func() {
		for {
			mt, data, err := conn.ReadMessage()
			frames <- wsFrame{mt: mt, data: data, err: err}
			if err != nil {
				close(frames)
				return
			}
		}
	}()

	return &termClient{conn: conn, frames: frames}
}

func liveProcess(pid int) bool {
	return syscall.Kill(pid, 0) == nil
}

// Scenario: "Starting a session spawns a real process and returns its
// identity."
func TestStartingASessionSpawnsARealProcessAndReturnsItsIdentity(t *testing.T) {
	srv, ts := newTerminalTestServer(t)

	resp := startTerminal(t, ts, `{}`)
	t.Cleanup(func() { _ = srv.terminal.Kill(fmt.Sprint(resp["id"])) })

	if resp["__status"] != http.StatusOK {
		t.Fatalf("status = %v, want 200; body=%+v", resp["__status"], resp)
	}
	id, _ := resp["id"].(string)
	if id == "" {
		t.Fatal("response has no session id")
	}
	pidF, ok := resp["pid"].(float64)
	if !ok || pidF <= 0 {
		t.Fatalf("response pid = %v, want a positive process id", resp["pid"])
	}
	if shell, _ := resp["shell"].(string); shell == "" {
		t.Error("response has no resolved shell path")
	}

	if !liveProcess(int(pidF)) {
		t.Errorf("pid %d is not a live process on the host", int(pidF))
	}
}

// Scenario: "A client can send input and receive the shell's real output."
// This is the one scenario that must exercise the actual WebSocket upgrade
// path end-to-end, not call terminalManager methods directly.
func TestClientCanSendInputAndReceiveTheShellsRealOutput(t *testing.T) {
	srv, ts := newTerminalTestServer(t)

	resp := startTerminal(t, ts, `{}`)
	id := fmt.Sprint(resp["id"])
	t.Cleanup(func() { _ = srv.terminal.Kill(id) })

	client := dialTerminalSocket(t, ts, id)
	client.writeBinary(t, []byte("echo hello\n"))

	data, _ := client.readUntil("hello", 5*time.Second)
	if !strings.Contains(data, "hello") {
		t.Fatalf("output did not contain %q; got %q", "hello", data)
	}
}

// Scenario: "Input to one session does not appear in another."
func TestInputToOneSessionDoesNotAppearInAnother(t *testing.T) {
	srv, ts := newTerminalTestServer(t)

	respA := startTerminal(t, ts, `{}`)
	idA := fmt.Sprint(respA["id"])
	t.Cleanup(func() { _ = srv.terminal.Kill(idA) })

	respB := startTerminal(t, ts, `{}`)
	idB := fmt.Sprint(respB["id"])
	t.Cleanup(func() { _ = srv.terminal.Kill(idB) })

	clientA := dialTerminalSocket(t, ts, idA)
	clientB := dialTerminalSocket(t, ts, idB)

	marker := "only-in-session-a-98765"
	clientA.writeBinary(t, []byte("echo "+marker+"\n"))

	dataA, _ := clientA.readUntil(marker, 5*time.Second)
	if !strings.Contains(dataA, marker) {
		t.Fatalf("session A did not see its own output; got %q", dataA)
	}

	// Give session B's socket the same wall-clock window to have received
	// anything, then confirm it saw nothing session A produced.
	dataB, _ := clientB.readUntil("", 500*time.Millisecond)
	if strings.Contains(dataB, marker) {
		t.Fatalf("session B received session A's output: %q", dataB)
	}
}

// Scenario: "An explicit kill request terminates the underlying process."
func TestAnExplicitKillRequestTerminatesTheUnderlyingProcess(t *testing.T) {
	srv, ts := newTerminalTestServer(t)

	resp := startTerminal(t, ts, `{}`)
	id := fmt.Sprint(resp["id"])
	pid := int(resp["pid"].(float64))

	killResp, err := http.Post(ts.URL+"/api/terminal-kill", "application/json", strings.NewReader(fmt.Sprintf(`{"id":%q}`, id)))
	if err != nil {
		t.Fatalf("POST /api/terminal-kill: %v", err)
	}
	defer killResp.Body.Close()
	if killResp.StatusCode != http.StatusOK {
		t.Fatalf("kill status = %d, want 200", killResp.StatusCode)
	}

	deadline := time.Now().Add(3 * time.Second)
	for liveProcess(pid) && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if liveProcess(pid) {
		t.Errorf("pid %d is still running after an explicit kill request", pid)
	}

	if _, ok := srv.terminal.Get(id); ok {
		t.Error("killed session is still known to terminalManager")
	}
}

// Scenario: "Killing an unknown or already-dead session is not an error."
func TestKillingAnUnknownOrAlreadyDeadSessionIsNotAnError(t *testing.T) {
	_, ts := newTerminalTestServer(t)

	resp, err := http.Post(ts.URL+"/api/terminal-kill", "application/json", strings.NewReader(`{"id":"term-never-existed"}`))
	if err != nil {
		t.Fatalf("POST /api/terminal-kill: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200 for an unknown id", resp.StatusCode)
	}

	var out map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decoding response: %v", err)
	}
	if ok, _ := out["ok"].(bool); !ok {
		t.Errorf("response = %+v, want ok=true", out)
	}
}

// Scenario: "A process that exits on its own is reported before the socket
// closes."
func TestAProcessThatExitsOnItsOwnIsReportedBeforeTheSocketCloses(t *testing.T) {
	srv, ts := newTerminalTestServer(t)

	resp := startTerminal(t, ts, `{}`)
	id := fmt.Sprint(resp["id"])
	t.Cleanup(func() { _ = srv.terminal.Kill(id) })

	client := dialTerminalSocket(t, ts, id)
	client.writeBinary(t, []byte("exit\n"))

	_, textFrames := client.readUntil("", 5*time.Second)

	var gotExitFrame bool
	for _, tf := range textFrames {
		var frame struct {
			Type string `json:"type"`
		}
		if json.Unmarshal([]byte(tf), &frame) == nil && frame.Type == "exit" {
			gotExitFrame = true
		}
	}
	if !gotExitFrame {
		t.Fatalf("did not receive an exit text frame before the socket closed; text frames = %v", textFrames)
	}

	// The exit frame must arrive before the close: the connection's reader
	// must observe the socket closing shortly after.
	if !client.waitClosed(2 * time.Second) {
		t.Error("socket is still open after the exit frame; expected it closed")
	}
}

// Scenario: "Starting a session with a bullet id sets its working directory."
func TestStartingASessionWithABulletIDSetsItsWorkingDirectory(t *testing.T) {
	srv, ts := newTerminalTestServer(t)

	worktree := t.TempDir()
	if err := srv.Store.CreateIntent(&store.IntentRecord{
		ID: "intent-term-1", Project: "o3", Statement: "s", Status: "approved",
	}); err != nil {
		t.Fatalf("creating intent: %v", err)
	}
	if err := srv.Store.CreateBullet(&store.BulletRecord{
		ID: "bullet-term-1", IntentID: "intent-term-1", Repo: "api", Position: 1,
		Status: "pending", Worktree: worktree,
	}); err != nil {
		t.Fatalf("creating bullet: %v", err)
	}

	resp := startTerminal(t, ts, `{"bullet_id":"bullet-term-1"}`)
	t.Cleanup(func() { _ = srv.terminal.Kill(fmt.Sprint(resp["id"])) })

	if resp["__status"] != http.StatusOK {
		t.Fatalf("status = %v, want 200; body=%+v", resp["__status"], resp)
	}
	if cwd, _ := resp["cwd"].(string); cwd != worktree {
		t.Errorf("response cwd = %q, want %q", cwd, worktree)
	}

	sess, ok := srv.terminal.Get(fmt.Sprint(resp["id"]))
	if !ok {
		t.Fatal("session not found in terminalManager")
	}
	if sess.cwd != worktree {
		t.Errorf("session cwd = %q, want %q", sess.cwd, worktree)
	}
}

// Scenario: "An explicit cwd and a bullet id are mutually exclusive."
func TestAnExplicitCwdAndABulletIDAreMutuallyExclusive(t *testing.T) {
	_, ts := newTerminalTestServer(t)

	resp, err := http.Post(ts.URL+"/api/terminal-start", "application/json",
		strings.NewReader(`{"cwd":"/tmp","bullet_id":"bullet-term-1"}`))
	if err != nil {
		t.Fatalf("POST /api/terminal-start: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400 when cwd and bullet_id are both set", resp.StatusCode)
	}
}

// Scenario: "A resize control message changes the PTY's window size."
func TestAResizeControlMessageChangesThePTYsWindowSize(t *testing.T) {
	srv, ts := newTerminalTestServer(t)

	resp := startTerminal(t, ts, `{}`)
	id := fmt.Sprint(resp["id"])
	t.Cleanup(func() { _ = srv.terminal.Kill(id) })

	client := dialTerminalSocket(t, ts, id)

	resizeMsg, _ := json.Marshal(map[string]interface{}{"type": "resize", "cols": 100, "rows": 40})
	client.writeText(t, resizeMsg)

	// Give the resize a moment to apply before a program queries it —
	// pty.Setsize is synchronous, but the shell's own read loop needs a
	// beat to have processed the resize before running the query command.
	time.Sleep(100 * time.Millisecond)

	client.writeBinary(t, []byte("stty size\n"))

	data, _ := client.readUntil("40 100", 5*time.Second)
	if !strings.Contains(data, "40 100") {
		t.Fatalf("stty size did not report the resized dimensions; got %q", data)
	}
}

// Scenario: "The server does not bind beyond loopback for the new routes."
// design.md is explicit that this is a property of Start()'s existing
// address string, not new enforcement: this test inspects that literal
// rather than inventing a second binding mechanism to exercise.
func TestServerDoesNotBindBeyondLoopbackForTerminalRoutes(t *testing.T) {
	src, err := os.ReadFile("server.go")
	if err != nil {
		t.Fatalf("reading server.go: %v", err)
	}
	if !strings.Contains(string(src), `fmt.Sprintf("127.0.0.1:%d", srv.Port)`) {
		t.Fatal("Start() no longer binds its listen address to 127.0.0.1; the terminal routes registered in Handler() would become reachable beyond loopback")
	}
}
