# Skill: load-project

Load and internalize the full context for a sergeant project before doing any work.

---

## When to use

Load this skill whenever:
- The user names a project ("work on smith", "let's look at myapp")
- You need to understand which repos are involved in a task
- You're about to do cross-repo work
- A new sergeant session starts and no project is loaded yet

---

## Protocol

### Step 1 — Confirm the project exists

```bash
bin/sgt-list
```

If the project name doesn't appear, tell the user. Offer to create a new project config.

### Step 2 — Load context

```bash
bin/sgt-context <project>
```

Read the entire output. It contains:
- All repos, their paths, and clone status
- Groups and which repos belong to them
- Resolved agent instructions per repo (defaults → group → repo)
- Knowledge graph status and output path

### Step 3 — Internalize and surface constraints

From the context block, extract and hold in mind:
- Which repos are cloned vs. missing
- Which repos belong to which groups
- Any active `agent_instructions` for repos you'll touch
- Whether a knowledge graph exists at `graphify.output`

If any repos are NOT CLONED that are relevant to the task, ask the user whether to run `bin/sgt-sync <project>` first.

### Step 4 — Check the knowledge graph (if available)

If `graphify.output/GRAPH_REPORT.md` exists:

```bash
cat <graphify_output>/GRAPH_REPORT.md
```

Read the god nodes and community structure. This gives you cross-repo architecture context before you start writing code.

If the graph is stale (user says things have changed significantly), offer:

```bash
bin/sgt-graphify <project>
```

### Step 5 — Confirm orientation

Tell the user:
- Which project is loaded
- How many repos, which are cloned
- Any constraints from agent_instructions that will affect the work
- Whether the knowledge graph is available

Example:

```
Project: smith (4 repos — 4 cloned)
Groups: backend (smith-api, smith-core), infra (smith-infra), frontend (smith-app)
Knowledge graph: available at ~/Dev/smith/graphify-out/

Active constraints:
- All Go services: run `go test ./...` before committing
- smith-infra: never delete PVCs without confirmation
```

---

## Error cases

| Situation | Action |
|---|---|
| Project YAML not found | Tell user. Offer to create one using schema/project.yaml.example as a template. |
| `yq` not installed | Tell user: `brew install yq` |
| All repos missing | Confirm URLs are configured, then offer `bin/sgt-sync <project>` |
| No graphify output | Note it, offer to run `bin/sgt-graphify <project>` if needed |
