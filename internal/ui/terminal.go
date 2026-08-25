package ui

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"sync"
	"sync/atomic"

	"github.com/creack/pty"
	"github.com/gorilla/websocket"
)

// terminalSession is one real, PTY-attached shell process. killed is set by
// terminalManager.Kill before it tears the process down, so the socket
// handler's own exit-detection (which also observes the PTY closing) can
// tell "the operator asked for this" apart from "the process exited on its
// own" — only the latter gets an exit frame (design.md's frame protocol).
type terminalSession struct {
	id     string
	pty    *os.File
	cmd    *exec.Cmd
	pid    int
	shell  string
	cwd    string
	killed atomic.Bool
}

// terminalManager owns every live terminal session. Mirrors the
// fleetCleaner/deliveryReporter pattern: PTY lifecycle lives in its own type
// rather than as bare fields on Server.
type terminalManager struct {
	mu       sync.Mutex
	sessions map[string]*terminalSession
	nextID   int
}

func newTerminalManager() *terminalManager {
	return &terminalManager{sessions: map[string]*terminalSession{}}
}

// Start spawns a real shell PTY with the given size and working directory.
// An empty cwd leaves cmd.Dir unset, which os/exec already treats as "the
// sergeant process's own working directory". cols/rows default to 80/24 when
// zero, matching the frontend's full-size fallback before its first resize.
func (m *terminalManager) Start(cwd string, cols, rows int) (*terminalSession, error) {
	if cols <= 0 {
		cols = 80
	}
	if rows <= 0 {
		rows = 24
	}

	shell := os.Getenv("SHELL")
	if shell == "" {
		shell = "/bin/zsh"
	}

	cmd := exec.Command(shell)
	cmd.Dir = cwd
	cmd.Env = append(os.Environ(), "TERM=xterm-256color", "COLORTERM=truecolor")

	f, err := pty.StartWithSize(cmd, &pty.Winsize{Rows: uint16(rows), Cols: uint16(cols)})
	if err != nil {
		return nil, err
	}

	m.mu.Lock()
	m.nextID++
	sess := &terminalSession{
		id:    fmt.Sprintf("term-%d", m.nextID),
		pty:   f,
		cmd:   cmd,
		pid:   cmd.Process.Pid,
		shell: shell,
		cwd:   cwd,
	}
	m.sessions[sess.id] = sess
	m.mu.Unlock()

	return sess, nil
}

// Write forwards raw bytes to the session's PTY (the operator's keystrokes).
func (m *terminalManager) Write(id string, data []byte) error {
	sess, ok := m.Get(id)
	if !ok {
		return fmt.Errorf("unknown terminal session %q", id)
	}
	_, err := sess.pty.Write(data)
	return err
}

// Resize updates the PTY's real window size.
func (m *terminalManager) Resize(id string, cols, rows int) error {
	sess, ok := m.Get(id)
	if !ok {
		return fmt.Errorf("unknown terminal session %q", id)
	}
	return pty.Setsize(sess.pty, &pty.Winsize{Rows: uint16(rows), Cols: uint16(cols)})
}

// Kill terminates the session's process and removes it from the map. Safe to
// call on an already-exited or unknown session — a no-op, not an error,
// matching this project's existing "deleting an unknown run is not an error"
// precedent.
func (m *terminalManager) Kill(id string) error {
	m.mu.Lock()
	sess, ok := m.sessions[id]
	delete(m.sessions, id)
	m.mu.Unlock()
	if !ok {
		return nil
	}

	sess.killed.Store(true)
	if sess.cmd.Process != nil {
		_ = sess.cmd.Process.Kill()
	}
	_ = sess.pty.Close()
	// Reap the process so it does not linger as a zombie: kill(pid, 0)
	// still reports success against zombies, and no socket read loop will
	// call Wait for a session that killed.Load() found true (it returns
	// immediately instead), so this is the one call site left to reap it.
	go func() { _ = sess.cmd.Wait() }()
	return nil
}

// Get returns the session for id, or (nil, false).
func (m *terminalManager) Get(id string) (*terminalSession, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	sess, ok := m.sessions[id]
	return sess, ok
}

// remove drops a session that the socket handler discovered had exited on
// its own (as opposed to Kill, which removes the session itself).
func (m *terminalManager) remove(id string) {
	m.mu.Lock()
	delete(m.sessions, id)
	m.mu.Unlock()
}

func (srv *Server) handleTerminalStart(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		Cwd      string `json:"cwd"`
		BulletID string `json:"bullet_id"`
		Cols     int    `json:"cols"`
		Rows     int    `json:"rows"`
	}
	if r.Body != nil {
		_ = json.NewDecoder(r.Body).Decode(&req)
	}

	if req.Cwd != "" && req.BulletID != "" {
		http.Error(w, "cwd and bullet_id are mutually exclusive", http.StatusBadRequest)
		return
	}

	cwd := req.Cwd
	if req.BulletID != "" {
		bullet, err := srv.Store.GetBullet(req.BulletID)
		if err != nil {
			http.Error(w, fmt.Sprintf("bullet %q not found: %v", req.BulletID, err), http.StatusBadRequest)
			return
		}
		cwd = bullet.Worktree
	}

	sess, err := srv.terminal.Start(cwd, req.Cols, req.Rows)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"id":    sess.id,
		"pid":   sess.pid,
		"shell": sess.shell,
		"cwd":   sess.cwd,
	})
}

func (srv *Server) handleTerminalKill(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		ID string `json:"id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.ID == "" {
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}

	// Kill is already a no-op on an unknown or dead id, so this is
	// unconditionally reported as success (design.md's idempotent-kill
	// contract).
	_ = srv.terminal.Kill(req.ID)
	writeJSON(w, http.StatusOK, map[string]interface{}{"ok": true})
}

var terminalUpgrader = websocket.Upgrader{
	ReadBufferSize:  4096,
	WriteBufferSize: 4096,
	// No new auth model: the dashboard already binds to 127.0.0.1 only
	// (proposal.md), and any browser tab able to reach this origin already
	// has the same trust as every other unrestricted local API this
	// dashboard serves.
	CheckOrigin: func(r *http.Request) bool { return true },
}

// handleTerminalSocket upgrades to a WebSocket scoped to exactly one
// session and pumps bytes in both directions until the client disconnects or
// the underlying process exits. See design.md's "Routes" section for the
// exact frame protocol.
func (srv *Server) handleTerminalSocket(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("id")
	sess, ok := srv.terminal.Get(id)
	if !ok {
		http.Error(w, "unknown terminal session", http.StatusNotFound)
		return
	}

	conn, err := terminalUpgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	var closeOnce sync.Once
	closeConn := func() { closeOnce.Do(func() { _ = conn.Close() }) }
	defer closeConn()

	var doneOnce sync.Once
	done := make(chan struct{})
	notifyDone := func() { doneOnce.Do(func() { close(done) }) }

	// client -> pty: keystrokes/paste as binary frames, a resize control
	// message as a text frame.
	go func() {
		defer notifyDone()
		for {
			mt, data, err := conn.ReadMessage()
			if err != nil {
				return
			}
			switch mt {
			case websocket.BinaryMessage:
				_, _ = sess.pty.Write(data)
			case websocket.TextMessage:
				var msg struct {
					Type string `json:"type"`
					Cols int    `json:"cols"`
					Rows int    `json:"rows"`
				}
				if json.Unmarshal(data, &msg) == nil && msg.Type == "resize" && msg.Cols > 0 && msg.Rows > 0 {
					_ = pty.Setsize(sess.pty, &pty.Winsize{Rows: uint16(msg.Rows), Cols: uint16(msg.Cols)})
				}
			}
		}
	}()

	// pty -> client: terminal output as binary frames. When the read loop
	// ends because the process itself exited (not because Kill closed the
	// PTY out from under it), send the exit frame the frontend's
	// launchpad-equivalent pty:exit event needs before the socket closes.
	go func() {
		defer notifyDone()
		buf := make([]byte, 4096)
		for {
			n, readErr := sess.pty.Read(buf)
			if n > 0 {
				if wErr := conn.WriteMessage(websocket.BinaryMessage, buf[:n]); wErr != nil {
					return
				}
			}
			if readErr != nil {
				break
			}
		}
		if sess.killed.Load() {
			return
		}
		_ = sess.cmd.Wait()
		code := 0
		if sess.cmd.ProcessState != nil {
			code = sess.cmd.ProcessState.ExitCode()
		}
		payload, _ := json.Marshal(map[string]interface{}{"type": "exit", "code": code})
		_ = conn.WriteMessage(websocket.TextMessage, payload)
		srv.terminal.remove(id)
	}()

	<-done
	closeConn()
}
