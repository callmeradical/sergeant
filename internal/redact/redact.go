// Package redact scrubs common secret shapes out of captured process output
// before it is ever written to durable storage. It is a heuristic pass, not
// a guarantee: it closes high-confidence, common cases (R4.4), not every
// possible secret shape.
package redact

import (
	"encoding/json"
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
// (AWS), AIza (Google), and xox[bpoa]- (Slack). No leading or trailing \b on
// any alternative: these prefixes are distinctive enough on their own, and a
// secret is often glued directly to adjacent non-whitespace text (e.g.
// inside a quoted string, URL, or followed by more characters appended by
// whatever emitted it) with no word boundary at either edge — requiring one
// silently missed real secrets, which is worse than the rare over-match an
// open-ended quantifier risks. AKIA/AIza's minimum lengths use a "{n,}" floor
// rather than a fixed "{n}\b" count for the same reason.
var apiKeyPattern = regexp.MustCompile(
	`sk-[A-Za-z0-9]{20,}` +
		`|gh[oprsu]_[A-Za-z0-9]{20,}` +
		`|AKIA[A-Z0-9]{16,}` +
		`|AIza[A-Za-z0-9_\-]{35,}` +
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

// JSON walks an arbitrary JSON document and applies Text to every string
// leaf, returning the re-marshaled result. It exists because an envelope's
// payload is not always built by sergeant field-by-field — a dispatched
// agent can write its own envelope.json, and that content must not bypass
// redaction just because sergeant did not construct it itself. Malformed
// JSON is returned unchanged: redaction cannot inspect what it cannot parse,
// and refusing an otherwise-valid envelope over that would be a worse
// failure than a heuristic miss.
func JSON(data []byte) []byte {
	if len(data) == 0 {
		return data
	}
	var v interface{}
	if err := json.Unmarshal(data, &v); err != nil {
		return data
	}
	out, err := json.Marshal(redactValue(v))
	if err != nil {
		return data
	}
	return out
}

func redactValue(v interface{}) interface{} {
	switch t := v.(type) {
	case string:
		return Text(t)
	case []interface{}:
		out := make([]interface{}, len(t))
		for i, e := range t {
			out[i] = redactValue(e)
		}
		return out
	case map[string]interface{}:
		out := make(map[string]interface{}, len(t))
		for k, e := range t {
			out[k] = redactValue(e)
		}
		return out
	default:
		return v
	}
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
