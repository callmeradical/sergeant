package ui

import (
	"context"
	"embed"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/callmeradical/sergeant/internal/config"
	"github.com/callmeradical/sergeant/internal/graphify"
	"github.com/callmeradical/sergeant/internal/naming"
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

	// RunShippingGate runs one shipping-gate command. It is a struct field
	// defaulting to runner.RunShippingGate, not a bare call inside
	// handleCreatePR, so a test can substitute a recording stub and prove no
	// shipping-gate command ran for a project that declares none — the same
	// swap-a-dependency shape GHPRCreate above already uses.
	RunShippingGate func(ctx context.Context, name, command string, worktrees []string) (*runner.GateResult, error)

	// cancels holds one CancelFunc per in-flight run so that a cancel request can
	// actually stop the work. Without it "Stop Run" only writes a status column
	// that the dispatch goroutine later overwrites, and agents keep writing to
	// worktrees after the operator believes they were stopped.
	mu      sync.Mutex
	cancels map[string]context.CancelFunc

	// fleet owns fleet worktree views and reclaim decisions (see fleet.go). It
	// depends on fleetRunSource rather than *store.Store directly.
	fleet *fleetCleaner

	// delivery owns delivery reporting (see delivery.go). It depends on
	// runGetter rather than *store.Store directly.
	delivery *deliveryReporter

	// terminal owns embedded-terminal session state and PTY lifecycle (see
	// terminal.go).
	terminal *terminalManager
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
		Store:           s,
		Port:            port,
		cancels:         map[string]context.CancelFunc{},
		GHPRCreate:      runGHPRCreate,
		RunShippingGate: runner.RunShippingGate,
		fleet:           newFleetCleaner(s),
		delivery:        newDeliveryReporter(s),
		terminal:        newTerminalManager(),
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
	mux.HandleFunc("/api/fleet", srv.fleet.handleFleet)
	mux.HandleFunc("/api/clean-worktrees", srv.fleet.handleCleanWorktrees)
	mux.HandleFunc("/api/run-cancel", srv.handleRunCancel)
	mux.HandleFunc("/api/run-resume", srv.handleRunResume)
	mux.HandleFunc("/api/run-delete", srv.handleRunDelete)
	mux.HandleFunc("/api/delivery-history", srv.handleDeliveryHistory)
	mux.HandleFunc("/api/delivery-quarantine", srv.handleDeliveryQuarantine)
	mux.HandleFunc("/api/build-graph", srv.handleBuildGraph)
	// The sequenced state stream. Clients follow this instead of re-reading
	// /api/runs on a timer.
	mux.HandleFunc("/api/stream", srv.handleStream)
	mux.HandleFunc("/api/terminal-start", srv.handleTerminalStart)
	mux.HandleFunc("/api/terminal-socket", srv.handleTerminalSocket)
	mux.HandleFunc("/api/terminal-kill", srv.handleTerminalKill)

	// Vendored xterm.js assets, served the same way index.html already is
	// (via the embedded static/* glob), plus a long cache header: these
	// files are versioned by filename choice, not auto-fingerprinted, so
	// their content never changes under a given path.
	mux.HandleFunc("/static/xterm.js", srv.handleStaticAsset("xterm.js", "text/javascript; charset=utf-8"))
	mux.HandleFunc("/static/xterm.css", srv.handleStaticAsset("xterm.css", "text/css; charset=utf-8"))
	mux.HandleFunc("/static/xterm-addon-fit.js", srv.handleStaticAsset("xterm-addon-fit.js", "text/javascript; charset=utf-8"))

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
	go srv.fleet.runFleetCleanupLoop(context.Background())

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

// handleStaticAsset serves one embedded static/* file with a long,
// immutable cache header, mirroring handleIndex's embed.FS read but for a
// file whose content is safe to cache indefinitely.
func (srv *Server) handleStaticAsset(name, contentType string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		data, err := staticFS.ReadFile("static/" + name)
		if err != nil {
			http.Error(w, "asset not found", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", contentType)
		w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
		_, _ = w.Write(data)
	}
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

	// D5(c)/shipping-gate: the seal above may have been the last bullet an
	// intent needed to reach sealed-or-merged. If so, this is the one point in
	// the codebase where that condition is checked and the intent's shipping
	// gate evaluated — exactly once per intent's path to the condition
	// becoming true, not a recurring poll. This never fails or delays the
	// PR-creation response below: a shipping-gate outcome is bookkeeping on
	// the intent, not a precondition for the seal or PR action that already
	// succeeded.
	if run.IntentID != "" {
		if bullets, berr := srv.Store.ListBulletsForIntent(run.IntentID); berr == nil && store.AllBulletsSealedOrMerged(bullets) {
			srv.evaluateShippingGate(r.Context(), proj, run.IntentID, bullets)
		}
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

// evaluateShippingGate runs an intent's configured shipping gates and records
// the outcome. Callers must have already confirmed AllBulletsSealedOrMerged
// for intentID — this does not re-check it — because the trigger is "the seal
// that completed the condition", not a standing poll.
//
// A project with no ShippingGates configured records a pass immediately and
// unconditionally, invoking no command, matching how FactoryConfig.Gates
// already defaults to none (PRD: "A project with no configured shipping
// gates passes trivially"). Otherwise every configured gate runs, in sorted
// name order for the same determinism TestGatesRunInDeterministicOrder
// already requires of per-bullet gates; the first failing gate's name becomes
// the recorded reason.
//
// Errors recording the result are swallowed (matching every other
// best-effort write in this handler, e.g. RecordEnvelope above): a shipping
// gate is bookkeeping on the intent, not a precondition for the seal or PR
// action that already succeeded.
func (srv *Server) evaluateShippingGate(ctx context.Context, proj *config.Project, intentID string, bullets []store.BulletRecord) {
	if proj == nil || len(proj.ShippingGates) == 0 {
		_ = srv.Store.RecordShippingGateResult(intentID, true, "")
		return
	}

	worktrees := make([]string, len(bullets))
	for i, b := range bullets {
		worktrees[i] = b.Worktree
	}

	names := make([]string, 0, len(proj.ShippingGates))
	for name := range proj.ShippingGates {
		names = append(names, name)
	}
	sort.Strings(names)

	allPassed := true
	var firstFailureReason string
	for _, name := range names {
		res, _ := srv.RunShippingGate(ctx, name, proj.ShippingGates[name], worktrees)
		if res == nil || !res.Passed {
			allPassed = false
			if firstFailureReason == "" {
				firstFailureReason = fmt.Sprintf("shipping gate %q failed", name)
			}
		}
	}
	_ = srv.Store.RecordShippingGateResult(intentID, allPassed, firstFailureReason)
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
