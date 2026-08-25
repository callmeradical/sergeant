# Design — v2-native skills and docs

## Ownership

One repository, `sergeant-v2`. Touches only prose/config files (five
`skills/*/SKILL.md`, one `.agents/skills/*/SKILL.md`, two `docs`/`schema`
files) and `tests/instruction-policy-test.sh`. No Go code changes.

## Baseline: what `instruction-policy-test.sh` requires today, and what stays true

Running it now produces exactly 15 failures, all `AGENTS.md`-related
(`## Procedural skills`, `.sergeant-intent.md`, `td context <id> --work-dir
<owning-repo-path>`, etc. — none about the eight files this change touches).
Every `require_text`/`reject_text` line naming one of this change's eight
files currently **passes**, because the files currently still carry the v1
content those lines check for. This change replaces that content, so those
specific lines must change in lockstep or they will newly fail. The 15
pre-existing `AGENTS.md` failures are untouched and must still number
exactly 15 after this change — a smaller number would mean this change
accidentally touched `AGENTS.md` (out of scope); a larger number would mean
a regression.

## `skills/dispatch/SKILL.md`

Remove the banner (lines 1-12):
```
> **V1 ONLY — DO NOT FOLLOW ON THE `v2` BRANCH.**
> ...
```

Replace each v1 procedure with its v2 equivalent:

| v1 (removed) | v2 (replacement) |
|---|---|
| `sgt-dispatch <project> --td <task-id>` / `sgt-dispatch <project> "<brief>" --repos ... --branch ... --deps ...` | `POST /api/dispatch` with JSON body `{"project", "brief", "repos", "agent", "type", "change_id", "request_id"}` (`internal/ui/server.go` `handleDispatch`). `type` is O2's fixed vocabulary (`feat`/`fix`/`refactor`/`docs`/`chore`/`test`); `change_id` resolves to an OpenSpec change per O3, scaffolded from the brief if omitted. `request_id` is the idempotency key (D10) — a repeat returns the original run, not a duplicate. |
| `bin/sgt-watch <task-id>` polling `.sergeant-status`/`.sergeant-message`/`.sergeant-result` | `GET /api/runs?project=<name>` for the list, `GET /api/run-details?id=<run-id>` for phase-level detail (`handleRuns`, `handleRunDetails`). No file sync — status is read directly from the store (truthfulness rule, `AGENTS.md`). |
| `sgt-respond <task-id> <repo> "<response>"` + tmux pane nudge | No structured response-message channel exists in v2. Resolve the underlying cause directly (in the bullet's worktree, under `~/.local/share/sergeant-v2/fleet/<run-id>/<repo>/`, or by fixing the OpenSpec change/spec mismatch a review finding named), then `POST /api/run-resume {"id": "<run-id>"}` (`handleRunResume`) — this is v2's actual, coarser equivalent: it resumes a `failed`/`blocked` run, skipping phases already recorded `passed`. |
| `tmux attach -t sgt-<task-id>` | No v2 equivalent — v2 has no persistent interactive pane to attach to; a dispatched agent phase runs headlessly to completion or a bounded timeout (`RunAgentPhase`). |
| Treehouse pool section (`sgt-treehouse-init`, `treehouse get --lease`, `treehouse return`) | Removed outright. D7 forbids tmux; v2's worktree isolation (`internal/dag/engine.go`, plain `git worktree add`) has no pooling concept and needs none — each run's worktrees are cleaned up by the existing fleet-cleanup mechanism (`internal/ui/fleet.go`). |
| `--deps "a>b,a>c"` dependency flag | No flag equivalent. Cross-bullet merge order is a property of the Intent itself (D6: "Sergeant releases a bullet's PR only once its upstream bullets are reviewed and merged"), set when the intent's bullets were decomposed (D2), not stated per-dispatch. |
| Worker contract steps referencing `.sergeant-brief.md`, `.sergeant-message`, `.sergeant-response`, `td start`/`td log`/`td handoff`/`td review`, `sgt-no-mistakes-finding`, `sgt-review-findings`, `bin/_sgt-review-axes.sh` | Replaced with: a dispatched agent receives its brief via `sergeant_get_brief` (MCP) or the rendered prompt `Store.RenderIntentBrief` builds into the phase (both call the same function, dispatch-briefs-render-from-the-stored-intent); reports findings via envelope payload (`internal/handoff`), read by the review phase (`a-green-bullet-awaits-independent-review`) if one is configured; a blocking finding transitions the bullet to `blocked`, resolved as described above. Task tracking is out of scope for a dispatched agent to create or mutate (D4) — see task-tracking-is-a-readonly-export. |
| "td task creation" section (`sgt-dispatch` auto-creating td tasks, `sgt-td-create`) | Removed; replaced with a note that v2 records no task in an external tracker as part of dispatch — Intent/Bullet rows in Sergeant's own store are the durable record (D4), and export (if configured) is read-only. |
| Flags reference table | Replaced with the `POST /api/dispatch` JSON body fields table above. |
| Troubleshooting table (tmux/worktree/fleet-state entries) | Replaced: "Worker stuck" → check `GET /api/run-details?id=` for the stalled phase; "Need to recover a waiting/orphaned worker" → `POST /api/run-resume`; "Need to retry a failed repo" → fix the cause, then `POST /api/run-resume`. |

## `skills/cross-repo-work/SKILL.md`

Remove the banner. Replace `sgt-context <project>` (repo ownership lookup)
with reading the project YAML directly (`~/.config/sergeant/<name>.yaml`,
`internal/config.LoadProject`) or `GET /api/project-details`. Replace
"`prerequisite>dependent` notation accepted by `sgt-dispatch`" with: state
merge order directly as the bullet order within the intent (D6), since
there is no per-dispatch flag for it (see dispatch table above). Replace
`sgt-status <project>` (repo state inspection) with plain `git status`/
`git worktree list` in each repo's own path from the project YAML — v2
has no fleet-wide multi-repo status command. Replace "load `dispatch` and
execute through `sgt-dispatch`" with "load `dispatch` and execute through
`POST /api/dispatch`" (one dispatch per repo/bullet, each is its own
call). The five-step reconciliation procedure (PR URLs, CI, review threads,
merge order, terminal state) is kept as-is — none of it names a v1 command;
"terminal td/fleet state" becomes "terminal run/bullet status via
`GET /api/bullets?run_id=`".

## `skills/load-project/SKILL.md`

Remove the banner. Replace `sgt-list`/`bin/sgt-list` (list registered
projects) with: list `~/.config/sergeant/*.yaml` or `GET /api/projects`.
Replace `sgt-context <project>`/`bin/sgt-context <project>` with
`GET /api/project-details?name=<project>` or reading the project YAML
directly via `internal/config.LoadProject`. Replace `sgt-sync <project>`
(clone missing repos) — no v2 equivalent; v2 does not clone repositories on
an operator's behalf, so this step becomes: stop and report which
repository path from the project YAML does not exist, matching v2's actual
`prepareWorktree` refusal behavior (`internal/dag/engine.go`) for a
non-existent or non-git path. Replace `sgt-graphify <project>`/
`bin/sgt-graphify <project>` with the v2-native graphify build path
(`internal/graphify.BuildProjectGraph`, exposed via `POST /api/build-graph`
and the `graphify_query`/`graphify_affected`/`graphify_explain` MCP tools
per D9) — the graph is a v2 capability now, not a shelled-out `sgt-graphify`
call. Keep the project-registration and Graphify-usage procedures
structurally as-is (steps still make sense), only replacing the specific
commands named. `docs/schema.md` remains the schema source of truth
(unchanged reference).

## `skills/wiki/SKILL.md`

Remove the banner. `wiki-daily-digest` itself is unchanged (explicitly kept
on `v2` during the v1-removal work) — this file needs a narrower edit than
the other four: only the "Automatic captures" table's three rows
(`sgt-dispatch`, `sgt-notify`, `sgt-cleanup` as capture-owning commands) are
removed, since none of those commands exist on v2 and v2 has no equivalent
automatic-capture mechanism today — stated as a gap, not replaced with an
invented v2 command. Everything else (storage ownership, daily-digest
procedure, scheduled execution, failure behavior) names no v1 command and
is unchanged.

## `skills/sergeant-help/SKILL.md`

Remove the banner. The documentation map table's rows are unaffected (they
name doc files, not commands) except: add a note that v2's command
reference is now `POST /api/*` routes and MCP tools, not `bin/sgt-*` — the
"For flag or argument questions, run `--help`" step becomes N/A for v2 (an
HTTP API has no `--help`; the reference is the route/body-field table this
change adds to `skills/dispatch/SKILL.md`, cited from here). The precedence
list's "command behavior, tests, and supported `--help` output" becomes
"route/handler behavior and its tests (`internal/ui/server_test.go` and
friends)".

## `.agents/skills/to-tickets/SKILL.md`

No banner exists on this file today (it is not one of the five). Replace:
`sgt-list`/`sgt-context` (step 1, load project context) → same replacement
as `load-project` above. `sgt-td-list <project> --all --json` (dedup check)
→ v2 has no task list to dedup against beyond its own Intent/Bullet store;
replace with: check `GET /api/runs?project=<name>` for existing open
intents targeting the same outcome. `sgt-td-create <project> ...` (manual
task creation) and every `td create`/`td update`/`td close` call in "Publish
to td" and "Validate the Graph" → **explicit gap, not replaced**: v2's
task-tracking is read-only export (D4, task-tracking-is-a-readonly-export);
this skill cannot create, update, or close tasks in an external tracker on
v2. The section is rewritten to say this plainly and stop, per the PRD's
explicit instruction not to invent a v2 command that doesn't exist. `sgt-
dispatch <project> --td <ticket-id>` (final dispatch command) → `POST /api/
dispatch` with `change_id` set to the ticket's corresponding OpenSpec change
id (O3) instead of a td ticket id, since dispatch resolves to an OpenSpec
change on v2, not a td ticket.

## `docs/troubleshooting.md`

Remove entirely (no v2 relevance): "Bash 3.2 validation" section (the
Docker/`tests/runtime-bash-test.sh` suite — that file no longer exists),
"Pane is missing" (tmux-specific), "Worker became orphaned after blocking"
in its current fleet-file form, "Response already pending", "Cleanup
refuses or state is partial" and its two sub-sections (fleet-file
retirement protocol), "`sgt-cleanup` reports... same filesystem" (that
constraint is v1-specific to `bin/sgt-cleanup`'s atomic-rename
implementation, which doesn't exist on v2).

Rewrite with v2 answers: "Command not found" → N/A, replaced with "API
unreachable" (check `sergeant ui` is running, `curl http://127.0.0.1:8484/
api/runs`). "Project is missing or wrong" → `GET /api/projects` /
`~/.config/sergeant/*.yaml`, same as `load-project`. "Repository is missing
or behind" → plain `git status`/`git fetch` in the repo path from project
YAML (no `sgt-sync`). "Wrong `td` executable" section — remove; v2 has no
`td` dependency at all (only the read-only export path does, and only if
configured). "Worker says in_progress but not moving" → check `GET /api/
run-details?id=` for the stalled phase's `duration_ms` and whether the
worktree under the fleet dir has recent file-modification activity, rather
than tmux pane_activity. "GitHub account cannot access a repo" — unchanged,
names no v1 command. "Graphify output is wrong or recursive" → replace
`sgt-context`/regeneration guidance with `POST /api/build-graph` and the
`Project.Graphify` config block (D9). "Where to inspect state" table →
replace fleet-file paths with: project registry (`~/.config/sergeant/`,
unchanged), run/bullet/intent state (`~/.local/share/sergeant/sergeant.db`,
queryable via the API or `sqlite3` directly), worktree (`~/.local/share/
sergeant-v2/fleet/<run-id>/<repo>/`).

## `schema/project.yaml.example`

Remove three comment lines: `# Repo names used by sgt-graphify must match...`
→ becomes `# Repo names used by Graphify must match...` (the constraint
itself is still real — `internal/graphify` — only the command name in the
comment is stale). `# Optional: git remote, used by sgt-sync to clone if
path doesn't exist.` → becomes `# Optional: git remote. v2 does not clone
this automatically; the path must already exist.` (matches the `load-
project` gap noted above — do not imply an auto-clone capability v2 lacks).
`# Run with: sgt-dag-run <project>` / `# sgt-watch auto-advances the DAG...`
→ becomes a note that `dag:` stages are read by `internal/dag.Engine`
directly as part of a dispatch's own execution, not a separate `sgt-dag-run`
command — there is no standalone DAG-trigger command on v2 today; a DAG
stage runs as part of whatever dispatch names it.

## `tests/instruction-policy-test.sh`

Exact line changes:

Remove (content deleted, no longer applicable):
```
reject_text "skills/cross-repo-work/SKILL.md" 'git -C <path> checkout -b'
reject_text "skills/cross-repo-work/SKILL.md" 'git -C <path> push -u origin'
reject_text "skills/cross-repo-work/SKILL.md" 'gh pr create'
reject_text "skills/dispatch/SKILL.md" "Ask for confirmation before dispatching."
reject_text "skills/dispatch/SKILL.md" "remain alive, and wait"
reject_text "skills/dispatch/SKILL.md" 'treehouse return <path> --force'
require_text "skills/dispatch/SKILL.md" 'sgt-watch --sync <task-id>'
require_text "skills/dispatch/SKILL.md" '--intent-file <path>'
require_text "skills/dispatch/SKILL.md" "standard-isolated"
require_text "skills/dispatch/SKILL.md" "auth, OAuth, security, secret, credential, payment, database, migration, stateful, production, destructive"
require_text "skills/dispatch/SKILL.md" "mutation before validation"
require_text "skills/dispatch/SKILL.md" "After two remediation cycles"
require_text "skills/cross-repo-work/SKILL.md" "If the user requested planning only"
reject_text "docs/troubleshooting.md" "follow no-mistakes policy"
require_text "docs/troubleshooting.md" "Do not authorize an in-run fix"
require_text "docs/troubleshooting.md" 'sgt-watch --sync <task-id>'
require_text "docs/troubleshooting.md" "tests/runtime-bash-test.sh"
require_text "docs/troubleshooting.md" "docker.io/library/bash:3.2@sha256:3a13e5da38baa575985778cd09ce8ac736d4b4dafc91a430e71271f6e5311b89"
reject_text "docs/troubleshooting.md" 'Use `sgt-watch <task>`'
```
(all of these check for v1-specific text this change removes or replaces;
`skills/cross-repo-work/SKILL.md`'s "If the user requested planning only"
line is kept verbatim in the rewrite, so its `require_text` line is kept
too, unchanged)

Add, matching the new content:
```
reject_text "skills/dispatch/SKILL.md" "sgt-dispatch"
reject_text "skills/dispatch/SKILL.md" "sgt-watch"
reject_text "skills/dispatch/SKILL.md" "sgt-respond"
reject_text "skills/dispatch/SKILL.md" "treehouse"
require_text "skills/dispatch/SKILL.md" "POST /api/dispatch"
require_text "skills/dispatch/SKILL.md" "POST /api/run-resume"
reject_text "skills/cross-repo-work/SKILL.md" "sgt-context"
reject_text "skills/cross-repo-work/SKILL.md" "sgt-status"
reject_text "skills/cross-repo-work/SKILL.md" "sgt-dispatch"
reject_text "skills/load-project/SKILL.md" "sgt-list"
reject_text "skills/load-project/SKILL.md" "sgt-context"
reject_text "skills/load-project/SKILL.md" "sgt-sync"
reject_text "skills/load-project/SKILL.md" "sgt-graphify"
reject_text "skills/wiki/SKILL.md" "sgt-dispatch"
reject_text "skills/wiki/SKILL.md" "sgt-notify"
reject_text "skills/wiki/SKILL.md" "sgt-cleanup"
reject_text ".agents/skills/to-tickets/SKILL.md" "sgt-td-create"
reject_text ".agents/skills/to-tickets/SKILL.md" "sgt-list"
reject_text ".agents/skills/to-tickets/SKILL.md" "sgt-context"
require_text ".agents/skills/to-tickets/SKILL.md" "read-only export"
reject_text "docs/troubleshooting.md" "sgt-cleanup"
reject_text "docs/troubleshooting.md" "sgt-sync"
reject_text "schema/project.yaml.example" "sgt-graphify"
reject_text "schema/project.yaml.example" "sgt-sync"
reject_text "schema/project.yaml.example" "sgt-dag-run"
reject_text "schema/project.yaml.example" "sgt-watch"
```
(the implementer's exact wording in the rewritten files must satisfy these;
if a rewrite phrases something so a `require_text` string doesn't match
verbatim, adjust the rewrite's wording to match, not the assertion, unless
the assertion itself is imprecise — the assertions above are illustrative
of intent, not necessarily the final exact strings, which tasks.md's
verification step confirms by running the test after both are written)

## Rejected alternatives

**Delete these skill files instead of rewriting them**, matching what the
v1-removal work did to `.agents/skills/sergeant-setup/SKILL.md`. Rejected:
`sergeant-setup` was a one-time bootstrap/install concern that `AGENTS.md`'s
policy content adequately replaces on its own. Dispatch, cross-repo work,
project loading, wiki maintenance, and help are recurring, day-to-day
procedures a v2 operator or agent genuinely needs walked through — deleting
them leaves a real gap `AGENTS.md` alone does not fill (it states policy,
not step-by-step procedure). The five-file "V1 ONLY" banner pattern was
consistent between these and `sergeant-setup`, but the right response to
that pattern differs by what the file is *for*, not by the pattern alone.

**Leave `.agents/skills/to-tickets/SKILL.md`'s task-creation commands as
v1-flavored placeholders** (e.g., leaving `sgt-td-create` in place with a
comment saying "v1 only"), rather than an explicit stated gap. Rejected:
a placeholder that still names a real-looking command invites exactly the
failure mode this whole PRD exists to close — someone or something running
it and hitting "command not found" with no context. Stating plainly that
v2 has no writable task-tracker integration (D4) is more useful and
strictly more honest than a dead command reference, even one labeled
stale.

**Rewrite `tests/instruction-policy-test.sh`'s `AGENTS.md`-related failures
too, while already in this file.** Rejected: those 15 failures are
confirmed pre-existing and unrelated (parent session verified via `git
stash` comparison against the original `v2` HEAD before any of this
session's work). Fixing them requires rewriting `AGENTS.md` content this
PRD explicitly puts out of scope; bundling that in here would make this
change's diff much larger than its own stated purpose and mix two unrelated
concerns into one review.
