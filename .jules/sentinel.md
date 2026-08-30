## 2026-07-28 - Predictable temporary file path in wiki-daily-digest
**Vulnerability:** A script creates temporary files at predictable paths (`/tmp/wiki_claude_{session_id}.txt`) allowing potential local attackers to execute a symlink attack to overwrite arbitrary files, or to view sensitive session content.
**Learning:** Hardcoded predictable temporary file paths, especially those derived from predictable elements like session_ids, expose local file operations to race conditions.
**Prevention:** Always use `mktemp -d` to create secure temporary directories or `mktemp` for files, and keep sensitive logic contained within those directories. Remove hardcoded predictable file paths.
## 2026-07-28 - Command line argument code injection in python -c
**Vulnerability:** Calling inline Python scripts from Bash using `python -c "..."` but passing variables by string interpolation (e.g. `start_ts="$(python3 -c "import datetime; print(int(datetime.datetime(*(int(x) for x in '$date'.split('-'))).timestamp() * 1000))")"`) exposes the script to code injection if the variable is not properly sanitized or comes from user input.
**Learning:** Bash string interpolation directly into a Python script evaluates the variables as code.
**Prevention:** Pass variables as command-line arguments (via `sys.argv`) rather than relying on bash string interpolation when executing inline scripts with python.
