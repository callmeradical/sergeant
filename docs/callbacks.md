# Durable Callback Protocol

Sergeant callback protocol v1 gives an external request a durable return path
that does not depend on a coordinator pane, OpenCode API session, or model turn.
It is generic: callback profile names select trusted local executables, while the
consumer decides how to deliver an event to its fixed destination.

## Configure A Profile

Install each callback executable as
`~/.config/sergeant/callbacks/<profile>`. Profile names must match
`^[a-z][a-z0-9-]{0,31}$`. The callbacks directory and executable must be real
(not symlinks), owned by the Sergeant user, and not group/world writable. The
executable must have its owner execute bit set. Sergeant never accepts an
executable path from fleet state.

For tests or an isolated service account, `SERGEANT_CALLBACKS` may select a
different fixed callbacks directory. Treat that environment setting as trusted
local configuration, not request input.

## Register An Origin

Dispatch can atomically bind one origin to the new fleet task:

```bash
sgt-dispatch hermes-bridge --td td-123abc \
  --origin-profile hermes-discord \
  --correlation-id req-7f91b230
```

Both flags are required together. A correlation ID must match
`^[a-z][a-z0-9._-]{7,127}$` and must not contain a 17-20 digit platform ID.
Use a new opaque request ID, never a Discord guild/channel/user/message ID.

An existing task can be bound directly before events are produced:

```bash
sgt-callback register <fleet-task-id> <profile> <correlation-id>
```

Registration writes only `.callbacks/origin.json` under the fleet task:

```json
{"correlation_id":"req-7f91b230","profile":"hermes-discord","version":"sergeant.callback-origin/v1"}
```

It never stores request text, Discord IDs, destination IDs, tokens, secrets,
message content, callback commands, or logs. Repeating the same registration is
idempotent; changing an existing registration is rejected.

Tasks with no origin retain the existing Sergeant notification behavior.
`sgt-callback sync` is a no-op and no callback state is created for them.

## Produce Events

`sgt-notify` and `sgt-watch --sync` automatically call `sgt-callback sync`.
The synchronizer reads authoritative worktree/fleet state and creates only these
classified events:

| Sergeant state | Callback `type` | Payload source |
|---|---|---|
| `needs_input` | `needs_input` | `.sergeant-message` |
| `blocked` | `blocked` | `.sergeant-message` |
| `failed: <reason>` | `failed` | terminal reason |
| `done` with result | `done` | `.sergeant-result` |

Waiting-event identity includes the repository, class, and
`.sergeant-gate-generation`. Terminal identity includes the repository and
terminal class. Repeated synchronization of the same source creates no new
generation.

A coordinator can enqueue a pre-worker or follow-up decision directly. Payload
is read only from standard input:

```bash
printf '%s\n' 'Choose option A or B.' | \
  sgt-callback enqueue <fleet-task-id> needs_input coordinator-followup-1
```

The source ID must match `^[a-z][a-z0-9._:-]{0,127}$`; it is hashed before
persistence. Reusing the same event class/source ID returns the original event
and generation.

Payloads must be nonempty UTF-8, at most 4096 bytes and 16 lines, and contain no
NUL/control data other than tab/newline. Sergeant rejects shell command
metacharacters, command-like lines, secret-shaped assignments, and 17-20 digit
platform IDs. A producer must still supply only concise status, a decision
question/options, or completion evidence. Request/user message text, logs,
diffs, private IDs, credentials, and arbitrary commands are outside this
contract.

## Consumer Input

Each generation is retained at
`.callbacks/events/<8-digit-generation>/event.json`. Sergeant invokes the fixed
profile with no arguments, a minimal environment (`HOME`, `PATH`, locale, and
temporary-directory variables only), stderr discarded, and exactly one compact
UTF-8 JSON object on stdin:

```json
{"correlation_id":"req-7f91b230","created_at":"2026-07-27T12:00:00Z","generation":1,"idempotency_key":"sgt-callback-v1:req-7f91b230:1","payload":"Choose option A or B.","profile":"hermes-discord","source_hash":"<lowercase sha256>","type":"needs_input","version":"sergeant.callback-event/v1"}
```

The fields are exact:

| Field | Contract |
|---|---|
| `version` | `sergeant.callback-event/v1` |
| `correlation_id` | Registered opaque ID |
| `profile` | Registered fixed profile |
| `generation` | Positive task-local monotonic integer |
| `idempotency_key` | `sgt-callback-v1:<correlation_id>:<generation>` |
| `type` | `needs_input`, `blocked`, `failed`, or `done` |
| `payload` | Validated bounded status text |
| `source_hash` | Lowercase SHA-256 of the internal class/source identity |
| `created_at` | UTC RFC 3339 timestamp |

The consumer must durably deduplicate by `idempotency_key` before creating a
user-visible message. This is required because a crash after external delivery
but before acknowledgement causes an intentional retry.

## Consumer Acknowledgement

The executable has 15 seconds by default (`SGT_CALLBACK_TIMEOUT_SECONDS`, range
1-120) and may write at most 1024 bytes to stdout. It returns exit code zero and
one of these JSON objects:

```json
{"idempotency_key":"sgt-callback-v1:req-7f91b230:1","status":"ack","version":"sergeant.callback-ack/v1"}
{"idempotency_key":"sgt-callback-v1:req-7f91b230:1","retry_after_seconds":30,"status":"retry","version":"sergeant.callback-ack/v1"}
{"idempotency_key":"sgt-callback-v1:req-7f91b230:1","status":"reject","version":"sergeant.callback-ack/v1"}
```

`ack` durably suppresses all later callback attempts for that generation.
`retry` keeps the event pending; `retry_after_seconds` is optional and bounded
to 0-3600. `reject` records a permanent policy failure without deleting the
event or retrying it automatically. Any timeout, nonzero exit, malformed JSON,
wrong version/key, unknown field/status, or oversized output remains pending.
Consumer stderr and output details are never persisted.

## Retry And Recovery

State lives beside each event in `state.json` with version
`sergeant.callback-state/v1`, status (`pending`, `delivering`, `acknowledged`, or
`rejected`), attempt count, next-attempt epoch, claim time, acknowledgement time,
and a fixed result class only. The event is claimed before invocation. A stale
`delivering` claim becomes eligible after 60 seconds by default. Failed attempts
use exponential backoff (5 seconds through 300 seconds by default), and each
drain processes a bounded number of distinct events.

Run a task drain or a session-independent periodic drain with:

```bash
sgt-callback drain <fleet-task-id>
sgt-callback drain --all
```

After repairing a permanent consumer policy/configuration failure, an operator
can requeue the retained event without changing its idempotency key:

```bash
sgt-callback retry <fleet-task-id> <idempotency-key>
```

These commands need no coordinator or worker session. Automatic producers make
one bounded delivery attempt and return without waiting indefinitely. Events
survive callback/process restarts. `sgt-cleanup` synchronizes origin tasks and
refuses full fleet deletion until this command succeeds:

```bash
sgt-callback check-acked <fleet-task-id>
```

Rejected events are intentionally unacknowledged and therefore also block
cleanup until an operator repairs the consumer and runs `sgt-callback retry`.
Immediately before fleet deletion, `sgt-cleanup` takes the callback lock,
verifies the same condition again, and writes a terminal seal. The seal rejects
new event generations and closes the acknowledgement-check/deletion race. If
cleanup fails after sealing and the fleet must resume, remove only that
supported gate with:

```bash
sgt-callback unseal <fleet-task-id>
```

## ws-lab Consumer Handoff

The ws-lab `hermes-discord` consumer must implement the stdin and stdout schemas
above. It should forward the unchanged event through its source-bound forced
transport, deduplicate durably by `idempotency_key`, map only the four event
classes to bounded Discord text, and return `ack` only after the fixed approved
destination confirms delivery. It must never accept destination IDs or commands
from any event field. Discord and Doppler credentials remain exclusively on the
Hermes host and must not appear in the callback executable environment, stdout,
stderr, or Sergeant fleet state.
