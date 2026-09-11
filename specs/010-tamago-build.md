# 010 — `tamago.build` port worker

Build-order step 4. Depends only on 001; parallel with 002/005.

Read [`000-overview.md`](000-overview.md) first. Enforces **I8**.

## Goal

`GOOS=tamago` build of the working tree as an eval. `PRODUCT.md`: "Build runs after apply
(or on demand) so you review a compiler, not a vibe." A hung toolchain must not kill the
session.

## Scope

In: `Hatch.Build.Worker` (GenServer, serialised, port with timeout, streaming log).

Out: QEMU / UART golden strings (v2, explicitly not now), the keybind (011), the tool
schema (007).

## Design

### Worker

One `Hatch.Build.Worker` per board job, child of `Hatch.BoardJob.Supervisor`
(`PRODUCT.md`: "Build.Worker ... 1–2 at a time"; v1 is 1).

```elixir
@callback build(String.t(), keyword()) :: {:ok, result()} | {:error, err()}
@type result :: %{build_id: String.t(), exit_status: integer(), timed_out: boolean(),
                  duration_ms: non_neg_integer(), log: String.t()}
@spec build(session_id :: String.t(), opts :: [package: String.t(), timeout_ms: pos_integer()]) ::
        {:ok, result()} | {:error, err()}
```

- Synchronous `GenServer.call` with `timeout_ms + 5_000`, but the port work happens in the
  worker so `:build_log` events stream while it runs.
- **Busy behaviour**: a second concurrent build returns `{:error, %{code: :busy, message:
  "a build is already running (build_id ...)"}}`. No queue. A queued build against a tree
  that has since changed is a lie; the operator or the model re-runs it.

### The port

```elixir
Port.open({:spawn_executable, go_bin},
  [:binary, :exit_status, :stderr_to_stdout, :hide,
   args: ["build", package],
   cd: tree_root,
   env: [{~c"GOOS", ~c"tamago"}, {~c"GOARCH", goarch}, {~c"GOARM", goarm},
         {~c"CGO_ENABLED", ~c"0"}, ...]])
```

- `go_bin = System.find_executable(config.tamago_go)`; missing →
  `{:error, %{code: :no_toolchain, message: "tamago-go not found on PATH (HATCH_TAMAGO_GO=...)"}}`.
  Checked before spawning, and surfaced at startup so the TUI can grey out the keybind.
- `GOARCH`/`GOARM` come from the **draft board record** when the session has one,
  defaulting to `arm`/`7`. They are validated against the enums in 003 before being put in
  the environment.
- Environment is **explicit**: inherit the OS env (the toolchain needs `HOME`, `PATH`,
  `GOCACHE`, `GOMODCACHE`) but override the four above. Do not construct a shell command;
  do not interpolate anything into a string. **(I8)**
- `package` is validated by 007's arg rules before it reaches here; re-validate anyway
  (defence in depth) — a package starting with `-` is `:invalid_args`.

### Streaming and truncation

- Each `{port, {:data, chunk}}` is broadcast as `:build_log` and appended to a buffer.
- The buffer is capped at 1 MiB: keep the **first 64 KiB and the last 512 KiB** with a
  `... (N bytes elided) ...` marker between them. Go puts the useful errors at the end and
  the invocation at the start.
- The returned `log` for the tool result is the **last 32 KiB** (007's contract).

### Timeout and cleanup

- On `timeout_ms` (config default 120 s, per-call override): get the OS pid via
  `Port.info(port, :os_pid)`, send `TERM` via an argv port to `kill`, wait 2 s, then
  `KILL`; then `Port.close/1`. Return `timed_out: true`, `exit_status: 124`.
  A one-line comment must record *why* `Port.close/1` alone is not enough (it closes the
  pipe; `go build`'s children keep running).
- The worker traps exits and always demonitors/closes the port in `terminate/2`, so a
  crashed worker does not leak a `go build`.
- A worker crash restarts under the supervisor without touching the session. **(`PRODUCT.md`:
  "A hung QEMU or a bad PDF page must not kill the session.")**

### Events

`:build_started` (`build_id`, `argv` — the literal argv list, so the operator can re-run
it by hand), `:build_log`, `:build_finished`.

`Hatch.Session.note_build/2` appends a transcript note with the exit status and the log
tail, so the model iterates on the compiler and not on a summary.

## Acceptance criteria

Tests use a **fake `tamago-go`**: an executable shell script in a tmp dir, pointed at by
`HATCH_TAMAGO_GO`, which can be told to print, exit non-zero, or sleep forever.

1. Exit 0 with output → `{:ok, %{exit_status: 0, timed_out: false, log: <output>}}`, and
   `:build_started` / `:build_log`+ / `:build_finished` are broadcast in order.
2. Exit 2 with a compiler-shaped error on stderr → the error text is in `log`
   (`:stderr_to_stdout`).
3. A hanging fake with `timeout_ms: 500` → returns within ~2.5 s with `timed_out: true,
   exit_status: 124`, **and the OS process is gone** (assert with `Process.alive?`-style
   polling of the pid via `kill -0`). **(I8 — the "hung QEMU" case.)**
4. A concurrent second build → `:busy`; the first still completes normally.
5. `tamago_go` set to a nonexistent binary → `:no_toolchain`, no crash, keybind
   availability reflects it.
6. The env handed to the port contains `GOOS=tamago` and the draft's `GOARCH`/`GOARM`;
   asserted by having the fake print its environment.
7. 3 MiB of output is truncated head+tail with the elision marker, and the tool-facing
   log is ≤ 32 KiB.
8. Killing the worker mid-build leaves no orphan process and the session process is
   unaffected.
9. Grep test: the port is spawned with `:spawn_executable` and an `args:` list; no
   `System.cmd`, no `sh -c`, no string interpolation into argv, anywhere in this module.

## Test plan

`test/hatch/build/worker_test.exs`. Fake toolchain scripts written to a tmp dir with
`File.chmod!(0o755)`. Tag the timeout test `@tag :slow` but keep it in the default run —
it is the one that protects the session.

## Constraints

- Nothing in this module parses Go, rewrites files, or retries a failed build. It runs a
  compiler and reports it.
- No QEMU, no UART, no golden strings in v1 (`PRODUCT.md` V2).
