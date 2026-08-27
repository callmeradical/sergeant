#!/usr/bin/env python3
"""Build the bounded sergeant.status-query/v1 document from a simple
tab-separated fact protocol on stdin.

sgt-watch's --snapshot --project path resolves everything (project config,
td namespace, fleet evidence, coordinator identity) in bash/tmux/git/td, then
hands the resulting facts to this helper so the JSON is built exactly once,
by code that understands JSON types (None/True/False are not interchangeable
with the strings "null"/"true"/"false"), instead of by ad hoc printf quoting.

Protocol: each stdin line is "<key>\\t<value...>". Unknown keys are ignored.
Repeated "REPO" lines each add one entry to project_state.repos.
"""

import json
import sys


def to_bool(raw):
    return raw == "1"


def to_int(raw, default=0):
    try:
        return int(raw)
    except (TypeError, ValueError):
        return default


def opt_str(raw):
    return raw if raw != "" else None


def main():
    facts = {}
    repos = []

    for line in sys.stdin:
        line = line.rstrip("\n")
        if not line:
            continue
        parts = line.split("\t")
        key = parts[0]
        if key == "REPO":
            # REPO\t<name>\t<cloned:0|1>\t<branch-or-empty>
            repos.append(parts[1:4])
            continue
        facts[key] = parts[1] if len(parts) > 1 else ""

    doc = {
        "schema": "sergeant.status-query/v1",
        "observed_at": facts.get("observed_at", ""),
        "scope": {
            "project": opt_str(facts.get("project", "")),
            "td_id": opt_str(facts.get("td_id", "")),
        },
        "resolved": to_bool(facts.get("resolved", "0")),
        "namespace": facts.get("namespace", "unknown"),
        "reason": facts.get("reason", "unknown"),
    }

    if to_bool(facts.get("fleet_present", "0")):
        busy_raw = facts.get("fleet_busy", "null")
        doc["fleet"] = {
            "busy": True if busy_raw == "true" else None,
            "basis": facts.get("fleet_basis", "no_verified_active_witness"),
            "totals": {
                "total": to_int(facts.get("fleet_total", "0")),
                "needs_input": to_int(facts.get("fleet_needs_input", "0")),
                "blocked": to_int(facts.get("fleet_blocked", "0")),
                "waiting": to_int(facts.get("fleet_waiting", "0")),
                "terminal": to_int(facts.get("fleet_terminal", "0")),
                "in_progress": to_int(facts.get("fleet_in_progress", "0")),
                "other": to_int(facts.get("fleet_other", "0")),
                "queued": to_int(facts.get("fleet_queued", "0")),
            },
        }
    else:
        doc["fleet"] = None

    if to_bool(facts.get("project_state_present", "0")):
        doc["project_state"] = {
            "name": facts.get("project_name", ""),
            "repos": [
                {
                    "name": entry[0] if len(entry) > 0 else "",
                    "cloned": entry[1] == "1" if len(entry) > 1 else False,
                    "branch": (entry[2] if len(entry) > 2 and entry[2] != "" else None),
                }
                for entry in repos
            ],
        }
    else:
        doc["project_state"] = None

    if to_bool(facts.get("coordinator_present", "0")):
        doc["coordinator"] = {
            "verified": to_bool(facts.get("coordinator_verified", "0")),
            # Version 1 never performs a request/response round-trip: it only
            # ever reports locally verified identity/heartbeat evidence, so
            # this is a closed constant, not a computed value.
            "queried": False,
            "pane": opt_str(facts.get("coordinator_pane", "")),
            "reason": facts.get("coordinator_reason", "unknown"),
        }
    else:
        doc["coordinator"] = None

    json.dump(doc, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
