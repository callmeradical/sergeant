package changerequest

import (
	"strings"
	"testing"
)

// Scenario: "A GitHub remote uses the GitHub provider automatically"
// (specs/change-request-merge/spec.md) — both SSH and HTTPS forms.
func TestDetectProviderRecognizesGitHubRemotes(t *testing.T) {
	cases := []string{
		"git@github.com:owner/repo.git",
		"https://github.com/owner/repo",
	}
	for _, remote := range cases {
		t.Run(remote, func(t *testing.T) {
			got, err := DetectProvider(remote)
			if err != nil {
				t.Fatalf("DetectProvider(%q) returned error: %v", remote, err)
			}
			if got != "github" {
				t.Errorf("DetectProvider(%q) = %q, want %q", remote, got, "github")
			}
		})
	}
}

// Scenario: "An unrecognized remote is refused clearly" — a non-GitHub host
// is refused naming that host, and a remote with no discernible host at all
// is refused too, rather than either being silently treated as GitHub.
func TestDetectProviderRefusesUnrecognizedRemotes(t *testing.T) {
	cases := []struct {
		name        string
		remote      string
		wantInError string
	}{
		{"gitlab ssh", "git@gitlab.com:owner/repo.git", "gitlab.com"},
		{"gitlab https", "https://gitlab.com/owner/repo", "gitlab.com"},
		{"bare unrecognized string", "not-a-remote-url", "not-a-remote-url"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := DetectProvider(c.remote)
			if err == nil {
				t.Fatalf("DetectProvider(%q) = %q, nil error; want a refusal", c.remote, got)
			}
			if got != "" {
				t.Errorf("DetectProvider(%q) returned provider %q alongside an error; want empty", c.remote, got)
			}
			if !strings.Contains(err.Error(), c.wantInError) {
				t.Errorf("DetectProvider(%q) error = %q, want it to mention %q", c.remote, err.Error(), c.wantInError)
			}
		})
	}
}

// Scenario: the provider registry is actually populated by init(), not just
// declared. This codebase has a known recurring "implemented but never
// wired up" bug class (tasks.md) — a test that only calls DetectProvider
// would not catch a githubProvider that forgot to register itself.
func TestGitHubProviderIsRegisteredInProvidersMap(t *testing.T) {
	p, ok := Providers["github"]
	if !ok {
		t.Fatal(`Providers["github"] is not registered — init() did not run or did not populate the map`)
	}
	if p == nil {
		t.Fatal(`Providers["github"] is registered but nil`)
	}
}
