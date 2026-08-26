# Tasks — Captured output is redacted and bounded

One repository, `sergeant-v2`, so one task.

## Task 1 — redact and bound raw_output at capture

Repository: `sergeant-v2`. Depends on: nothing.

- Add a new package `internal/redact` with `Text(s string) string` and
  `Truncate(s string, maxBytes int) string` as specified in design.md.
  `Text` uses regular expressions (not a hardcoded provider list) to match:
  provider API key prefixes (`sk-`, `ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_`,
  `AKIA`, `AIza`, `xox[bpoa]-`) followed by the alphanumeric run those real
  keys use; `Authorization: Bearer <token>` headers (case-insensitive header
  name), redacting only the token; and lines shaped `NAME=value` where NAME
  (case-insensitive) contains "key", "token", "secret", "password", or
  "credential", redacting only value. Every match is replaced with the
  literal string `[REDACTED]` — the same placeholder for every match, do not
  encode which pattern matched into the placeholder text.
- In `internal/runner/runner.go`, add a package constant
  `maxRawOutputBytes = 64 * 1024` and change both `RunAgentPhase` (the
  `"raw_output": stripANSI(outBuf.String())` map entry) and `RunCodeGate`
  (the `Output: stripANSI(outBuf.String())` field) to instead compute
  `redact.Truncate(redact.Text(stripANSI(outBuf.String())), maxRawOutputBytes)`
  once and use that value. Redaction must run before truncation, not after.
- Do not touch `internal/dag/engine.go`'s or `internal/runner`'s
  `cmd.Env = append(os.Environ(), ...)` lines — subprocess environment
  inheritance is explicitly out of scope for this bullet (see proposal.md).
  Do not add a config field for the size limit or redaction patterns — both
  are fixed constants for this bullet. Do not modify historical rows. Do not
  add retention/deletion logic.

Verification: `go build ./... && go vet ./... && go test ./internal/... -count=1`.
Tests must cover every scenario in `specs/output-redaction/spec.md`:
`redact.Text` redacts each of the three pattern classes (provider key
prefix, bearer token, credential-shaped env line) while leaving ordinary
text and the surrounding non-secret content unchanged; `redact.Truncate`
leaves under-cap input unchanged and appends a visible marker with the cut
byte count for over-cap input; a combined `redact.Truncate(redact.Text(...),
...)` call on input where a secret sits right at the truncation boundary
shows the secret fully redacted, not a partial unredacted fragment (i.e.
redaction-before-truncation is exercised end to end, not just as two
separately-tested functions). Also add a test that exercises the real
`RunAgentPhase`/`RunCodeGate` call sites with a fake agent/gate command that
prints a secret-shaped string, asserting the persisted `PhaseRecord`/
`EnvelopeRecord` payload contains `[REDACTED]` and not the original
value — this session has repeatedly found gaps where a store-level or
pure-function guarantee was correct but never actually wired into a real
production call site; do not let that recur here. Exit status decides the
outcome.
