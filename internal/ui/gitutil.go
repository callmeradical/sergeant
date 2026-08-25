package ui

import (
	"os/exec"
	"path/filepath"
	"strings"

	"os"
)

// gitOut runs a git subcommand in dir and returns its trimmed stdout, or ""
// on any error — callers treat "" as "unknown" rather than distinguishing
// failure reasons, since none of them act on a specific git error today.
func gitOut(dir string, args ...string) string {
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
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
