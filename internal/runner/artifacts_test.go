package runner

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestGateArtifactIsCapturedDurably covers spec.md's "A file written to the
// artifact directory is captured durably": a gate command that writes a file
// to $SERGEANT_ARTIFACT_DIR produces one durable ArtifactRecord, readable via
// ListArtifactsForRun, whose on-disk content matches what the command wrote.
func TestGateArtifactIsCapturedDurably(t *testing.T) {
	pr, st := newRunner(t, "", 0)
	t.Setenv("SERGEANT_ARTIFACTS_ROOT", t.TempDir())

	res, err := pr.RunCodeGate(context.Background(), "screenshot-gate",
		`echo -n "hello artifact" > "$SERGEANT_ARTIFACT_DIR/shot.png"`)
	if err != nil {
		t.Fatalf("RunCodeGate: %v", err)
	}
	if !res.Passed {
		t.Fatalf("expected gate to pass, output: %s", res.Output)
	}

	artifacts, err := st.ListArtifactsForRun(pr.RunID)
	if err != nil {
		t.Fatal(err)
	}
	if len(artifacts) != 1 {
		t.Fatalf("expected 1 artifact, got %d: %+v", len(artifacts), artifacts)
	}
	a := artifacts[0]
	if a.Filename != "shot.png" {
		t.Errorf("Filename = %q, want shot.png", a.Filename)
	}
	if a.RunID != pr.RunID {
		t.Errorf("RunID = %q, want %q", a.RunID, pr.RunID)
	}
	if a.Repo != pr.RepoName {
		t.Errorf("Repo = %q, want %q", a.Repo, pr.RepoName)
	}
	if a.ContentType == "" {
		t.Errorf("ContentType should not be empty")
	}
	if a.SizeBytes != int64(len("hello artifact")) {
		t.Errorf("SizeBytes = %d, want %d", a.SizeBytes, len("hello artifact"))
	}
	if strings.HasPrefix(a.Path, pr.Worktree) {
		t.Errorf("artifact path %s is inside the worktree %s, want a durable path outside it", a.Path, pr.Worktree)
	}

	data, err := os.ReadFile(a.Path)
	if err != nil {
		t.Fatalf("reading durable artifact at %s: %v", a.Path, err)
	}
	if string(data) != "hello artifact" {
		t.Errorf("durable artifact content = %q, want %q", data, "hello artifact")
	}
}

// TestGateWithNoArtifactsProducesNoRecords covers spec.md's "A command that
// writes nothing produces no artifacts": no rows are created, and the gate's
// own pass/fail result is unaffected.
func TestGateWithNoArtifactsProducesNoRecords(t *testing.T) {
	pr, st := newRunner(t, "", 0)
	t.Setenv("SERGEANT_ARTIFACTS_ROOT", t.TempDir())

	res, err := pr.RunCodeGate(context.Background(), "quiet-gate", "echo 'nothing written'")
	if err != nil {
		t.Fatalf("RunCodeGate: %v", err)
	}
	if !res.Passed {
		t.Fatalf("expected gate to pass, output: %s", res.Output)
	}

	artifacts, err := st.ListArtifactsForRun(pr.RunID)
	if err != nil {
		t.Fatal(err)
	}
	if len(artifacts) != 0 {
		t.Fatalf("expected no artifacts, got %d: %+v", len(artifacts), artifacts)
	}
}

// TestExceedingArtifactCountCapIsRecordedNotDropped covers spec.md's
// "Exceeding the artifact cap is recorded, not silently dropped": writing
// more files than maxArtifactCount allows still captures exactly the allowed
// artifacts, plus one additional row whose DroppedCount/DroppedReason report
// what was skipped.
func TestExceedingArtifactCountCapIsRecordedNotDropped(t *testing.T) {
	pr, st := newRunner(t, "", 0)
	t.Setenv("SERGEANT_ARTIFACTS_ROOT", t.TempDir())

	var script strings.Builder
	for i := 0; i < maxArtifactCount+1; i++ {
		fmt.Fprintf(&script, "echo -n %d > \"$SERGEANT_ARTIFACT_DIR/f%02d.txt\"\n", i, i)
	}

	res, err := pr.RunCodeGate(context.Background(), "many-files-gate", script.String())
	if err != nil {
		t.Fatalf("RunCodeGate: %v", err)
	}
	if !res.Passed {
		t.Fatalf("expected gate to pass, output: %s", res.Output)
	}

	artifacts, err := st.ListArtifactsForRun(pr.RunID)
	if err != nil {
		t.Fatal(err)
	}

	var captured, droppedRows, droppedTotal int
	for _, a := range artifacts {
		if a.DroppedCount > 0 {
			droppedRows++
			droppedTotal += a.DroppedCount
			if a.DroppedReason == "" {
				t.Errorf("dropped row has empty DroppedReason")
			}
			continue
		}
		captured++
	}
	if captured != maxArtifactCount {
		t.Errorf("captured = %d, want exactly the allowed max of %d", captured, maxArtifactCount)
	}
	if droppedRows != 1 {
		t.Fatalf("expected exactly one dropped-notice row, got %d: %+v", droppedRows, artifacts)
	}
	if droppedTotal != 1 {
		t.Errorf("DroppedCount total = %d, want 1 (one file over the cap)", droppedTotal)
	}
}

// TestFailingGateStillCapturesArtifacts covers spec.md's "A failing gate's
// artifacts are still captured": capture is not conditioned on the gate
// passing.
func TestFailingGateStillCapturesArtifacts(t *testing.T) {
	pr, st := newRunner(t, "", 0)
	t.Setenv("SERGEANT_ARTIFACTS_ROOT", t.TempDir())

	res, err := pr.RunCodeGate(context.Background(), "failing-gate",
		`echo -n "evidence" > "$SERGEANT_ARTIFACT_DIR/failure.log"; exit 1`)
	if err != nil {
		t.Fatalf("RunCodeGate: %v", err)
	}
	if res.Passed {
		t.Fatalf("expected gate to fail")
	}

	artifacts, err := st.ListArtifactsForRun(pr.RunID)
	if err != nil {
		t.Fatal(err)
	}
	if len(artifacts) != 1 || artifacts[0].Filename != "failure.log" {
		t.Fatalf("expected the failing gate's artifact to still be captured, got %+v", artifacts)
	}
}

// TestCaptureFailureDoesNotChangeGateResult covers spec.md's "A capture
// failure does not change the gate's own result": when the durable artifact
// destination is unwritable, a gate that would otherwise pass still passes,
// and the failure is recorded rather than silently swallowed.
func TestCaptureFailureDoesNotChangeGateResult(t *testing.T) {
	pr, st := newRunner(t, "", 0)

	// Point the durable root at a path whose parent component is a plain
	// file, so os.MkdirAll can never create anything under it.
	blocker := filepath.Join(t.TempDir(), "not-a-directory")
	if err := os.WriteFile(blocker, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SERGEANT_ARTIFACTS_ROOT", filepath.Join(blocker, "artifacts"))

	res, err := pr.RunCodeGate(context.Background(), "would-pass-gate",
		`echo -n "data" > "$SERGEANT_ARTIFACT_DIR/out.txt"`)
	if err != nil {
		t.Fatalf("RunCodeGate: %v", err)
	}
	if !res.Passed {
		t.Fatalf("a capture failure must not change the gate's own passing result, got Passed=false, output: %s", res.Output)
	}

	artifacts, err := st.ListArtifactsForRun(pr.RunID)
	if err != nil {
		t.Fatal(err)
	}
	if len(artifacts) != 1 || artifacts[0].DroppedCount == 0 || artifacts[0].DroppedReason == "" {
		t.Fatalf("expected one dropped-artifacts note reporting the capture failure, got %+v", artifacts)
	}
}

// TestSuccessiveGatesInTheSameWorktreeDoNotLeakArtifacts guards the
// "empty directory" half of spec.md's contract: internal/dag/engine.go runs
// every configured gate against the same pr.Worktree, so
// $SERGEANT_ARTIFACT_DIR resolves to the same on-disk path across calls. A
// second gate must not see (or capture as its own) a file the first gate
// left behind.
func TestSuccessiveGatesInTheSameWorktreeDoNotLeakArtifacts(t *testing.T) {
	pr, st := newRunner(t, "", 0)
	t.Setenv("SERGEANT_ARTIFACTS_ROOT", t.TempDir())

	if _, err := pr.RunCodeGate(context.Background(), "gate-one",
		`echo -n "from gate one" > "$SERGEANT_ARTIFACT_DIR/one.txt"`); err != nil {
		t.Fatalf("RunCodeGate gate-one: %v", err)
	}
	if _, err := pr.RunCodeGate(context.Background(), "gate-two",
		`echo -n "from gate two" > "$SERGEANT_ARTIFACT_DIR/two.txt"`); err != nil {
		t.Fatalf("RunCodeGate gate-two: %v", err)
	}

	artifacts, err := st.ListArtifactsForRun(pr.RunID)
	if err != nil {
		t.Fatal(err)
	}
	if len(artifacts) != 2 {
		t.Fatalf("expected exactly 2 artifacts (one per gate), got %d: %+v", len(artifacts), artifacts)
	}
	byFile := map[string]string{}
	for _, a := range artifacts {
		byFile[a.Filename] = a.PhaseID
	}
	onePhase, ok := byFile["one.txt"]
	if !ok {
		t.Fatalf("gate-one's artifact is missing: %+v", artifacts)
	}
	twoPhase, ok := byFile["two.txt"]
	if !ok {
		t.Fatalf("gate-two's artifact is missing: %+v", artifacts)
	}
	if onePhase == twoPhase {
		t.Errorf("both artifacts recorded against the same phase %q; gate-one's file leaked into gate-two's capture", onePhase)
	}
}

// TestAgentPhaseCapturesArtifacts proves the second capture site design.md
// specifies (RunAgentPhase, not only RunCodeGate) is actually wired: an agent
// command that writes to $SERGEANT_ARTIFACT_DIR gets the same durable capture
// a gate command does.
func TestAgentPhaseCapturesArtifacts(t *testing.T) {
	agentDir := t.TempDir()
	agent := fakeAgent(t, agentDir, "fake-agent.sh", `printf 'trace-data' > "$SERGEANT_ARTIFACT_DIR/trace.json"`)
	pr, st := newRunner(t, agent, 0)
	t.Setenv("SERGEANT_ARTIFACTS_ROOT", t.TempDir())

	_, _, err := pr.RunAgentPhase(context.Background(), "build", "do the thing", 0)
	if err != nil {
		t.Fatalf("RunAgentPhase: %v", err)
	}

	artifacts, err := st.ListArtifactsForRun(pr.RunID)
	if err != nil {
		t.Fatal(err)
	}
	if len(artifacts) != 1 || artifacts[0].Filename != "trace.json" {
		t.Fatalf("expected the agent phase's artifact to be captured, got %+v", artifacts)
	}
	data, err := os.ReadFile(artifacts[0].Path)
	if err != nil {
		t.Fatalf("reading durable artifact: %v", err)
	}
	if string(data) != "trace-data" {
		t.Errorf("durable artifact content = %q, want %q", data, "trace-data")
	}
}
