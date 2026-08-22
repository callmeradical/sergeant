package handoff

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// Envelope represents a structured contract produced by an agent phase.
type Envelope struct {
	TaskID    string          `json:"task_id"`
	Repo      string          `json:"repo"`
	Stage     string          `json:"stage"`
	Summary   string          `json:"summary"`
	Artifacts []string        `json:"artifacts,omitempty"`
	Payload   json.RawMessage `json:"payload,omitempty"`
}

// Router handles passing envelopes and exported artifacts between worktrees.
type Router struct {
	// BaseDir is <fleet root>/<run_id>/handoff, where the fleet root comes from
	// dag.FleetRoot. Callers must not build it from a literal path.
	BaseDir string
}

func NewRouter(baseDir string) *Router {
	return &Router{BaseDir: baseDir}
}

// SaveEnvelope writes an envelope to disk under the repo's handoff namespace.
func (r *Router) SaveEnvelope(env *Envelope) error {
	repoDir := filepath.Join(r.BaseDir, env.Repo)
	if err := os.MkdirAll(repoDir, 0755); err != nil {
		return fmt.Errorf("creating handoff dir: %w", err)
	}

	data, err := json.MarshalIndent(env, "", "  ")
	if err != nil {
		return fmt.Errorf("marshaling envelope: %w", err)
	}

	dest := filepath.Join(repoDir, fmt.Sprintf("envelope_%s.json", env.Stage))
	if err := os.WriteFile(dest, data, 0644); err != nil {
		return fmt.Errorf("writing envelope file: %w", err)
	}

	// Also write latest
	latest := filepath.Join(repoDir, "envelope_latest.json")
	return os.WriteFile(latest, data, 0644)
}

// ReadLatestEnvelope reads the latest envelope produced by a repo.
func (r *Router) ReadLatestEnvelope(repo string) (*Envelope, error) {
	path := filepath.Join(r.BaseDir, repo, "envelope_latest.json")
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading latest envelope for %s: %w", repo, err)
	}

	var env Envelope
	if err := json.Unmarshal(data, &env); err != nil {
		return nil, fmt.Errorf("parsing envelope for %s: %w", repo, err)
	}

	return &env, nil
}

// InjectHandoffToWorktree copies all upstream artifacts into the downstream worktree's .sergeant/handoff directory.
func (r *Router) InjectHandoffToWorktree(upstreamRepo, downstreamWorktree string) error {
	srcDir := filepath.Join(r.BaseDir, upstreamRepo)
	if _, err := os.Stat(srcDir); os.IsNotExist(err) {
		return nil // No handoff to inject
	}

	destDir := filepath.Join(downstreamWorktree, ".sergeant", "handoff", upstreamRepo)
	if err := os.MkdirAll(destDir, 0755); err != nil {
		return fmt.Errorf("creating downstream handoff dir: %w", err)
	}

	entries, err := os.ReadDir(srcDir)
	if err != nil {
		return err
	}

	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		srcFile := filepath.Join(srcDir, entry.Name())
		destFile := filepath.Join(destDir, entry.Name())
		content, err := os.ReadFile(srcFile)
		if err != nil {
			return err
		}
		if err := os.WriteFile(destFile, content, 0644); err != nil {
			return err
		}
	}

	return nil
}
