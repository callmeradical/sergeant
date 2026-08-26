## 2026-07-28 - Predictable temporary file path in wiki-daily-digest
**Vulnerability:** A script creates temporary files at predictable paths (`/tmp/wiki_claude_{session_id}.txt`) allowing potential local attackers to execute a symlink attack to overwrite arbitrary files, or to view sensitive session content.
**Learning:** Hardcoded predictable temporary file paths, especially those derived from predictable elements like session_ids, expose local file operations to race conditions.
**Prevention:** Always use `mktemp -d` to create secure temporary directories or `mktemp` for files, and keep sensitive logic contained within those directories. Remove hardcoded predictable file paths.
