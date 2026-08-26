# Proposal — Envelopes are typed, versioned and correlated

## Repository

One repository: `sergeant-v2`.

## Requirements and decisions served

Bullet 1 of 4 against **R5 — notification/envelope transport**, the largest
unmet block in the PRD. This bullet covers:

- **R5.1** — typed, versioned, schema-validated, immutable envelopes carrying a
  defined minimum of metadata.
- **R5.2** — correlation IDs stable across the factory/project/repository/run/
  phase/assignment chain, so consumers reconstruct causation without parsing
  prose, filenames or worker output.
- **R5.7** — the transport is Go-native, bounded and headless.

Bullets 2 to 4 cover durable delivery with retry (R5.3, R5.4), dead-lettering
with replay and quarantine (R5.5), and the operator surfaces (R5.6). They depend
on this one, because a delivery state machine needs an envelope with an identity
to key on.

## Problem

`EnvelopeRecord` holds eight fields:

```
ID  RunID  Repo  Stage  Summary  Artifacts  Data  CreatedAt
```

R5.1 names roughly fifteen: `envelope_id`, `type`, `schema_version`,
`occurred_at`, `published_at`, `producer`, `correlation_id`, optional
`causation_id`, and references for `factory_id`, `project_id`, `repo_id`,
`run_id`, `phase_id` and `assignment_id` where applicable.

Concretely, what is missing and what it costs:

- **No type and no schema version.** A consumer cannot tell what an envelope is
  without reading its payload, and a payload shape can never be changed safely
  because nothing declares which version it is.
- **No correlation or causation.** `RunID` is the only link. There is no way to
  say this envelope was caused by that one, so ordering and causation can only be
  guessed from timestamps.
- **No producer.** Nothing records what emitted the envelope.
- **`occurred_at` and `published_at` are one field.** When something happened and
  when it was recorded are different facts, and collapsing them hides delay.
- **Nothing enforces immutability.** A record can be rewritten after publication.

## Proposal

Give an envelope the metadata R5.1 names, validate it on publication, and refuse
to rewrite it afterwards. Carry a correlation id from the run through every
envelope it produces, and a causation id where one envelope follows another.

Existing rows are migrated additively and keep working: an envelope written before
this change has no type, and it must read as an envelope with no type rather than
one that fails validation.

## Out of scope

- Delivery state, retry, acknowledgement and dead-lettering — bullets 2 and 3.
- Operator surfaces over the history — bullet 4.
- Removing the current `Summary`/`Artifacts`/`Data` fields. They carry real
  content today; this bullet adds the envelope around them.
