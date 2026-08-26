package runner

import (
	"fmt"
	"log"
	"mime"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/callmeradical/sergeant/internal/store"
)

// maxArtifactCount and maxArtifactTotalBytes bound how much one phase's
// $SERGEANT_ARTIFACT_DIR capture can add to the durable artifacts root.
// Fixed constants, not config: a runaway gate writing unbounded evidence
// (or a misbehaving script looping on screenshots) must not be able to fill
// disk regardless of project configuration. Captured artifacts are expected
// to be a handful of screenshots/traces at a few MB each (design.md), so
// these bounds are generous for the intended use and still finite.
const (
	maxArtifactCount      = 20
	maxArtifactTotalBytes = 25 * 1024 * 1024
)

// artifactsRoot is the durable root every captured artifact is copied under,
// outside any run's worktree so it survives that worktree's later reclaim by
// automated-fleet-cleanup. SERGEANT_ARTIFACTS_ROOT overrides it, mirroring
// internal/ui/lock.go's SERGEANT_UI_LOCK pattern, so tests never write into
// an operator's real home directory.
func artifactsRoot() string {
	if p := os.Getenv("SERGEANT_ARTIFACTS_ROOT"); p != "" {
		return p
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".local", "share", "sergeant", "artifacts")
}

// captureArtifacts reads dir for files a just-finished gate/phase command
// left behind, copies each into the durable artifacts root under
// runID/phaseID, and records one ArtifactRecord per file via st. It never
// returns an error to its caller: a capture problem is logged and recorded
// as a best-effort dropped-artifacts note, matching the existing
// non-critical posture of SSE progress sampling in dispatch.go. Both
// RunCodeGate and RunAgentPhase call this only after their own phase result
// and PhaseRecord already exist, so nothing captureArtifacts does can turn a
// passing gate into a failing one.
//
// Capture is bounded by maxArtifactCount/maxArtifactTotalBytes. Anything
// beyond the bound — or any file that fails to copy, including every file
// when the durable destination itself is unwritable — is folded into one
// additional ArtifactRecord row reporting DroppedCount/DroppedReason,
// never silently omitted (spec.md: "Exceeding the artifact cap is recorded,
// not silently dropped").
func captureArtifacts(st *store.Store, runID, phaseID, repo, dir string) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		// No directory (or nothing readable) is the overwhelmingly common
		// case — most gates write no artifacts — not a failure worth a note.
		return
	}

	type capturedFile struct {
		name string
		size int64
	}
	var files []capturedFile
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		files = append(files, capturedFile{name: e.Name(), size: info.Size()})
	}
	if len(files) == 0 {
		return
	}
	// Deterministic order: which files land inside the cap must not depend on
	// directory-read ordering, which os.ReadDir does not guarantee stably
	// across platforms.
	sort.Slice(files, func(i, j int) bool { return files[i].name < files[j].name })

	destDir := filepath.Join(artifactsRoot(), runID, phaseID)
	if err := os.MkdirAll(destDir, 0o755); err != nil {
		log.Printf("sergeant: capture artifacts for run %s phase %s: creating durable destination: %v", runID, phaseID, err)
		recordDroppedArtifacts(st, runID, phaseID, repo, len(files),
			fmt.Sprintf("durable artifact destination unwritable: %v", err))
		return
	}

	var (
		count      int
		totalBytes int64
		dropped    []string
	)
	for _, f := range files {
		switch {
		case count >= maxArtifactCount:
			dropped = append(dropped, fmt.Sprintf("%s: exceeded max artifact count (%d)", f.name, maxArtifactCount))
			continue
		case totalBytes+f.size > maxArtifactTotalBytes:
			dropped = append(dropped, fmt.Sprintf("%s: exceeded max total artifact bytes (%d)", f.name, maxArtifactTotalBytes))
			continue
		}

		srcPath := filepath.Join(dir, f.name)
		destPath := filepath.Join(destDir, f.name)
		data, err := os.ReadFile(srcPath)
		if err != nil {
			dropped = append(dropped, fmt.Sprintf("%s: reading source file: %v", f.name, err))
			continue
		}
		if err := os.WriteFile(destPath, data, 0o644); err != nil {
			dropped = append(dropped, fmt.Sprintf("%s: writing durable copy: %v", f.name, err))
			continue
		}

		contentType := mime.TypeByExtension(filepath.Ext(f.name))
		if contentType == "" {
			contentType = "application/octet-stream"
		}
		rec := &store.ArtifactRecord{
			ID:          fmt.Sprintf("art-%s-%s-%d", runID, phaseID, time.Now().UnixNano()),
			RunID:       runID,
			PhaseID:     phaseID,
			Repo:        repo,
			Filename:    f.name,
			ContentType: contentType,
			SizeBytes:   f.size,
			Path:        destPath,
			CapturedAt:  time.Now().UTC(),
		}
		if err := st.RecordArtifact(rec); err != nil {
			log.Printf("sergeant: recording artifact %s for run %s phase %s: %v", f.name, runID, phaseID, err)
			dropped = append(dropped, fmt.Sprintf("%s: recording artifact: %v", f.name, err))
			continue
		}
		count++
		totalBytes += f.size
	}

	if len(dropped) > 0 {
		recordDroppedArtifacts(st, runID, phaseID, repo, len(dropped), strings.Join(dropped, "; "))
	}
}

// recordDroppedArtifacts writes the one additional ArtifactRecord row that
// reports artifacts captureArtifacts could not keep. It carries no
// filename/content_type/path of its own — DroppedCount and DroppedReason are
// the whole point of the row.
func recordDroppedArtifacts(st *store.Store, runID, phaseID, repo string, droppedCount int, reason string) {
	rec := &store.ArtifactRecord{
		ID:            fmt.Sprintf("art-%s-%s-dropped-%d", runID, phaseID, time.Now().UnixNano()),
		RunID:         runID,
		PhaseID:       phaseID,
		Repo:          repo,
		CapturedAt:    time.Now().UTC(),
		DroppedCount:  droppedCount,
		DroppedReason: reason,
	}
	if err := st.RecordArtifact(rec); err != nil {
		log.Printf("sergeant: recording dropped-artifacts note for run %s phase %s: %v", runID, phaseID, err)
	}
}
