// Package redact scrubs common secret shapes out of captured process output
// before it is ever written to durable storage. It is a heuristic pass, not
// a guarantee: it closes high-confidence, common cases (R4.4), not every
// possible secret shape.
package redact

import (
	"fmt"
	"regexp"
)

// placeholder replaces every recognised secret, regardless of which pattern
// matched. Naming the specific credential type in the retained text would be
// a small information leak with no benefit to an auditor who already knows
// redaction happened.
const placeholder = "[REDACTED]"

// apiKeyPattern matches common provider API key prefixes followed by the
// alphanumeric (or, for Slack, alphanumeric-and-hyphen) run those real keys
// use: sk- (OpenAI/Anthropic-style), ghp_/gho_/ghu_/ghs_/ghr_ (GitHub), AKIA
// (AWS), AIza (Google), and xox[bpoa]- (Slack). No leading \b: these
// prefixes are distinctive enough on their own, and a secret is often glued
// directly to adjacent non-whitespace text (e.g. inside a quoted string or
// URL) with no word boundary before it — requiring one there silently missed
// real secrets, which is worse than the rare over-match a bare prefix risks.
var apiKeyPattern = regexp.MustCompile(
	`sk-[A-Za-z0-9]{20,}` +
		`|gh[oprsu]_[A-Za-z0-9]{20,}` +
		`|AKIA[A-Z0-9]{16}\b` +
		`|AIza[A-Za-z0-9_\-]{35}\b` +
		`|xox[bpoa]-[A-Za-z0-9-]{10,}`,
)

// bearerPattern matches an `Authorization: Bearer <token>` header, case-
// insensitive on the header name and scheme. Group 1 captures everything up
// to and including "bearer " so it can be preserved verbatim; only the token
// (group 2, consumed but not re-emitted) is replaced.
var bearerPattern = regexp.MustCompile(`(?i)(authorization:\s*bearer\s+)\S+`)

// credentialLinePattern matches a `NAME=value` line where NAME contains one
// of the credential-shaped substrings, case-insensitive. Group 1 captures
// NAME verbatim so it survives; the value (up to end of line) is replaced.
var credentialLinePattern = regexp.MustCompile(`(?im)^([A-Za-z0-9_.-]*(?:key|token|secret|password|credential)[A-Za-z0-9_.-]*)=(.+)$`)

// Text replaces recognised secret-shaped substrings in s with a fixed
// placeholder and returns the result. Ordinary text with no secret-shaped
// substrings is returned unchanged.
func Text(s string) string {
	s = apiKeyPattern.ReplaceAllString(s, placeholder)
	s = bearerPattern.ReplaceAllString(s, "${1}"+placeholder)
	s = credentialLinePattern.ReplaceAllString(s, "${1}="+placeholder)
	return s
}

// Truncate caps s at maxBytes, appending a marker naming how many bytes were
// cut when truncation occurs. Callers should apply Text before Truncate:
// redaction can only shorten (the placeholder is fixed-length and typically
// shorter than a real secret), so truncating first could cut a secret in
// half right at the boundary, leaving an unredacted fragment.
func Truncate(s string, maxBytes int) string {
	if len(s) <= maxBytes {
		return s
	}
	cut := len(s) - maxBytes
	return s[:maxBytes] + fmt.Sprintf("\n[TRUNCATED: %d bytes cut]", cut)
}
