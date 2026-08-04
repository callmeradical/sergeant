#!/usr/bin/env python3
"""Assert that mise's dependency check and sgt-bootstrap classify tools alike.

Usage: assert-toolchain-sets.py <mise.toml> <bin/sgt-bootstrap>

`mise run check` and `bin/sgt-bootstrap --verify-only` are the two commands a
user may run to find out whether their toolchain is complete. If their required
and optional sets drift, one reports success while the other fails, and the
docs that point at both become wrong. Exits non-zero naming the divergence.
"""

import re
import sys


def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def mise_sets(toml):
    """Return (required, optional) command names declared by the check task."""
    required = set()
    optional = set()
    for _label, command, kind in re.findall(
        r'_check\s+"([^"]+)"\s+(\S+)\s+(required|optional)', toml
    ):
        (required if kind == "required" else optional).add(command)
    # These two are hand-rolled required checks rather than _check calls.
    if "_check_td" in toml:
        required.add("td")
    return required, optional


def bootstrap_array(bootstrap, name):
    match = re.search(name + r"=\((.*?)\)", bootstrap, re.S)
    if match is None:
        raise SystemExit("bin/sgt-bootstrap is missing %s" % name)
    return set(re.findall(r"'([^']+)'", match.group(1)))


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    toml = read(sys.argv[1])
    bootstrap = read(sys.argv[2])

    check_required, check_optional = mise_sets(toml)
    boot_required = bootstrap_array(bootstrap, "required_commands")
    boot_optional = bootstrap_array(bootstrap, "optional_commands")

    missing_required = check_required - boot_required
    if missing_required:
        raise SystemExit(
            "mise run check requires %s; bin/sgt-bootstrap does not require %s"
            % (sorted(check_required), sorted(missing_required))
        )

    wrongly_required = check_optional & boot_required
    if wrongly_required:
        raise SystemExit(
            "bin/sgt-bootstrap requires tools mise run check treats as optional: %s"
            % sorted(wrongly_required)
        )

    ignored_optional = check_optional - boot_optional - boot_required
    if ignored_optional:
        raise SystemExit(
            "mise run check reports %s as optional; bin/sgt-bootstrap ignores %s"
            % (sorted(check_optional), sorted(ignored_optional))
        )

    if "_check_agent_harness" in toml and "agent_harnesses=(" not in bootstrap:
        raise SystemExit(
            "mise run check accepts any one agent harness; "
            "bin/sgt-bootstrap must declare agent_harnesses"
        )


if __name__ == "__main__":
    main()
