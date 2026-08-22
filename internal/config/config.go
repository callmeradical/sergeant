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
}

// ProjectDefaults defines shared settings across repos.
type ProjectDefaults struct {
	Agent string `yaml:"agent,omitempty" json:"agent"` // e.g. "pi", "opencode", "claude"
	Model string `yaml:"model,omitempty" json:"model"` // e.g. "anthropic/claude-3-7-sonnet"
}

// Repo represents a single repository managed in the project.
type Repo struct {
	Name        string         `yaml:"name,omitempty" json:"name"`
	Path        string         `yaml:"path" json:"path"`
	Role        string         `yaml:"role,omitempty" json:"role"`
	Group       string         `yaml:"group,omitempty" json:"group"`
	Factory     *FactoryConfig `yaml:"factory,omitempty" json:"factory"`
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

func fileExists(p string) bool {
	info, err := os.Stat(p)
	return err == nil && !info.IsDir()
}
