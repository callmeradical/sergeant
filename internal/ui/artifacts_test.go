package ui

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/callmeradical/sergeant/internal/handoff"
	"github.com/callmeradical/sergeant/internal/runner"
	"github.com/callmeradical/sergeant/internal/store"

	_ "modernc.org/sqlite"
)

// artifactsFixture opens a store for a test, same shape as cleanupFixture but
// without the fleet-dir env override this file's tests don't need.
func artifactsFixture(t *testing.T) (*Server, *store.Store) {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	return NewServer(st, 0), st
}

// TestHandleListArtifactsReturnsCapturedArtifacts covers the API substrate
// for spec.md's "A run with captured artifacts shows them beneath its
// workflow graph": GET /api/artifacts?run_id=<id> answers the run's captured
// artifacts.
func TestHandleListArtifactsReturnsCapturedArtifacts(t *testing.T) {
	srv, st := artifactsFixture(t)
	mux := srv.Handler()

	if err := st.RecordArtifact(&store.ArtifactRecord{
		ID: "art-1", RunID: "run-1", PhaseID: "phase-1", Repo: "svc",
		Filename: "shot.png", ContentType: "image/png", SizeBytes: 5,
		Path: "/tmp/does-not-matter.png", CapturedAt: time.Now().UTC(),
	}); err != nil {
		t.Fatal(err)
	}

	w := httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest("GET", "/api/artifacts?run_id=run-1", nil))
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", w.Code, w.Body.String())
	}

	var got []store.ArtifactRecord
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatalf("decoding response %s: %v", w.Body.String(), err)
	}
	if len(got) != 1 || got[0].ID != "art-1" || got[0].Filename != "shot.png" {
		t.Fatalf("got %+v, want the one recorded artifact", got)
	}
}

// TestHandleListArtifactsRequiresRunID mirrors handleDeliveryHistory's own
// guard: an empty result for a missing run_id must not be indistinguishable
// from "this run truly has no artifacts".
func TestHandleListArtifactsRequiresRunID(t *testing.T) {
	srv, _ := artifactsFixture(t)
	mux := srv.Handler()

	w := httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest("GET", "/api/artifacts", nil))
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", w.Code)
	}
}

// TestHandleListArtifactsEmptyForRunWithNone covers spec.md's "A run with no
// artifacts shows no artifacts section": the API's half of that is an empty
// array, not an error and not null.
func TestHandleListArtifactsEmptyForRunWithNone(t *testing.T) {
	srv, _ := artifactsFixture(t)
	mux := srv.Handler()

	w := httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest("GET", "/api/artifacts?run_id=no-such-run", nil))
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", w.Code, w.Body.String())
	}
	if w.Body.String() != "[]" {
		t.Errorf("body = %q, want an empty JSON array, not null", w.Body.String())
	}
}

// TestHandleArtifactContentServesBytesWithRecordedContentType covers
// spec.md's requirement that a recorded artifact is readable back with its
// content type and size — the content route's whole job.
func TestHandleArtifactContentServesBytesWithRecordedContentType(t *testing.T) {
	srv, st := artifactsFixture(t)
	mux := srv.Handler()

	filePath := filepath.Join(t.TempDir(), "shot.png")
	if err := os.WriteFile(filePath, []byte("fake-png-bytes"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := st.RecordArtifact(&store.ArtifactRecord{
		ID: "art-2", RunID: "run-1", PhaseID: "phase-1", Repo: "svc",
		Filename: "shot.png", ContentType: "image/png", SizeBytes: 14,
		Path: filePath, CapturedAt: time.Now().UTC(),
	}); err != nil {
		t.Fatal(err)
	}

	w := httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest("GET", "/api/artifacts/art-2/content", nil))
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", w.Code, w.Body.String())
	}
	if ct := w.Header().Get("Content-Type"); ct != "image/png" {
		t.Errorf("Content-Type = %q, want image/png", ct)
	}
	if w.Body.String() != "fake-png-bytes" {
		t.Errorf("body = %q, want the artifact's real bytes", w.Body.String())
	}
}

// TestHandleArtifactContentReturns404ForUnknownID covers spec.md's
// requirement that an id sergeant does not recognise 404s.
func TestHandleArtifactContentReturns404ForUnknownID(t *testing.T) {
	srv, _ := artifactsFixture(t)
	mux := srv.Handler()

	w := httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest("GET", "/api/artifacts/no-such-id/content", nil))
	if w.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", w.Code)
	}
}

// TestArtifactCapturedByRealGateIsServedAsAnImage is the end-to-end check
// tasks.md's Task 2 verification asks for: a gate that writes a PNG to
// $SERGEANT_ARTIFACT_DIR is captured by the real mechanism (RunCodeGate ->
// captureArtifacts), then served back through the real HTTP routes with an
// image/* content type — exactly what the dashboard's artifactItemHTML
// switches on to decide whether to render a thumbnail. This repo has no
// scripted frontend test suite (per the embedded-terminal change's own
// precedent), so the rendering itself is verified manually per the PR
// description; this test verifies every real, non-DOM step feeding it.
func TestArtifactCapturedByRealGateIsServedAsAnImage(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	t.Setenv("SERGEANT_ARTIFACTS_ROOT", t.TempDir())

	const runID = "run-real-capture"
	if err := st.CreateRun(&store.RunRecord{ID: runID, Project: "p", TaskID: runID, Status: "running"}); err != nil {
		t.Fatal(err)
	}

	pr := &runner.PhaseRunner{
		Store:    st,
		Router:   handoff.NewRouter(t.TempDir()),
		Worktree: t.TempDir(),
		RepoName: "svc",
		RunID:    runID,
	}
	pngBytes := "\x89PNG\r\n\x1a\nfake-but-real-enough"
	res, err := pr.RunCodeGate(context.Background(), "screenshot-gate",
		`printf '`+pngBytes+`' > "$SERGEANT_ARTIFACT_DIR/shot.png"`)
	if err != nil {
		t.Fatalf("RunCodeGate: %v", err)
	}
	if !res.Passed {
		t.Fatalf("expected gate to pass, output: %s", res.Output)
	}

	mux := NewServer(st, 0).Handler()

	w := httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest("GET", "/api/artifacts?run_id="+runID, nil))
	if w.Code != http.StatusOK {
		t.Fatalf("list status = %d, want 200; body=%s", w.Code, w.Body.String())
	}
	var got []store.ArtifactRecord
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatalf("decoding %s: %v", w.Body.String(), err)
	}
	if len(got) != 1 {
		t.Fatalf("expected 1 captured artifact, got %d: %+v", len(got), got)
	}
	if !strings.HasPrefix(got[0].ContentType, "image/") {
		t.Fatalf("content_type = %q, want an image/* type so the dashboard renders a thumbnail", got[0].ContentType)
	}

	cw := httptest.NewRecorder()
	mux.ServeHTTP(cw, httptest.NewRequest("GET", "/api/artifacts/"+got[0].ID+"/content", nil))
	if cw.Code != http.StatusOK {
		t.Fatalf("content status = %d, want 200", cw.Code)
	}
	if cw.Header().Get("Content-Type") != got[0].ContentType {
		t.Errorf("served Content-Type = %q, want %q", cw.Header().Get("Content-Type"), got[0].ContentType)
	}
	if cw.Body.String() != pngBytes {
		t.Errorf("served bytes = %q, want the file the gate actually wrote", cw.Body.String())
	}
}

// TestHandleArtifactContentReturns404WhenFileIsGone covers the case
// design.md names explicitly: an artifact past its retention horizon (per
// the separate data-retention-and-rotation change) still has a metadata row,
// but its file is gone. The content route must 404, not 500.
func TestHandleArtifactContentReturns404WhenFileIsGone(t *testing.T) {
	srv, st := artifactsFixture(t)
	mux := srv.Handler()

	if err := st.RecordArtifact(&store.ArtifactRecord{
		ID: "art-3", RunID: "run-1", PhaseID: "phase-1", Repo: "svc",
		Filename: "gone.png", ContentType: "image/png", SizeBytes: 3,
		Path: filepath.Join(t.TempDir(), "already-deleted.png"), CapturedAt: time.Now().UTC(),
	}); err != nil {
		t.Fatal(err)
	}

	w := httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest("GET", "/api/artifacts/art-3/content", nil))
	if w.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404; body=%s", w.Code, w.Body.String())
	}
}
