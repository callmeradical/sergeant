# Output redaction

## ADDED Requirements

### Requirement: Captured output is scrubbed for common secret shapes before it is written

Captured agent and gate output SHALL have common secret-shaped substrings
replaced with a fixed placeholder before being written to any durable
record. Requirement R4.4 requires that logs, records, responses, and
notifications must not retain credentials, tokens, or secrets.

#### Scenario: A provider API key is redacted

- **WHEN** captured output contains a substring shaped like a common
  provider API key (e.g. a `sk-`, `ghp_`, or `AKIA`-prefixed token)
- **THEN** the stored record contains the fixed placeholder in place of that
  substring, not the original value

#### Scenario: A bearer token is redacted

- **WHEN** captured output contains an `Authorization: Bearer <token>`
  header
- **THEN** the stored record retains the header name but replaces the token
  with the fixed placeholder

#### Scenario: A credential-shaped environment line is redacted

- **WHEN** captured output contains a line shaped like `NAME=value` where
  NAME's name suggests a credential (key, token, secret, password,
  credential)
- **THEN** the stored record retains NAME but replaces value with the fixed
  placeholder

#### Scenario: Ordinary output is unaffected

- **WHEN** captured output contains no secret-shaped substrings
- **THEN** the stored record is byte-for-byte identical to the ANSI-stripped
  input

### Requirement: Captured output is bounded in size before it is written

Captured output SHALL be capped at a fixed maximum size before being written
to any durable record, with truncation made visible rather than silent.
Requirement R4.5 requires retaining only the minimum content needed to
reproduce or audit a run.

#### Scenario: Output under the cap is retained in full

- **WHEN** captured output is smaller than the maximum size
- **THEN** the stored record contains it unchanged (aside from redaction)

#### Scenario: Output over the cap is truncated with a visible marker

- **WHEN** captured output exceeds the maximum size
- **THEN** the stored record contains output truncated to the maximum size
  plus a marker stating that truncation occurred and how much was cut

### Requirement: Redaction happens before truncation

Redaction SHALL be applied before size truncation, so a secret is not left
half-redacted by being cut at the size boundary.

#### Scenario: A secret near the size boundary is fully redacted, not truncated mid-match

- **WHEN** captured output's size is near the maximum and contains a
  secret-shaped substring that would straddle the truncation point if cut
  first
- **THEN** the secret is fully redacted before truncation is applied, so no
  partial, unredacted fragment of it survives in the stored record
