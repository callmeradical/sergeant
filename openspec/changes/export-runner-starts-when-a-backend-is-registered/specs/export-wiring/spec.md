# Export runner wiring

## ADDED Requirements

### Requirement: A registered export backend actually starts exporting

When a project configures an `export.backend` name that has a registered
`Constructor`, the process SHALL construct that backend's `Target`, build
an `export.Runner` for it, and start delivering transitions — not merely
recognize that the project configured one.

#### Scenario: A project with a registered backend causes a Runner to start

- **WHEN** `startExportRunners` runs against a project configuring
  `export.backend: "test-backend"`, and `"test-backend"` is registered in
  the backends map passed in, with a constructor returning a test `Target`
- **THEN** that `Target`'s `Export` method is called at least once within a
  short bounded wait

### Requirement: An unregistered backend name behaves exactly as before this change

A project configuring an `export.backend` name with no registered
`Constructor` SHALL be handled exactly as `startExportRunners` already
handled every project before this change: reported, nothing started. This
is the common case today, since the registry starts empty.

#### Scenario: An unknown backend name starts nothing

- **WHEN** `startExportRunners` runs against a project configuring
  `export.backend: "unknown-backend"`, and the backends map passed in has
  no entry for `"unknown-backend"`
- **THEN** no `Target` is constructed, no `Runner` is started, and the
  existing warning is reported exactly as before this change

### Requirement: A project with no export configuration is unaffected

A project with no `export:` block configured SHALL cause no lookup, no
construction, and no goroutine to start — the same as before this change.

#### Scenario: No export block starts nothing and reports nothing

- **WHEN** `startExportRunners` runs against a project with a nil `Export`
  field
- **THEN** no `Target` is constructed, no `Runner` is started, and nothing
  is reported for that project
