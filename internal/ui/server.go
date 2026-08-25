package ui

import (
	"context"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"gopkg.in/yaml.v3"

	"github.com/callmeradical/sergeant/internal/config"
	"github.com/callmeradical/sergeant/internal/dag"
	"github.com/callmeradical/sergeant/internal/graphify"
	"github.com/callmeradical/sergeant/internal/handoff"
	"github.com/callmeradical/sergeant/internal/naming"
	"github.com/callmeradical/sergeant/internal/plan"
	"github.com/callmeradical/sergeant/internal/redact"
	"github.com/callmeradical/sergeant/internal/runner"
	"github.com/callmeradical/sergeant/internal/store"
)

//go:embed static/*
var staticFS embed.FS

type Server struct {
	Store *store.Store
	Port  int

	// GHPRCreate invokes `gh pr create` for a PR-creation request. It is a
	// struct field defaulting to runGHPRCreate's real subprocess, not a bare
	// exec.Command call inside handleCreatePR, so a test can substitute a
	// recording stub and prove gh was never invoked for a request the seal
	// guard refused — the same swap-a-dependency shape PhaseRunner.AgentCLI
	// uses for the agent binary.
	GHPRCreate func(repoPath, title, body, branch string) ([]byte, error)

	// cancels holds one CancelFunc per in-flight run so that a cancel request can
	// actually stop the work. Without it "Stop Run" only writes a status column
	// that the dispatch goroutine later overwrites, and agents keep writing to
	// worktrees after the operator believes they were stopped.
	mu      sync.Mutex
	cancels map[string]context.CancelFunc
}

func (srv *Server) registerRun(runID string, cancel context.CancelFunc) {
	srv.mu.Lock()
	defer srv.mu.Unlock()
	if srv.cancels == nil {
		srv.cancels = map[string]context.CancelFunc{}
	}
	srv.cancels[runID] = cancel
}

// isRunActive reports whether this process is currently driving the run. A status
// check alone is not enough: a run registered as in-flight may not have written
// its status yet, and resuming it would put two agents in one worktree.
func (srv *Server) isRunActive(runID string) bool {
	srv.mu.Lock()
	defer srv.mu.Unlock()
	_, ok := srv.cancels[runID]
	return ok
}

func (srv *Server) finishRun(runID string) {
	srv.mu.Lock()
	defer srv.mu.Unlock()
	delete(srv.cancels, runID)
}

// cancelRun stops an in-flight run. Reports whether a live run was found.
func (srv *Server) cancelRun(runID string) bool {
	srv.mu.Lock()
	cancel, ok := srv.cancels[runID]
	srv.mu.Unlock()
	if ok && cancel != nil {
		cancel()
	}
	return ok
}

// writeJSON marshals v before writing any header, so a marshal failure becomes a
// real 500 instead of a silent HTTP 200 with a zero-byte body.
func writeJSON(w http.ResponseWriter, status int, v interface{}) {
	body, err := json.Marshal(v)
	if err != nil {
		http.Error(w, fmt.Sprintf("encoding response: %v", err), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Length", strconv.Itoa(len(body)))
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

func NewServer(s *store.Store, port int) *Server {
	if port <= 0 {
		port = 8484
	}
	return &Server{
		Store:      s,
		Port:       port,
		cancels:    map[string]context.CancelFunc{},
		GHPRCreate: runGHPRCreate,
	}
}

// runGHPRCreate is the real `gh pr create` invocation. It is a plain function,
// not inlined into handleCreatePR, so NewServer can hand it to Server.GHPRCreate
// as the default while a test swaps in a recording stub instead.
func runGHPRCreate(repoPath, title, body, branch string) ([]byte, error) {
	cmd := exec.Command("gh", "pr", "create", "--title", title, "--body", body, "--head", branch)
	cmd.Dir = repoPath
	return cmd.CombinedOutput()
}

func (srv *Server) Handler() http.Handler {
	mux := http.NewServeMux()

	// API endpoints
	mux.HandleFunc("/api/projects", srv.handleProjects)
	mux.HandleFunc("/api/project-details", srv.handleProjectDetails)
	mux.HandleFunc("/api/refine-project", srv.handleRefineProject)
	mux.HandleFunc("/api/runs", srv.handleRuns)
	mux.HandleFunc("/api/analytics", srv.handleAnalytics)
	mux.HandleFunc("/api/run-details", srv.handleRunDetails)
	mux.HandleFunc("/api/validate-intent", srv.handleValidateIntent)
	mux.HandleFunc("/api/discover-workflow", srv.handleDiscoverWorkflow)
	mux.HandleFunc("/api/workflow", srv.handleWorkflow)
	mux.HandleFunc("/api/save-dag", srv.handleSaveDAG)
	mux.HandleFunc("/api/dispatch", srv.handleDispatch)
	mux.HandleFunc("/api/create-pr", srv.handleCreatePR)
	mux.HandleFunc("/api/bullets", srv.handleBullets)
	mux.HandleFunc("/api/plans", srv.handlePlans)
	mux.HandleFunc("/api/plans/{intent_id}/approve", srv.handleApprovePlan)
	mux.HandleFunc("/api/plans/{intent_id}/reject", srv.handleRejectPlan)
	mux.HandleFunc("/api/fleet", srv.handleFleet)
	mux.HandleFunc("/api/clean-worktrees", srv.handleCleanWorktrees)
	mux.HandleFunc("/api/run-cancel", srv.handleRunCancel)
	mux.HandleFunc("/api/run-resume", srv.handleRunResume)
	mux.HandleFunc("/api/run-delete", srv.handleRunDelete)
	mux.HandleFunc("/api/delivery-history", srv.handleDeliveryHistory)
	mux.HandleFunc("/api/delivery-quarantine", srv.handleDeliveryQuarantine)
	mux.HandleFunc("/api/build-graph", srv.handleBuildGraph)
	// The sequenced state stream. Clients follow this instead of re-reading
	// /api/runs on a timer.
	mux.HandleFunc("/api/stream", srv.handleStream)

	// Static assets
	mux.HandleFunc("/", srv.handleIndex)

	return mux
}

func (srv *Server) Start() error {
	// Reconcile before binding the port. Any run the store still marks as
	// running is unowned: a freshly started coordinator drives no runs by
	// construction. Doing this before ListenAndServe closes the window where a
	// client could observe a stale status and act on it (e.g. refuse a resume
	// for a reason that stops being true the moment reconciliation finishes).
	//
	// ReconcileOrphanedRuns must NEVER be called again after this point. Mid-life
	// it would reconcile a live run out from under itself.
	if result, err := srv.Store.ReconcileOrphanedRuns(); err != nil {
		log.Printf("sergeant: startup reconciliation failed: %v", err)
	} else if result.RunsReconciled > 0 {
		log.Printf("sergeant: reconciled %d orphaned run(s) and %d phase(s) to interrupted",
			result.RunsReconciled, result.PhasesReconciled)
	}

	// Started once, here, alongside the reconciliation above — the same
	// "something runs automatically as part of server lifecycle" precedent,
	// not a new one. Runs for the lifetime of the process; there is no
	// shutdown path today, so it is never cancelled.
	go srv.runFleetCleanupLoop(context.Background())

	handler := srv.Handler()
	addr := fmt.Sprintf("127.0.0.1:%d", srv.Port)
	fmt.Printf("🌐 Sergeant Factory UI running at http://%s\n", addr)
	return http.ListenAndServe(addr, handler)
}

func (srv *Server) handleIndex(w http.ResponseWriter, r *http.Request) {
	data, err := staticFS.ReadFile("static/index.html")
	if err != nil {
		http.Error(w, "UI assets not found", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write(data)
}

func (srv *Server) handleProjects(w http.ResponseWriter, r *http.Request) {
	projects, err := config.ListProjects()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if projects == nil {
		projects = []*config.Project{}
	}
	writeJSON(w, http.StatusOK, projects)
}

func (srv *Server) handleProjectDetails(w http.ResponseWriter, r *http.Request) {
	name := r.URL.Query().Get("name")
	if name == "" {
		http.Error(w, "missing project name", http.StatusBadRequest)
		return
	}

	proj, err := config.LoadProject(name)
	if err != nil {
		http.Error(w, fmt.Sprintf("project '%s' not found: %v", name, err), http.StatusNotFound)
		return
	}

	writeJSON(w, http.StatusOK, proj)
}

// runPayload is a run as a client receives it: the stored record, plus the
// server's answer to "may this run be resumed?".
//
// The answer is served rather than left to the client because the refusal in
// handleRunResume is authoritative. A dashboard holding its own list of resumable
// statuses would be a second authority for one rule, and the two would drift into
// offering an action the server rejects. Resumable is derived here from the same
// ResumableStatuses that endpoint enforces, so there is exactly one list.
type runPayload struct {
	store.RunRecord
	Resumable bool `json:"resumable"`
}

// runPayloads answers the resume question for every run in a list. It never
// returns nil, so an empty list serialises as [] rather than null.
func runPayloads(runs []store.RunRecord) []runPayload {
	out := make([]runPayload, 0, len(runs))
	for _, r := range runs {
		out = append(out, runPayload{RunRecord: r, Resumable: isResumable(r.Status)})
	}
	return out
}

func (srv *Server) handleRuns(w http.ResponseWriter, r *http.Request) {
	project := r.URL.Query().Get("project")
	runs := []store.RunRecord{}
	var err error

	if project != "" && project != "all" {
		runs, err = srv.Store.ListRunsForProject(project, 50)
	} else {
		runs, err = srv.Store.ListRecentRuns(50)
	}

	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if runs == nil {
		runs = []store.RunRecord{}
	}
	writeJSON(w, http.StatusOK, runPayloads(runs))
}

// handleAnalytics answers GET /api/analytics?project=<name>, matching
// handleRuns' project/all scoping convention exactly: a named project
// (anything but "" or "all") scopes to that project, and an omitted or
// "all" param combines every project. Unlike handleRuns, ComputeWorkAnalytics
// draws that distinction internally, so the handler just forwards the param.
// A plain read like handleRuns: no request body, no side effects.
func (srv *Server) handleAnalytics(w http.ResponseWriter, r *http.Request) {
	project := r.URL.Query().Get("project")
	analytics, err := srv.Store.ComputeWorkAnalytics(project)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, analytics)
}

func (srv *Server) handleRunDetails(w http.ResponseWriter, r *http.Request) {
	runID := r.URL.Query().Get("id")
	if runID == "" {
		http.Error(w, "missing run id", http.StatusBadRequest)
		return
	}

	phases, err := srv.Store.ListPhasesForRun(runID)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if phases == nil {
		phases = []store.PhaseRecord{}
	}

	envelopes, err := srv.Store.ListEnvelopesForRun(runID)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if envelopes == nil {
		envelopes = []store.EnvelopeRecord{}
	}

	// The phases a resume would skip, named before the operator commits rather
	// than only reported afterwards by /api/run-resume. Both come from
	// passedPhaseNames, so what the interface promises and what the resume does
	// cannot disagree. It reads empty when no phase holds a passed record, which
	// means "nothing will be skipped", never "unknown".
	skips := srv.passedPhaseNames(runID)
	if skips == nil {
		skips = []string{}
	}

	resp := map[string]interface{}{
		"run_id":       runID,
		"phases":       phases,
		"envelopes":    envelopes,
		"resume_skips": skips,
	}

	writeJSON(w, http.StatusOK, resp)
}

func resolveGitRemoteURL(repoDir string) string {
	if strings.HasPrefix(repoDir, "~/") {
		home, _ := os.UserHomeDir()
		repoDir = filepath.Join(home, repoDir[2:])
	}
	cmd := exec.Command("git", "-C", repoDir, "config", "--get", "remote.origin.url")
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	raw := strings.TrimSpace(string(out))
	if strings.HasPrefix(raw, "git@github.com:") {
		raw = strings.TrimPrefix(raw, "git@github.com:")
		raw = strings.TrimSuffix(raw, ".git")
		return "https://github.com/" + raw
	}
	if strings.HasPrefix(raw, "https://github.com/") {
		return strings.TrimSuffix(raw, ".git")
	}
	if strings.HasPrefix(raw, "http://") || strings.HasPrefix(raw, "https://") {
		return strings.TrimSuffix(raw, ".git")
	}
	return ""
}

func (srv *Server) handleCreatePR(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		RunID   string `json:"run_id"`
		Project string `json:"project"`
		Repo    string `json:"repo"`
		Title   string `json:"title"`
		Body    string `json:"body"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.RunID == "" {
		http.Error(w, "invalid PR payload", http.StatusBadRequest)
		return
	}

	// R3.5: human approval for a risky delivery action must be required, not
	// merely possible. Sealing runs before gh is ever invoked, so a bullet that
	// has not passed its gates refuses the whole request — this is what makes
	// approval a real gate on the action rather than a status update tacked on
	// after the fact.
	if err := srv.Store.SealBulletForRun(req.RunID, req.Repo); err != nil {
		http.Error(w, err.Error(), http.StatusConflict)
		return
	}

	proj, _ := config.LoadProject(req.Project)
	repoPath := ""
	if proj != nil && len(proj.Repos) > 0 {
		if req.Repo != "" {
			if rCfg, exists := proj.Repos[req.Repo]; exists {
				repoPath = rCfg.Path
			}
		}
		if repoPath == "" {
			for _, rCfg := range proj.Repos {
				repoPath = rCfg.Path
				break
			}
		}
	}

	remoteBase := ""
	if repoPath != "" {
		remoteBase = resolveGitRemoteURL(repoPath)
	}

	run, err := srv.Store.GetRun(req.RunID)
	if err != nil {
		http.Error(w, fmt.Sprintf("loading run %q: %v", req.RunID, err), http.StatusInternalServerError)
		return
	}
	branch := naming.BranchNameForRun(run.ID, run.Type, run.ChangeID)
	if req.Title == "" {
		req.Title = fmt.Sprintf("feat(%s): verified patch for run [%s]", req.Project, req.RunID)
	}

	var prURL string
	var prError string

	if repoPath != "" && remoteBase != "" {
		// Attempt real gh pr create in git repo if remote exists
		out, err := srv.GHPRCreate(repoPath, req.Title, req.Body, branch)
		if err == nil && strings.HasPrefix(strings.TrimSpace(string(out)), "https://") {
			prURL = strings.TrimSpace(string(out))
		} else {
			// gh's own error output can echo back a credential-bearing remote
			// URL or similar, and prError is persisted into an envelope and
			// returned in the HTTP response, not just logged locally.
			prError = redact.Text(strings.TrimSpace(string(out)))
			prURL = fmt.Sprintf("%s/compare/%s?expand=1", remoteBase, branch)
		}
	} else {
		prURL = fmt.Sprintf("local://worktree/%s", branch)
	}

	summary := fmt.Sprintf("PR Staged: %s", req.Title)
	if prError != "" {
		summary = fmt.Sprintf("PR Ready (Local Branch '%s'): %s", branch, req.Title)
	}

	prNow := time.Now().UTC()
	envRec := &store.EnvelopeRecord{
		ID:            fmt.Sprintf("pr-%s-%d", req.RunID, prNow.UnixNano()),
		RunID:         req.RunID,
		Repo:          req.Repo,
		Stage:         "review",
		Summary:       summary,
		Artifacts:     []string{prURL, ".sergeant/review.json"},
		Data:          json.RawMessage(fmt.Sprintf(`{"pr_url": %q, "branch": %q, "remote_base": %q, "error": %q}`, prURL, branch, remoteBase, prError)),
		Type:          "pr.staged",
		SchemaVersion: "1",
		OccurredAt:    prNow,
		Producer:      "sergeant/ui",
		CorrelationID: req.RunID,
		CausationID:   srv.Store.CausationFromLatest(req.RunID, req.Repo),
	}
	_ = srv.Store.RecordEnvelope(envRec)

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"status": "created",
		"run_id": req.RunID,
		"pr_url": prURL,
		"branch": branch,
		"error":  prError,
	})
}

// handleBullets answers a run-scoped or intent-scoped view of bullet status
// (R3.5): the API substrate that makes "which bullets are green and awaiting
// approval versus already sealed" inspectable, the same guard SealBulletForRun
// enforces.
//
// intent_id is a direct lookup, with no run to resolve through — a plan
// awaiting approval (decision D2) has no run yet, and this is the dashboard's
// existing bullet-listing behaviour, not a new concept. run_id remains
// required when intent_id is absent, for the same reason as
// handleDeliveryHistory's: an empty result for a missing id would be
// indistinguishable from "this run truly has no bullets".
func (srv *Server) handleBullets(w http.ResponseWriter, r *http.Request) {
	if intentID := r.URL.Query().Get("intent_id"); intentID != "" {
		bullets, err := srv.Store.ListBulletsForIntent(intentID)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		if bullets == nil {
			bullets = []store.BulletRecord{}
		}
		writeJSON(w, http.StatusOK, bullets)
		return
	}

	runID := r.URL.Query().Get("run_id")
	if runID == "" {
		http.Error(w, "missing run_id or intent_id", http.StatusBadRequest)
		return
	}

	run, err := srv.Store.GetRun(runID)
	if err != nil {
		http.Error(w, err.Error(), http.StatusNotFound)
		return
	}

	// A run written before intent tracking existed carries no intent id; that
	// is not an error, it means the run served no bullets sergeant can name.
	bullets := []store.BulletRecord{}
	if run.IntentID != "" {
		listed, err := srv.Store.ListBulletsForIntent(run.IntentID)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		if listed != nil {
			bullets = listed
		}
	}

	writeJSON(w, http.StatusOK, bullets)
}

// planEntry is what an operator reviews before deciding on a proposed plan
// (decision D5(a)): the intent and every bullet it proposes.
type planEntry struct {
	Intent  store.IntentRecord   `json:"intent"`
	Bullets []store.BulletRecord `json:"bullets"`
}

// handlePlans lists every plan awaiting approval (decision D2): intents with
// status "proposed", each with its proposed bullets.
func (srv *Server) handlePlans(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	intents, err := srv.Store.ListIntentsByStatus("proposed")
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	plans := make([]planEntry, 0, len(intents))
	for _, intent := range intents {
		bullets, err := srv.Store.ListBulletsForIntent(intent.ID)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		if bullets == nil {
			bullets = []store.BulletRecord{}
		}
		plans = append(plans, planEntry{Intent: intent, Bullets: bullets})
	}

	writeJSON(w, http.StatusOK, plans)
}

// handleApprovePlan is decision D2/D5(a)'s explicit approval gate. Approving is
// the only way a proposed plan's work begins: on success it transitions the
// intent and its bullets out of "proposed" and calls createRunAndDispatch —
// the same run-creation-and-dispatch sequence an explicit-repos dispatch
// already runs — over the plan's own bullets' repositories.
func (srv *Server) handleApprovePlan(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	intentID := r.PathValue("intent_id")

	intent, err := srv.Store.GetIntent(intentID)
	if err != nil {
		http.Error(w, fmt.Sprintf("plan %q not found: %v", intentID, err), http.StatusNotFound)
		return
	}

	if intent.Status != "proposed" {
		if intent.Status == "abandoned" {
			http.Error(w, fmt.Sprintf("plan %q was rejected and cannot be approved", intentID), http.StatusConflict)
			return
		}
		// Already approved (or beyond): a repeat changes nothing and is not an
		// error — the caller cannot tell an approval from its own retry.
		srv.writePlanState(w, intentID)
		return
	}

	bullets, err := srv.Store.ListBulletsForIntent(intentID)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	targetRepos := make([]string, len(bullets))
	for i, b := range bullets {
		targetRepos[i] = b.Repo
	}

	proj, err := config.LoadProject(intent.Project)
	if err != nil {
		http.Error(w, fmt.Sprintf("loading project %q: %v", intent.Project, err), http.StatusInternalServerError)
		return
	}

	// Decision O3 still applies, but the change was already resolved once, at
	// proposal time, and is reused here verbatim — not re-resolved. Calling
	// changeRepo/resolveChange a second time, with different inputs than
	// proposal time had (no caller-supplied change_id is available at
	// approval time; repo selection can depend on argument order), could
	// silently pick a different repository or scaffold a second change,
	// discarding whatever change_id the caller named when the plan was
	// proposed.
	changeRepoName := intent.ChangeRepo
	repoCfg, ok := proj.Repos[changeRepoName]
	if !ok || strings.TrimSpace(repoCfg.Path) == "" {
		http.Error(w, fmt.Sprintf("plan %q's change repository %q is no longer configured in project %q", intentID, changeRepoName, proj.Name), http.StatusInternalServerError)
		return
	}
	changeRepoPath := repoCfg.Path
	change, err := resolveChange(changeRepoPath, intent.ChangeID, intent.Statement)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	if err := srv.Store.UpdateIntentStatus(intentID, "in_progress"); err != nil {
		http.Error(w, fmt.Sprintf("approving plan %q: %v", intentID, err), http.StatusInternalServerError)
		return
	}
	for _, b := range bullets {
		if err := srv.Store.UpdateBulletStatus(b.ID, "pending"); err != nil {
			http.Error(w, fmt.Sprintf("approving bullet %q: %v", b.ID, err), http.StatusInternalServerError)
			return
		}
	}

	srv.createRunAndDispatch(w, proj, intent.Statement, targetRepos, change, "", changeRepoName, changeRepoPath, intentID, intent.Type)
}

// handleRejectPlan is decision D2/D5(a)'s explicit rejection path. Rejecting
// ends a proposed plan and starts nothing: the intent transitions to
// "abandoned" and its bullets are left "proposed" — the intent's terminal
// status alone is what makes them inert, so no bullet-level rejected status is
// introduced.
func (srv *Server) handleRejectPlan(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	intentID := r.PathValue("intent_id")

	intent, err := srv.Store.GetIntent(intentID)
	if err != nil {
		http.Error(w, fmt.Sprintf("plan %q not found: %v", intentID, err), http.StatusNotFound)
		return
	}

	switch intent.Status {
	case "abandoned":
		// A repeat changes nothing and is not an error.
		srv.writePlanState(w, intentID)
		return
	case "proposed":
		if err := srv.Store.UpdateIntentStatus(intentID, "abandoned"); err != nil {
			http.Error(w, fmt.Sprintf("rejecting plan %q: %v", intentID, err), http.StatusInternalServerError)
			return
		}
		srv.writePlanState(w, intentID)
	default:
		http.Error(w, fmt.Sprintf("plan %q is %q, not proposed — refusing to reject", intentID, intent.Status), http.StatusConflict)
	}
}

// writePlanState answers with an intent's current state and its bullets. Both
// the idempotent-repeat branches of approve and reject, and a normal reject,
// report the same shape: what the plan is now, not what changed.
func (srv *Server) writePlanState(w http.ResponseWriter, intentID string) {
	intent, err := srv.Store.GetIntent(intentID)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	bullets, err := srv.Store.ListBulletsForIntent(intentID)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if bullets == nil {
		bullets = []store.BulletRecord{}
	}
	writeJSON(w, http.StatusOK, planEntry{Intent: *intent, Bullets: bullets})
}

func (srv *Server) handleFleet(w http.ResponseWriter, r *http.Request) {
	fleetDir := dag.FleetRoot()

	type WorktreeLease struct {
		TaskID    string `json:"task_id"`
		Path      string `json:"path"`
		Status    string `json:"status"`
		CreatedAt string `json:"created_at"`
	}

	recentRuns, _ := srv.Store.ListRecentRuns(200)
	runStatusMap := make(map[string]string)
	for _, r := range recentRuns {
		runStatusMap[r.ID] = r.Status
		runStatusMap[r.TaskID] = r.Status
	}

	var leases []WorktreeLease
	entries, _ := os.ReadDir(fleetDir)
	for _, entry := range entries {
		if entry.IsDir() {
			info, _ := entry.Info()
			modTime := time.Now().Format(time.RFC3339)
			if info != nil {
				modTime = info.ModTime().Format(time.RFC3339)
			}
			st, ok := runStatusMap[entry.Name()]
			if !ok {
				st = "unknown"
			}
			leases = append(leases, WorktreeLease{
				TaskID:    entry.Name(),
				Path:      filepath.Join(fleetDir, entry.Name()),
				Status:    st,
				CreatedAt: modTime,
			})
		}
	}
	if leases == nil {
		leases = []WorktreeLease{}
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"allocated_worktrees": len(leases),
		"leases":              leases,
	})
}

func (srv *Server) handleCleanWorktrees(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		TaskID string `json:"task_id"`
		DryRun bool   `json:"dry_run"`
		Force  bool   `json:"force"`
	}

	if r.Body != nil {
		_ = json.NewDecoder(r.Body).Decode(&req)
	}

	if req.TaskID != "" && (strings.Contains(req.TaskID, "/") || strings.Contains(req.TaskID, "..") || strings.Contains(req.TaskID, string(filepath.Separator))) {
		http.Error(w, "invalid task_id", http.StatusBadRequest)
		return
	}

	fleetDir := dag.FleetRoot()
	_ = os.MkdirAll(fleetDir, 0755)

	recentRuns, _ := srv.Store.ListRecentRuns(200)
	runStatusMap := make(map[string]string)
	for _, r := range recentRuns {
		runStatusMap[r.ID] = r.Status
		runStatusMap[r.TaskID] = r.Status
	}

	type SkippedLease struct {
		Path   string `json:"path"`
		Reason string `json:"reason"`
	}

	removed := []string{}
	skipped := []SkippedLease{}

	entries, _ := os.ReadDir(fleetDir)
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		if req.TaskID != "" && entry.Name() != req.TaskID {
			continue
		}

		targetPath := filepath.Join(fleetDir, entry.Name())
		status := runStatusMap[entry.Name()]

		ok, reason := reclaimFleetDir(targetPath, status, req.Force, req.DryRun)
		if !ok {
			if reason != "" {
				skipped = append(skipped, SkippedLease{Path: targetPath, Reason: reason})
			}
			continue
		}
		removed = append(removed, targetPath)
	}

	statusStr := "cleaned"
	if req.DryRun {
		statusStr = "preview"
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"status":  statusStr,
		"removed": removed,
		"skipped": skipped,
		"count":   len(removed),
	})
}

// reclaimFleetDir is the one reclaim decision behind both the on-demand
// /api/clean-worktrees handler and the automatic background pass: a
// still-running run is refused, and unless force is set, a worktree with
// uncommitted changes is refused too. dryRun reports what would happen
// without touching disk — the on-demand handler's preview mode; the
// automatic pass always passes force=false and dryRun=false, so it never
// applies a relaxed version of the on-demand safety rules.
//
// On a RemoveAll failure this reports not-removed with no reason, matching
// handleCleanWorktrees's original behaviour: such a directory is neither
// counted as removed nor reported as skipped.
func reclaimFleetDir(fleetDir string, runStatus string, force bool, dryRun bool) (removed bool, skipReason string) {
	if runStatus == "running" && !force {
		return false, "run still in progress"
	}

	// Never destroy unreviewed work by default. A completed run whose worktree
	// still has uncommitted changes represents agent output that exists nowhere
	// else; deleting it is unrecoverable.
	if !force {
		if dirty := dirtyWorktreesUnder(fleetDir); len(dirty) > 0 {
			return false, fmt.Sprintf("uncommitted changes in %s — commit or use force", strings.Join(dirty, ", "))
		}
	}

	if dryRun {
		return true, ""
	}
	if err := os.RemoveAll(fleetDir); err != nil {
		return false, ""
	}
	return true, ""
}

// fleetCleanupRetention is how long a run must have sat in a terminal status
// before its fleet worktree is reclaimed automatically. It is a fixed
// constant, not configurable — a deliberate choice for this single-user,
// local-first tool (see design.md's rejected alternatives).
const fleetCleanupRetention = 7 * 24 * time.Hour

// fleetCleanupInterval is how often the automatic pass runs. Fixed for the
// same reason as fleetCleanupRetention.
const fleetCleanupInterval = 1 * time.Hour

// reclaimEligibleFleetDirs finds every run whose status has been terminal
// longer than fleetCleanupRetention and reclaims its fleet worktree via
// reclaimFleetDir — the same running-check and dirty-worktree check the
// on-demand handler applies, always with force disabled. A run whose fleet
// directory does not exist (already cleaned, or never created) is silently
// skipped, not an error. It never deletes or modifies a database row: only
// the on-disk worktree is touched.
func (srv *Server) reclaimEligibleFleetDirs() {
	runs, err := srv.Store.RunsEligibleForCleanup(time.Now().Add(-fleetCleanupRetention))
	if err != nil {
		log.Printf("sergeant: fleet cleanup: listing eligible runs: %v", err)
		return
	}

	fleetRoot := dag.FleetRoot()
	for _, run := range runs {
		fleetDir := filepath.Join(fleetRoot, run.ID)
		if _, err := os.Stat(fleetDir); err != nil {
			continue
		}
		if removed, _ := reclaimFleetDir(fleetDir, run.Status, false, false); removed {
			log.Printf("sergeant: fleet cleanup: reclaimed %s (run %s, status %s)", fleetDir, run.ID, run.Status)
		}
	}
}

// runFleetCleanupLoop ticks on fleetCleanupInterval for the lifetime of the
// server, reclaiming fleet worktrees for runs that have been terminal past
// the retention window. Started once, alongside Start's existing startup
// reconciliation, and stops when ctx is cancelled.
func (srv *Server) runFleetCleanupLoop(ctx context.Context) {
	ticker := time.NewTicker(fleetCleanupInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			srv.reclaimEligibleFleetDirs()
		}
	}
}

type IntentValidationResult struct {
	Valid          bool     `json:"valid"`
	Score          int      `json:"score"`
	Project        string   `json:"project"`
	IdentifiedGoal string   `json:"identified_goal"`
	TargetRepos    []string `json:"target_repos"`
	ChecksPassed   []string `json:"checks_passed"`
	Warnings       []string `json:"warnings"`
	Errors         []string `json:"errors"`
}

func (srv *Server) handleValidateIntent(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		Project string `json:"project"`
		Brief   string `json:"brief"`
		Agent   string `json:"agent"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}

	brief := strings.TrimSpace(req.Brief)
	if brief == "" {
		http.Error(w, "Intent brief is required", http.StatusBadRequest)
		return
	}

	proj, err := config.LoadProject(req.Project)
	if err != nil {
		http.Error(w, fmt.Sprintf("project '%s' not found: %v", req.Project, err), http.StatusBadRequest)
		return
	}

	res := IntentValidationResult{
		Project:      proj.Name,
		ChecksPassed: []string{},
		Warnings:     []string{},
		Errors:       []string{},
	}
	res.IdentifiedGoal = brief

	totalChecks := 5
	passedChecks := 0

	// Check 1: Length
	if len(brief) >= 20 {
		passedChecks++
		res.ChecksPassed = append(res.ChecksPassed, "Sufficient intent clarity and length")
	} else {
		res.Warnings = append(res.Warnings, "Brief is quite concise; consider providing more context.")
	}

	// Check 2: Acceptance criteria signal words
	lowerBrief := strings.ToLower(brief)
	hasSignal := false
	signalWords := []string{"should", "must", "when", "given", "expect", "test", "verify"}
	for _, word := range signalWords {
		if strings.Contains(lowerBrief, word) {
			hasSignal = true
			break
		}
	}
	if hasSignal {
		passedChecks++
		res.ChecksPassed = append(res.ChecksPassed, "Contains explicit acceptance criteria signals")
	} else {
		res.Warnings = append(res.Warnings, "Brief lacks acceptance criteria signal words (e.g. should, must, expect, test).")
	}

	// Check 3: Repos in topology
	for repoName := range proj.Repos {
		res.TargetRepos = append(res.TargetRepos, repoName)
	}
	if len(res.TargetRepos) > 0 {
		passedChecks++
		res.ChecksPassed = append(res.ChecksPassed, fmt.Sprintf("Resolved %d target repos in topology (%s)", len(res.TargetRepos), strings.Join(res.TargetRepos, ", ")))
	} else {
		res.Errors = append(res.Errors, "No repositories configured in project topology")
	}

	// Check 4: Names a configured repo or file path
	namesRepoOrPath := false
	for _, rName := range res.TargetRepos {
		if strings.Contains(lowerBrief, strings.ToLower(rName)) {
			namesRepoOrPath = true
			break
		}
	}
	if strings.Contains(lowerBrief, "/") || strings.Contains(lowerBrief, ".go") || strings.Contains(lowerBrief, ".ts") || strings.Contains(lowerBrief, ".js") || strings.Contains(lowerBrief, ".py") {
		namesRepoOrPath = true
	}
	if namesRepoOrPath {
		passedChecks++
		res.ChecksPassed = append(res.ChecksPassed, "Targets specific repository or file path in topology")
	} else {
		res.Warnings = append(res.Warnings, "Brief does not explicitly name a target repository or file path.")
	}

	// Check 5: Deterministic quality gates
	hasGates := false
	for _, r := range proj.Repos {
		if r.Factory != nil && len(r.Factory.Gates) > 0 {
			hasGates = true
			break
		}
	}
	if hasGates {
		passedChecks++
		res.ChecksPassed = append(res.ChecksPassed, "Zero-token deterministic code quality gates defined")
	} else {
		res.Warnings = append(res.Warnings, "No explicit factory.gates configured in project YAML.")
	}

	res.Score = (passedChecks * 100) / totalChecks
	res.Valid = (res.Score >= 60 && len(res.Errors) == 0)

	writeJSON(w, http.StatusOK, res)
}

func (srv *Server) handleDiscoverWorkflow(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		Project         string `json:"project"`
		IntentArchetype string `json:"intent_archetype"`
		QualityBar      string `json:"quality_bar"`
		DeliveryMode    string `json:"delivery_mode"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Project == "" {
		http.Error(w, "invalid discovery request", http.StatusBadRequest)
		return
	}

	proj, err := config.LoadProject(req.Project)
	if err != nil {
		http.Error(w, fmt.Sprintf("project '%s' not found: %v", req.Project, err), http.StatusBadRequest)
		return
	}

	var stages []config.DAGStage
	allRepos := []string{}
	for rName := range proj.Repos {
		allRepos = append(allRepos, rName)
	}

	stages = append(stages, config.DAGStage{
		Name:  "feature-tdd-execution",
		Repos: allRepos,
		Brief: "Execute test-driven implementation with zero-token deterministic gate verification",
	})

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"project":              proj.Name,
		"archetype":            req.IntentArchetype,
		"recommended_pipeline": stages,
		"decision_rationale":   fmt.Sprintf("Discovered %d repos across topology. Synthesized %d stages.", len(proj.Repos), len(stages)),
	})
}

func (srv *Server) handleSaveDAG(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		Project string            `json:"project"`
		Stages  []config.DAGStage `json:"stages"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Project == "" {
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}

	proj, err := config.LoadProject(req.Project)
	if err != nil {
		http.Error(w, fmt.Sprintf("project '%s' not found: %v", req.Project, err), http.StatusBadRequest)
		return
	}

	if proj.DAG == nil {
		proj.DAG = &config.DAGConfig{
			Name:        fmt.Sprintf("%s-pipeline", proj.Name),
			Description: fmt.Sprintf("Automated pipeline for %s", proj.Name),
		}
	}
	proj.DAG.Stages = req.Stages

	cfgDir := os.Getenv("SERGEANT_CONFIG")
	if cfgDir == "" {
		home, _ := os.UserHomeDir()
		cfgDir = filepath.Join(home, ".config", "sergeant")
	}
	filePath := filepath.Join(cfgDir, fmt.Sprintf("%s.yaml", proj.Name))

	out, err := yaml.Marshal(proj)
	if err != nil {
		http.Error(w, fmt.Sprintf("marshaling YAML: %v", err), http.StatusInternalServerError)
		return
	}

	if err := os.WriteFile(filePath, out, 0644); err != nil {
		http.Error(w, fmt.Sprintf("writing project YAML: %v", err), http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"status":  "saved",
		"project": proj.Name,
		"stages":  len(proj.DAG.Stages),
	})
}

// validWorkTypes is the fixed vocabulary decision O2 names for a dispatched
// branch's <type>/<change-id> prefix. It is checked before anything else about
// a dispatch — before change resolution, before either the no-repos or
// explicit-repos branch runs — mirroring where ValidateAgent is checked: reject
// what the engine cannot honor before any record exists.
var validWorkTypes = map[string]bool{
	"feat": true, "fix": true, "refactor": true,
	"docs": true, "chore": true, "test": true,
}

// sortedWorkTypes returns validWorkTypes' keys in a stable order, so a refusal
// names the valid set the same way on every call.
func sortedWorkTypes() []string {
	names := make([]string, 0, len(validWorkTypes))
	for t := range validWorkTypes {
		names = append(names, t)
	}
	sort.Strings(names)
	return names
}

// validateWorkType reports whether typ is one of the fixed work types a
// dispatch may name. An empty or unrecognized value is refused, naming the
// valid set, so the caller learns what would have been accepted.
func validateWorkType(typ string) error {
	if !validWorkTypes[typ] {
		return fmt.Errorf("invalid or missing type %q: must be one of %s", typ, strings.Join(sortedWorkTypes(), ", "))
	}
	return nil
}

// targetRepositories is the list of repositories a dispatch acts on: the ones it
// named, or every repository in the project when it named none.
//
// The fallback is sorted. Position in this list is a bullet's merge order, and
// map iteration order would give the same dispatch a different merge order on
// every call — the same reason changeRepo sorts before picking. The returned
// slice never aliases req.Repos, so a caller cannot append into the request.
func targetRepositories(proj *config.Project, requested []string) []string {
	if len(requested) > 0 {
		return append([]string(nil), requested...)
	}
	names := make([]string, 0, len(proj.Repos))
	for name := range proj.Repos {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

func (srv *Server) handleDispatch(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		Project string   `json:"project"`
		Brief   string   `json:"brief"`
		Repos   []string `json:"repos"`
		Agent   string   `json:"agent"`
		// Type is the work type a dispatch is accountable to (decision O2): one
		// of feat, fix, refactor, docs, chore, test. It names the dispatched
		// branch's <type>/ prefix and is refused if missing or unrecognized,
		// before change resolution and before any run, intent or worktree exists.
		Type string `json:"type"`
		// ChangeID is optional. When empty, a change is derived from the brief and
		// scaffolded (decision O3); when set, it must already exist.
		ChangeID string `json:"change_id"`
		// RequestID is the caller's optional idempotency key (decision D10, from
		// AHP's runAutomation). A repeat of a known key is a retry of the original
		// request: it returns that run and starts nothing. It stays optional so
		// existing callers and the MCP contract keep working, and two dispatches
		// that omit it never deduplicate against each other.
		RequestID string `json:"request_id"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Project == "" {
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}

	if strings.TrimSpace(req.Brief) == "" {
		http.Error(w, "Intent brief cannot be empty", http.StatusBadRequest)
		return
	}

	// Decision O2: a dispatch must state its work type before change resolution
	// and before either the no-repos or explicit-repos branch runs — the same
	// "reject what the engine cannot honor before any record exists" placement
	// as ValidateAgent below.
	if err := validateWorkType(req.Type); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	proj, err := config.LoadProject(req.Project)
	if err != nil {
		http.Error(w, fmt.Sprintf("loading project: %v", err), http.StatusBadRequest)
		return
	}

	// Reject an agent this engine cannot drive before creating a run, worktree or
	// branch. An unrecognised name used to fall through to `exe <prompt>`, producing
	// a malformed command whose failure was indistinguishable from agent failure.
	if err := runner.ValidateAgent(req.Agent); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if req.Agent != "" {
		proj.Defaults.Agent = req.Agent
	}

	// Decision O3: resolve the OpenSpec change BEFORE anything else exists. No run
	// row, no branch and no worktree may precede it, or a failure here would leave
	// behind dispatched work with no planning record — exactly what O3 forbids.
	changeRepoName, changeRepoPath, err := changeRepo(proj, req.Repos)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	change, err := resolveChange(changeRepoPath, req.ChangeID, req.Brief)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	// The target repositories are resolved once, here, above every record write.
	// The DAG fallback stage below consumes the same slice, so the bullets and the
	// work the engine actually performs cannot name different repositories.
	targetRepos := targetRepositories(proj, req.Repos)

	brief := strings.TrimSpace(req.Brief)
	requestID := strings.TrimSpace(req.RequestID)

	// Decision D2: a decomposition the caller did not state explicitly — the
	// literal case D2 calls "inferred" — must be recorded as a plan awaiting
	// approval, not executed. targetRepos falling back to every project
	// repository is exactly that case. No run, worktree, branch or agent process
	// is created on this path; approving or rejecting the plan is a separate
	// request (decision D5(a): a human is notified and decides explicitly).
	if len(req.Repos) == 0 {
		intentID := naming.RunID() + "-intent"
		// The change was already resolved above (decision O3), before this
		// branch, using whatever the caller supplied. Recording it here is
		// what lets approval reuse it verbatim instead of re-resolving with
		// different inputs and silently picking a different change or repo.
		if err := srv.Store.CreateIntent(&store.IntentRecord{
			ID:         intentID,
			Project:    proj.Name,
			Statement:  brief,
			Status:     "proposed",
			ChangeID:   change.ID,
			ChangeRepo: changeRepoName,
			Type:       req.Type,
		}); err != nil {
			http.Error(w, fmt.Sprintf("recording the proposed plan: %v", err), http.StatusInternalServerError)
			return
		}
		bullets := make([]store.BulletRecord, 0, len(targetRepos))
		for i, repoName := range targetRepos {
			b := store.BulletRecord{
				ID:       fmt.Sprintf("%s-b%d", intentID, i+1),
				IntentID: intentID,
				Repo:     repoName,
				Position: i + 1,
				Status:   "proposed",
			}
			if err := srv.Store.CreateBullet(&b); err != nil {
				http.Error(w, fmt.Sprintf("recording proposed bullet %d: %v", i+1, err), http.StatusInternalServerError)
				return
			}
			bullets = append(bullets, b)
		}
		writeJSON(w, http.StatusAccepted, map[string]interface{}{
			"status":    "proposed",
			"intent_id": intentID,
			"repos":     targetRepos,
			"bullets":   bullets,
		})
		return
	}

	srv.createRunAndDispatch(w, proj, brief, targetRepos, change, requestID, changeRepoName, changeRepoPath, "", req.Type)
}

// createRunAndDispatch is the run-creation-and-dispatch sequence a dispatch
// performs once its target repositories are settled: it is what an
// explicit-repos request in handleDispatch runs immediately, and what an
// approved plan runs after its intent and bullets transition out of
// "proposed". Sharing this one implementation is what makes the two paths
// incapable of drifting from each other (design.md, "Approval reuses the
// existing dispatch sequence, not a copy of it").
//
// existingIntentID is "" for a fresh, explicit-repos dispatch — the original
// behavior, which mints its own intent and one bullet per target repo. An
// approved plan passes its own (already-"in_progress") intent id here instead
// of "": that intent and its bullets (already transitioned to "pending" by
// the caller) are reused as-is rather than minted a second time. Without
// this, approving a plan would leave its original intent frozen forever at
// "in_progress"/"pending" — nothing ever advances it — while a second,
// disconnected intent silently became the one actually tracked, doubling
// the dashboard's primary object (D8) for what a human considers one piece
// of work.
func (srv *Server) createRunAndDispatch(
	w http.ResponseWriter,
	proj *config.Project,
	brief string,
	targetRepos []string,
	change ChangeRef,
	requestID string,
	changeRepoName string,
	changeRepoPath string,
	existingIntentID string,
	workType string,
) {
	taskID := naming.RunID()

	// The intent id is derived from the run id rather than generated
	// independently (decision D4), so it is known before the intent row exists.
	// That is what lets the run be written first while still pointing at its
	// intent. An approved plan already has one; reuse it instead.
	intentID := existingIntentID
	if intentID == "" {
		intentID = taskID + "-intent"
	}

	// The run row is inserted before the intent and the bullets, and it carries
	// the idempotency key. This ordering is the mechanism, not a preference.
	//
	// The key is claimed by inserting and inspecting the failure — never by
	// querying first, which would let two concurrent POSTs both observe an unused
	// key and both proceed. Because the claim is the run insert, it must come
	// before anything a repeat would have to undo. Writing the intent first would
	// mean a repeat had already created an intent and N bullets by the time the
	// key refused it, and decision D8 makes the intent the dashboard's primary
	// noun, so every retry would show up as a duplicate on the operator's screen.
	//
	// O3's ordering still holds: the change is resolved above, so no run row
	// precedes the planning record.
	runRec := &store.RunRecord{
		ID:        taskID,
		Project:   proj.Name,
		TaskID:    taskID,
		Brief:     brief,
		ChangeID:  change.ID,
		Type:      workType,
		IntentID:  intentID,
		RequestID: requestID,
		Status:    "running",
	}
	if err := srv.Store.CreateRun(runRec); err != nil {
		if !errors.Is(err, store.ErrDuplicateRequestID) {
			http.Error(w, fmt.Sprintf("recording the run for this dispatch: %v", err), http.StatusInternalServerError)
			return
		}
		// A retry of a request already served. Answer with the run it created and
		// start nothing: no intent, no bullet, no worktree, no branch, no agent.
		srv.respondWithExistingRun(w, requestID, changeRepoPath, changeRepoName, change)
		return
	}

	if existingIntentID == "" {
		// Decision D4: sergeant stores intents and bullets itself, and decision
		// D8 makes the intent the dashboard's primary noun.
		if err := srv.Store.CreateIntent(&store.IntentRecord{
			ID:        intentID,
			Project:   proj.Name,
			Statement: brief,
			Status:    "in_progress",
		}); err != nil {
			http.Error(w, fmt.Sprintf("recording the intent for this dispatch: %v", err), http.StatusInternalServerError)
			return
		}
		// One bullet per target repository, positioned in merge order. A bullet
		// names exactly one repository: work in a second repository is a second
		// bullet.
		for i, repoName := range targetRepos {
			if err := srv.Store.CreateBullet(&store.BulletRecord{
				ID:       fmt.Sprintf("%s-b%d", taskID, i+1),
				IntentID: intentID,
				Repo:     repoName,
				Position: i + 1,
				Status:   "pending",
			}); err != nil {
				http.Error(w, fmt.Sprintf("recording bullet %d of this dispatch: %v", i+1, err), http.StatusInternalServerError)
				return
			}
		}
	}

	handoffBase := filepath.Join(dag.FleetRoot(), taskID, "handoff")
	router := handoff.NewRouter(handoffBase)
	engine := dag.NewEngine(proj, srv.Store, router)

	// Async run dispatch. The context is cancellable so that handleRunCancel can
	// actually stop in-flight agent work rather than just relabelling the row.
	ctx, cancel := context.WithCancel(context.Background())
	srv.registerRun(taskID, cancel)

	go srv.executeRun(ctx, cancel, engine, proj, taskID, brief, targetRepos, change.Dir)

	writeJSON(w, http.StatusOK, dispatchResponse(taskID, proj.Name, changeRepoName, change))
}

// dispatchResponse is the one shape a dispatch answers with.
//
// A fresh dispatch and a deduplicated repeat both build their response here, so
// the caller cannot tell them apart and needs no branch — which is the point of
// the idempotency key. Two separately written response literals would drift.
func dispatchResponse(runID, project, changeRepoName string, change ChangeRef) map[string]interface{} {
	return map[string]interface{}{
		"status":  "dispatched",
		"task_id": runID,
		"project": project,
		// The change is reported as it was resolved on disk, including which repo
		// holds it, so the operator can find the audit artifact for this run.
		"change_id":      change.ID,
		"change_dir":     change.Dir,
		"change_repo":    changeRepoName,
		"change_created": change.Created,
	}
}

// respondWithExistingRun answers a repeat of a known idempotency key with the run
// that key already created.
//
// It reports the stored run's own change, not the change this repeat resolved. A
// caller that reuses a key with a different brief would otherwise be told its new
// change id alongside somebody else's run id, and the dashboard rule is that
// nothing is rendered that cannot be derived from stored state.
func (srv *Server) respondWithExistingRun(
	w http.ResponseWriter,
	requestID, changeRepoPath, changeRepoName string,
	resolved ChangeRef,
) {
	existing, err := srv.Store.GetRunByRequestID(requestID)
	if err != nil {
		// The insert was refused for this key and yet no run holds it. Something
		// deleted the run between the two statements. Say so rather than inventing
		// a run id.
		http.Error(w, fmt.Sprintf(
			"request id %q is already in use but its run could not be read back: %v", requestID, err),
			http.StatusInternalServerError)
		return
	}

	change := resolved
	if existing.ChangeID != resolved.ID {
		// The stored run is accountable to a different change than this repeat
		// named. Prove that change's directory rather than asserting it; a
		// non-empty id makes resolveChange verify and never scaffold.
		change, err = resolveChange(changeRepoPath, existing.ChangeID, "")
		if err != nil {
			http.Error(w, fmt.Sprintf(
				"run %s is accountable to change %q, which could not be resolved: %v",
				existing.ID, existing.ChangeID, err), http.StatusInternalServerError)
			return
		}
	}
	// A repeat scaffolded nothing, whatever the original did.
	change.Created = false

	writeJSON(w, http.StatusOK, dispatchResponse(existing.ID, existing.Project, changeRepoName, change))
}

// DeliveryReport describes what a run actually produced on disk. Every field is
// observed, never assumed. It deliberately has no "pr_url" unless a PR exists.
type DeliveryReport struct {
	Repo       string   `json:"repo"`
	Worktree   string   `json:"worktree"`
	Branch     string   `json:"branch"`
	Commits    int      `json:"commits"`
	Dirty      bool     `json:"dirty"`
	Pushed     bool     `json:"pushed"`
	RemoteBase string   `json:"remote_base,omitempty"`
	CompareURL string   `json:"compare_url,omitempty"`
	Summary    string   `json:"summary"`
	Artifacts  []string `json:"artifacts"`
	ReadyForPR bool     `json:"ready_for_pr"`
}

func gitOut(dir string, args ...string) string {
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// describeDelivery inspects the run's isolated worktree and reports its real state.
// It never claims a pull request exists; opening one is an explicit human action
// through /api/create-pr.
func (srv *Server) describeDelivery(proj *config.Project, runID string) DeliveryReport {
	branch := ""
	if run, err := srv.Store.GetRun(runID); err == nil {
		branch = naming.BranchNameForRun(run.ID, run.Type, run.ChangeID)
	}

	// Report on the first repo that actually produced a worktree for this run.
	for repoName, rCfg := range proj.Repos {
		wt := dag.FleetDir(runID, repoName)
		if _, err := os.Stat(wt); err != nil {
			continue
		}

		rep := DeliveryReport{Repo: repoName, Worktree: wt, Branch: branch}
		rep.Dirty = gitOut(wt, "status", "--porcelain") != ""
		if n := gitOut(wt, "rev-list", "--count", "HEAD", "^"+defaultBase(wt)); n != "" {
			fmt.Sscanf(n, "%d", &rep.Commits)
		}
		rep.Pushed = gitOut(wt, "rev-parse", "--verify", "origin/"+branch) != ""
		rep.RemoteBase = resolveGitRemoteURL(expandHome(rCfg.Path))
		if rep.RemoteBase != "" && rep.Pushed {
			rep.CompareURL = fmt.Sprintf("%s/compare/%s?expand=1", rep.RemoteBase, branch)
		}

		switch {
		case rep.Commits == 0 && rep.Dirty:
			rep.Summary = fmt.Sprintf("Uncommitted changes in worktree for %s — nothing committed yet", repoName)
		case rep.Commits == 0:
			rep.Summary = fmt.Sprintf("Run completed with no changes to %s", repoName)
		case !rep.Pushed:
			rep.Summary = fmt.Sprintf("%d commit(s) on %s in an isolated worktree — not pushed", rep.Commits, branch)
			rep.ReadyForPR = true
		default:
			rep.Summary = fmt.Sprintf("%d commit(s) pushed to %s — ready to open a PR", rep.Commits, branch)
			rep.ReadyForPR = true
		}

		rep.Artifacts = []string{wt}
		if rep.CompareURL != "" {
			rep.Artifacts = append(rep.Artifacts, rep.CompareURL)
		}
		return rep
	}

	return DeliveryReport{
		Repo:      proj.Name,
		Branch:    branch,
		Summary:   "Run completed but produced no isolated worktree",
		Artifacts: []string{},
	}
}

// defaultBase resolves the branch a run should be diffed against.
func defaultBase(dir string) string {
	if ref := gitOut(dir, "symbolic-ref", "refs/remotes/origin/HEAD"); ref != "" {
		return strings.TrimPrefix(ref, "refs/remotes/")
	}
	for _, c := range []string{"origin/main", "origin/master", "main", "master"} {
		if gitOut(dir, "rev-parse", "--verify", c) != "" {
			return c
		}
	}
	return "HEAD"
}

func expandHome(p string) string {
	if strings.HasPrefix(p, "~/") {
		home, _ := os.UserHomeDir()
		return filepath.Join(home, p[2:])
	}
	return p
}

// dirtyWorktreesUnder returns the names of per-repo worktrees beneath a run's
// fleet directory that still contain uncommitted changes.
func dirtyWorktreesUnder(runDir string) []string {
	entries, err := os.ReadDir(runDir)
	if err != nil {
		return nil
	}
	var dirty []string
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		repoWT := filepath.Join(runDir, e.Name())
		if gitOut(repoWT, "rev-parse", "--git-dir") == "" {
			continue // not a worktree
		}
		if gitOut(repoWT, "status", "--porcelain") != "" {
			dirty = append(dirty, e.Name())
		}
	}
	return dirty
}

// firstLine trims a brief down to a usable commit subject.
func firstLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexAny(s, "\r\n"); i >= 0 {
		s = s[:i]
	}
	if len(s) > 72 {
		s = strings.TrimSpace(s[:72])
	}
	return s
}

func marshalRaw(v interface{}) json.RawMessage {
	b, err := json.Marshal(v)
	if err != nil {
		return json.RawMessage(`{}`)
	}
	return json.RawMessage(b)
}

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

func cancelNote(stopped bool) string {
	if stopped {
		return "Run cancelled and in-flight agent work signalled to stop."
	}
	return "No in-flight run found on this server; status recorded as cancelled only."
}

// handleDeliveryHistory answers a run-scoped view of delivery state, the
// dashboard's substrate for R5.6. run_id is required — an empty result set for
// a missing id would be indistinguishable from "this run truly has no
// deliveries", so the two cases must not share a response shape.
func (srv *Server) handleDeliveryHistory(w http.ResponseWriter, r *http.Request) {
	runID := r.URL.Query().Get("run_id")
	if runID == "" {
		http.Error(w, "missing run_id", http.StatusBadRequest)
		return
	}

	deliveries, err := srv.Store.ListDeliveriesForRun(runID)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if deliveries == nil {
		deliveries = []store.DeliveryRecord{}
	}
	writeJSON(w, http.StatusOK, deliveries)
}

// handleDeliveryQuarantine is a thin transport over Store.QuarantineDelivery.
// It reconstructs nothing: quarantine only ever writes a record, so unlike
// replay there is no attempt closure to recover. The store's guard (refusing
// unless the delivery's latest state is dead_letter) is the only rule; this
// handler must not weaken or duplicate it.
func (srv *Server) handleDeliveryQuarantine(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		EnvelopeID string `json:"envelope_id"`
		Consumer   string `json:"consumer"`
		Reason     string `json:"reason"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil ||
		req.EnvelopeID == "" || req.Consumer == "" || req.Reason == "" {
		http.Error(w, "invalid request body: envelope_id, consumer, and reason are all required", http.StatusBadRequest)
		return
	}

	if err := srv.Store.QuarantineDelivery(req.EnvelopeID, req.Consumer, req.Reason); err != nil {
		// The guard's own message, not a generic 500: this refusal is an expected
		// outcome (the delivery is not dead_letter), not a server failure.
		http.Error(w, err.Error(), http.StatusConflict)
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"status":      "quarantined",
		"envelope_id": req.EnvelopeID,
		"consumer":    req.Consumer,
	})
}

// handleBuildGraph triggers a project's cross-repository code graph build
// (decision D9). It is the one explicit trigger this bullet adds — no CLI
// binary, no dashboard button, no automatic dispatch-lifecycle hook.
func (srv *Server) handleBuildGraph(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		Project string `json:"project"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Project == "" {
		http.Error(w, "invalid request body: project is required", http.StatusBadRequest)
		return
	}

	proj, err := config.LoadProject(req.Project)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if proj.Graphify == nil {
		http.Error(w, fmt.Sprintf("project %q has no graphify configuration", req.Project), http.StatusBadRequest)
		return
	}

	if err := graphify.BuildProjectGraph(proj); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"status": "built",
		"output": proj.Graphify.Output,
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

// executeRun drives a run's stages to completion and records its terminal status.
//
// It serves both a fresh dispatch and a resume. The two differ only in whether the
// run record already existed and in engine.Resume, which decides whether phases
// with a passed record are skipped. Keeping one body means a resumed run cannot
// drift from a dispatched one — commit behaviour, cancellation handling and
// delivery reporting are identical by construction rather than by discipline.
//
// changeDir is the absolute path to the OpenSpec change directory (may be empty
// for resume paths that do not carry it — those runs report no progress).
func (srv *Server) executeRun(
	ctx context.Context,
	cancel context.CancelFunc,
	engine *dag.Engine,
	proj *config.Project,
	taskID string,
	brief string,
	repos []string,
	changeDir string,
) {
	defer cancel()
	defer srv.finishRun(taskID)

	// Sample .sergeant/plan.json periodically while the run is in flight and
	// publish progress to the change stream so dashboard clients receive it over
	// the existing SSE connection. The goroutine stops when ctx is cancelled.
	//
	// Sampling is done here (in the run goroutine) rather than in the stream
	// handler so that N connected clients produce exactly one sampling tick, not
	// N. A five-second interval keeps the dashboard feeling live without hammering
	// the filesystem.
	//
	// A non-fatal error from appendRunProgress is silently ignored: the function
	// already swallows errors internally.
	go func() {
		t := time.NewTicker(5 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				srv.appendRunProgress(taskID)
			}
		}
	}()

	// setTerminal refuses to overwrite a cancellation. Previously the goroutine
	// unconditionally wrote "passed" at the end, silently reviving runs the
	// operator had stopped.
	setTerminal := func(status string) {
		if ctx.Err() != nil {
			srv.recordTerminalRun(taskID, "cancelled")
			return
		}
		srv.recordTerminalRun(taskID, status)
	}

	// Thread the change directory into the engine so RunStage can seed
	// .sergeant/plan.json into each worktree after prepareWorktree succeeds
	// but before the first agent phase starts.
	engine.ChangeDir = changeDir

	var stages []config.DAGStage
	if proj.DAG != nil && len(proj.DAG.Stages) > 0 {
		stages = proj.DAG.Stages
	} else {
		// One rule for resolving targets, shared with dispatch. A resume recovers
		// its repo list from phase records, which is empty when the original run
		// died before recording any, so the fallback has to apply here too — and it
		// has to be the same sorted fallback, or a resumed run could take a
		// different merge order than the dispatch that created it.
		stages = []config.DAGStage{{
			Name:  "custom-dispatch",
			Repos: targetRepositories(proj, repos),
			Brief: brief,
		}}
	}

	// Commit the agents' output. An uncommitted worktree is eligible for deletion
	// by "clean worktrees", so leaving it uncommitted means real work can be
	// destroyed by an unrelated click. Committing also makes it reviewable.
	commitMsg := firstLine(brief)
	if commitMsg == "" {
		commitMsg = "sergeant: automated changes"
	}
	commitAll := func() {
		for _, stage := range stages {
			for _, repoName := range stage.Repos {
				if _, _, err := dag.CommitRunOutput(context.Background(), taskID, repoName, commitMsg); err != nil {
					log.Printf("sergeant: commit failed for run %s repo %s: %v", taskID, repoName, err)
				}
			}
		}
	}

	// Sample plan progress on a background ticker while stages run. The ticker
	// appends a progress change to the change sequence so dashboard clients
	// learn about it over the existing SSE stream, with no new endpoint and no
	// client-side polling. The design says "reads happen when the run is
	// sampled — the same tick that already serves the change stream"; this is
	// the write side of that tick.
	//
	// Rules:
	//   - Sampling is best-effort: errors are silently swallowed (the plan file
	//     must not be able to fail the run).
	//   - The goroutine stops when ctx is cancelled or the stages loop exits.
	//   - Sergeant only reads here; the agent is the sole writer after seeding.
	progressCtx, stopProgress := context.WithCancel(ctx)
	defer stopProgress()
	go func() {
		t := time.NewTicker(2 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-progressCtx.Done():
				return
			case <-t.C:
				srv.appendRunProgress(taskID)
			}
		}
	}()

	for i := range stages {
		if ctx.Err() != nil {
			setTerminal("cancelled")
			return
		}
		if err := engine.RunStage(ctx, taskID, &stages[i]); err != nil {
			// Commit before reporting failure: a failed gate still leaves real agent
			// work on disk, and it must be reviewable rather than stranded.
			commitAll()
			setTerminal("failed")
			return
		}
	}

	if ctx.Err() != nil {
		setTerminal("cancelled")
		return
	}

	// Stop the progress sampling goroutine before the final sample, so the two
	// cannot interleave. One more sample after all stages complete captures
	// whatever the agent wrote last.
	stopProgress()
	srv.appendRunProgress(taskID)

	commitAll()

	// Delivery. This reports what actually happened on disk. It does NOT claim a
	// pull request exists — nothing in this path pushes a branch or calls the
	// GitHub API. Opening the PR is an explicit human action via /api/create-pr.
	delivery := srv.describeDelivery(proj, taskID)
	deliveryNow := time.Now().UTC()
	_ = srv.Store.RecordEnvelope(&store.EnvelopeRecord{
		ID:            fmt.Sprintf("delivery-%s-%d", taskID, deliveryNow.UnixNano()),
		RunID:         taskID,
		Repo:          delivery.Repo,
		Stage:         "review",
		Summary:       delivery.Summary,
		Artifacts:     delivery.Artifacts,
		Data:          marshalRaw(delivery),
		Type:          "run.delivered",
		SchemaVersion: "1",
		OccurredAt:    deliveryNow,
		Producer:      "sergeant/ui",
		CorrelationID: taskID,
		CausationID:   srv.Store.CausationFromLatest(taskID, delivery.Repo),
	})

	setTerminal("passed")
}

// recordTerminalRun writes a run's terminal status and advances the bullets that
// status justifies.
//
// It is the single place a run's outcome becomes a fact about the work. Before
// this, a run recorded passed or failed and its bullets stayed exactly as the
// dispatch wrote them — a row written once and never updated, stating something
// false for the whole life of the run.
//
// The bullet advance follows the run status write and never precedes it. Moving
// bullets for an outcome the run row does not carry would make the two records
// disagree about the same run.
//
// The intent is not touched here. Its status is derived from the bullets by the
// store, because an intent may span several bullets and several runs, so no one
// run knows whether the intent is complete.
func (srv *Server) recordTerminalRun(runID, status string) {
	if err := srv.Store.UpdateRunStatus(runID, status); err != nil {
		log.Printf("sergeant: recording terminal status %s for run %s: %v", status, runID, err)
		return
	}
	bulletStatus, advances := bulletStatusForRunOutcome(status)
	if !advances {
		return
	}
	reason := srv.blockedReasonForRun(runID, bulletStatus)
	if err := srv.Store.AdvanceBulletsForRun(runID, bulletStatus, reason); err != nil {
		log.Printf("sergeant: advancing the bullets of run %s to %s: %v", runID, bulletStatus, err)
	}
}

// blockedReasonForRun resolves the reason a run's bullets carry when they
// become bulletStatus. It is only meaningful for "blocked" — every other
// status carries no reason, because BlockedReason (D5(b)) exists to explain
// why a bullet is stuck, not to annotate green or any other outcome.
//
// An agent's own envelope may have named why it could not proceed, in its
// payload's blocked_reason key (design.md, "Where the reason comes from").
// Envelopes are read in the order they were recorded, and the last one
// naming a reason wins, so the run's most recent word on why it is stuck is
// what a human sees. When no envelope named one, a synthesized reason is
// used: sergeant dispatches a bullet's work exactly once per run and a run's
// own retry budget is already exhausted by the time it concludes without
// passing, so a human is never left with "blocked" and no explanation at all.
func (srv *Server) blockedReasonForRun(runID, bulletStatus string) string {
	if bulletStatus != "blocked" {
		return ""
	}
	envelopes, err := srv.Store.ListEnvelopesForRun(runID)
	if err != nil {
		log.Printf("sergeant: loading envelopes for run %s to resolve a blocked reason: %v", runID, err)
	}
	var reason string
	for _, e := range envelopes {
		if r := handoff.BlockedReason(e.Data); r != "" {
			reason = r
		}
	}
	if reason == "" {
		reason = "gates did not pass; no further automatic attempt available"
	}
	return reason
}

// bulletStatusForRunOutcome maps a run's terminal status onto the bullet status
// that outcome justifies. The second return is false when the outcome justifies
// no move at all, which is not the same as mapping to an unchanged status: it is
// the statement that this outcome concluded nothing about the bullets.
//
// passed becomes green, not sealed and not merged. The documented lifecycle is
// pending → red → green → sealed → merged, and passing gates means the work
// exists, not that it was reviewed, submitted or delivered (decision D6). sealed
// stays owned by the pull-request path and merged by observed PR state.
//
// failed becomes blocked, carrying a reason (decision D5(b)): sergeant dispatches
// a bullet's work exactly once per run and a run's own retry budget is already
// exhausted by the time it concludes without passing, so a bullet reaching this
// case already means no further automatic attempt is going to help — which is a
// human decision point, not merely "one attempt among several did not pass".
// This is a full replacement of "failed" as a run outcome going forward; failed
// remains a valid, undisturbed value only on rows a run wrote before this change.
//
// cancelled moves nothing. An operator stopping a run has concluded nothing about
// the work, and recording blocked would assert a judgment the operator did not
// make. Every outcome not named here is treated the same way, so an outcome this
// change did not reason about cannot silently be read as stuck.
func bulletStatusForRunOutcome(runStatus string) (string, bool) {
	switch runStatus {
	case "passed":
		return "green", true
	case "failed":
		return "blocked", true
	default:
		return "", false
	}
}

// ResumableStatuses are the run statuses a resume accepts.
//
// A passed run is excluded because re-running earned work can only lose it: a
// flaky gate would turn a pass into a failure. A running run is excluded because
// resuming it would put two agents in one worktree.
//
// interrupted is included: the coordinator stopped, not the work. Nothing judged
// the run; it was cut off. ReconcileOrphanedRuns moves orphaned running runs to
// this status at startup so the normal resume path recovers them without operator
// archaeology.
var ResumableStatuses = []string{"failed", "cancelled", "timed_out", "interrupted"}

func isResumable(status string) bool {
	for _, s := range ResumableStatuses {
		if status == s {
			return true
		}
	}
	return false
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

// reposForRun recovers which repositories a run touched from its phase records.
// An empty result lets the caller fall back to the project's configured repos.
func (srv *Server) reposForRun(runID string) []string {
	phases, err := srv.Store.ListPhasesForRun(runID)
	if err != nil {
		return nil
	}
	seen := map[string]bool{}
	var out []string
	for _, p := range phases {
		if p.Repo != "" && !seen[p.Repo] {
			seen[p.Repo] = true
			out = append(out, p.Repo)
		}
	}
	return out
}

// passedPhaseNames reports which phases a resume will skip, so the response says
// what it is not going to do rather than leaving the operator to infer it.
func (srv *Server) passedPhaseNames(runID string) []string {
	phases, err := srv.Store.ListPhasesForRun(runID)
	if err != nil {
		return nil
	}
	var out []string
	for _, p := range phases {
		if p.Status == "passed" {
			out = append(out, p.Name)
		}
	}
	return out
}

// appendRunProgress samples .sergeant/plan.json from every worktree belonging
// to runID and appends a progress change to the change sequence so dashboard
// clients learn about it over the existing SSE stream.
//
// Rules:
//   - If no worktree exists, or the plan file is absent or malformed, no change
//     is appended ("no progress reported" ≠ "zero progress").
//   - A plan change does NOT alter the run or phase status. Progress is reported,
//     never proven.
//   - The function is non-fatal: any error is silently swallowed so a broken
//     plan file cannot stop the run.
//
// The function scans FleetDir(runID, *) — all per-repo subdirectories under the
// run's fleet directory — so it covers multi-repo runs automatically.
func (srv *Server) appendRunProgress(runID string) {
	runDir := filepath.Join(dag.FleetRoot(), runID)
	entries, err := os.ReadDir(runDir)
	if err != nil {
		// Fleet dir absent (e.g. run never reached worktree creation): no progress.
		return
	}

	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		// Skip the shared handoff directory, which is not a repo worktree.
		if entry.Name() == "handoff" {
			continue
		}
		worktree := filepath.Join(runDir, entry.Name())
		p := plan.ReadPlan(worktree)
		if p == nil {
			// Absent or malformed: no progress reported for this repo.
			continue
		}

		// Build per-item status slice for the payload.
		type itemStatus struct {
			ID       string `json:"id"`
			Status   string `json:"status"`
			Scenario string `json:"scenario"`
		}
		items := make([]itemStatus, 0, len(p.Items))
		for _, it := range p.Items {
			items = append(items, itemStatus{
				ID:     it.ID,
				Status: it.Status,
				// Scenario is sergeant-seeded from the spec and the agent is
				// instructed not to alter it, but plan.json is a file the
				// agent has raw write access to and nothing enforces that
				// instruction in code — and AppendChange writes straight to
				// the changes table via raw SQL, bypassing the
				// RecordPhase/RecordEnvelope choke point entirely.
				Scenario: redact.Text(it.Scenario),
			})
		}

		payload := map[string]interface{}{
			"run_id":   runID,
			"repo":     entry.Name(),
			"complete": p.Complete(),
			"total":    p.Total(),
			"items":    items,
		}
		_, _ = srv.Store.AppendChange(store.ChannelProgress, runID, payload)
	}
}
