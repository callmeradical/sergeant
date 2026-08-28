
## 2024-08-20 - Expensive Syscalls in Hot Path of MCP Server
**Learning:** Found that `os.Executable()` and `filepath.EvalSymlinks()` were called on every single tool invocation in the MCP server to figure out the binary path. This causes a ~14000ns per-call overhead. Since the executable path is constant for the lifetime of a Go process, this redundant I/O is a bottleneck.
**Action:** When computing fixed paths or system values (like the executable path or host platform info) in handlers or frequent paths, memoize the result using `sync.OnceValue` or package-level variables so it's calculated exactly once and returns immediately (sub-10ns overhead).
## 2024-08-27 - Python ctypes.CDLL load overhead in tight loops
**Learning:** Found that invoking `ctypes.CDLL(None, use_errno=True)` within functions like `libc_pidfd_function` in `_sgt-process-token.py` (which are called continuously when iterating over all processes via `/proc`) is extremely slow, adding ~58µs of overhead per invocation compared to ~0.5µs for a cached lookup. This becomes a bottleneck during process discovery tasks involving thousands of PIDs.
**Action:** When a fallback or standard system function requires loading a dynamic library via `ctypes.CDLL`, initialize it once at the module scope or memoize it lazily in a module-level variable to avoid repeated disk and linking overhead.
## 2025-02-27 - Naive string search is unsafe for JSON parsing
**Learning:** Attempting to optimize JSON parsing by searching for literal strings (like `"id":`) introduces critical false positive bugs, as the literal string might appear inside nested objects (like `params`) or standard string payloads, completely breaking JSON-RPC request-response correlation. Speed without correctness is useless.
**Action:** Never use simple string searches as heuristics for JSON decoding without accounting for the structural syntax of JSON.

## 2025-02-27 - Avoid strings.Split in hot loops
**Learning:** `strings.Split` in Go creates a new slice and allocates individual strings for every element, which is inefficient when parsing payloads (like Server-Sent Events) in hot proxy paths where most lines are discarded.
**Action:** Use manual byte-slice or string scanning with `strings.IndexByte` inside a loop to iterate through lines without the overhead of creating an intermediate slice.
