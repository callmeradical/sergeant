package graphify

import (
	"encoding/json"
	"fmt"
	"os"
	"path"
	"strings"
)

// filterGraphFile rewrites the merged graph at graphPath in place, dropping
// every node, link, and hyperedge whose source_file matches any of
// patterns, then dropping any surviving link or hyperedge that references a
// node id filtering just removed. An empty patterns list still runs this
// pass in full: matchesAny never matches, so every element survives — the
// same "empty means everything" convention participatingRepoNames already
// applies to include_groups, not a bypassed code path.
//
// Every top-level key other than "nodes", "links", and "hyperedges" (e.g.
// directed, multigraph, graph, built_at_commit), and every field within a
// kept node/link/hyperedge, passes through untouched: each element is kept
// or dropped as a whole json.RawMessage, never decoded into a struct that
// would silently drop fields this pass doesn't know about.
func filterGraphFile(graphPath string, patterns []string) error {
	data, err := os.ReadFile(graphPath)
	if err != nil {
		return fmt.Errorf("reading merged graph %s: %w", graphPath, err)
	}

	var doc map[string]json.RawMessage
	if err := json.Unmarshal(data, &doc); err != nil {
		return fmt.Errorf("parsing merged graph %s: %w", graphPath, err)
	}

	nodes, err := decodeRawArray(doc, "nodes")
	if err != nil {
		return fmt.Errorf("parsing nodes in %s: %w", graphPath, err)
	}
	links, err := decodeRawArray(doc, "links")
	if err != nil {
		return fmt.Errorf("parsing links in %s: %w", graphPath, err)
	}
	hyperedges, err := decodeRawArray(doc, "hyperedges")
	if err != nil {
		return fmt.Errorf("parsing hyperedges in %s: %w", graphPath, err)
	}

	survivingIDs := map[string]bool{}
	keptNodes := make([]json.RawMessage, 0, len(nodes))
	for _, raw := range nodes {
		var n struct {
			ID         string `json:"id"`
			SourceFile string `json:"source_file"`
		}
		if err := json.Unmarshal(raw, &n); err != nil {
			return fmt.Errorf("parsing node in %s: %w", graphPath, err)
		}
		if matchesAny(patterns, n.SourceFile) {
			continue
		}
		keptNodes = append(keptNodes, raw)
		survivingIDs[n.ID] = true
	}

	keptLinks := make([]json.RawMessage, 0, len(links))
	for _, raw := range links {
		var l struct {
			Source     string `json:"source"`
			Target     string `json:"target"`
			SourceFile string `json:"source_file"`
		}
		if err := json.Unmarshal(raw, &l); err != nil {
			return fmt.Errorf("parsing link in %s: %w", graphPath, err)
		}
		if matchesAny(patterns, l.SourceFile) {
			continue
		}
		if !survivingIDs[l.Source] || !survivingIDs[l.Target] {
			continue // dangling: an endpoint's node was excluded
		}
		keptLinks = append(keptLinks, raw)
	}

	keptHyperedges := make([]json.RawMessage, 0, len(hyperedges))
	for _, raw := range hyperedges {
		var h struct {
			Nodes      []string `json:"nodes"`
			SourceFile string   `json:"source_file"`
		}
		if err := json.Unmarshal(raw, &h); err != nil {
			return fmt.Errorf("parsing hyperedge in %s: %w", graphPath, err)
		}
		if matchesAny(patterns, h.SourceFile) {
			continue
		}
		remaining := 0
		for _, id := range h.Nodes {
			if survivingIDs[id] {
				remaining++
			}
		}
		if remaining < 2 {
			continue // fewer than two real endpoints is not a graph fact
		}
		keptHyperedges = append(keptHyperedges, raw)
	}

	if err := encodeRawArray(doc, "nodes", keptNodes); err != nil {
		return fmt.Errorf("encoding filtered nodes: %w", err)
	}
	if err := encodeRawArray(doc, "links", keptLinks); err != nil {
		return fmt.Errorf("encoding filtered links: %w", err)
	}
	if err := encodeRawArray(doc, "hyperedges", keptHyperedges); err != nil {
		return fmt.Errorf("encoding filtered hyperedges: %w", err)
	}

	out, err := json.Marshal(doc)
	if err != nil {
		return fmt.Errorf("encoding filtered graph: %w", err)
	}
	if err := os.WriteFile(graphPath, out, 0644); err != nil {
		return fmt.Errorf("writing filtered graph %s: %w", graphPath, err)
	}
	return nil
}

// decodeRawArray returns doc[key] decoded as a slice of raw elements, or nil
// if key is absent — a graph.json missing one of these arrays is left alone
// rather than having the key invented.
func decodeRawArray(doc map[string]json.RawMessage, key string) ([]json.RawMessage, error) {
	raw, ok := doc[key]
	if !ok {
		return nil, nil
	}
	var arr []json.RawMessage
	if err := json.Unmarshal(raw, &arr); err != nil {
		return nil, err
	}
	return arr, nil
}

// encodeRawArray writes arr back into doc[key], only if key was already
// present in doc.
func encodeRawArray(doc map[string]json.RawMessage, key string, arr []json.RawMessage) error {
	if _, ok := doc[key]; !ok {
		return nil
	}
	encoded, err := json.Marshal(arr)
	if err != nil {
		return err
	}
	doc[key] = encoded
	return nil
}

// matchesAny reports whether sourceFile matches any of patterns,
// gitignore-style: '*' matches within a single path segment, '**' matches
// any number of segments, including zero.
func matchesAny(patterns []string, sourceFile string) bool {
	for _, p := range patterns {
		if matchesPattern(p, sourceFile) {
			return true
		}
	}
	return false
}

func matchesPattern(pattern, name string) bool {
	return matchSegments(strings.Split(pattern, "/"), strings.Split(name, "/"))
}

// matchSegments matches pattern segments against name segments one at a
// time. A "**" segment may consume zero or more name segments; go's
// path.Match has no such operator, so each non-"**" segment is matched
// against exactly one name segment via path.Match instead, which already
// supports '*', '?', and character classes within a segment.
func matchSegments(pattern, name []string) bool {
	if len(pattern) == 0 {
		return len(name) == 0
	}
	if pattern[0] == "**" {
		if matchSegments(pattern[1:], name) {
			return true
		}
		if len(name) == 0 {
			return false
		}
		return matchSegments(pattern, name[1:])
	}
	if len(name) == 0 {
		return false
	}
	ok, err := path.Match(pattern[0], name[0])
	if err != nil || !ok {
		return false
	}
	return matchSegments(pattern[1:], name[1:])
}
