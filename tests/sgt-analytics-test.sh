#!/usr/bin/env bash
set -euo pipefail
root="$(mktemp -d)"; trap 'rm -rf "$root"' EXIT
export SERGEANT_ANALYTICS_LEDGER="$root/events.ndjson"
bin/sgt-analytics --json | grep -q '"started": 0'
bin/sgt-analytics --record --type dispatch_started --project demo --repo core --task-id t1
bin/sgt-analytics --record --type terminal --project demo --repo core --task-id t1 --outcome completed
bin/sgt-analytics --json --project demo --repo core > "$root/report.json"
grep -q '"completed": 1' "$root/report.json"
printf 'malformed\n' >> "$root/events.ndjson"
bin/sgt-analytics --json | grep -q '"skipped_records": 1'
printf 'sgt analytics tests passed\n'
