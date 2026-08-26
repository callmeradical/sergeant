// Package changerequest provides a provider seam for opening a change
// request (pull request) against an external host and later observing
// whether it merged. It mirrors internal/export's Target/Backends split:
// this file defines what the consumer needs; registry membership lives in
// each provider's own file via init().
package changerequest

import (
	"context"
	"fmt"
	"strings"
)

// Provider is anything that can open a change request and report whether
// it has since merged. Defined here (the consumer) rather than in a
// provider's own package, per internal/export.Target's reasoning: a future
// provider imports this package and implements Provider, not the reverse.
type Provider interface {
	// Create opens a change request for head against base, returning its
	// URL. title/body are passed through as-is (already redacted by the
	// caller, same discipline runGHPRCreate's caller already applies).
	Create(ctx context.Context, repoPath, base, head, title, body string) (url string, err error)

	// Status reports whether the change request identified by url has
	// merged, and if so, which branch it actually merged into — the
	// caller (not this package) decides what a base mismatch means.
	Status(ctx context.Context, repoPath, url string) (*StatusResult, error)
}

// StatusResult is url's current state. Merged is false for every state
// except an actual merge; MergedIntoBranch is only meaningful when Merged
// is true.
type StatusResult struct {
	Merged           bool
	MergedIntoBranch string
}

// Providers is the process-wide registry of providers, keyed by the name
// DetectProvider returns. Ships with exactly one entry ("github"),
// registered by github.go's init — unlike export.Backends, which starts
// empty because no Target implementation existed yet at the time; here,
// one does.
var Providers = map[string]Provider{}

// DetectProvider parses remoteURL (as returned by a `git remote get-url`
// style command — not yet normalized to https://) and returns the
// registry key for its host, or an error naming the host when it is not
// recognized. v1 recognizes exactly the literal host github.com, both
// git@github.com: and https://github.com/ forms — no GitHub Enterprise
// allowlist, no configuration.
func DetectProvider(remoteURL string) (string, error) {
	host, ok := hostOf(remoteURL)
	if !ok {
		return "", fmt.Errorf("cannot determine a host from remote %q; refusing to open a change request", remoteURL)
	}
	if host == "github.com" {
		return "github", nil
	}
	return "", fmt.Errorf("no change-request provider registered for host %q", host)
}

// hostOf extracts the host from an SSH-style remote (git@host:owner/repo)
// or a URL-style remote (scheme://[user@]host[:port]/path). It reports
// false when no host could be found at all.
func hostOf(remoteURL string) (string, bool) {
	remoteURL = strings.TrimSpace(remoteURL)
	if remoteURL == "" {
		return "", false
	}
	if idx := strings.Index(remoteURL, "://"); idx != -1 {
		rest := remoteURL[idx+len("://"):]
		if at := strings.Index(rest, "@"); at != -1 {
			rest = rest[at+1:]
		}
		end := strings.IndexAny(rest, "/:")
		if end == -1 {
			end = len(rest)
		}
		host := rest[:end]
		return host, host != ""
	}
	if at := strings.Index(remoteURL, "@"); at != -1 {
		rest := remoteURL[at+1:]
		if colon := strings.Index(rest, ":"); colon != -1 {
			host := rest[:colon]
			return host, host != ""
		}
	}
	return "", false
}
