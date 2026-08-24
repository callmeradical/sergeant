package redact

import (
	"fmt"
	"strings"
	"testing"
)

// Requirement: Captured output is scrubbed for common secret shapes before it
// is written. Scenario: A provider API key is redacted.
func TestTextRedactsProviderAPIKeys(t *testing.T) {
	cases := []struct {
		name string
		key  string
	}{
		{"openai-style sk-", "sk-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOP"},
		{"github personal token ghp_", "ghp_1234567890abcdefghijklmnopqrstuvwxyz12"},
		{"github oauth token gho_", "gho_1234567890abcdefghijklmnopqrstuvwxyz12"},
		{"github user token ghu_", "ghu_1234567890abcdefghijklmnopqrstuvwxyz12"},
		{"github server token ghs_", "ghs_1234567890abcdefghijklmnopqrstuvwxyz12"},
		{"github refresh token ghr_", "ghr_1234567890abcdefghijklmnopqrstuvwxyz12"},
		{"aws access key AKIA", "AKIAIOSFODNN7EXAMPLE"},
		{"google api key AIza", "AIzaSyD-9tSrke72PouQMnMX-a7eZSW0jkFMBWY"},
		{"slack bot token xoxb-", "xoxb-EXAMPLE-NOTAREALTOKEN-abcdefghijklmnopqrstuvwx"},
		{"slack user token xoxp-", "xoxp-EXAMPLE-NOTAREALTOKEN-abcdefghijklmnopqrstuvwx"},
		{"slack legacy token xoxo-", "xoxo-EXAMPLE-NOTAREALTOKEN-abcdefghijklmnopqrstuvwx"},
		{"slack app token xoxa-", "xoxa-EXAMPLE-NOTAREALTOKEN-abcdefghijklmnopqrstuvwx"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			input := fmt.Sprintf("some log line before\nAPI_KEY_FOUND=%s\nsome log line after", tc.key)
			got := Text(input)
			if strings.Contains(got, tc.key) {
				t.Errorf("Text() left the original key in output: %q", got)
			}
			if !strings.Contains(got, "[REDACTED]") {
				t.Errorf("Text() did not insert placeholder: %q", got)
			}
			if !strings.Contains(got, "some log line before") || !strings.Contains(got, "some log line after") {
				t.Errorf("Text() disturbed surrounding non-secret content: %q", got)
			}
		})
	}
}

// Scenario: A bearer token is redacted. Header name survives, only the token
// is replaced, and matching is case-insensitive on the header name.
func TestTextRedactsBearerTokens(t *testing.T) {
	cases := []string{
		"Authorization: Bearer abcdef123456.ghijkl789012.mnopqr345678",
		"authorization: bearer abcdef123456.ghijkl789012.mnopqr345678",
		"AUTHORIZATION: BEARER abcdef123456.ghijkl789012.mnopqr345678",
	}
	for _, input := range cases {
		t.Run(input, func(t *testing.T) {
			got := Text(input)
			if strings.Contains(got, "abcdef123456.ghijkl789012.mnopqr345678") {
				t.Errorf("Text() left the bearer token in output: %q", got)
			}
			if !strings.Contains(got, "[REDACTED]") {
				t.Errorf("Text() did not insert placeholder: %q", got)
			}
			if !strings.Contains(strings.ToLower(got), "bearer") {
				t.Errorf("Text() removed the header name/scheme, want it retained: %q", got)
			}
		})
	}
}

// Scenario: A credential-shaped environment line is redacted. NAME survives,
// only value is replaced. NAME matching is case-insensitive on key/token/
// secret/password/credential substrings.
func TestTextRedactsCredentialShapedEnvLines(t *testing.T) {
	cases := []struct {
		name  string
		line  string
		value string
	}{
		{"API_KEY", "API_KEY=super-secret-value-12345", "super-secret-value-12345"},
		{"lowercase api_key", "api_key=super-secret-value-12345", "super-secret-value-12345"},
		{"AUTH_TOKEN", "AUTH_TOKEN=super-secret-value-12345", "super-secret-value-12345"},
		{"DB_PASSWORD", "DB_PASSWORD=super-secret-value-12345", "super-secret-value-12345"},
		{"CLIENT_SECRET", "CLIENT_SECRET=super-secret-value-12345", "super-secret-value-12345"},
		{"AWS_CREDENTIAL", "AWS_CREDENTIAL=super-secret-value-12345", "super-secret-value-12345"},
		{"mixed case Secret_Token", "Secret_Token=super-secret-value-12345", "super-secret-value-12345"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			input := "line before\n" + tc.line + "\nline after"
			got := Text(input)
			if strings.Contains(got, tc.value) {
				t.Errorf("Text() left the value in output: %q", got)
			}
			nameOnly := strings.SplitN(tc.line, "=", 2)[0]
			if !strings.Contains(got, nameOnly) {
				t.Errorf("Text() dropped the NAME %q from output: %q", nameOnly, got)
			}
			if !strings.Contains(got, "[REDACTED]") {
				t.Errorf("Text() did not insert placeholder: %q", got)
			}
			if !strings.Contains(got, "line before") || !strings.Contains(got, "line after") {
				t.Errorf("Text() disturbed surrounding non-secret content: %q", got)
			}
		})
	}
}

// Scenario: Ordinary output is unaffected.
func TestTextLeavesOrdinaryOutputUnchanged(t *testing.T) {
	cases := []string{
		"",
		"build succeeded\nall 42 tests passed\n",
		"PATH=/usr/local/bin:/usr/bin\n",
		"HOME=/Users/example\n",
		"the word secretary should not trigger a match",
		"keyboard shortcuts are not credentials",
		"visit https://example.com/token-info for docs",
	}
	for _, input := range cases {
		t.Run(input, func(t *testing.T) {
			got := Text(input)
			if got != input {
				t.Errorf("Text(%q) = %q, want unchanged", input, got)
			}
		})
	}
}

// The same fixed placeholder is used regardless of which pattern matched --
// the placeholder text must not encode which class of secret was found.
func TestTextUsesSamePlaceholderForEveryPatternClass(t *testing.T) {
	inputs := []string{
		"sk-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOP",
		"Authorization: Bearer abcdef123456.ghijkl789012.mnopqr345678",
		"API_KEY=super-secret-value-12345",
	}
	for _, input := range inputs {
		got := Text(input)
		if !strings.Contains(got, "[REDACTED]") {
			t.Fatalf("Text(%q) = %q, expected the [REDACTED] placeholder", input, got)
		}
		// No other bracketed marker naming a pattern class should appear.
		if strings.Contains(got, "REDACTED:") || strings.Contains(got, "REDACTED_") {
			t.Errorf("Text(%q) = %q, placeholder must not encode which pattern matched", input, got)
		}
	}
}

// Requirement: Captured output is bounded in size before it is written.
// Scenario: Output under the cap is retained in full.
func TestTruncateLeavesUnderCapInputUnchanged(t *testing.T) {
	input := "short output, well under the cap"
	got := Truncate(input, 1024)
	if got != input {
		t.Errorf("Truncate() = %q, want unchanged input %q", got, input)
	}
}

func TestTruncateLeavesExactlyAtCapInputUnchanged(t *testing.T) {
	input := strings.Repeat("a", 100)
	got := Truncate(input, 100)
	if got != input {
		t.Errorf("Truncate() modified input exactly at the cap: got %d bytes, want %d unchanged", len(got), len(input))
	}
}

// Scenario: Output over the cap is truncated with a visible marker.
func TestTruncateOverCapAddsVisibleMarkerWithCutCount(t *testing.T) {
	input := strings.Repeat("a", 200)
	maxBytes := 100
	got := Truncate(input, maxBytes)

	if !strings.HasPrefix(got, strings.Repeat("a", maxBytes)) {
		t.Fatalf("Truncate() did not retain the first %d bytes: %q", maxBytes, got)
	}
	wantCut := len(input) - maxBytes
	if !strings.Contains(got, fmt.Sprintf("%d", wantCut)) {
		t.Errorf("Truncate() marker does not name the cut byte count (%d): %q", wantCut, got)
	}
	// The marker must be visibly distinguishable, not just more "a"s.
	suffix := got[maxBytes:]
	if suffix == "" || strings.Trim(suffix, "a") == "" {
		t.Errorf("Truncate() has no visible marker after the cut point: %q", got)
	}
}

// Combined use: a secret sitting right at the truncation boundary must be
// fully redacted, not truncated mid-match into a partial, unredacted
// fragment. This exercises redact.Truncate(redact.Text(...)) together, not
// each function in isolation.
func TestRedactThenTruncateFullyRedactsSecretAtBoundary(t *testing.T) {
	secret := "sk-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOP"
	padding := strings.Repeat("x", 50)
	input := padding + secret

	// Choose maxBytes so a naive truncate-then-redact (or truncate of the raw
	// input) would have sliced straight through the secret.
	maxBytes := len(padding) + len(secret)/2

	got := Truncate(Text(input), maxBytes)

	if strings.Contains(got, secret) {
		t.Fatalf("full secret survived redact+truncate: %q", got)
	}
	// No fragment of the raw key body (past the "sk-" prefix) may remain.
	rawBody := secret[3:]
	for i := 8; i <= len(rawBody); i++ {
		frag := rawBody[:i]
		if strings.Contains(got, frag) {
			t.Errorf("partial unredacted fragment of the secret survived: %q (in %q)", frag, got)
		}
	}
	if !strings.Contains(got, "[REDACTED]") {
		t.Errorf("expected the placeholder to survive truncation since it is far shorter than the raw secret: %q", got)
	}
}
