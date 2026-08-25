package ui

import (
	"fmt"
	"os"

	"github.com/callmeradical/sergeant/internal/config"
	"github.com/callmeradical/sergeant/internal/dag"
	"github.com/callmeradical/sergeant/internal/naming"
	"github.com/callmeradical/sergeant/internal/store"
)

// DeliveryReport is what describeDelivery reports: the run's isolated
// worktree's real, on-disk state. Never a claim about anything git cannot
// prove (AGENTS.md's truthfulness rule; see also the "delivery reports never
// claim a PR that git cannot prove" test).
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

// runGetter is the one store method describeDelivery needs: the run's
// recorded type and change id, to name the branch it should look for on
// disk. Defined here, in the consuming file, so a test can substitute a
// fake run instead of a real SQLite-backed store.
type runGetter interface {
	GetRun(runID string) (*store.RunRecord, error)
}

// deliveryReporter owns delivery reporting. It depends on runGetter rather
// than *store.Store directly.
type deliveryReporter struct {
	runs runGetter
}

func newDeliveryReporter(runs runGetter) *deliveryReporter {
	return &deliveryReporter{runs: runs}
}

// describeDelivery inspects the run's isolated worktree and reports its real state.
// It never claims a pull request exists; opening one is an explicit human action
// through /api/create-pr.
func (dr *deliveryReporter) describeDelivery(proj *config.Project, runID string) DeliveryReport {
	branch := ""
	if run, err := dr.runs.GetRun(runID); err == nil {
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
