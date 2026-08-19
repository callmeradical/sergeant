## 2025-02-18 - Caching repeated OS calls
**Learning:** Found that `scriptDir()` in `cmd/sergeant-mcp/main.go` was making repeated, expensive OS and filesystem calls (`os.Executable()`, `filepath.EvalSymlinks()`) on every MCP tool invocation, which adds up since tool execution is highly recurrent.
**Action:** Used `sync.Once` to cache the resolved script directory at the process level to avoid duplicate syscalls. The executable path doesn't change during the lifecycle of the Go process, making this a safe caching opportunity.
