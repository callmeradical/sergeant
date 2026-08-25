# task-tracking-is-a-readonly-export

Sergeant's durable change log (intents, bullets) already exists for the dashboard's live stream; this change adds a second, independent reader of that same log that projects each transition into a redacted, read-only record and hands it to an external task tracker — Sergeant never reads anything back, so its own store stays the sole authority (D4).
