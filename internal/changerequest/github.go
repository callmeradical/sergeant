package changerequest

import (
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
)

func init() { Providers["github"] = &githubProvider{} }

type githubProvider struct{}

// Create shells out to `gh pr create --base base --head head --title
// title --body body`, matching runGHPRCreate's existing invocation shape
// exactly except for the added --base. cmd.Dir = repoPath.
func (g *githubProvider) Create(ctx context.Context, repoPath, base, head, title, body string) (string, error) {
	cmd := exec.CommandContext(ctx, "gh", "pr", "create",
		"--base", base, "--title", title, "--body", body, "--head", head)
	cmd.Dir = repoPath
	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("gh pr create: %v: %s", err, strings.TrimSpace(string(out)))
	}
	url := strings.TrimSpace(string(out))
	if !strings.HasPrefix(url, "https://") {
		return "", fmt.Errorf("gh pr create did not return a URL: %s", url)
	}
	return url, nil
}

// Status shells out to `gh pr view url --json state,mergedAt,baseRefName`.
// state == "MERGED" means Merged; baseRefName is the branch it actually
// merged into.
func (g *githubProvider) Status(ctx context.Context, repoPath, url string) (*StatusResult, error) {
	cmd := exec.CommandContext(ctx, "gh", "pr", "view", url, "--json", "state,mergedAt,baseRefName")
	cmd.Dir = repoPath
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("gh pr view %s: %w", url, err)
	}
	var parsed struct {
		State       string `json:"state"`
		MergedAt    string `json:"mergedAt"`
		BaseRefName string `json:"baseRefName"`
	}
	if err := json.Unmarshal(out, &parsed); err != nil {
		return nil, fmt.Errorf("parsing gh pr view output for %s: %w", url, err)
	}
	return &StatusResult{
		Merged:           parsed.State == "MERGED",
		MergedIntoBranch: parsed.BaseRefName,
	}, nil
}
