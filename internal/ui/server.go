package ui

import (
	"bytes"
	"context"
	"embed"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"gopkg.in/yaml.v3"

	"github.com/callmeradical/sergeant/internal/config"
	"github.com/callmeradical/sergeant/internal/dag"
	"github.com/callmeradical/sergeant/internal/handoff"
	"github.com/callmeradical/sergeant/internal/runner"
	"github.com/callmeradical/sergeant/internal/store"
)

//go:embed static/*
var staticFS embed.FS

type Server struct {
	Store *store.Store
	Port  int

	// cancels holds one CancelFunc per in-flight run so that a cancel request can
	// actually stop the work. Without it "Stop Run" only writes a status column
	// that the dispatch goroutine later overwrites, and agents keep writing to
	// worktrees after the operator believes they were stopped.
	mu      sync.Mutex
	cancels map[string]context.CancelFunc
}

func (srv *Server) registerRun(runID string, cancel context.CancelFunc) {
	srv.mu.Lock()
	defer srv.mu.Unlock()
	if srv.cancels == nil {
		srv.cancels = map[string]context.CancelFunc{}
	}
	srv.cancels[runID] = cancel
}

// isRunActive reports whether this process is currently driving the run. A status
// check alone is not enough: a run registered as in-flight may not have written
// its status yet, and resuming it would put two agents in one worktree.
func (srv *Server) isRunActive(runID string) bool {
	srv.mu.Lock()
	defer srv.mu.Unlock()
	_, ok := srv.cancels[runID]
	return ok
}

func (srv *Server) finishRun(runID string) {
	srv.mu.Lock()
	defer srv.mu.Unlock()
	delete(srv.cancels, runID)
}

// cancelRun stops an in-flight run. Reports whether a live run was found.
func (srv *Server) cancelRun(runID string) bool {
	srv.mu.Lock()
	cancel, ok := srv.cancels[runID]
	srv.mu.Unlock()
	if ok && cancel != nil {
		cancel()
	}
	return ok
}

// writeJSON marshals v before writing any header, so a marshal failure becomes a
// real 500 instead of a silent HTTP 200 with a zero-byte body.
func writeJSON(w http.ResponseWriter, status int, v interface{}) {
	body, err := json.Marshal(v)
	if err != nil {
		http.Error(w, fmt.Sprintf("encoding response: %v", err), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Length", strconv.Itoa(len(body)))
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

func NewServer(s *store.Store, port int) *Server {
	if port <= 0 {
		port = 8484
	}
	return &Server{
		Store:   s,
		Port:    port,
		cancels: map[string]context.CancelFunc{},
	}
}

func (srv *Server) Handler() http.Handler {
	mux := http.NewServeMux()

	// API endpoints
	mux.HandleFunc("/api/projects", srv.handleProjects)
	mux.HandleFunc("/api/project-details", srv.handleProjectDetails)
	mux.HandleFunc("/api/refine-project", srv.handleRefineProject)
	mux.HandleFunc("/api/runs", srv.handleRuns)
	mux.HandleFunc("/api/run-details", srv.handleRunDetails)
	mux.HandleFunc("/api/validate-intent", srv.handleValidateIntent)
	mux.HandleFunc("/api/discover-workflow", srv.handleDiscoverWorkflow)
	mux.HandleFunc("/api/workflow", srv.handleWorkflow)
	mux.HandleFunc("/api/save-dag", srv.handleSaveDAG)
	mux.HandleFunc("/api/dispatch", srv.handleDispatch)
	mux.HandleFunc("/api/create-pr", srv.handleCreatePR)
	mux.HandleFunc("/api/fleet", srv.handleFleet)
	mux.HandleFunc("/api/clean-worktrees", srv.handleCleanWorktrees)
	mux.HandleFunc("/api/run-cancel", srv.handleRunCancel)
	mux.HandleFunc("/api/run-resume", srv.handleRunResume)
	mux.HandleFunc("/api/run-delete", srv.handleRunDelete)

	// Static assets
	mux.HandleFunc("/", srv.handleIndex)

	return mux
}

func (srv *Server) Start() error {
	handler := srv.Handler()
	addr := fmt.Sprintf("127.0.0.1:%d", srv.Port)
	fmt.Printf("🌐 Sergeant Factory UI running at http://%s\n", addr)
	return http.ListenAndServe(addr, handler)
}

func (srv *Server) handleIndex(w http.ResponseWriter, r *http.Request) {
	data, err := staticFS.ReadFile("static/index.html")
	if err != nil {
		http.Error(w, "UI assets not found", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write(data)
}

func (srv *Server) handleProjects(w http.ResponseWriter, r *http.Request) {
	projects, err := config.ListProjects()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if projects == nil {
		projects = []*config.Project{}
	}
	writeJSON(w, http.StatusOK, projects)
}

func (srv *Server) handleProjectDetails(w http.ResponseWriter, r *http.Request) {
	name := r.URL.Query().Get("name")
	if name == "" {
		http.Error(w, "missing project name", http.StatusBadRequest)
		return
	}

	proj, err := config.LoadProject(name)
	if err != nil {
		http.Error(w, fmt.Sprintf("project '%s' not found: %v", name, err), http.StatusNotFound)
		return
	}

	writeJSON(w, http.StatusOK, proj)
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

func (srv *Server) handleRuns(w http.ResponseWriter, r *http.Request) {
	project := r.URL.Query().Get("project")
	runs := []store.RunRecord{}
	var err error

	if project != "" && project != "all" {
		runs, err = srv.Store.ListRunsForProject(project, 50)
	} else {
		runs, err = srv.Store.ListRecentRuns(50)
	}

	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if runs == nil {
		runs = []store.RunRecord{}
	}
	writeJSON(w, http.StatusOK, runs)
}

func (srv *Server) handleRunDetails(w http.ResponseWriter, r *http.Request) {
	runID := r.URL.Query().Get("id")
	if runID == "" {
		http.Error(w, "missing run id", http.StatusBadRequest)
		return
	}

	phases, err := srv.Store.ListPhasesForRun(runID)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if phases == nil {
		phases = []store.PhaseRecord{}
	}

	envelopes, err := srv.Store.ListEnvelopesForRun(runID)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if envelopes == nil {
		envelopes = []store.EnvelopeRecord{}
	}

	resp := map[string]interface{}{
		"run_id":    runID,
		"phases":    phases,
		"envelopes": envelopes,
	}

	writeJSON(w, http.StatusOK, resp)
}

func resolveGitRemoteURL(repoDir string) string {
	if strings.HasPrefix(repoDir, "~/") {
		home, _ := os.UserHomeDir()
		repoDir = filepath.Join(home, repoDir[2:])
	}
	cmd := exec.Command("git", "-C", repoDir, "config", "--get", "remote.origin.url")
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	raw := strings.TrimSpace(string(out))
	if strings.HasPrefix(raw, "git@github.com:") {
		raw = strings.TrimPrefix(raw, "git@github.com:")
		raw = strings.TrimSuffix(raw, ".git")
		return "https://github.com/" + raw
	}
	if strings.HasPrefix(raw, "https://github.com/") {
		return strings.TrimSuffix(raw, ".git")
	}
	if strings.HasPrefix(raw, "http://") || strings.HasPrefix(raw, "https://") {
		return strings.TrimSuffix(raw, ".git")
	}
	return ""
}

func (srv *Server) handleCreatePR(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		RunID   string `json:"run_id"`
		Project string `json:"project"`
		Repo    string `json:"repo"`
		Title   string `json:"title"`
		Body    string `json:"body"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.RunID == "" {
		http.Error(w, "invalid PR payload", http.StatusBadRequest)
		return
	}

	proj, _ := config.LoadProject(req.Project)
	repoPath := ""
	if proj != nil && len(proj.Repos) > 0 {
		if req.Repo != "" {
			if rCfg, exists := proj.Repos[req.Repo]; exists {
				repoPath = rCfg.Path
			}
		}
		if repoPath == "" {
			for _, rCfg := range proj.Repos {
				repoPath = rCfg.Path
				break
			}
		}
	}

	remoteBase := ""
	if repoPath != "" {
		remoteBase = resolveGitRemoteURL(repoPath)
	}

	branch := fmt.Sprintf("sergeant/%s", req.RunID)
	if req.Title == "" {
		req.Title = fmt.Sprintf("feat(%s): verified patch for run [%s]", req.Project, req.RunID)
	}

	var prURL string
	var prError string

	if repoPath != "" && remoteBase != "" {
		// Attempt real gh pr create in git repo if remote exists
		cmd := exec.Command("gh", "pr", "create", "--title", req.Title, "--body", req.Body, "--head", branch)
		cmd.Dir = repoPath
		out, err := cmd.CombinedOutput()
		if err == nil && strings.HasPrefix(strings.TrimSpace(string(out)), "https://") {
			prURL = strings.TrimSpace(string(out))
		} else {
			prError = strings.TrimSpace(string(out))
			prURL = fmt.Sprintf("%s/compare/%s?expand=1", remoteBase, branch)
		}
	} else {
		prURL = fmt.Sprintf("local://worktree/%s", branch)
	}

	summary := fmt.Sprintf("PR Staged: %s", req.Title)
	if prError != "" {
		summary = fmt.Sprintf("PR Ready (Local Branch '%s'): %s", branch, req.Title)
	}

	envRec := &store.EnvelopeRecord{
		ID:        fmt.Sprintf("pr-%s-%d", req.RunID, time.Now().UnixNano()),
		RunID:     req.RunID,
		Repo:      req.Repo,
		Stage:     "review",
		Summary:   summary,
		Artifacts: []string{prURL, ".sergeant/review.json"},
		Data:      json.RawMessage(fmt.Sprintf(`{"pr_url": %q, "branch": %q, "remote_base": %q, "error": %q}`, prURL, branch, remoteBase, prError)),
	}
	_ = srv.Store.RecordEnvelope(envRec)

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"status": "created",
		"run_id": req.RunID,
		"pr_url": prURL,
		"branch": branch,
		"error":  prError,
	})
}

func (srv *Server) handleFleet(w http.ResponseWriter, r *http.Request) {
	home, _ := os.UserHomeDir()
	fleetDir := filepath.Join(home, ".local", "share", "sergeant", "fleet")

	type WorktreeLease struct {
		TaskID    string `json:"task_id"`
		Path      string `json:"path"`
		Status    string `json:"status"`
		CreatedAt string `json:"created_at"`
	}

	recentRuns, _ := srv.Store.ListRecentRuns(200)
	runStatusMap := make(map[string]string)
	for _, r := range recentRuns {
		runStatusMap[r.ID] = r.Status
		runStatusMap[r.TaskID] = r.Status
	}

	var leases []WorktreeLease
	entries, _ := os.ReadDir(fleetDir)
	for _, entry := range entries {
		if entry.IsDir() {
			info, _ := entry.Info()
			modTime := time.Now().Format(time.RFC3339)
			if info != nil {
				modTime = info.ModTime().Format(time.RFC3339)
			}
			st, ok := runStatusMap[entry.Name()]
			if !ok {
				st = "unknown"
			}
			leases = append(leases, WorktreeLease{
				TaskID:    entry.Name(),
				Path:      filepath.Join(fleetDir, entry.Name()),
				Status:    st,
				CreatedAt: modTime,
			})
		}
	}
	if leases == nil {
		leases = []WorktreeLease{}
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"allocated_worktrees": len(leases),
		"leases":              leases,
	})
}

func (srv *Server) handleCleanWorktrees(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		TaskID string `json:"task_id"`
		DryRun bool   `json:"dry_run"`
		Force  bool   `json:"force"`
	}

	if r.Body != nil {
		_ = json.NewDecoder(r.Body).Decode(&req)
	}

	if req.TaskID != "" && (strings.Contains(req.TaskID, "/") || strings.Contains(req.TaskID, "..") || strings.Contains(req.TaskID, string(filepath.Separator))) {
		http.Error(w, "invalid task_id", http.StatusBadRequest)
		return
	}

	home, _ := os.UserHomeDir()
	fleetDir := filepath.Join(home, ".local", "share", "sergeant", "fleet")
	_ = os.MkdirAll(fleetDir, 0755)

	recentRuns, _ := srv.Store.ListRecentRuns(200)
	runStatusMap := make(map[string]string)
	for _, r := range recentRuns {
		runStatusMap[r.ID] = r.Status
		runStatusMap[r.TaskID] = r.Status
	}

	type SkippedLease struct {
		Path   string `json:"path"`
		Reason string `json:"reason"`
	}

	removed := []string{}
	skipped := []SkippedLease{}

	entries, _ := os.ReadDir(fleetDir)
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		if req.TaskID != "" && entry.Name() != req.TaskID {
			continue
		}

		targetPath := filepath.Join(fleetDir, entry.Name())
		status := runStatusMap[entry.Name()]
		if status == "running" && !req.Force {
			skipped = append(skipped, SkippedLease{
				Path:   targetPath,
				Reason: "run still in progress",
			})
			continue
		}

		// Never destroy unreviewed work by default. A completed run whose worktree
		// still has uncommitted changes represents agent output that exists nowhere
		// else; deleting it is unrecoverable.
		if !req.Force {
			if dirty := dirtyWorktreesUnder(targetPath); len(dirty) > 0 {
				skipped = append(skipped, SkippedLease{
					Path:   targetPath,
					Reason: fmt.Sprintf("uncommitted changes in %s — commit or use force", strings.Join(dirty, ", ")),
				})
				continue
			}
		}

		if !req.DryRun {
			if err := os.RemoveAll(targetPath); err == nil {
				removed = append(removed, targetPath)
			}
		} else {
			removed = append(removed, targetPath)
		}
	}

	statusStr := "cleaned"
	if req.DryRun {
		statusStr = "preview"
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"status":  statusStr,
		"removed": removed,
		"skipped": skipped,
		"count":   len(removed),
	})
}

type IntentValidationResult struct {
	Valid          bool     `json:"valid"`
	Score          int      `json:"score"`
	Project        string   `json:"project"`
	IdentifiedGoal string   `json:"identified_goal"`
	TargetRepos    []string `json:"target_repos"`
	ChecksPassed   []string `json:"checks_passed"`
	Warnings       []string `json:"warnings"`
	Errors         []string `json:"errors"`
}

func (srv *Server) handleValidateIntent(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		Project string `json:"project"`
		Brief   string `json:"brief"`
		Agent   string `json:"agent"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}

	brief := strings.TrimSpace(req.Brief)
	if brief == "" {
		http.Error(w, "Intent brief is required", http.StatusBadRequest)
		return
	}

	proj, err := config.LoadProject(req.Project)
	if err != nil {
		http.Error(w, fmt.Sprintf("project '%s' not found: %v", req.Project, err), http.StatusBadRequest)
		return
	}

	res := IntentValidationResult{
		Project:      proj.Name,
		ChecksPassed: []string{},
		Warnings:     []string{},
		Errors:       []string{},
	}
	res.IdentifiedGoal = brief

	totalChecks := 5
	passedChecks := 0

	// Check 1: Length
	if len(brief) >= 20 {
		passedChecks++
		res.ChecksPassed = append(res.ChecksPassed, "Sufficient intent clarity and length")
	} else {
		res.Warnings = append(res.Warnings, "Brief is quite concise; consider providing more context.")
	}

	// Check 2: Acceptance criteria signal words
	lowerBrief := strings.ToLower(brief)
	hasSignal := false
	signalWords := []string{"should", "must", "when", "given", "expect", "test", "verify"}
	for _, word := range signalWords {
		if strings.Contains(lowerBrief, word) {
			hasSignal = true
			break
		}
	}
	if hasSignal {
		passedChecks++
		res.ChecksPassed = append(res.ChecksPassed, "Contains explicit acceptance criteria signals")
	} else {
		res.Warnings = append(res.Warnings, "Brief lacks acceptance criteria signal words (e.g. should, must, expect, test).")
	}

	// Check 3: Repos in topology
	for repoName := range proj.Repos {
		res.TargetRepos = append(res.TargetRepos, repoName)
	}
	if len(res.TargetRepos) > 0 {
		passedChecks++
		res.ChecksPassed = append(res.ChecksPassed, fmt.Sprintf("Resolved %d target repos in topology (%s)", len(res.TargetRepos), strings.Join(res.TargetRepos, ", ")))
	} else {
		res.Errors = append(res.Errors, "No repositories configured in project topology")
	}

	// Check 4: Names a configured repo or file path
	namesRepoOrPath := false
	for _, rName := range res.TargetRepos {
		if strings.Contains(lowerBrief, strings.ToLower(rName)) {
			namesRepoOrPath = true
			break
		}
	}
	if strings.Contains(lowerBrief, "/") || strings.Contains(lowerBrief, ".go") || strings.Contains(lowerBrief, ".ts") || strings.Contains(lowerBrief, ".js") || strings.Contains(lowerBrief, ".py") {
		namesRepoOrPath = true
	}
	if namesRepoOrPath {
		passedChecks++
		res.ChecksPassed = append(res.ChecksPassed, "Targets specific repository or file path in topology")
	} else {
		res.Warnings = append(res.Warnings, "Brief does not explicitly name a target repository or file path.")
	}

	// Check 5: Deterministic quality gates
	hasGates := false
	for _, r := range proj.Repos {
		if r.Factory != nil && len(r.Factory.Gates) > 0 {
			hasGates = true
			break
		}
	}
	if hasGates {
		passedChecks++
		res.ChecksPassed = append(res.ChecksPassed, "Zero-token deterministic code quality gates defined")
	} else {
		res.Warnings = append(res.Warnings, "No explicit factory.gates configured in project YAML.")
	}

	res.Score = (passedChecks * 100) / totalChecks
	res.Valid = (res.Score >= 60 && len(res.Errors) == 0)

	writeJSON(w, http.StatusOK, res)
}

func (srv *Server) handleDiscoverWorkflow(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		Project         string `json:"project"`
		IntentArchetype string `json:"intent_archetype"`
		QualityBar      string `json:"quality_bar"`
		DeliveryMode    string `json:"delivery_mode"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Project == "" {
		http.Error(w, "invalid discovery request", http.StatusBadRequest)
		return
	}

	proj, err := config.LoadProject(req.Project)
	if err != nil {
		http.Error(w, fmt.Sprintf("project '%s' not found: %v", req.Project, err), http.StatusBadRequest)
		return
	}

	var stages []config.DAGStage
	allRepos := []string{}
	for rName := range proj.Repos {
		allRepos = append(allRepos, rName)
	}

	stages = append(stages, config.DAGStage{
		Name:  "feature-tdd-execution",
		Repos: allRepos,
		Brief: "Execute test-driven implementation with zero-token deterministic gate verification",
	})

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"project":              proj.Name,
		"archetype":            req.IntentArchetype,
		"recommended_pipeline": stages,
		"decision_rationale":   fmt.Sprintf("Discovered %d repos across topology. Synthesized %d stages.", len(proj.Repos), len(stages)),
	})
}

func (srv *Server) handleSaveDAG(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		Project string            `json:"project"`
		Stages  []config.DAGStage `json:"stages"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Project == "" {
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}

	proj, err := config.LoadProject(req.Project)
	if err != nil {
		http.Error(w, fmt.Sprintf("project '%s' not found: %v", req.Project, err), http.StatusBadRequest)
		return
	}

	if proj.DAG == nil {
		proj.DAG = &config.DAGConfig{
			Name:        fmt.Sprintf("%s-pipeline", proj.Name),
			Description: fmt.Sprintf("Automated pipeline for %s", proj.Name),
		}
	}
	proj.DAG.Stages = req.Stages

	cfgDir := os.Getenv("SERGEANT_CONFIG")
	if cfgDir == "" {
		home, _ := os.UserHomeDir()
		cfgDir = filepath.Join(home, ".config", "sergeant")
	}
	filePath := filepath.Join(cfgDir, fmt.Sprintf("%s.yaml", proj.Name))

	out, err := yaml.Marshal(proj)
	if err != nil {
		http.Error(w, fmt.Sprintf("marshaling YAML: %v", err), http.StatusInternalServerError)
		return
	}

	if err := os.WriteFile(filePath, out, 0644); err != nil {
		http.Error(w, fmt.Sprintf("writing project YAML: %v", err), http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"status":  "saved",
		"project": proj.Name,
		"stages":  len(proj.DAG.Stages),
	})
}

// targetRepositories is the list of repositories a dispatch acts on: the ones it
// named, or every repository in the project when it named none.
//
// The fallback is sorted. Position in this list is a bullet's merge order, and
// map iteration order would give the same dispatch a different merge order on
// every call — the same reason changeRepo sorts before picking. The returned
// slice never aliases req.Repos, so a caller cannot append into the request.
func targetRepositories(proj *config.Project, requested []string) []string {
	if len(requested) > 0 {
		return append([]string(nil), requested...)
	}
	names := make([]string, 0, len(proj.Repos))
	for name := range proj.Repos {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

func (srv *Server) handleDispatch(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		Project string   `json:"project"`
		Brief   string   `json:"brief"`
		Repos   []string `json:"repos"`
		Agent   string   `json:"agent"`
		// ChangeID is optional. When empty, a change is derived from the brief and
		// scaffolded (decision O3); when set, it must already exist.
		ChangeID string `json:"change_id"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Project == "" {
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}

	if strings.TrimSpace(req.Brief) == "" {
		http.Error(w, "Intent brief cannot be empty", http.StatusBadRequest)
		return
	}

	proj, err := config.LoadProject(req.Project)
	if err != nil {
		http.Error(w, fmt.Sprintf("loading project: %v", err), http.StatusBadRequest)
		return
	}

	// Reject an agent this engine cannot drive before creating a run, worktree or
	// branch. An unrecognised name used to fall through to `exe <prompt>`, producing
	// a malformed command whose failure was indistinguishable from agent failure.
	if err := runner.ValidateAgent(req.Agent); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if req.Agent != "" {
		proj.Defaults.Agent = req.Agent
	}

	// Decision O3: resolve the OpenSpec change BEFORE anything else exists. No run
	// row, no branch and no worktree may precede it, or a failure here would leave
	// behind dispatched work with no planning record — exactly what O3 forbids.
	changeRepoName, changeRepoPath, err := changeRepo(proj, req.Repos)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	change, err := resolveChange(changeRepoPath, req.ChangeID, req.Brief)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	// The target repositories are resolved once, here, above every record write.
	// The DAG fallback stage below consumes the same slice, so the bullets and the
	// work the engine actually performs cannot name different repositories.
	targetRepos := targetRepositories(proj, req.Repos)

	taskID := fmt.Sprintf("sgt-%d", time.Now().Unix())
	brief := strings.TrimSpace(req.Brief)

	// Decision D4: sergeant stores intents and bullets itself, and decision D8
	// makes the intent the dashboard's primary noun. The intent is written after
	// the change is resolved and before the run exists, so the record order reads
	// planning record, then domain record, then execution record — the ordering O3
	// requires, extended inward. A dispatch refused above this point has written
	// nothing.
	intentID := taskID + "-intent"
	if err := srv.Store.CreateIntent(&store.IntentRecord{
		ID:        intentID,
		Project:   proj.Name,
		Statement: brief,
		Status:    "in_progress",
	}); err != nil {
		http.Error(w, fmt.Sprintf("recording the intent for this dispatch: %v", err), http.StatusInternalServerError)
		return
	}
	// One bullet per target repository, positioned in merge order. A bullet names
	// exactly one repository: work in a second repository is a second bullet.
	for i, repoName := range targetRepos {
		if err := srv.Store.CreateBullet(&store.BulletRecord{
			ID:       fmt.Sprintf("%s-b%d", taskID, i+1),
			IntentID: intentID,
			Repo:     repoName,
			Position: i + 1,
			Status:   "pending",
		}); err != nil {
			http.Error(w, fmt.Sprintf("recording bullet %d of this dispatch: %v", i+1, err), http.StatusInternalServerError)
			return
		}
	}

	runRec := &store.RunRecord{
		ID:       taskID,
		Project:  proj.Name,
		TaskID:   taskID,
		Brief:    brief,
		ChangeID: change.ID,
		IntentID: intentID,
		Status:   "running",
	}
	_ = srv.Store.CreateRun(runRec)

	home, _ := os.UserHomeDir()
	handoffBase := filepath.Join(home, ".local", "share", "sergeant", "fleet", taskID, "handoff")
	router := handoff.NewRouter(handoffBase)
	engine := dag.NewEngine(proj, srv.Store, router)

	// Async run dispatch. The context is cancellable so that handleRunCancel can
	// actually stop in-flight agent work rather than just relabelling the row.
	ctx, cancel := context.WithCancel(context.Background())
	srv.registerRun(taskID, cancel)

	go srv.executeRun(ctx, cancel, engine, proj, taskID, strings.TrimSpace(req.Brief), targetRepos)

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"status":  "dispatched",
		"task_id": taskID,
		"project": proj.Name,
		// The change is reported as it was resolved on disk, including which repo
		// holds it, so the operator can find the audit artifact for this run.
		"change_id":      change.ID,
		"change_dir":     change.Dir,
		"change_repo":    changeRepoName,
		"change_created": change.Created,
	})
}

// DeliveryReport describes what a run actually produced on disk. Every field is
// observed, never assumed. It deliberately has no "pr_url" unless a PR exists.
type DeliveryReport struct {
	Repo       string   `json:"repo"`
	Worktree   string   `json:"worktree"`
	Branch     string   `json:"branch"`
	Commits    int      `json:"commits"`
	Dirty      bool     `json:"dirty"`
	Pushed     bool     `json:"pushed"`
	RemoteBase string   `json:"remote_base,omitempty"`
	CompareURL string   `json:"compare_url,omitempty"`
	Summary    string   `json:"summary"`
	Artifacts  []string `json:"artifacts"`
	ReadyForPR bool     `json:"ready_for_pr"`
}

func gitOut(dir string, args ...string) string {
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// describeDelivery inspects the run's isolated worktree and reports its real state.
// It never claims a pull request exists; opening one is an explicit human action
// through /api/create-pr.
func (srv *Server) describeDelivery(proj *config.Project, runID string) DeliveryReport {
	branch := dag.BranchName(runID)

	// Report on the first repo that actually produced a worktree for this run.
	for repoName, rCfg := range proj.Repos {
		wt := dag.FleetDir(runID, repoName)
		if _, err := os.Stat(wt); err != nil {
			continue
		}

		rep := DeliveryReport{Repo: repoName, Worktree: wt, Branch: branch}
		rep.Dirty = gitOut(wt, "status", "--porcelain") != ""
		if n := gitOut(wt, "rev-list", "--count", "HEAD", "^"+defaultBase(wt)); n != "" {
			fmt.Sscanf(n, "%d", &rep.Commits)
		}
		rep.Pushed = gitOut(wt, "rev-parse", "--verify", "origin/"+branch) != ""
		rep.RemoteBase = resolveGitRemoteURL(expandHome(rCfg.Path))
		if rep.RemoteBase != "" && rep.Pushed {
			rep.CompareURL = fmt.Sprintf("%s/compare/%s?expand=1", rep.RemoteBase, branch)
		}

		switch {
		case rep.Commits == 0 && rep.Dirty:
			rep.Summary = fmt.Sprintf("Uncommitted changes in worktree for %s — nothing committed yet", repoName)
		case rep.Commits == 0:
			rep.Summary = fmt.Sprintf("Run completed with no changes to %s", repoName)
		case !rep.Pushed:
			rep.Summary = fmt.Sprintf("%d commit(s) on %s in an isolated worktree — not pushed", rep.Commits, branch)
			rep.ReadyForPR = true
		default:
			rep.Summary = fmt.Sprintf("%d commit(s) pushed to %s — ready to open a PR", rep.Commits, branch)
			rep.ReadyForPR = true
		}

		rep.Artifacts = []string{wt}
		if rep.CompareURL != "" {
			rep.Artifacts = append(rep.Artifacts, rep.CompareURL)
		}
		return rep
	}

	return DeliveryReport{
		Repo:      proj.Name,
		Branch:    branch,
		Summary:   "Run completed but produced no isolated worktree",
		Artifacts: []string{},
	}
}

// defaultBase resolves the branch a run should be diffed against.
func defaultBase(dir string) string {
	if ref := gitOut(dir, "symbolic-ref", "refs/remotes/origin/HEAD"); ref != "" {
		return strings.TrimPrefix(ref, "refs/remotes/")
	}
	for _, c := range []string{"origin/main", "origin/master", "main", "master"} {
		if gitOut(dir, "rev-parse", "--verify", c) != "" {
			return c
		}
	}
	return "HEAD"
}

func expandHome(p string) string {
	if strings.HasPrefix(p, "~/") {
		home, _ := os.UserHomeDir()
		return filepath.Join(home, p[2:])
	}
	return p
}

// dirtyWorktreesUnder returns the names of per-repo worktrees beneath a run's
// fleet directory that still contain uncommitted changes.
func dirtyWorktreesUnder(runDir string) []string {
	entries, err := os.ReadDir(runDir)
	if err != nil {
		return nil
	}
	var dirty []string
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		repoWT := filepath.Join(runDir, e.Name())
		if gitOut(repoWT, "rev-parse", "--git-dir") == "" {
			continue // not a worktree
		}
		if gitOut(repoWT, "status", "--porcelain") != "" {
			dirty = append(dirty, e.Name())
		}
	}
	return dirty
}

// firstLine trims a brief down to a usable commit subject.
func firstLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexAny(s, "\r\n"); i >= 0 {
		s = s[:i]
	}
	if len(s) > 72 {
		s = strings.TrimSpace(s[:72])
	}
	return s
}

func marshalRaw(v interface{}) json.RawMessage {
	b, err := json.Marshal(v)
	if err != nil {
		return json.RawMessage(`{}`)
	}
	return json.RawMessage(b)
}

func (srv *Server) handleRunCancel(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var req struct {
		ID string `json:"id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.ID == "" {
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}

	// Actually stop the work, then record it. Previously this only wrote the status
	// column, which the still-running dispatch goroutine later overwrote with
	// "passed" while its agents kept writing to disk.
	stopped := srv.cancelRun(req.ID)

	if err := srv.Store.UpdateRunStatus(req.ID, "cancelled"); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"status":      "cancelled",
		"id":          req.ID,
		"was_running": stopped,
		"note":        cancelNote(stopped),
	})
}

func cancelNote(stopped bool) string {
	if stopped {
		return "Run cancelled and in-flight agent work signalled to stop."
	}
	return "No in-flight run found on this server; status recorded as cancelled only."
}

func (srv *Server) handleRunDelete(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var req struct {
		ID string `json:"id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.ID == "" {
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}

	if err := srv.Store.DeleteRun(req.ID); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "deleted", "id": req.ID})
}

// executeRun drives a run's stages to completion and records its terminal status.
//
// It serves both a fresh dispatch and a resume. The two differ only in whether the
// run record already existed and in engine.Resume, which decides whether phases
// with a passed record are skipped. Keeping one body means a resumed run cannot
// drift from a dispatched one — commit behaviour, cancellation handling and
// delivery reporting are identical by construction rather than by discipline.
func (srv *Server) executeRun(
	ctx context.Context,
	cancel context.CancelFunc,
	engine *dag.Engine,
	proj *config.Project,
	taskID string,
	brief string,
	repos []string,
) {
	defer cancel()
	defer srv.finishRun(taskID)

	// setTerminal refuses to overwrite a cancellation. Previously the goroutine
	// unconditionally wrote "passed" at the end, silently reviving runs the
	// operator had stopped.
	setTerminal := func(status string) {
		if ctx.Err() != nil {
			_ = srv.Store.UpdateRunStatus(taskID, "cancelled")
			return
		}
		_ = srv.Store.UpdateRunStatus(taskID, status)
	}

	var stages []config.DAGStage
	if proj.DAG != nil && len(proj.DAG.Stages) > 0 {
		stages = proj.DAG.Stages
	} else {
		// One rule for resolving targets, shared with dispatch. A resume recovers
		// its repo list from phase records, which is empty when the original run
		// died before recording any, so the fallback has to apply here too — and it
		// has to be the same sorted fallback, or a resumed run could take a
		// different merge order than the dispatch that created it.
		stages = []config.DAGStage{{
			Name:  "custom-dispatch",
			Repos: targetRepositories(proj, repos),
			Brief: brief,
		}}
	}

	// Commit the agents' output. An uncommitted worktree is eligible for deletion
	// by "clean worktrees", so leaving it uncommitted means real work can be
	// destroyed by an unrelated click. Committing also makes it reviewable.
	commitMsg := firstLine(brief)
	if commitMsg == "" {
		commitMsg = "sergeant: automated changes"
	}
	commitAll := func() {
		for _, stage := range stages {
			for _, repoName := range stage.Repos {
				if _, _, err := dag.CommitRunOutput(context.Background(), taskID, repoName, commitMsg); err != nil {
					log.Printf("sergeant: commit failed for run %s repo %s: %v", taskID, repoName, err)
				}
			}
		}
	}

	for i := range stages {
		if ctx.Err() != nil {
			_ = srv.Store.UpdateRunStatus(taskID, "cancelled")
			return
		}
		if err := engine.RunStage(ctx, taskID, &stages[i]); err != nil {
			// Commit before reporting failure: a failed gate still leaves real agent
			// work on disk, and it must be reviewable rather than stranded.
			commitAll()
			setTerminal("failed")
			return
		}
	}

	if ctx.Err() != nil {
		_ = srv.Store.UpdateRunStatus(taskID, "cancelled")
		return
	}

	commitAll()

	// Delivery. This reports what actually happened on disk. It does NOT claim a
	// pull request exists — nothing in this path pushes a branch or calls the
	// GitHub API. Opening the PR is an explicit human action via /api/create-pr.
	delivery := srv.describeDelivery(proj, taskID)
	_ = srv.Store.RecordEnvelope(&store.EnvelopeRecord{
		ID:        fmt.Sprintf("delivery-%s-%d", taskID, time.Now().UnixNano()),
		RunID:     taskID,
		Repo:      delivery.Repo,
		Stage:     "review",
		Summary:   delivery.Summary,
		Artifacts: delivery.Artifacts,
		Data:      marshalRaw(delivery),
	})

	setTerminal("passed")
}

// ResumableStatuses are the run statuses a resume accepts.
//
// A passed run is excluded because re-running earned work can only lose it: a
// flaky gate would turn a pass into a failure. A running run is excluded because
// resuming it would put two agents in one worktree.
var ResumableStatuses = []string{"failed", "cancelled", "timed_out"}

func isResumable(status string) bool {
	for _, s := range ResumableStatuses {
		if status == s {
			return true
		}
	}
	return false
}

// handleRunResume re-enters an existing run instead of starting a new one.
//
// A run that dies leaves its worktree, its branch and its commits on disk, and
// before this there was no way to pick any of it up — the work was orphaned and
// the only recovery was a human merging the branch by hand. Run sgt-1787427981
// was killed at the former default agent timeout having already committed a
// change whose build and tests passed.
//
// Resume reuses the run id, so it reuses the worktree and branch (prepareWorktree
// returns an existing worktree untouched and no longer resets the branch), and
// skips phases that already hold a passed record. The run record is reused rather
// than copied: a second row would split one piece of work across two runs and two
// branches.
func (srv *Server) handleRunResume(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		ID string `json:"id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || strings.TrimSpace(req.ID) == "" {
		http.Error(w, "invalid request body: an id is required", http.StatusBadRequest)
		return
	}

	run, err := srv.Store.GetRun(strings.TrimSpace(req.ID))
	if err != nil || run == nil {
		http.Error(w, fmt.Sprintf("no run %q", req.ID), http.StatusNotFound)
		return
	}

	if !isResumable(run.Status) {
		http.Error(w, fmt.Sprintf(
			"run %s is %s and cannot be resumed; resumable statuses are %s",
			run.ID, run.Status, strings.Join(ResumableStatuses, ", ")),
			http.StatusConflict)
		return
	}

	// Refuse if this process is already driving the run. The status check above is
	// not sufficient on its own: a run registered as in-flight may not have written
	// its status yet.
	if srv.isRunActive(run.ID) {
		http.Error(w, fmt.Sprintf("run %s is already executing", run.ID), http.StatusConflict)
		return
	}

	proj, err := config.LoadProject(run.Project)
	if err != nil {
		http.Error(w, fmt.Sprintf("loading project %s: %v", run.Project, err), http.StatusBadRequest)
		return
	}

	// Resume runs the same body as a dispatch. The repository list is recovered
	// from the phase records where possible, so a resume targets what the original
	// run targeted rather than re-deriving it from configuration that may have
	// changed since.
	repos := srv.reposForRun(run.ID)

	home, _ := os.UserHomeDir()
	router := handoff.NewRouter(filepath.Join(home, ".local", "share", "sergeant-v2", "fleet", run.ID, "handoff"))
	engine := dag.NewEngine(proj, srv.Store, router)
	engine.Resume = true

	_ = srv.Store.UpdateRunStatus(run.ID, "running")

	ctx, cancel := context.WithCancel(context.Background())
	srv.registerRun(run.ID, cancel)
	go srv.executeRun(ctx, cancel, engine, proj, run.ID, run.Brief, repos)

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"status":  "resumed",
		"task_id": run.ID,
		"run_id":  run.ID,
		"project": proj.Name,
		"skipped": srv.passedPhaseNames(run.ID),
	})
}

// reposForRun recovers which repositories a run touched from its phase records.
// An empty result lets the caller fall back to the project's configured repos.
func (srv *Server) reposForRun(runID string) []string {
	phases, err := srv.Store.ListPhasesForRun(runID)
	if err != nil {
		return nil
	}
	seen := map[string]bool{}
	var out []string
	for _, p := range phases {
		if p.Repo != "" && !seen[p.Repo] {
			seen[p.Repo] = true
			out = append(out, p.Repo)
		}
	}
	return out
}

// passedPhaseNames reports which phases a resume will skip, so the response says
// what it is not going to do rather than leaving the operator to infer it.
func (srv *Server) passedPhaseNames(runID string) []string {
	phases, err := srv.Store.ListPhasesForRun(runID)
	if err != nil {
		return nil
	}
	var out []string
	for _, p := range phases {
		if p.Status == "passed" {
			out = append(out, p.Name)
		}
	}
	return out
}
