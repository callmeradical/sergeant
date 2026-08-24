package mcp

import (
	"strings"
	"testing"

	"github.com/callmeradical/sergeant/internal/store"
)

// sergeant_emit_envelope's summary and payload are supplied directly by the
// calling agent, not built by sergeant field-by-field. This is a second,
// independent write path into EnvelopeRecord (alongside
// internal/runner.RunAgentPhase's agent-authored envelope.json branch), and
// it needs the same redaction guarantee (R4.4) — an MCP tool call is exactly
// as agent-controlled as a file the agent writes to disk.
func TestEmitEnvelopeRedactsAgentSuppliedContent(t *testing.T) {
	s, st := mcpFixture(t)

	secret := "sk-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOP"
	if err := st.CreateRun(&store.RunRecord{ID: "run-1", Project: "p", TaskID: "run-1", Status: "running"}); err != nil {
		t.Fatal(err)
	}

	text, err := s.executeTool("sergeant_emit_envelope", map[string]interface{}{
		"run_id":  "run-1",
		"repo":    "svc",
		"stage":   "build",
		"summary": "leaked " + secret,
		"payload": map[string]interface{}{"nested": map[string]interface{}{"note": secret}},
	})
	if err != nil {
		t.Fatalf("sergeant_emit_envelope returned an error: %v", err)
	}
	if strings.Contains(text, secret) {
		t.Errorf("tool response leaked the secret: %q", text)
	}

	envelopes, err := st.ListEnvelopesForRun("run-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(envelopes) != 1 {
		t.Fatalf("expected 1 envelope, got %d", len(envelopes))
	}
	if strings.Contains(envelopes[0].Summary, secret) {
		t.Errorf("persisted EnvelopeRecord.Summary leaked the secret: %q", envelopes[0].Summary)
	}
	if !strings.Contains(envelopes[0].Summary, "[REDACTED]") {
		t.Errorf("persisted EnvelopeRecord.Summary was not redacted: %q", envelopes[0].Summary)
	}
	if strings.Contains(string(envelopes[0].Data), secret) {
		t.Errorf("persisted EnvelopeRecord.Data leaked the secret: %s", envelopes[0].Data)
	}
	if !strings.Contains(string(envelopes[0].Data), "[REDACTED]") {
		t.Errorf("persisted EnvelopeRecord.Data was not redacted: %s", envelopes[0].Data)
	}
}
