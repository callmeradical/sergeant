## 2026-07-28 - Predictable temporary file path in wiki-daily-digest
**Vulnerability:** A script creates temporary files at predictable paths (`/tmp/wiki_claude_{session_id}.txt`) allowing potential local attackers to execute a symlink attack to overwrite arbitrary files, or to view sensitive session content.
**Learning:** Hardcoded predictable temporary file paths, especially those derived from predictable elements like session_ids, expose local file operations to race conditions.
**Prevention:** Always use `mktemp -d` to create secure temporary directories or `mktemp` for files, and keep sensitive logic contained within those directories. Remove hardcoded predictable file paths.
## 2026-07-28 - [Python Command Injection via Bash String Interpolation]
**Vulnerability:** Bash variables were interpolated directly into inline Python scripts (`python -c "import datetime; print('$date')"`), allowing attackers to execute arbitrary Python code if they could control the bash variable.
**Learning:** String interpolation in shell commands calling interpreted languages (like Python, awk, sed) allows code injection.
**Prevention:** Always pass variables to inline scripts as command-line arguments (e.g., `sys.argv[1]`) or via environment variables, rather than direct text replacement.
