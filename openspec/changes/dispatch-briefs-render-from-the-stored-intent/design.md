# Design — Dispatch briefs render from the stored intent

## Ownership

One repository, `sergeant-v2`. Touches `internal/store/` (new file, new
method), `internal/dag/engine.go` (`RunStage`), and `internal/mcp/server.go`
(`sergeant_get_brief`'s schema and implementation).

## `Store.RenderIntentBrief` — a pure rendering over existing rows

New file `internal/store/brief.go`:

```go
// RenderIntentBrief renders the canonical brief for one bullet of an
// intent: the intent's statement, the bullet's repo/position/status (and
// blocked reason, if blocked), the OpenSpec change it resolved to, and the
// gate names the caller supplies. It performs no write and reads nothing
// beyond the given intent's own rows — it is the one rendering both
// dispatch paths (D1) must call, so they cannot describe the same work
// differently.
func (s *Store) RenderIntentBrief(intentID, repo string, gates []string) (string, error) {
	intent, err := s.GetIntent(intentID)
	if err != nil {
		return "", fmt.Errorf("loading intent %q for brief: %w", intentID, err)
	}
	bullets, err := s.ListBulletsForIntent(intentID)
	if err != nil {
		return "", err
	}
	var bullet *BulletRecord
	for i := range bullets {
		if bullets[i].Repo == repo {
			bullet = &bullets[i]
			break
		}
	}
	if bullet == nil {
		return "", fmt.Errorf("no bullet found for repo %q on intent %q", repo, intentID)
	}

	var b strings.Builder
	fmt.Fprintf(&b, "# Intent\n\n%s\n\n", intent.Statement)
	fmt.Fprintf(&b, "# Bullet\n\nRepo: %s\nPosition: %d of %d\nStatus: %s\n",
		bullet.Repo, bullet.Position, len(bullets), bullet.Status)
	if bullet.Status == "blocked" && bullet.BlockedReason != "" {
		fmt.Fprintf(&b, "Blocked reason: %s\n", bullet.BlockedReason)
	}
	if intent.ChangeID != "" {
		fmt.Fprintf(&b, "\n# OpenSpec change\n\n%s", intent.ChangeID)
		if intent.ChangeRepo != "" {
			fmt.Fprintf(&b, " (%s)", intent.ChangeRepo)
		}
		b.WriteString("\n")
	}
	if len(gates) > 0 {
		fmt.Fprintf(&b, "\n# Gates\n\n%s\n", strings.Join(gates, ", "))
	}
	return b.String(), nil
}
```

Deliberately takes `gates []string` as a caller-supplied parameter rather
than loading `*config.Project` itself: `internal/store` does not import
`internal/config` today (verified — no cycle either direction), and gate
names are a configuration fact, not something recorded on `IntentRecord`/
`BulletRecord`. Both call sites below already have the project config
loaded for their own purposes, so passing the names in costs them nothing
and keeps this method testable with a fake store and a literal `[]string`,
no project-YAML fixture required.

## `internal/dag/engine.go`'s `RunStage`

Current (`engine.go:352-357`):

```go
prompt := stage.Brief
if prompt == "" {
	prompt = fmt.Sprintf("Execute %s phase for stage %s on %s", phase, stage.Name, repoName)
}
```

New: immediately before this block, load the run once
(`run, err := e.Store.GetRun(runID)`; `RunStage` already has `runID` as a
parameter) and, when `run.IntentID != ""`, render the brief:

```go
prompt := stage.Brief
if run, err := e.Store.GetRun(runID); err == nil && run.IntentID != "" {
	gates := SortedGateNames(repoCfg)
	if rendered, rerr := e.Store.RenderIntentBrief(run.IntentID, repoName, gates); rerr == nil {
		prompt = rendered
	}
}
if prompt == "" {
	prompt = fmt.Sprintf("Execute %s phase for stage %s on %s", phase, stage.Name, repoName)
}
```

A `GetRun`/`RenderIntentBrief` error (a run created before this change had
no intent id path populated correctly, or a genuinely missing bullet) falls
through to the existing `stage.Brief`/generic-fallback behavior unchanged —
this proposal adds a preferred path, it does not remove the one that exists
today, so no run that worked before this change can start failing because
of it.

## `internal/mcp/server.go`'s `sergeant_get_brief`

Schema (`server.go:101-109`) changes from a single required `project`
string to:

```go
"properties": map[string]interface{}{
	"intent_id": map[string]string{"type": "string", "description": "Intent id to render a brief for"},
	"repo":      map[string]string{"type": "string", "description": "Repository name (the bullet within the intent)"},
},
"required": []string{"intent_id", "repo"},
```

Implementation (`server.go:298-305`) changes from `config.LoadProject` +
raw dump to:

```go
case "sergeant_get_brief":
	intentID, _ := args["intent_id"].(string)
	repo, _ := args["repo"].(string)
	intent, err := s.Store.GetIntent(intentID)
	if err != nil {
		return "", err
	}
	proj, err := config.LoadProject(intent.Project)
	if err != nil {
		return "", err
	}
	repoCfg, ok := proj.Repos[repo]
	if !ok {
		return "", fmt.Errorf("repo %q not configured in project %q", repo, proj.Name)
	}
	gates := SortedGateNames(repoCfg) // dag.SortedGateNames, already exported
	return s.Store.RenderIntentBrief(intentID, repo, gates)
```

This is a breaking change to the tool's input schema (`project` is gone).
Accepted deliberately: the tool's own registered description already
promised intent-brief content it never delivered (see proposal.md's
Problem section) — no caller could have been relying on the current
behavior actually matching that description, since it never did.

## Rejected alternatives

**Store a rendered brief as a new column or file, refreshed on write.**
Rejected by the PRD itself and by D4: a second durable copy that must be
kept in sync with the rows it was derived from is exactly the
multiple-sources-of-truth problem D4 already resolved by making Intent/
Bullet the sole store. `RenderIntentBrief` is called fresh every time
instead.

**Give `Store.RenderIntentBrief` its own `*config.Project` parameter and
have it load gates itself.** Rejected: would make `internal/store` import
`internal/config`, coupling the persistence layer to project-YAML parsing
for a fact (gate names) that is not itself persisted. Passing `gates
[]string` keeps the dependency direction the same as it is today.

**Keep `sergeant_get_brief`'s `project` parameter and have it guess or list
all in-progress intents for that project.** Rejected: ambiguous when a
project has more than one in-flight intent, and every other MCP tool this
session touches resolves to one target of one operation, not a filtered
list the caller must disambiguate further.
