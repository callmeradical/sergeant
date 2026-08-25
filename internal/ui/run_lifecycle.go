package ui

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"path/filepath"
	"strings"

	"github.com/callmeradical/sergeant/internal/config"
	"github.com/callmeradical/sergeant/internal/dag"
	"github.com/callmeradical/sergeant/internal/handoff"
)

func (srv *Server) handleRunCancel(w http.ResponseWriter, r *http.Request) {
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

	// Actually stop the work, then record it. Previously this only wrote the status
	// column, which the still-running dispatch goroutine later overwrote with
	// "passed" while its agents kept writing to disk.
	stopped := srv.cancelRun(req.ID)

	if err := srv.Store.UpdateRunStatus(req.ID, "cancelled"); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"status":      "cancelled",
		"id":          req.ID,
		"was_running": stopped,
		"note":        cancelNote(stopped),
	})
}

func (srv *Server) handleRunDelete(w http.ResponseWriter, r *http.Request) {
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

	if err := srv.Store.DeleteRun(req.ID); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "deleted", "id": req.ID})
}

// handleRunResume re-enters an existing run instead of starting a new one.
//
// A run that dies leaves its worktree, its branch and its commits on disk, and
// before this there was no way to pick any of it up — the work was orphaned and
// the only recovery was a human merging the branch by hand. Run sgt-1787427981
// was killed at the former default agent timeout having already committed a
// change whose build and tests passed.
//
// Resume reuses the run id, so it reuses the worktree and branch (prepareWorktree
// returns an existing worktree untouched and no longer resets the branch), and
// skips phases that already hold a passed record. The run record is reused rather
// than copied: a second row would split one piece of work across two runs and two
// branches.
func (srv *Server) handleRunResume(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		ID string `json:"id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || strings.TrimSpace(req.ID) == "" {
		http.Error(w, "invalid request body: an id is required", http.StatusBadRequest)
		return
	}

	run, err := srv.Store.GetRun(strings.TrimSpace(req.ID))
	if err != nil || run == nil {
		http.Error(w, fmt.Sprintf("no run %q", req.ID), http.StatusNotFound)
		return
	}

	if !isResumable(run.Status) {
		http.Error(w, fmt.Sprintf(
			"run %s is %s and cannot be resumed; resumable statuses are %s",
			run.ID, run.Status, strings.Join(ResumableStatuses, ", ")),
			http.StatusConflict)
		return
	}

	// Refuse if this process is already driving the run. The status check above is
	// not sufficient on its own: a run registered as in-flight may not have written
	// its status yet.
	if srv.isRunActive(run.ID) {
		http.Error(w, fmt.Sprintf("run %s is already executing", run.ID), http.StatusConflict)
		return
	}

	proj, err := config.LoadProject(run.Project)
	if err != nil {
		http.Error(w, fmt.Sprintf("loading project %s: %v", run.Project, err), http.StatusBadRequest)
		return
	}

	// Resume runs the same body as a dispatch. The repository list is recovered
	// from the phase records where possible, so a resume targets what the original
	// run targeted rather than re-deriving it from configuration that may have
	// changed since.
	repos := srv.reposForRun(run.ID)

	router := handoff.NewRouter(filepath.Join(dag.FleetRoot(), run.ID, "handoff"))
	engine := dag.NewEngine(proj, srv.Store, router)
	engine.Resume = true

	_ = srv.Store.UpdateRunStatus(run.ID, "running")

	ctx, cancel := context.WithCancel(context.Background())
	srv.registerRun(run.ID, cancel)
	// Resume does not carry the change dir: the worktree (and its seeded
	// plan.json) already exists from the original dispatch. Pass empty so
	// SeedPlan is not re-run on resume, which would overwrite agent progress.
	go srv.executeRun(ctx, cancel, engine, proj, run.ID, run.Brief, repos, "")

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"status":  "resumed",
		"task_id": run.ID,
		"run_id":  run.ID,
		"project": proj.Name,
		"skipped": srv.passedPhaseNames(run.ID),
	})
}
