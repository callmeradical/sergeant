package ui

// handleDispatch, createRunAndDispatch, executeRun and their support functions
// move here verbatim from server.go — the run-execution state machine, the
// largest and riskiest undivided block server.go still held (proposal.md).
// No behavior change: same validation order, same response shapes, same
// records created, same stage-execution and terminal-status behavior.
//
// This introduces exactly one interface, stageRunner (design.md): executeRun's
// engine parameter narrows from *dag.Engine to stageRunner, which *dag.Engine
// already satisfies unmodified. No interface is introduced for *store.Store
// (design.md's "Rejected alternatives") — every *store.Store dependency here
// stays direct and concrete, matching every other handler in this package that
// was not extracted behind a seam.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/callmeradical/sergeant/internal/config"
	"github.com/callmeradical/sergeant/internal/dag"
	"github.com/callmeradical/sergeant/internal/handoff"
	"github.com/callmeradical/sergeant/internal/naming"
	"github.com/callmeradical/sergeant/internal/plan"
	"github.com/callmeradical/sergeant/internal/redact"
	"github.com/callmeradical/sergeant/internal/runner"
	"github.com/callmeradical/sergeant/internal/store"
)

// stageRunner is the one method executeRun needs from a stage-execution
// engine. *dag.Engine already satisfies it unmodified. The seam exists so a
// test can drive executeRun's goroutine — which today requires a real git
// worktree and a real or stubbed agent CLI via *dag.Engine — with a fake
// that records which stages ran and returns a canned result instead.
type stageRunner interface {
	RunStage(ctx context.Context, runID string, stage *config.DAGStage) error
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
	// Thread the change directory into the engine so RunStage can seed
	// .sergeant/plan.json into each worktree after prepareWorktree succeeds
	// but before the first agent phase starts. Set here, on the concrete
	// engine, rather than inside executeRun: executeRun's engine parameter is
	// stageRunner (a 1-method interface), which does not expose ChangeDir.
	engine.ChangeDir = change.Dir

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
	engine stageRunner,
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
	delivery := srv.delivery.describeDelivery(proj, taskID)
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
// A "review" phase's envelope instead carries a findings array
// (a-green-bullet-awaits-independent-review); when it contains any
// severity:"error" finding, that finding's Summary (joined, if more than
// one) is the reason instead of falling through to handoff.BlockedReason or
// the synthesized string for that envelope. Envelopes are read in the order
// they were recorded, and the last one naming a reason wins either way, so
// the run's most recent word on why it is stuck is what a human sees. When
// no envelope named one, a synthesized reason is used: sergeant dispatches a
// bullet's work exactly once per run and a run's own retry budget is already
// exhausted by the time it concludes without passing, so a human is never
// left with "blocked" and no explanation at all.
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
		if e.Stage == "review" {
			if findings := handoff.ReviewFindings(e.Data); handoff.HasBlockingFinding(findings) {
				var summaries []string
				for _, f := range findings {
					if f.Severity == "error" {
						summaries = append(summaries, f.Summary)
					}
				}
				reason = strings.Join(summaries, "; ")
				continue
			}
		}
		if r := handoff.BlockedReason(e.Data); r != "" {
			reason = r
		}
	}
	if reason == "" {
		reason = "gates did not pass; no further automatic attempt available"
	}
	return reason
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
