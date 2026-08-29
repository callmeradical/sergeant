
## 2024-08-20 - Expensive Syscalls in Hot Path of MCP Server
**Learning:** Found that `os.Executable()` and `filepath.EvalSymlinks()` were called on every single tool invocation in the MCP server to figure out the binary path. This causes a ~14000ns per-call overhead. Since the executable path is constant for the lifetime of a Go process, this redundant I/O is a bottleneck.
**Action:** When computing fixed paths or system values (like the executable path or host platform info) in handlers or frequent paths, memoize the result using `sync.OnceValue` or package-level variables so it's calculated exactly once and returns immediately (sub-10ns overhead).
## 2024-08-27 - Python ctypes.CDLL load overhead in tight loops
**Learning:** Found that invoking `ctypes.CDLL(None, use_errno=True)` within functions like `libc_pidfd_function` in `_sgt-process-token.py` (which are called continuously when iterating over all processes via `/proc`) is extremely slow, adding ~58µs of overhead per invocation compared to ~0.5µs for a cached lookup. This becomes a bottleneck during process discovery tasks involving thousands of PIDs.
**Action:** When a fallback or standard system function requires loading a dynamic library via `ctypes.CDLL`, initialize it once at the module scope or memoize it lazily in a module-level variable to avoid repeated disk and linking overhead.
## 2024-11-20 - Unnecessary Allocation in Payload Parsing
**Learning:** Found that using `strings.Split(string(body), "\n")` on large payload bodies during SSE parsing allocates a giant string and an intermediate slice array, which can lead to increased memory footprint and slower processing on hot paths.
**Action:** When parsing high-throughput streams or large payloads, avoid converting the entire `[]byte` to string prematurely. Instead, iterate through the byte slice manually using `bytes.IndexByte` and only allocate strings when strictly necessary (e.g., when a parsed line is finalized and stored).
