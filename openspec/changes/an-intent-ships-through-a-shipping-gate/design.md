# Design — An intent ships through a shipping gate

## Ownership

One repository, `sergeant-v2`. Touches `internal/config/config.go`
(`Project`), `internal/store/store.go` (`IntentRecord`, a new pure
predicate, a new write method), `internal/runner/runner.go` (a new
sibling to `RunCodeGate`), and `internal/ui/server.go` (`handleCreatePR`).

## Config: `Project.ShippingGates`

```go
// ShippingGates are checks that run once every bullet of an intent has
// reached sealed (or merged), evaluating the intent as a whole rather than
// any single bullet. Same shape as FactoryConfig.Gates, but declared once
// per project: a shipping gate spans repos, so it cannot live on one repo's
// Factory the way a bullet gate does.
ShippingGates map[string]string `yaml:"shipping_gates,omitempty" json:"shipping_gates"`
```

Added to `Project` (`config.go:13`) alongside the existing `Graphify
*Graphify` field, same optional/pointer-free style since a `map` already
distinguishes "unset" (nil) from "declared empty" the same way the existing
`FactoryConfig.Gates` map does — no new pointer wrapper needed.

## Store: new fields and predicate

```go
// ShippingGateStatus is "", "passed", or "failed". Empty means the
// intent's bullets have not all reached sealed/merged yet, OR they have
// and no ShippingGates are configured for the project — in the latter
// case this proposal writes "passed" immediately (see handleCreatePR
// below), so a caller never has to distinguish "not evaluated" from
// "trivially passed" by reading config elsewhere.
ShippingGateStatus string `json:"shipping_gate_status,omitempty"`
// ShippingGateReason is set only when ShippingGateStatus is "failed",
// mirroring BulletRecord.BlockedReason's existing pattern exactly.
ShippingGateReason string `json:"shipping_gate_reason,omitempty"`
```

Added to `IntentRecord` (`store.go:88`).

```go
// AllBulletsSealedOrMerged reports whether every one of an intent's
// bullets has reached sealed or merged — the condition that makes the
// intent, as a whole, a candidate for its shipping gate. merged is
// accepted alongside sealed for BulletProgression's documented ordering
// (sealed -> merged), though as of this change nothing in the codebase
// ever writes "merged" to a bullet yet — no code path observes real PR
// merge state. Accepting it now costs nothing and avoids this predicate
// needing a second revision the day that path exists.
//
// The empty case is answered before the rule is applied, the same
// reasoning DeriveIntentStatus already uses: "every bullet is
// sealed-or-merged" is vacuously true for an empty set, which would
// trigger a shipping gate for an intent that has had no bullets created
// against it at all.
func AllBulletsSealedOrMerged(bullets []BulletRecord) bool {
	if len(bullets) == 0 {
		return false
	}
	for _, b := range bullets {
		if b.Status != "sealed" && b.Status != "merged" {
			return false
		}
	}
	return true
}
```

Placed in `store.go` immediately after `DeriveIntentStatus` (line ~1520).

```go
// RecordShippingGateResult records the outcome of an intent's shipping
// gate. Unlike AdvanceBulletsForRun, this never touches any BulletRecord —
// a shipping-gate failure is evidence about the intent, not a bullet
// outcome, and no individual bullet's honestly-earned sealed status
// changes because of it (PRD: "Out of scope — Per-bullet gate changes").
func (s *Store) RecordShippingGateResult(intentID string, passed bool, reason string) error {
	status := "passed"
	if !passed {
		status = "failed"
	} else {
		reason = "" // a pass never carries a reason, mirroring BlockedReason's rule
	}
	_, err := s.db.Exec(
		`UPDATE intents SET shipping_gate_status = ?, shipping_gate_reason = ? WHERE id = ?`,
		status, reason, intentID,
	)
	if err != nil {
		return err
	}
	return requireOneRow(sql.Result(nil), "intent", intentID) // illustrative; use the *sql.Result from Exec above, not a nil literal
}
```

(The `requireOneRow` call above is illustrative of intent, not literal Go —
implementation must pass the real `sql.Result` from `Exec`, matching every
other existing write method's error-handling shape in this file, e.g.
`UpdateBulletStatus`.)

A migration adds the `shipping_gate_status` and `shipping_gate_reason`
columns to the `intents` table, following this file's existing
`migrateAddColumns` idempotent-column pattern (used for `BlockedReason` and
other additive fields) rather than a numbered migration — consistent with
this project's stated approach: a reopened old database self-heals with no
separate migration step.

## Runner: `RunShippingGate`

```go
// RunShippingGate executes a shipping-gate command across an intent's
// bullets. Unlike RunCodeGate, it is not a *PhaseRunner method: a shipping
// gate evaluates an intent as a whole, which may span several
// repositories/worktrees, so there is no single pr.Worktree to run it in.
// The command runs with cmd.Dir unset (the sergeant process's own working
// directory) and SERGEANT_BULLET_WORKTREES set to the bullets' worktree
// paths, comma-joined in merge order, in its environment — the substrate a
// project's shipping-gate command needs to inspect more than one repo.
//
// It reuses GateResult rather than a new struct: the pass/fail, redaction,
// and timeout shape RunCodeGate already established is identical here: only
// where the command runs and what tells it where to look differ. Worktree
// is set to the same comma-joined list, so a shipping-gate result is
// auditable the same way RunCodeGate's comment already requires for a
// per-bullet gate.
func RunShippingGate(ctx context.Context, name, command string, worktrees []string) (*GateResult, error) {
	start := time.Now()
	gateCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	cmd := exec.CommandContext(gateCtx, "bash", "-c", command)
	superviseGroup(cmd)
	joined := strings.Join(worktrees, ",")
	cmd.Env = append(os.Environ(), "SERGEANT_BULLET_WORKTREES="+joined)

	var outBuf bytes.Buffer
	cmd.Stdout = &outBuf
	cmd.Stderr = &outBuf

	err := cmd.Run()
	_ = start // duration bookkeeping identical to RunCodeGate, omitted here for brevity

	cleaned := redact.Truncate(redact.Text(stripANSI(outBuf.String())), maxRawOutputBytes)
	passed := (err == nil)
	return &GateResult{
		GateName: name,
		Command:  redact.Text(command),
		Passed:   passed,
		Output:   cleaned,
		Worktree: joined,
	}, nil
}
```

`Branch` is left empty — a shipping gate spans potentially several
branches (one per bullet), and `GateResult.Branch` is documented as a
single value; inventing a comma-joined branch list adds a second place to
parse the same information `Worktree` already carries per-bullet order,
for no proven need.

## Trigger: `handleCreatePR`, after a successful seal

```go
// After the existing SealBulletForRun call succeeds (server.go:650):
intentID := /* the run's IntentID, already loaded to reach SealBulletForRun */
bullets, err := srv.Store.ListBulletsForIntent(intentID)
if err == nil && store.AllBulletsSealedOrMerged(bullets) {
	proj, _ := config.LoadProject(req.Project) // project already resolved earlier in this handler
	if len(proj.ShippingGates) == 0 {
		_ = srv.Store.RecordShippingGateResult(intentID, true, "")
	} else {
		worktrees := make([]string, len(bullets))
		for i, b := range bullets {
			worktrees[i] = b.Worktree
		}
		allPassed := true
		var firstFailureReason string
		for name, command := range proj.ShippingGates {
			res, _ := runner.RunShippingGate(r.Context(), name, command, worktrees)
			if res == nil || !res.Passed {
				allPassed = false
				if firstFailureReason == "" {
					firstFailureReason = fmt.Sprintf("shipping gate %q failed", name)
				}
			}
		}
		_ = srv.Store.RecordShippingGateResult(intentID, allPassed, firstFailureReason)
	}
}
```

This runs synchronously inside the existing `POST /api/create-pr` request
that completed the last seal. It does not gate or delay the PR-creation
response that already happened (the seal itself, and the PR action, are
unaffected by shipping-gate outcome — PRD: "does not fail any individual
bullet," "does not prevent an operator... from proceeding manually").
Whether the request handler waits for shipping-gate commands to finish
before responding, or kicks them off and responds immediately, is an
implementation detail for the task that builds this — not a product
requirement this design needs to settle, since either is externally
observable only through `IntentRecord.ShippingGateStatus`, not through
`POST /api/create-pr`'s own response shape (unchanged by this proposal).

## Rejected alternatives

**A new endpoint, `GET /api/intents/{id}/shipping-gate`.** Rejected:
`ShippingGateStatus`/`ShippingGateReason` are ordinary `IntentRecord`
fields; wherever an intent is already serialized to JSON, they are present
for free. A dedicated endpoint would duplicate data already reachable, for
no proven need — the same reasoning that kept `a-sealed-bullet-awaits-
explicit-approval` from inventing a notification mechanism beyond making
state inspectable.

**Failing individual bullets when the shipping gate fails.** Rejected by
the PRD explicitly. A bullet's `sealed` status is a fact about that one
bullet's own, already-passed gates and human approval (D3, D5(c) as it
exists today) — a cross-cutting shipping-gate failure is a fact about the
intent, not a retroactive claim that any one bullet's own evidence was
wrong.

**Running shipping gates from an arbitrary "primary" bullet's worktree**
(e.g. the first in merge order) instead of an unset `cmd.Dir` with an env
var. Rejected: there is no principled reason one bullet's repo is more
authoritative than another's for a cross-repo check, and picking one
arbitrarily would tempt a shipping-gate command to assume file paths
relative to that one repo, which breaks the moment the "primary" repo's
identity changes across projects.

**A new `ShippingGateResult` struct distinct from `GateResult`.** Rejected:
the pass/fail/output/redaction/timeout shape is identical; the only
difference (multiple worktrees instead of one) fits inside the existing
`Worktree string` field as a comma-joined list without changing its type.

**Re-deriving "all sealed" every time any bullet or intent is read, instead
of storing a status.** Considered: `AllBulletsSealedOrMerged` is cheap and
could be called on every read instead of persisting a result. Rejected
because the shipping gate's *outcome* (pass/fail and why) is not cheaply
re-derivable — it is the result of running real commands — so it must be
stored regardless; once it must be stored, storing the status/reason on
`IntentRecord` directly (rather than storing the outcome separately and
re-deriving "should I run it" separately) keeps one place to look, matching
`BulletRecord.BlockedReason`'s existing precedent.
