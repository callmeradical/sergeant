package graphify

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/callmeradical/sergeant/internal/config"
)

// ErrNoGraph is returned by Query, Explain, and Affected when no graph has
// been published yet at a Graphify configuration's Output. Callers must
// surface this as a clear "no graph built" condition rather than shelling
// out to graphify against a path that does not exist.
var ErrNoGraph = errors.New("no graph built for this project")

func graphPath(g *config.Graphify) string {
	return filepath.Join(g.Output, "graph.json")
}

func requireGraph(g *config.Graphify) (string, error) {
	path := graphPath(g)
	info, err := os.Stat(path)
	if err != nil || info.Size() == 0 {
		return "", fmt.Errorf("%w: %s", ErrNoGraph, path)
	}
	return path, nil
}

// Query runs `graphify query <question>` against the graph published at g's
// Output and returns its stdout (combined with stderr, matching
// BuildProjectGraph's error-reporting convention).
func Query(g *config.Graphify, question string) (string, error) {
	path, err := requireGraph(g)
	if err != nil {
		return "", err
	}
	out, err := runCommand("graphify", "query", question, "--graph", path)
	if err != nil {
		return "", fmt.Errorf("graphify query failed: %w\n%s", err, out)
	}
	return string(out), nil
}

// Explain runs `graphify explain <node>` against the graph published at g's
// Output and returns its stdout.
func Explain(g *config.Graphify, node string) (string, error) {
	path, err := requireGraph(g)
	if err != nil {
		return "", err
	}
	out, err := runCommand("graphify", "explain", node, "--graph", path)
	if err != nil {
		return "", fmt.Errorf("graphify explain failed: %w\n%s", err, out)
	}
	return string(out), nil
}

// Affected runs `graphify affected <node>` against the graph published at
// g's Output and returns its stdout.
func Affected(g *config.Graphify, node string) (string, error) {
	path, err := requireGraph(g)
	if err != nil {
		return "", err
	}
	out, err := runCommand("graphify", "affected", node, "--graph", path)
	if err != nil {
		return "", fmt.Errorf("graphify affected failed: %w\n%s", err, out)
	}
	return string(out), nil
}
