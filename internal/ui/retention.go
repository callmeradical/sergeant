package ui

import (
	"context"
	"log"
	"sync"
	"time"

	"github.com/callmeradical/sergeant/internal/config"
	"github.com/callmeradical/sergeant/internal/store"
)

// retentionInterval is how often the automatic rotation pass runs. Fixed,
// not configurable — the same reasoning fleetCleanupInterval already
// documents for this single-user, local-first tool.
const retentionInterval = 1 * time.Hour

// retentionPass records the outcome of one rotation pass for a project, kept
// in memory only — matching fleetCleaner's own in-memory last-run
// bookkeeping, since this only ever needs to answer "since this process
// started."
type retentionPass struct {
	LastRunAt        time.Time
	RunsRotated      int
	ArtifactsRotated int
}

// retentionRotator owns the background data-rotation pass: for every project
// with a non-nil Retention, it rotates runs/phases/envelopes/deliveries past
// RunsAfterDays and artifacts past ArtifactsAfterDays, and remembers each
// project's last pass so the analytics response can report it.
type retentionRotator struct {
	store *store.Store

	mu        sync.Mutex
	byProject map[string]retentionPass
}

func newRetentionRotator(s *store.Store) *retentionRotator {
	return &retentionRotator{store: s, byProject: map[string]retentionPass{}}
}

// rotateAll runs one pass over every configured project. A project with no
// Retention block is skipped entirely — it is never rotated, regardless of
// how old its runs are (spec.md's "A project with no retention block never
// rotates").
func (r *retentionRotator) rotateAll() {
	projects, err := config.ListProjects()
	if err != nil {
		log.Printf("sergeant: retention: listing projects: %v", err)
		return
	}

	now := time.Now()
	for _, p := range projects {
		if p.Retention == nil {
			continue
		}
		runCutoff := now.Add(-time.Duration(p.Retention.RunsAfterDays) * 24 * time.Hour)
		artifactCutoff := now.Add(-time.Duration(p.Retention.ArtifactsAfterDays) * 24 * time.Hour)

		runsRotated, err := r.store.RotateProject(p.Name, runCutoff)
		if err != nil {
			log.Printf("sergeant: retention: rotating project %q runs: %v", p.Name, err)
			continue
		}
		// RotateArtifacts has no project scope of its own — the artifacts
		// table carries no project column, only run_id — so calling it here
		// with this project's own artifact cutoff is exact only when every
		// configured project shares one artifact horizon. A deployment
		// mixing horizons across projects can have one project's pass rotate
		// another's artifacts early; accepted for now since horizons
		// typically agree across a single operator's projects, per
		// proposal.md.
		artifactsRotated, err := r.store.RotateArtifacts(artifactCutoff)
		if err != nil {
			log.Printf("sergeant: retention: rotating project %q artifacts: %v", p.Name, err)
			continue
		}

		r.mu.Lock()
		r.byProject[p.Name] = retentionPass{LastRunAt: now, RunsRotated: runsRotated, ArtifactsRotated: artifactsRotated}
		r.mu.Unlock()
	}
}

// statusFor returns the most recent rotation pass recorded for project, and
// whether one has ever run.
func (r *retentionRotator) statusFor(project string) (retentionPass, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	p, ok := r.byProject[project]
	return p, ok
}

// runRetentionLoop ticks on retentionInterval for the lifetime of the
// server, mirroring fleetCleaner's runFleetCleanupLoop exactly. Started once,
// alongside Start's existing fleet-cleanup loop startup, and stops when ctx
// is cancelled.
func (r *retentionRotator) runRetentionLoop(ctx context.Context) {
	ticker := time.NewTicker(retentionInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			r.rotateAll()
		}
	}
}

// retentionSummary is the observability block GET /api/analytics attaches
// per project: {"last_run_at": "...", "runs_rotated": N, "artifacts_rotated": N}.
// Absent for a project with no retention: block configured — the same
// "absent, not zero" convention Export/Graphify already use — so an operator
// never confuses "never configured" with "configured but never run yet."
type retentionSummary struct {
	LastRunAt        string `json:"last_run_at"`
	RunsRotated      int    `json:"runs_rotated"`
	ArtifactsRotated int    `json:"artifacts_rotated"`
}

// retentionSummaryFor returns project's retention observability block, or
// nil when project declares no retention: block. Scoped to a single named
// project only — handleAnalytics' "" / "all" combined view carries no
// retention block, since it has no single project's config to check.
func (srv *Server) retentionSummaryFor(project string) *retentionSummary {
	if project == "" || project == "all" {
		return nil
	}
	proj, err := config.LoadProject(project)
	if err != nil || proj.Retention == nil {
		return nil
	}
	pass, _ := srv.retention.statusFor(project)
	return &retentionSummary{
		LastRunAt:        formatRetentionTime(pass.LastRunAt),
		RunsRotated:      pass.RunsRotated,
		ArtifactsRotated: pass.ArtifactsRotated,
	}
}

// formatRetentionTime renders t as RFC3339, or "" for the zero time — a
// project with retention configured but no pass completed yet reports an
// empty timestamp rather than a misleadingly precise one.
func formatRetentionTime(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format(time.RFC3339)
}
