// Package graphify builds and publishes a project's cross-repository code
// graph by orchestrating the external graphify binary (decision D9). It does
// not reimplement graphify's extraction or graph algorithms — those already
// exist in the installed binary, invoked the same way internal/runner
// invokes agent CLIs.
package graphify

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"time"

	"github.com/callmeradical/sergeant/internal/config"
)

// runCommand executes name with args, capturing combined output. It is a
// package variable so tests can wrap it to record every invocation
// BuildProjectGraph makes — e.g. to assert no process named sgt-graphify is
// ever spawned — while still exec'ing the real binary underneath.
var runCommand = func(name string, args ...string) ([]byte, error) {
	return exec.Command(name, args...).CombinedOutput()
}

// publishHook, when non-nil, runs immediately before BuildProjectGraph
// backs up any prior Output and renames the scratch directory into place.
// Tests use it to pause a build mid-flight and assert Output is still fully
// readable under the prior graph until the rename actually happens.
var publishHook func()

// renamePublish performs the final scratch-into-Output rename. It is a
// package variable so a test can force this specific rename to fail (e.g. a
// disk-full or permission error partway through publish) without needing a
// real cross-filesystem boundary, to prove the prior graph survives.
var renamePublish = os.Rename

// BuildProjectGraph builds a graph for each participating repository in
// proj, merges them into one cross-repository graph, and publishes the
// result atomically to proj.Graphify.Output.
//
// "Atomically" means: every artifact is written into a scratch directory
// first; only once the merged graph exists and is non-empty does a single
// directory rename move the scratch directory into place at Output. A
// reader of Output never observes a partially-written graph.
func BuildProjectGraph(proj *config.Project) error {
	if proj.Graphify == nil {
		return fmt.Errorf("project %q has no graphify configuration", proj.Name)
	}

	repoNames := participatingRepoNames(proj)
	if len(repoNames) == 0 {
		return fmt.Errorf("no participating repositories for project %q graph build (check include_groups)", proj.Name)
	}

	scratch, err := os.MkdirTemp("", "sergeant-graphify-*")
	if err != nil {
		return fmt.Errorf("creating scratch dir: %w", err)
	}
	defer os.RemoveAll(scratch)

	var repoGraphs []string
	for _, name := range repoNames {
		repo := proj.Repos[name]
		repoScratch := filepath.Join(scratch, name)
		out, err := runCommand("graphify", "extract", repo.Path, "--out", repoScratch)
		if err != nil {
			return fmt.Errorf("graphify extract failed for repo %q: %w\n%s", name, err, out)
		}
		repoGraphs = append(repoGraphs, filepath.Join(repoScratch, "graphify-out", "graph.json"))
	}

	mergedPath := filepath.Join(scratch, "graph.json")
	if len(repoGraphs) == 1 {
		// graphify merge-graphs requires at least two inputs; a single
		// participating repo's own graph.json is already the merged result.
		data, err := os.ReadFile(repoGraphs[0])
		if err != nil {
			return fmt.Errorf("reading single-repo graph %s: %w", repoGraphs[0], err)
		}
		if err := os.WriteFile(mergedPath, data, 0644); err != nil {
			return fmt.Errorf("writing merged graph: %w", err)
		}
	} else {
		mergeArgs := append([]string{"merge-graphs"}, repoGraphs...)
		mergeArgs = append(mergeArgs, "--out", mergedPath)
		if out, err := runCommand("graphify", mergeArgs...); err != nil {
			return fmt.Errorf("graphify merge-graphs failed: %w\n%s", err, out)
		}
	}

	info, err := os.Stat(mergedPath)
	if err != nil || info.Size() == 0 {
		return fmt.Errorf("merged graph at %s is missing or empty", mergedPath)
	}

	manifest := struct {
		Repos   []string `json:"repos"`
		BuiltAt string   `json:"built_at"`
	}{
		Repos:   repoNames,
		BuiltAt: time.Now().UTC().Format(time.RFC3339),
	}
	manifestBytes, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return fmt.Errorf("encoding manifest: %w", err)
	}
	if err := os.WriteFile(filepath.Join(scratch, "manifest.json"), manifestBytes, 0644); err != nil {
		return fmt.Errorf("writing manifest: %w", err)
	}

	if publishHook != nil {
		publishHook()
	}

	// Publish via move-aside, move-in, remove — matching v1's sgt-graphify
	// crash-safety guarantee, ported rather than reinvented (its trap-based
	// backup/restore mechanism does the same two same-filesystem renames with
	// an inline rollback if the second one fails). Deleting the prior output
	// before the new one is confirmed in place (the previous version of this
	// function) meant a failed rename destroyed the prior graph with nothing
	// to restore — masked on this machine only because APFS firmlinks put
	// scratch and Output on the same volume, so the rename itself rarely
	// fails; it is not masked in general.
	output := proj.Graphify.Output
	var backup string
	if _, err := os.Stat(output); err == nil {
		backup = filepath.Join(filepath.Dir(output), fmt.Sprintf(".sergeant-graphify-old-%d", time.Now().UnixNano()))
		if err := os.Rename(output, backup); err != nil {
			return fmt.Errorf("backing up prior output before publish: %w", err)
		}
	}
	if err := renamePublish(scratch, output); err != nil {
		if backup != "" {
			// Best-effort restore, matching v1's inline recovery on the
			// failed second mv — if this also fails there is nothing further
			// to do, but the backup directory itself is left on disk rather
			// than removed, so it is not silently lost.
			_ = os.Rename(backup, output)
		}
		return fmt.Errorf("publishing graph to %s: %w", output, err)
	}
	if backup != "" {
		_ = os.RemoveAll(backup)
	}

	return nil
}

// participatingRepoNames resolves which repos in proj take part in the
// build: every repo if IncludeGroups is empty, otherwise only those whose
// Group is named. Sorted for deterministic build order.
func participatingRepoNames(proj *config.Project) []string {
	filterByGroup := len(proj.Graphify.IncludeGroups) > 0
	groups := make(map[string]bool, len(proj.Graphify.IncludeGroups))
	for _, g := range proj.Graphify.IncludeGroups {
		groups[g] = true
	}

	var names []string
	for name, repo := range proj.Repos {
		if !filterByGroup || groups[repo.Group] {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	return names
}
