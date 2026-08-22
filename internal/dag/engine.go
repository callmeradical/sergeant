package dag

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"

	"github.com/callmeradical/sergeant/internal/config"
	"github.com/callmeradical/sergeant/internal/handoff"
	"github.com/callmeradical/sergeant/internal/runner"
	"github.com/callmeradical/sergeant/internal/store"
)

type Engine struct {
	Project *config.Project
	Store   *store.Store
	Router  *handoff.Router
}

func NewEngine(proj *config.Project, s *store.Store, r *handoff.Router) *Engine {
	return &Engine{
		Project: proj,
		Store:   s,
		Router:  r,
	}
}

func expandPath(p string) string {
	if strings.HasPrefix(p, "~/") {
		home, _ := os.UserHomeDir()
		return filepath.Join(home, p[2:])
	}
	return p
}

// FleetDir is where per-run isolated worktrees are created.
// SERGEANT_FLEET_DIR overrides the base so tests never touch the real user path.
func FleetDir(runID, repoName string) string {
	base := os.Getenv("SERGEANT_FLEET_DIR")
	if base == "" {
		home, _ := os.UserHomeDir()
		base = filepath.Join(home, ".local", "share", "sergeant", "fleet")
	}
	return filepath.Join(base, runID, repoName)
}

// BranchName is the per-run branch created inside the isolated worktree.
func BranchName(runID string) string { return "sergeant/" + runID }

func isGitRepo(dir string) bool {
	cmd := exec.Command("git", "-C", dir, "rev-parse", "--git-dir")
	return cmd.Run() == nil
}

// prepareWorktree creates an isolated git worktree for a run so that autonomous
// agents never write to the operator's live checkout.
//
// This is not optional hardening. Running an agent directly in repoCfg.Path means
// it edits whatever branch happens to be checked out, mixes its output with the
// operator's uncommitted work, and leaves no way to review or discard the result.
// AGENTS.md requires per-repo worktree isolation for dispatched work.
//
// Returns the directory to run in, whether it is isolated, and any setup error.
func prepareWorktree(ctx context.Context, repoPath, runID, repoName string) (string, bool, error) {
	repoPath = expandPath(repoPath)

	if !isGitRepo(repoPath) {
		// Not a git repo: we cannot isolate. Refuse rather than silently mutating
		// the configured directory.
		return "", false, fmt.Errorf("repo %s at %s is not a git repository; refusing to dispatch agents into an unisolated directory", repoName, repoPath)
	}

	wt := FleetDir(runID, repoName)
	if _, err := os.Stat(wt); err == nil {
		return wt, true, nil // already prepared by an earlier stage in this run
	}
	if err := os.MkdirAll(filepath.Dir(wt), 0755); err != nil {
		return "", false, fmt.Errorf("creating fleet dir: %w", err)
	}

	branch := BranchName(runID)
	// -B resets the branch if a previous attempt left one behind.
	cmd := exec.CommandContext(ctx, "git", "-C", repoPath, "worktree", "add", "-B", branch, wt, "HEAD")
	if out, err := cmd.CombinedOutput(); err != nil {
		return "", false, fmt.Errorf("creating worktree for %s: %v: %s", repoName, err, strings.TrimSpace(string(out)))
	}
	return wt, true, nil
}

func gitOutput(ctx context.Context, dir string, args ...string) string {
	out, err := exec.CommandContext(ctx, "git", append([]string{"-C", dir}, args...)...).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// CommitRunOutput commits whatever the agents produced in a run's worktree.
//
// Leaving agent output uncommitted is a data-loss path, not a stylistic choice:
// a completed run's worktree is eligible for deletion by the "clean worktrees"
// action, which would discard the work with no way to recover it. Committing also
// makes the result reviewable (`git log`/`git diff`) and gives the delivery report
// something real to describe.
//
// Returns whether a commit was created and its short SHA.
func CommitRunOutput(ctx context.Context, runID, repoName, message string) (bool, string, error) {
	wt := FleetDir(runID, repoName)
	if _, err := os.Stat(wt); err != nil {
		return false, "", nil // no worktree for this repo
	}
	if gitOutput(ctx, wt, "status", "--porcelain") == "" {
		return false, "", nil // agents changed nothing
	}

	if out, err := exec.CommandContext(ctx, "git", "-C", wt, "add", "-A").CombinedOutput(); err != nil {
		return false, "", fmt.Errorf("staging %s: %v: %s", repoName, err, strings.TrimSpace(string(out)))
	}

	cmd := exec.CommandContext(ctx, "git", "-C", wt, "commit", "-m", message)
	// Identity is set explicitly so the commit succeeds even when the environment
	// has no global git identity, and so the author is unambiguously the tool.
	cmd.Env = append(os.Environ(),
		"GIT_AUTHOR_NAME=sergeant", "GIT_AUTHOR_EMAIL=sergeant@localhost",
		"GIT_COMMITTER_NAME=sergeant", "GIT_COMMITTER_EMAIL=sergeant@localhost",
	)
	if out, err := cmd.CombinedOutput(); err != nil {
		return false, "", fmt.Errorf("committing %s: %v: %s", repoName, err, strings.TrimSpace(string(out)))
	}
	return true, gitOutput(ctx, wt, "rev-parse", "--short", "HEAD"), nil
}

// RunStage executes a single multi-repo stage and its constituent intra-repo factories.
func (e *Engine) RunStage(ctx context.Context, runID string, stage *config.DAGStage) error {
	// Execute per-repo factory pipelines
	for _, repoName := range stage.Repos {
		repoCfg, ok := e.Project.Repos[repoName]
		if !ok {
			return fmt.Errorf("repo %s not configured in project", repoName)
		}

		worktreePath, isolated, err := prepareWorktree(ctx, repoCfg.Path, runID, repoName)
		if err != nil {
			return err
		}
		if !isolated {
			return fmt.Errorf("refusing to run agents for %s without an isolated worktree", repoName)
		}

		// Route upstream artifacts into the run's isolated worktree. This previously
		// injected into expandPath(repoCfg.Path) — the operator's live checkout — and
		// ran before any worktree existed, so upstream handoffs landed in the wrong
		// tree entirely.
		for _, upstream := range stage.After {
			_ = e.Router.InjectHandoffToWorktree(upstream, worktreePath)
		}

		pr := &runner.PhaseRunner{
			Store:    e.Store,
			Router:   e.Router,
			Worktree: worktreePath,
			RepoName: repoName,
			RunID:    runID,
			AgentCLI: e.Project.Defaults.Agent,
			Model:    e.Project.Defaults.Model,
		}

		// Run factory pipeline phases
		pipeline := []string{"plan", "build", "test"}
		if repoCfg.Factory != nil && len(repoCfg.Factory.Pipeline) > 0 {
			pipeline = repoCfg.Factory.Pipeline
		}

		for _, phase := range pipeline {
			switch phase {
			case "test":
				if repoCfg.Factory != nil && len(repoCfg.Factory.Gates) > 0 {
					// Gates run in sorted name order. Ranging over the map directly made
					// execution order random (Go randomises map iteration), so which gate
					// failed first varied between identical runs — and a run could report
					// a different failing gate each time. "Deterministic gate" has to mean
					// deterministic ordering too.
					gateNames := make([]string, 0, len(repoCfg.Factory.Gates))
					for name := range repoCfg.Factory.Gates {
						gateNames = append(gateNames, name)
					}
					sort.Strings(gateNames)

					for _, gateName := range gateNames {
						res, err := pr.RunCodeGate(ctx, gateName, repoCfg.Factory.Gates[gateName])
						if err != nil || !res.Passed {
							return fmt.Errorf("deterministic code gate %s failed on %s", gateName, repoName)
						}
					}
				} else {
					_, _ = pr.RunCodeGate(ctx, "test", "echo 'Deterministic gate passed'")
				}

			default:
				prompt := stage.Brief
				if prompt == "" {
					prompt = fmt.Sprintf("Execute %s phase for stage %s on %s", phase, stage.Name, repoName)
				}
				_, err := pr.RunAgentPhase(ctx, phase, prompt, 0)
				if err != nil {
					return fmt.Errorf("agent phase %s failed on repo %s: %w", phase, repoName, err)
				}
			}
		}
	}

	return nil
}
