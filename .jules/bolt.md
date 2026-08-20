
## 2024-08-20 - Expensive Syscalls in Hot Path of MCP Server
**Learning:** Found that `os.Executable()` and `filepath.EvalSymlinks()` were called on every single tool invocation in the MCP server to figure out the binary path. This causes a ~14000ns per-call overhead. Since the executable path is constant for the lifetime of a Go process, this redundant I/O is a bottleneck.
**Action:** When computing fixed paths or system values (like the executable path or host platform info) in handlers or frequent paths, memoize the result using `sync.OnceValue` or package-level variables so it's calculated exactly once and returns immediately (sub-10ns overhead).
