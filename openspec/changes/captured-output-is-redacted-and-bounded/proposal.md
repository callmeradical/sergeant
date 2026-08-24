# Proposal — Captured output is redacted and bounded

## Repository

One repository: `sergeant-v2`.

## Requirements served

**R4.4**: "Logs, records, responses, and notifications must not retain
credentials, tokens, environment dumps, or unrelated secrets. Product design
must define redaction and retention before production release."

**R4.5** (partial — see scope below): "The product must distinguish
operational metadata from request/brief content and retain only the minimum
content needed to reproduce or audit a run."

## Problem

`internal/runner.go`'s `RunAgentPhase` (line 456) and `RunCodeGate` (line
245) both capture an agent's or gate command's combined stdout/stderr,
strip ANSI escapes (`stripANSI`, R4.3, already done), and write the result
verbatim as `raw_output` into a phase/envelope payload — which becomes both
`PhaseRecord.Payload` and `EnvelopeRecord.Data`. `GET /api/run-details`
returns these records in full, unfiltered. A real run's response is already
several KB; a verbose agent session can be much larger.

Nothing between capture and storage inspects this content. Both
`internal/runner.go` and `internal/dag/engine.go` invoke agent/gate
subprocesses with `cmd.Env = append(os.Environ(), ...)` — the dispatched
process inherits the full parent environment. An agent with shell access
that runs `env`, `git remote -v` against an HTTPS remote with an embedded
token, or `cat`s a `.env` file — all plausible, legitimate-looking actions
for a coding agent to take — puts that content straight into `raw_output`
with nothing to catch it. Grepping the codebase for any existing
redaction/secret-scrubbing logic returns zero hits.

(The dashboard's SSE stream, `internal/ui/stream.go`, was checked and is
**not** a leak path — `recordTransition` broadcasts only a small summary,
never the payload/data blob. An earlier session's flag that "the SSE
snapshot ships full agent briefs" no longer matches the current code; `GET
/api/run-details` is the real surface.)

## Proposal

Add a redaction pass, applied to `raw_output` at the point both call sites
already have it in memory — before it is placed into any payload map, not
after, and not at a read boundary. A pattern-based scrubber
(`internal/redact`) recognizes common secret shapes (provider API key
prefixes — `sk-`, `ghp_`, `AKIA`, etc. — `Authorization: Bearer <token>`
headers, and generic `KEY=value`-shaped lines whose key name looks
credential-related) and replaces the matched span with a fixed placeholder,
leaving the surrounding output otherwise intact and readable.

Also cap `raw_output`'s size at write time (a fixed byte limit, output
truncated with a marker naming how much was cut) — the minimum-content half
of R4.5 that this bullet can honestly deliver: bounding what is retained,
not restructuring the payload schema.

## Out of scope

- **Restricting subprocess environment inheritance** (`cmd.Env =
  append(os.Environ(), ...)` in `internal/runner.go` and
  `internal/dag/engine.go`, replacing it with an explicit allowlist). This
  closes the vector at its source rather than scrubbing its output and is
  the more complete fix for R4.4, but it is a materially larger, riskier
  change — an agent could legitimately need `PATH`, `HOME`, `LANG`, or other
  inherited variables sergeant does not currently enumerate, and getting the
  allowlist wrong silently breaks agent dispatch rather than merely under-
  redacting. Deserves its own design pass, not a rider on this bullet.
- **A full operational-metadata-vs-content schema split for R4.5.** The
  payload map already separates several operational fields (`agent`,
  `attempt`, `worktree`, `branch`, `model`, `provider` — the last two added
  by R4.6 this session) from `raw_output`; a formal `Metadata`/`Content`
  envelope split is a larger, structural change R4.5's text does not by
  itself demand this bullet solve completely. This bullet's size cap is the
  "minimum content" half delivered now; the structural split is future
  scope if a later requirement needs it.
- **A configurable retention/deletion policy** (e.g. "delete raw_output
  after N days"). R4.4 asks for a design decision on retention before
  production release; this bullet defines redaction now and leaves
  retention-period policy for that later decision.
- **Retroactively redacting or truncating existing rows.** This bullet
  changes what gets written going forward; it does not touch historical
  `PhaseRecord`/`EnvelopeRecord` rows already in the store.
- Detecting every possible secret shape. Pattern matching is inherently
  heuristic; this bullet closes the common, high-confidence cases, not a
  guarantee that no secret can ever appear in captured output.
