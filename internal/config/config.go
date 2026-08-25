package config

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

// Project represents a Sergeant multi-repo project definition.
type Project struct {
	Name        string          `yaml:"name" json:"name"`
	ProjectName string          `yaml:"project" json:"project"` // alternate key
	Description string          `yaml:"description,omitempty" json:"description"`
	Defaults    ProjectDefaults `yaml:"defaults,omitempty" json:"defaults"`
	Repos       map[string]Repo `yaml:"-" json:"repos"`
	RawRepos    yaml.Node       `yaml:"repos" json:"-"`
	DAG         *DAGConfig      `yaml:"dag,omitempty" json:"dag"`
	// Graphify declares the project's cross-repository code graph (decision
	// D9). A pointer so a project that declares no graphify: block has one
	// that is nil, distinguishable from a project that declared an empty
	// block.
	Graphify *Graphify `yaml:"graphify,omitempty" json:"graphify"`
	// Export declares an optional read-only task-tracking export target for
	// this project (task-tracking-is-a-readonly-export). A pointer, following
	// Graphify exactly, so a project that declares no export: block has one
	// that is nil, distinguishable from a project that declared an empty
	// block.
	Export *Export `yaml:"export,omitempty" json:"export"`
}

// Graphify declares a project's cross-repository code graph: which repos
// participate and where the built graph is published.
type Graphify struct {
	// Output is the directory the merged graph is published to.
	Output string `yaml:"output" json:"output"`
	// IncludeGroups filters which repos participate, matched against each
	// repo's Group. Empty means every repo in the project participates — the
	// same "unset means everything" default other per-repo filters in this
	// config already use.
	IncludeGroups []string `yaml:"include_groups,omitempty" json:"include_groups"`
	// ExcludePatterns filters files out of the published graph by
	// repo-relative path, gitignore-style ('*' one path segment, '**' any
	// number of segments), applied by BuildProjectGraph after merge and
	// before publish.
	ExcludePatterns []string `yaml:"exclude_patterns,omitempty" json:"exclude_patterns"`
}

// Export declares an optional read-only task-tracking export target for a
// project. A nil pointer (no export: block) is distinguished from an empty
// one the same way Graphify already is.
type Export struct {
	// Backend names which internal/export.Target implementation to construct.
	// The registry of valid names is an implementation decision for whoever
	// adds the first Target, not fixed here.
	Backend string `yaml:"backend" json:"backend"`
}

// ProjectDefaults defines shared settings across repos.
type ProjectDefaults struct {
	Agent   string `yaml:"agent,omitempty" json:"agent"`     // e.g. "pi", "opencode", "claude"
	Model   string `yaml:"model,omitempty" json:"model"`     // e.g. "anthropic/claude-3-7-sonnet"
	Retries int    `yaml:"retries,omitempty" json:"retries"` // agent phase retry count (0 = one attempt, no retry)
}

// Repo represents a single repository managed in the project.
type Repo struct {
	Name    string         `yaml:"name,omitempty" json:"name"`
	Path    string         `yaml:"path" json:"path"`
	Role    string         `yaml:"role,omitempty" json:"role"`
	Group   string         `yaml:"group,omitempty" json:"group"`
	Factory *FactoryConfig `yaml:"factory,omitempty" json:"factory"`
	// Retries overrides Defaults.Retries for this repository. Zero means
	// "not set here" — use the project default (which itself defaults to zero).
	// Because zero is the Go default for int, a repo that omits the field cannot
	// be distinguished from one that sets it to zero by value alone; the
	// resolution rule is: if the repo's Retries is non-zero, use it; otherwise
	// fall back to the project default.
	Retries int `yaml:"retries,omitempty" json:"retries"`
}

// FactoryConfig defines the intra-repo software factory pipeline and quality gates.
type FactoryConfig struct {
	Pipeline []string          `yaml:"pipeline,omitempty" json:"pipeline"` // e.g. ["plan", "build", "test", "review"]
	Gates    map[string]string `yaml:"gates,omitempty" json:"gates"`       // e.g. "test": "go test ./...", "lint": "golangci-lint run"
}

// DAGConfig defines cross-repo workflow DAG stages.
type DAGConfig struct {
	Name        string     `yaml:"name" json:"name"`
	Description string     `yaml:"description,omitempty" json:"description"`
	Stages      []DAGStage `yaml:"stages" json:"stages"`
}

// DAGStage defines a single stage in the cross-repo workflow.
type DAGStage struct {
	Name   string   `yaml:"name" json:"name"`
	Repos  []string `yaml:"repos" json:"repos"`
	After  []string `yaml:"after,omitempty" json:"after"`
	Brief  string   `yaml:"brief,omitempty" json:"brief"`
	TD     string   `yaml:"td,omitempty" json:"td"`
}

// LoadProject reads and parses a project YAML from ~/.config/sergeant/<name>.yaml or a custom path.
func LoadProject(nameOrPath string) (*Project, error) {
	path := nameOrPath
	if !filepath.IsAbs(path) && !fileExists(path) {
		configDir := os.Getenv("SERGEANT_CONFIG")
		if configDir == "" {
			home, err := os.UserHomeDir()
			if err != nil {
				return nil, fmt.Errorf("resolving home directory: %w", err)
			}
			configDir = filepath.Join(home, ".config", "sergeant")
		}
		path = filepath.Join(configDir, nameOrPath)
		if filepath.Ext(path) == "" {
			path += ".yaml"
		}
	}

	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading project config %s: %w", path, err)
	}

	var p Project
	if err := yaml.Unmarshal(data, &p); err != nil {
		return nil, fmt.Errorf("parsing yaml in %s: %w", path, err)
	}

	// Normalise project name
	if p.Name == "" {
		if p.ProjectName != "" {
			p.Name = p.ProjectName
		} else {
			base := filepath.Base(path)
			p.Name = strings.TrimSuffix(base, filepath.Ext(base))
		}
	}
	p.ProjectName = p.Name

	// Parse repos whether map or list
	p.Repos = make(map[string]Repo)
	if p.RawRepos.Kind == yaml.SequenceNode {
		var repoList []Repo
		if err := p.RawRepos.Decode(&repoList); err == nil {
			for _, r := range repoList {
				rName := r.Name
				if rName == "" {
					rName = filepath.Base(r.Path)
				}
				p.Repos[rName] = r
			}
		}
	} else if p.RawRepos.Kind == yaml.MappingNode {
		_ = p.RawRepos.Decode(&p.Repos)
	}

	return &p, nil
}

// ResolvedRetries returns the effective retry count for repoName.
//
// Resolution mirrors how AgentCLI is resolved for the pipeline today:
//   - repo-level value if non-zero
//   - project default if non-zero
//   - zero (one attempt, no retry)
//
// Zero anywhere in the chain means "not configured at that level", not "retry
// zero times". A project that omits the field behaves exactly as before this
// field existed: one attempt, no retry.
func (p *Project) ResolvedRetries(repoName string) int {
	if repo, ok := p.Repos[repoName]; ok && repo.Retries != 0 {
		return repo.Retries
	}
	return p.Defaults.Retries
}

func fileExists(p string) bool {
	info, err := os.Stat(p)
	return err == nil && !info.IsDir()
}
