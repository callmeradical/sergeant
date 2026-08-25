package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"text/tabwriter"

	"github.com/callmeradical/sergeant/internal/config"
	"github.com/callmeradical/sergeant/internal/dag"
	"github.com/callmeradical/sergeant/internal/handoff"
	"github.com/callmeradical/sergeant/internal/mcp"
	"github.com/callmeradical/sergeant/internal/naming"
	"github.com/callmeradical/sergeant/internal/store"
	"github.com/callmeradical/sergeant/internal/ui"
)

func main() {
	if len(os.Args) < 2 {
		printUsage()
		os.Exit(1)
	}

	command := os.Args[1]
	switch command {
	case "run":
		if len(os.Args) < 3 {
			fmt.Fprintf(os.Stderr, "Usage: sergeant run <project-name-or-file>\n")
			os.Exit(1)
		}
		runProject(os.Args[2])
	case "status":
		showStatus()
	case "ui":
		startUI()
	case "mcp":
		startMCP()
	case "version":
		fmt.Println("sergeant v0.2.1 (Go Native Multi-Repo Software Factory Engine + Goose MCP Extension)")
	default:
		printUsage()
		os.Exit(1)
	}
}

func printUsage() {
	fmt.Println("Sergeant - Multi-Repo Software Factory Orchestrator")
	fmt.Println("\nUsage:")
	fmt.Println("  sergeant run <project>    Run a multi-repo factory pipeline DAG")
	fmt.Println("  sergeant status           Show recent factory runs and phase states")
	fmt.Println("  sergeant ui               Start embedded Web UI dashboard (http://127.0.0.1:8484)")
	fmt.Println("  sergeant mcp              Start MCP JSON-RPC stdio server for Goose / Claude")
	fmt.Println("  sergeant version          Print version info")
}

func startMCP() {
	home, _ := os.UserHomeDir()
	dbPath := filepath.Join(home, ".local", "share", "sergeant", "sergeant.db")
	st, err := store.Open(dbPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error opening store: %v\n", err)
		os.Exit(1)
	}
	defer st.Close()

	srv := mcp.NewMCPServer(st)
	if err := srv.ServeStdio(); err != nil {
		fmt.Fprintf(os.Stderr, "MCP server error: %v\n", err)
		os.Exit(1)
	}
}

func runProject(projName string) {
	proj, err := config.LoadProject(projName)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error loading project %s: %v\n", projName, err)
		os.Exit(1)
	}

	home, _ := os.UserHomeDir()
	dbPath := filepath.Join(home, ".local", "share", "sergeant", "sergeant.db")
	st, err := store.Open(dbPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error opening store: %v\n", err)
		os.Exit(1)
	}
	defer st.Close()

	// The same generator the dispatch handler uses. Two id formats would let a
	// CLI run and a dispatched run collide on the runs primary key.
	taskID := naming.RunID()
	// dag.FleetRoot is the single authority for the fleet root (D7). Building this
	// path by hand here is how the CLI kept writing handoffs into v1's directory
	// after the server stopped.
	handoffBase := filepath.Join(dag.FleetRoot(), taskID, "handoff")
	router := handoff.NewRouter(handoffBase)

	runRec := &store.RunRecord{
		ID:      taskID,
		Project: proj.Name,
		TaskID:  taskID,
		Status:  "running",
	}
	_ = st.CreateRun(runRec)

	fmt.Printf("🚀 Starting Multi-Repo Factory Run [%s] for project: %s\n", taskID, proj.Name)

	engine := dag.NewEngine(proj, st, router)
	ctx := context.Background()

	if proj.DAG != nil && len(proj.DAG.Stages) > 0 {
		for _, stage := range proj.DAG.Stages {
			fmt.Printf("\n▶ Executing Stage: %s (Repos: %v)\n", stage.Name, stage.Repos)
			if err := engine.RunStage(ctx, taskID, &stage); err != nil {
				fmt.Fprintf(os.Stderr, "❌ Stage %s failed: %v\n", stage.Name, err)
				_ = st.UpdateRunStatus(taskID, "failed")
				os.Exit(1)
			}
			fmt.Printf("✔ Stage %s passed\n", stage.Name)
		}
	}

	_ = st.UpdateRunStatus(taskID, "passed")
	fmt.Printf("\n🎉 Factory Run [%s] completed successfully!\n", taskID)
}

func showStatus() {
	home, _ := os.UserHomeDir()
	dbPath := filepath.Join(home, ".local", "share", "sergeant", "sergeant.db")
	st, err := store.Open(dbPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error opening store: %v\n", err)
		os.Exit(1)
	}
	defer st.Close()

	runs, err := st.ListRecentRuns(10)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error listing runs: %v\n", err)
		os.Exit(1)
	}

	w := tabwriter.NewWriter(os.Stdout, 0, 0, 3, ' ', 0)
	fmt.Fprintln(w, "RUN ID\tPROJECT\tSTATUS\tCREATED AT")
	for _, r := range runs {
		fmt.Fprintf(w, "%s\t%s\t%s\t%s\n", r.ID, r.Project, r.Status, r.CreatedAt.Format("2006-01-02 15:04:05"))
	}
	w.Flush()
}

func startUI() {
	home, _ := os.UserHomeDir()
	dbPath := filepath.Join(home, ".local", "share", "sergeant", "sergeant.db")
	st, err := store.Open(dbPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error opening store: %v\n", err)
		os.Exit(1)
	}
	defer st.Close()

	startExportRunners(st)

	server := ui.NewServer(st, 8484)
	if err := server.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "Error starting server: %v\n", err)
		os.Exit(1)
	}
}

// startExportRunners is the wiring point for internal/export.Runner: once a
// Target implementation exists, this starts one Runner per project with an
// Export block configured, in a goroutine alongside the HTTP server. No
// Target implementation exists yet — which backend name resolves to which
// Target is a separate, later decision — so today this only reports a
// configured project rather than silently ignoring it.
func startExportRunners(st *store.Store) {
	projects, err := config.ListProjects()
	if err != nil {
		fmt.Fprintf(os.Stderr, "export: listing projects: %v\n", err)
		return
	}
	for _, proj := range projects {
		if proj.Export == nil {
			continue
		}
		fmt.Fprintf(os.Stderr, "export: project %q configures backend %q, but no export target implementation is registered yet; skipping\n", proj.Name, proj.Export.Backend)
	}
}
