package ui

import (
	"context"
	"testing"

	"github.com/callmeradical/sergeant/internal/changerequest"
)

// fakeChangeRequestProvider is a swappable stand-in for changerequest.Provider.
// It replaces the old srv.GHPRCreate recording-stub pattern now that
// handleCreatePR talks to changerequest.Providers directly (design.md: "the
// same swap-a-dependency shape GHPRCreate above already used, one seam
// earlier").
type fakeChangeRequestProvider struct {
	createFn func(ctx context.Context, repoPath, base, head, title, body string) (string, error)
	statusFn func(ctx context.Context, repoPath, url string) (*changerequest.StatusResult, error)

	createCalls int
	lastBase    string
	lastHead    string
}

func (f *fakeChangeRequestProvider) Create(ctx context.Context, repoPath, base, head, title, body string) (string, error) {
	f.createCalls++
	f.lastBase = base
	f.lastHead = head
	if f.createFn != nil {
		return f.createFn(ctx, repoPath, base, head, title, body)
	}
	return "https://github.com/example/repo/pull/1", nil
}

func (f *fakeChangeRequestProvider) Status(ctx context.Context, repoPath, url string) (*changerequest.StatusResult, error) {
	if f.statusFn != nil {
		return f.statusFn(ctx, repoPath, url)
	}
	return &changerequest.StatusResult{}, nil
}

// installFakeGitHubProvider swaps changerequest.Providers["github"] for fake
// and restores the real one when the test ends, so one test's stub never
// leaks into a later test in the same run.
func installFakeGitHubProvider(t *testing.T, fake *fakeChangeRequestProvider) {
	t.Helper()
	orig := changerequest.Providers["github"]
	changerequest.Providers["github"] = fake
	t.Cleanup(func() { changerequest.Providers["github"] = orig })
}
