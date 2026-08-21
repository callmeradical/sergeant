## 2026-08-21 - [Cache scriptDir in sergeant-mcp]
**Learning:** `os.Executable` and `filepath.EvalSymlinks` are expensive system calls in Go. When used in a frequently called utility function (like `scriptDir` which was called on *every* tool invocation in the MCP server), they can create unnecessary overhead.
**Action:** Use `sync.Once` to cache the result of expensive path-resolution functions that return static values for the lifetime of the process.
