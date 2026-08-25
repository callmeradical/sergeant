package ui

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"

	"github.com/callmeradical/sergeant/internal/config"
	"github.com/callmeradical/sergeant/internal/store"
)

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
