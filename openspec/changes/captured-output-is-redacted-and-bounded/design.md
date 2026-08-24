# Design — Captured output is redacted and bounded

## Ownership

One repository, `sergeant-v2`. Standalone — no dependency on R5/D9/R4.6.
Touches the same two call sites in `internal/runner/runner.go`
(`RunAgentPhase` line ~456, `RunCodeGate` line ~245) that already call
`stripANSI(outBuf.String())`.

## `internal/redact` — pattern-based, applied once, at capture

```go
// Package redact scrubs common secret shapes out of captured process output
// before it is ever written to durable storage. It is a heuristic pass, not
// a guarantee: it closes high-confidence, common cases (R4.4), not every
// possible secret shape.
package redact

// Text replaces recognised secret-shaped substrings in s with a fixed
// placeholder ("[REDACTED]") and returns the result. Matches:
//   - Common provider API key prefixes: sk-, ghp_, gho_, ghu_, ghs_, ghr_,
//     AKIA (AWS), AIza (Google), xox[bpoa]- (Slack) — each followed by the
//     alphanumeric run that shape's real keys use.
//   - `Authorization: Bearer <token>` headers (case-insensitive on the
//     header name), redacting only the token, not the header name.
//   - Lines shaped like `<NAME>=<value>` where NAME (case-insensitive)
//     contains "key", "token", "secret", "password", or "credential" —
//     redacting the value, keeping the name so the shape of what leaked is
//     still visible without the leaked value itself.
func Text(s string) string

// Truncate caps s at maxBytes, appending a marker naming how many bytes were
// cut when truncation occurs. Applied after Text, since redaction can only
// shorten (placeholder text is fixed-length and typically shorter than a
// real secret) and truncating first could cut a pattern in half, producing
// a redaction near-miss right at the cut boundary.
func Truncate(s string, maxBytes int) string
```

Both are pure string functions — no I/O, no state — so they are trivially
unit-testable against known secret-shaped fixtures without needing a real
agent invocation.

## Call sites: redact-then-cap, replacing the bare `stripANSI` calls

```go
// internal/runner/runner.go, both RunAgentPhase and RunCodeGate:
cleaned := redact.Truncate(redact.Text(stripANSI(outBuf.String())), maxRawOutputBytes)
```

`stripANSI` runs first (ANSI escape codes are noise `redact.Text`'s patterns
should not have to account for), then `redact.Text`, then `redact.Truncate`
— order matters for the reason in `Truncate`'s doc comment above.
`maxRawOutputBytes` is a package-level constant in `internal/runner`
(proposed: 64KB — large enough that a normal verbose agent session is never
truncated in practice per this session's own captured runs, small enough to
bound a pathological one) rather than a new config field; R4.4's "define
retention" call is a policy decision this bullet does not own (see
proposal.md's out-of-scope section), so a fixed, documented constant is
honest about what this bullet actually decides.

## Placeholder text names the class, not the exact match

`[REDACTED]` alone, everywhere — not `[REDACTED:AWS_KEY]` or similar,
because naming the specific credential type in the retained text is itself
a small information leak (it tells a reader exactly what kind of secret to
go looking for elsewhere) with no operational benefit to an auditor who
already knows redaction happened. Existing surrounding context (a `git
remote -v` line, an `env` dump) already tells a reader what was being
inspected.

## Rejected alternatives

**Redacting at the read boundary (`GET /api/run-details`) instead of at
capture.** Rejected: the store would still hold the unredacted secret
forever, satisfying neither R4.4's "must not retain" text nor limiting
exposure to a future store compromise, a backup, or a direct SQLite read —
only to callers of that one HTTP endpoint. Redacting before the write is
what "must not retain" actually requires.

**An allowlist/denylist of specific known API providers instead of shape-
based pattern matching.** A provider list needs updating every time a new
service format appears and misses anything internal or unlisted; shape-based
matching (prefix + charset + length) generalizes better and is what
`git-secrets`-style tools already do for the same reason.

**Restricting subprocess environment as part of this bullet instead of
scrubbing output.** Covered in proposal.md's out-of-scope section — real,
larger, separate work.
