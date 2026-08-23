# Intent lifecycle

## ADDED Requirements

### Requirement: A run's terminal outcome advances its bullets

A run reaching a terminal status SHALL advance the bullets it carries. Decision D4
places intents and bullets in sergeant's own store, and a record that is written
once and never updated states something false for the whole life of the row.

#### Scenario: A passed run moves its bullets to green

- **WHEN** a run whose bullets are `pending` reaches `passed`
- **THEN** each of its bullets becomes `green`

Fails today: `UpdateBulletStatus` has no production caller, so the bullets stay
`pending` forever.

#### Scenario: A passed run does not mark its bullets merged or sealed

- **WHEN** a run reaches `passed`
- **THEN** no bullet of that run becomes `sealed` or `merged`

Decision D6: sergeant never merges. Passing gates means the work exists, not that
it was reviewed, submitted or delivered.

#### Scenario: A failed run records failure on its bullets

- **WHEN** a run reaches `failed`
- **THEN** each of its bullets becomes `failed`

#### Scenario: A cancelled run leaves its bullets untouched

- **WHEN** a run reaches `cancelled` while its bullets are `pending`
- **THEN** each of those bullets is still `pending`

An operator stopping a run has concluded nothing about the work. Recording
`failed` would assert a judgment the operator did not make.

#### Scenario: Advancing twice is a no-op

- **WHEN** a run that already advanced its bullets reaches the same terminal
  status again, as a resumed run does
- **THEN** the bullets hold the same status and no error is returned

### Requirement: An intent is satisfied only when every one of its bullets is merged

Intent status SHALL be derived from its bullets and SHALL NOT be assigned from any
single run's outcome. An intent may span several bullets and several runs, so no
one run knows whether the intent is complete.

#### Scenario: An intent with an unmerged bullet is not satisfied

- **WHEN** an intent's bullets are evaluated and at least one is not `merged`
- **THEN** the intent's status is `in_progress`

#### Scenario: An intent whose bullets are all merged is satisfied

- **WHEN** every bullet of an intent is `merged`
- **THEN** the intent's status is `satisfied`

#### Scenario: A passing run cannot satisfy an intent on its own

- **WHEN** a run reaches `passed` and its bullets become `green`
- **THEN** its intent's status is `in_progress`

This is the D6 guarantee expressed as a test. Sergeant is never the thing that
merged, so it must never be the thing that declares the work delivered.

#### Scenario: An intent with no bullets is not satisfied

- **WHEN** an intent has no bullets at all
- **THEN** its status is `in_progress`

A rule of the form "every bullet is merged" is vacuously true for an empty set,
which would silently satisfy an intent that has had no work done against it.
