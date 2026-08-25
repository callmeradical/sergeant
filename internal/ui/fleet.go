package ui

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/callmeradical/sergeant/internal/dag"
	"github.com/callmeradical/sergeant/internal/store"
)

// fleetRunSource is the subset of *store.Store the fleet cleaner needs: which
// runs exist and which are old enough to reclaim. Defined here, in the
// consuming file, so a test can substitute a fake run list instead of a real
// SQLite-backed store.
type fleetRunSource interface {
	ListRecentRuns(limit int) ([]store.RunRecord, error)
	RunsEligibleForCleanup(cutoff time.Time) ([]store.RunRecord, error)
}

// fleetCleaner owns the fleet worktree views and reclaim decisions — both the
// on-demand /api/fleet and /api/clean-worktrees handlers and the automatic
// background pass. It depends on fleetRunSource rather than *store.Store
// directly so its handlers and the background pass are testable without a
// real database.
type fleetCleaner struct {
	runs fleetRunSource
}

func newFleetCleaner(runs fleetRunSource) *fleetCleaner {
	return &fleetCleaner{runs: runs}
}

func (fc *fleetCleaner) handleFleet(w http.ResponseWriter, r *http.Request) {
	fleetDir := dag.FleetRoot()

	type WorktreeLease struct {
		TaskID    string `json:"task_id"`
		Path      string `json:"path"`
		Status    string `json:"status"`
		CreatedAt string `json:"created_at"`
	}

	recentRuns, _ := fc.runs.ListRecentRuns(200)
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

func (fc *fleetCleaner) handleCleanWorktrees(w http.ResponseWriter, r *http.Request) {
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

	recentRuns, _ := fc.runs.ListRecentRuns(200)
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
func (fc *fleetCleaner) reclaimEligibleFleetDirs() {
	runs, err := fc.runs.RunsEligibleForCleanup(time.Now().Add(-fleetCleanupRetention))
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
func (fc *fleetCleaner) runFleetCleanupLoop(ctx context.Context) {
	ticker := time.NewTicker(fleetCleanupInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			fc.reclaimEligibleFleetDirs()
		}
	}
}
