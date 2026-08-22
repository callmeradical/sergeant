package ui

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/callmeradical/sergeant/internal/config"
)

// Decision O3 of docs/prd-sergeant-v2.md: a dispatch must resolve to an OpenSpec
// change, and sergeant scaffolds one from the brief if none is referenced, before
// any worktree is created. Sergeant dispatches agents that write code and open
// PRs; exempting dispatched work would make sergeant the largest producer of the
// undocumented work OpenSpec is adopted to eliminate.
//
// Decision O1 puts planning per repository, so the change lives in the target
// repo's own openspec/ and its directory travels in that repo's pull request.

// ChangeRef is a resolved OpenSpec change. Dir is only ever a directory this
// code has stat'd, so a ChangeRef is evidence the change exists on disk rather
// than a claim that it should.
type ChangeRef struct {
	ID      string // the openspec change id
	Dir     string // absolute path to openspec/changes/<id>
	Created bool   // true if we scaffolded it during this dispatch
}

// maxChangeIDLen caps a derived id. A change id becomes a directory name and the
// suffix of a branch named <type>/<change-id>, so an unbounded slug taken from a
// multi-paragraph brief is unusable as both.
const maxChangeIDLen = 48

// openSpecScaffoldTimeout bounds the `openspec new change` call. Dispatch is a
// synchronous HTTP handler; a CLI that blocks forever would hang the request
// instead of reporting a failure the operator can act on.
const openSpecScaffoldTimeout = 60 * time.Second

// openSpecInstallHint names the package that provides the binary, so the error
// tells the operator how to fix the machine rather than only what is missing.
const openSpecInstallHint = "npm install -g @fission-ai/openspec"

// changesDir is where O1 keeps changes: inside the repository being changed.
func changesDir(repoPath string) string {
	return filepath.Join(repoPath, "openspec", "changes")
}

func changeDirFor(repoPath, id string) string {
	return filepath.Join(changesDir(repoPath), id)
}

// validateChangeID rejects anything that is not a single path segment. A change
// id is interpolated into a filesystem path, so `../../etc` or `a/b` would let a
// dispatch request address a directory outside the repository's openspec tree.
func validateChangeID(id string) error {
	if id == "" {
		return fmt.Errorf("change id is empty")
	}
	// Both separators are rejected regardless of host OS: the request may have
	// been written on one platform and served on another.
	if strings.ContainsAny(id, `/\`) || strings.Contains(id, "..") || id == "." {
		return fmt.Errorf("invalid change id %q: a change id is a single kebab-case segment, not a path", id)
	}
	return nil
}

// deriveChangeID turns a brief into a kebab-case change id: lowercase, runs of
// non-alphanumeric characters collapsed to one hyphen, trimmed, and capped at
// maxChangeIDLen on a word boundary where one exists. It returns "" when the
// brief holds no alphanumeric character, because there is then no honest id to
// derive and the caller must fail rather than invent one.
func deriveChangeID(brief string) string {
	var b strings.Builder
	pendingHyphen := false
	for _, r := range brief {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
			if pendingHyphen && b.Len() > 0 {
				b.WriteByte('-')
			}
			pendingHyphen = false
			b.WriteRune(r)
		case r >= 'A' && r <= 'Z':
			if pendingHyphen && b.Len() > 0 {
				b.WriteByte('-')
			}
			pendingHyphen = false
			b.WriteRune(r + ('a' - 'A'))
		default:
			pendingHyphen = true
		}
	}

	id := b.String()
	if len(id) <= maxChangeIDLen {
		return id
	}
	id = id[:maxChangeIDLen]
	// Prefer cutting at a word boundary, but only if one survives the cut; a
	// single word longer than the cap is truncated mid-word rather than emptied.
	if cut := strings.LastIndexByte(id, '-'); cut > 0 {
		id = id[:cut]
	}
	return strings.Trim(id, "-")
}

// resolveChange resolves the OpenSpec change a dispatch is accountable to.
//
// A non-empty changeID must already exist: naming a change that is not there is
// an operator error, and scaffolding it under the given name would fabricate the
// planning record the id was supposed to point at. An empty changeID is derived
// from the brief and scaffolded with the openspec CLI.
func resolveChange(repoPath, changeID, brief string) (ChangeRef, error) {
	repoPath = strings.TrimSpace(repoPath)
	if repoPath == "" {
		return ChangeRef{}, fmt.Errorf("cannot resolve an OpenSpec change: no repository path given")
	}
	abs, err := filepath.Abs(expandHome(repoPath))
	if err != nil {
		return ChangeRef{}, fmt.Errorf("resolving repository path %s: %w", repoPath, err)
	}

	if id := strings.TrimSpace(changeID); id != "" {
		if err := validateChangeID(id); err != nil {
			return ChangeRef{}, err
		}
		dir := changeDirFor(abs, id)
		if !isDir(dir) {
			return ChangeRef{}, fmt.Errorf(
				"OpenSpec change %q not found: %s does not exist; create it with `openspec new change %s` in %s",
				id, dir, id, abs)
		}
		return ChangeRef{ID: id, Dir: dir}, nil
	}

	id := deriveChangeID(brief)
	if id == "" {
		return ChangeRef{}, fmt.Errorf(
			"cannot derive an OpenSpec change id from the brief: it contains no letters or digits")
	}
	if err := validateChangeID(id); err != nil {
		return ChangeRef{}, err
	}

	dir := changeDirFor(abs, id)
	// A brief that derives an id which already exists reuses that change rather
	// than failing: the same stated intent dispatched twice is the same change.
	if isDir(dir) {
		return ChangeRef{ID: id, Dir: dir}, nil
	}
	if err := scaffoldChange(abs, id); err != nil {
		return ChangeRef{}, err
	}
	// Trust the directory, not the exit code: the run record must not claim a
	// change whose directory is absent.
	if !isDir(dir) {
		return ChangeRef{}, fmt.Errorf(
			"`openspec new change %s` reported success but %s does not exist", id, dir)
	}
	return ChangeRef{ID: id, Dir: dir, Created: true}, nil
}

// scaffoldChange is the only part of change resolution that needs the openspec
// binary. Everything else — validation, derivation, existence checks — is pure
// Go, so the rules are testable on a machine with no CLI installed.
func scaffoldChange(repoPath, id string) error {
	bin, err := exec.LookPath("openspec")
	if err != nil {
		return fmt.Errorf(
			"dispatch requires the openspec CLI to scaffold change %q, but `openspec` is not on PATH; "+
				"install it with `%s`, or pass an existing change_id",
			id, openSpecInstallHint)
	}

	ctx, cancel := context.WithTimeout(context.Background(), openSpecScaffoldTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, bin, "new", "change", id)
	cmd.Dir = repoPath
	out, cmdErr := cmd.CombinedOutput()
	if cmdErr != nil {
		return fmt.Errorf("`openspec new change %s` failed in %s: %v: %s",
			id, repoPath, cmdErr, strings.TrimSpace(string(out)))
	}
	return nil
}

func isDir(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

// changeRepo picks the repository whose openspec/ owns this dispatch's change.
// A bullet is scoped to exactly one repository, and O1 keeps planning in that
// repository, so exactly one repo owns the change. Selection is deterministic:
// map iteration order would otherwise put a run's change in a different repo on
// every dispatch of the same request.
func changeRepo(proj *config.Project, requested []string) (name string, path string, err error) {
	if proj == nil || len(proj.Repos) == 0 {
		return "", "", fmt.Errorf("project has no repositories configured, so no repository can hold the OpenSpec change")
	}

	pick := func(candidates []string) (string, string, bool) {
		for _, c := range candidates {
			if rCfg, ok := proj.Repos[c]; ok && strings.TrimSpace(rCfg.Path) != "" {
				return c, rCfg.Path, true
			}
		}
		return "", "", false
	}

	if len(requested) > 0 {
		if n, p, ok := pick(requested); ok {
			return n, p, nil
		}
		return "", "", fmt.Errorf("none of the requested repos %v is configured in project %s with a path",
			requested, proj.Name)
	}

	if proj.DAG != nil && len(proj.DAG.Stages) > 0 {
		if n, p, ok := pick(proj.DAG.Stages[0].Repos); ok {
			return n, p, nil
		}
	}

	names := make([]string, 0, len(proj.Repos))
	for n := range proj.Repos {
		names = append(names, n)
	}
	sort.Strings(names)
	if n, p, ok := pick(names); ok {
		return n, p, nil
	}
	return "", "", fmt.Errorf("no repository in project %s declares a path", proj.Name)
}
