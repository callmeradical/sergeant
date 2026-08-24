## 1. Ledger foundation

- [ ] 1.1 Add the versioned allowlisted event schema and validation helpers; verify schema tests reject sensitive/unbounded fields and accept valid lifecycle events
- [ ] 1.2 Add locked atomic NDJSON append with unique IDs and UTC timestamps; verify concurrent fixture writers produce only parseable complete records
- [ ] 1.3 Add corruption-tolerant reader and bounded retention pruning; verify malformed records are counted, valid records survive, and newest record is retained

## 2. Reporting

- [ ] 2.1 Add deterministic aggregate calculations for totals, success rate, median/p95 duration, and sorted failure categories; verify exact fixture expectations
- [ ] 2.2 Add `sgt-analytics` CLI with JSON/human output and since/project/repo filters; verify empty-install and filter integration tests
- [ ] 2.3 Ensure report output never includes raw payload or sensitive fields; verify privacy regression tests

## 3. Lifecycle integration

- [ ] 3.1 Add best-effort dispatch-start, terminal, and recovery capture hooks after authoritative status writes; verify injected ledger failures do not change command status or state
- [ ] 3.2 Run focused analytics tests plus existing dispatch/watch suites and ShellCheck; verify no compatibility regressions and document command usage
