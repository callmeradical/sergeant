# Skill: cross-repo-work

Plan and execute a task that spans multiple repositories in a project.

---

## When to use

Load this skill when:
- A feature, fix, or change requires touching more than one repo
- The user asks for something that sounds cross-cutting ("add OAuth", "update the API contract", "deploy this change")
- You've loaded project context and determined multiple repos are affected

Prerequisite: **load-project** skill must already be complete.

---

## Protocol

### Step 1 — Identify affected repos

From the project context, determine which repos the change touches. Use the knowledge graph if available:

```bash
graphify query "<the task description>" --output <graphify_output>
```

Or reason from the context block: which repos own the code paths involved?

State your conclusion:

```
Affected repos:
- smith-api (add OAuth endpoints)
- smith-app (add login UI)
- smith-infra (add OAuth secret to values)
```

### Step 2 — Identify dependency order

Determine which repos must change first. Common patterns:

- **Contract-first**: the API or schema repo changes first; consumers follow
- **Infrastructure-first**: credentials/config land in infra before app code that reads them
- **Parallel**: UI and backend can be developed concurrently if the contract is agreed upfront

State the order explicitly:

```
Order:
1. smith-infra (secret first — needed by API at runtime)
2. smith-api (endpoints — depends on secret)
3. smith-app (UI — depends on API endpoints being defined)
```

Ask the user to confirm the order if non-obvious or if it has deployment implications.

### Step 3 — Check branch hygiene

For each affected repo, confirm current state:

```bash
bin/sgt-status <project>
```

Flag anything unusual:
- Repos on non-main branches (ask: is that intentional?)
- Uncommitted changes (ask: should those be stashed?)
- Behind upstream (offer: pull first?)

Per the mandatory AGENTS.md convention: **never work directly on main**. Plan a branch for each affected repo.

Proposed branch name convention: `<type>/<short-description>`
- e.g., `feat/add-oauth` across all three repos (same name keeps cross-repo PRs easy to correlate)

### Step 4 — Plan the work

Write a per-repo task breakdown before touching any file:

```
smith-infra / feat/add-oauth:
  - Add google_client_secret to values/production.yaml (sealed)
  - Update Helm chart to mount secret as env var GOOGLE_CLIENT_SECRET

smith-api / feat/add-oauth:
  - Add POST /auth/google endpoint in pkg/handlers/auth.go
  - Wire OAuth2 exchange using GOOGLE_CLIENT_SECRET env var
  - Add integration test in pkg/handlers/auth_test.go

smith-app / feat/add-oauth:
  - Add "Continue with Google" button to src/routes/login/+page.svelte
  - Wire to POST /auth/google
  - Add E2E test
```

Show this plan to the user and get confirmation before writing code.

### Step 5 — Execute in dependency order

Work through each repo in the order established in Step 2. For each:

1. Create the branch: `git -C <path> checkout -b <branch>`
2. Do the work, following that repo's `agent_instructions`
3. Run the repo's tests/lint (from its agent_instructions)
4. Commit: `git -C <path> add -A && git -C <path> commit -m "<message>"`
5. Push: `git -C <path> push -u origin <branch>`
6. Open a PR (use `gh pr create` from that repo's directory)

Do not move to the next repo until the current one has a clean commit.

### Step 6 — Report outcomes

When all repos are done, emit a summary:

```
Cross-repo work complete: feat/add-oauth

PRs:
- smith-infra: https://github.com/myorg/smith-infra/pull/42
- smith-api:   https://github.com/myorg/smith-api/pull/88
- smith-app:   https://github.com/myorg/smith-app/pull/31

Merge order: smith-infra → smith-api → smith-app
Note: merge smith-infra and deploy to staging before merging smith-api
      (API reads GOOGLE_CLIENT_SECRET at startup).
```

---

## Rules

- **Never commit to main.** One feature branch per repo per cross-repo task.
- **Follow repo agent_instructions** at every step. Those constraints exist for a reason.
- **Surface cross-repo implications.** If smith-api's response shape changed, flag it to smith-app. If infra added a required env var, flag it to every service that needs it.
- **Confirm destructive or risky changes.** Infra changes especially — ask before touching production values.
- **Don't skip repos.** If a repo in the dependency chain isn't cloned, stop and sort that out before continuing.
