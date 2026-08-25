package ui

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

// refinePayload models a partial update. Pointers and nil maps distinguish
// "absent, leave alone" from "present and empty, set to empty".
type refinePayload struct {
	Name        string  `json:"name"`
	Description *string `json:"description"`
	Defaults    *struct {
		Agent *string `json:"agent"`
	} `json:"defaults"`
	Repos map[string]refineRepoPatch `json:"repos"`
}

type refineRepoPatch struct {
	Role    *string `json:"role"`
	Factory *struct {
		Gates map[string]string `json:"gates"`
	} `json:"factory"`
}

func (srv *Server) handleRefineProject(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req refinePayload
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Name == "" {
		http.Error(w, "invalid project payload", http.StatusBadRequest)
		return
	}
	if strings.ContainsAny(req.Name, "/\\") || strings.Contains(req.Name, "..") {
		http.Error(w, "invalid project name", http.StatusBadRequest)
		return
	}

	cfgDir := os.Getenv("SERGEANT_CONFIG")
	if cfgDir == "" {
		home, _ := os.UserHomeDir()
		cfgDir = filepath.Join(home, ".config", "sergeant")
	}
	_ = os.MkdirAll(cfgDir, 0755)

	filePath := filepath.Join(cfgDir, fmt.Sprintf("%s.yaml", req.Name))

	// Patch the existing document rather than serialising a Project struct.
	//
	// Two reasons this must not round-trip through config.Project:
	//   1. Project.Repos is `yaml:"-"` while Project.RawRepos owns the `repos` key,
	//      so marshalling a struct built from JSON emits `repos: null` and destroys
	//      every repo, path, role, group, gate and pipeline in the file.
	//   2. Any key the struct does not model (notably `dag:`) would be dropped.
	// Editing the decoded document preserves everything we were not asked to change.
	// Patch a yaml.Node tree, not a map. Marshalling a map would alphabetise every
	// key and discard all comments — these files are hand-maintained, so that is
	// itself a form of data loss. Node patching preserves order, comments and any
	// key this server does not model.
	doc := &yaml.Node{}
	existed := false
	if data, err := os.ReadFile(filePath); err == nil && len(strings.TrimSpace(string(data))) > 0 {
		existed = true
		var root yaml.Node
		if err := yaml.Unmarshal(data, &root); err != nil {
			http.Error(w, fmt.Sprintf("existing project YAML is not parseable, refusing to overwrite: %v", err), http.StatusConflict)
			return
		}
		if len(root.Content) > 0 && root.Content[0].Kind == yaml.MappingNode {
			doc = root.Content[0]
		} else {
			http.Error(w, "existing project YAML is not a mapping, refusing to overwrite", http.StatusConflict)
			return
		}
	} else {
		doc.Kind = yaml.MappingNode
		doc.Tag = "!!map"
	}

	nodeSet(doc, "name", scalarNode(req.Name))
	// `project:` is a read-side alias for `name:`; persisting it produces a junk key.
	nodeDelete(doc, "project")

	if req.Description != nil {
		nodeSet(doc, "description", scalarNode(*req.Description))
	}
	if req.Defaults != nil && req.Defaults.Agent != nil {
		defaults := nodeGet(doc, "defaults")
		if defaults == nil || defaults.Kind != yaml.MappingNode {
			defaults = &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map"}
			nodeSet(doc, "defaults", defaults)
		}
		nodeSet(defaults, "agent", scalarNode(*req.Defaults.Agent))
	}

	var unknownRepos []string
	if len(req.Repos) > 0 {
		unknownRepos = patchReposNode(nodeGet(doc, "repos"), req.Repos)
	}

	out, err := marshalYAMLDoc(doc)
	if err != nil {
		http.Error(w, fmt.Sprintf("marshaling project YAML: %v", err), http.StatusInternalServerError)
		return
	}

	// Write atomically so a failure cannot leave a truncated config behind.
	tmp := filePath + ".tmp"
	if err := os.WriteFile(tmp, out, 0644); err != nil {
		http.Error(w, fmt.Sprintf("writing project YAML: %v", err), http.StatusInternalServerError)
		return
	}
	if err := os.Rename(tmp, filePath); err != nil {
		_ = os.Remove(tmp)
		http.Error(w, fmt.Sprintf("replacing project YAML: %v", err), http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"status":        "saved",
		"project":       req.Name,
		"created":       !existed,
		"unknown_repos": unknownRepos,
		"preserved_dag": nodeGet(doc, "dag") != nil,
	})
}

// --- yaml.Node helpers -------------------------------------------------------
// A yaml.v3 MappingNode stores Content as a flat [key, value, key, value...] slice.

func scalarNode(s string) *yaml.Node {
	return &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: s}
}

func nodeGet(m *yaml.Node, key string) *yaml.Node {
	if m == nil || m.Kind != yaml.MappingNode {
		return nil
	}
	for i := 0; i+1 < len(m.Content); i += 2 {
		if m.Content[i].Value == key {
			return m.Content[i+1]
		}
	}
	return nil
}

// nodeSet replaces a key's value in place (preserving its position and comments)
// or appends the key if absent.
func nodeSet(m *yaml.Node, key string, val *yaml.Node) {
	if m.Kind != yaml.MappingNode {
		m.Kind = yaml.MappingNode
		m.Tag = "!!map"
	}
	for i := 0; i+1 < len(m.Content); i += 2 {
		if m.Content[i].Value == key {
			m.Content[i+1] = val
			return
		}
	}
	m.Content = append(m.Content, scalarNode(key), val)
}

func nodeDelete(m *yaml.Node, key string) {
	if m == nil || m.Kind != yaml.MappingNode {
		return
	}
	for i := 0; i+1 < len(m.Content); i += 2 {
		if m.Content[i].Value == key {
			m.Content = append(m.Content[:i], m.Content[i+2:]...)
			return
		}
	}
}

func applyRepoPatchNode(repo *yaml.Node, p refineRepoPatch) {
	if repo == nil || repo.Kind != yaml.MappingNode {
		return
	}
	if p.Role != nil {
		nodeSet(repo, "role", scalarNode(*p.Role))
	}
	// Gates are replaced wholesale because the client sends the complete set it
	// rendered; merging key-by-key would make deleting a gate impossible.
	if p.Factory != nil && p.Factory.Gates != nil {
		factory := nodeGet(repo, "factory")
		if factory == nil || factory.Kind != yaml.MappingNode {
			factory = &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map"}
			nodeSet(repo, "factory", factory)
		}
		gates := &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map"}
		names := make([]string, 0, len(p.Factory.Gates))
		for k := range p.Factory.Gates {
			names = append(names, k)
		}
		sort.Strings(names) // stable output for a freshly built map
		for _, k := range names {
			gates.Content = append(gates.Content, scalarNode(k), scalarNode(p.Factory.Gates[k]))
		}
		nodeSet(factory, "gates", gates)
	}
}

// patchReposNode applies patches to whichever repo shape the file uses (a sequence
// of entries carrying `name:`, or a mapping keyed by name). Repos not already
// present are reported rather than invented, since this payload carries no `path`.
func patchReposNode(repos *yaml.Node, patches map[string]refineRepoPatch) []string {
	var unknown []string
	if repos == nil {
		for name := range patches {
			unknown = append(unknown, name)
		}
		sort.Strings(unknown)
		return unknown
	}

	switch repos.Kind {
	case yaml.SequenceNode:
		seen := map[string]bool{}
		for _, item := range repos.Content {
			nameNode := nodeGet(item, "name")
			if nameNode == nil {
				continue
			}
			if p, ok := patches[nameNode.Value]; ok {
				applyRepoPatchNode(item, p)
				seen[nameNode.Value] = true
			}
		}
		for name := range patches {
			if !seen[name] {
				unknown = append(unknown, name)
			}
		}

	case yaml.MappingNode:
		for name, p := range patches {
			entry := nodeGet(repos, name)
			if entry == nil {
				unknown = append(unknown, name)
				continue
			}
			applyRepoPatchNode(entry, p)
		}

	default:
		for name := range patches {
			unknown = append(unknown, name)
		}
	}

	sort.Strings(unknown)
	return unknown
}

func marshalYAMLDoc(doc *yaml.Node) ([]byte, error) {
	var buf bytes.Buffer
	enc := yaml.NewEncoder(&buf)
	enc.SetIndent(2)
	if err := enc.Encode(doc); err != nil {
		_ = enc.Close()
		return nil, err
	}
	if err := enc.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}
