# 007 — Closed-world tool registry

Build-order step 2. Depends on 002 (sandbox) and 004 (search).

Read [`000-overview.md`](000-overview.md) first. Enforces **I2**, **I3**.

## Goal

The complete, closed set of things the model can do. `PRODUCT.md`: "The session may call
only ..." and "No `web_fetch`. No unrestricted `bash`. ... A sandbox (or simply: those
tools do not exist) is the product."

## Scope

In: `Hatch.Tools` (registry, schemas, dispatch, read-log), `Hatch.Tools.KB`,
`Hatch.Tools.WS`. Read-only tools only.

Out: `propose_patch` (008), `ws.apply` (009), `tamago.build`'s port (010 — this spec
declares its schema and delegates).

## Design

### Registry

```elixir
@spec schemas(Config.t()) :: [map()]                  # OpenAI function-tool objects
@spec call(String.t(), String.t(), ctx()) :: {:ok, String.t()} | {:error, err()}
@type ctx :: %{session_id: String.t(), read_log: pid() | :ets.tid()}
```

`call/3` takes the tool name and the **raw JSON argument string** from the model:

1. `Jason.decode` → on failure `{:error, %{code: :invalid_args, message: "arguments were
   not valid JSON: ..."}}`. Do not attempt repair.
2. Validate against the tool's declared arg spec (required keys, types, enum values,
   integer ranges). A hand-rolled validator in `Hatch.Tools.Args` is sufficient and
   preferred to a JSON-schema library.
3. Dispatch. Any exception inside a tool is caught and returned as
   `%{code: :tool_crashed, message: Exception.message(e)}` — a bad path from the model
   must never take down the session (I7).
4. Success returns a **string** ready to be a tool message: JSON for structured results,
   plain text for file contents (wrapped, see below).

Unknown tool name → `:unknown_tool` with the list of valid names. That list is the
product boundary; when the model asks for `web_fetch`, the error must say so plainly:
`"no such tool. hatch has no network and no shell. available: kb.search, kb.read, ws.read, ws.list, ws.diff, tamago.build, propose_patch"`.

`schemas/1` omits `ws.*` and `tamago.build` when `tree_root` is `nil` — a tool that
cannot work should not be offered.

### Read-log

Citations (008) are checked against what was actually read. `Hatch.Tools.ReadLog` is an
ETS set owned by the session process, recording `{path, tool, at}` for every successful
`kb.read` and every KB path returned by `kb.search`. Exposed as
`@spec read?(ctx(), String.t()) :: boolean()`.

### Tools

**`kb.search`** — args `{soc?: string, uart?: string, peripherals?: [string], text?: string, limit?: int 1..20}`.
At least one of `soc`/`text`/`peripherals` required (`:invalid_args` otherwise — an
unfiltered dump of the KB is not a search). Returns JSON:

```json
{"hits":[{"id":"mk2","path":"boards/mk2/board.toml","soc":"imx6ul","soc_match":"exact",
          "score":19.5,"why":["same soc imx6ul","same uart UART2","4/5 peripherals overlap",
                              "pinmux unknown on both"],
          "facts":{"ram_start":"0x80000000","ram_size":"0x20000000","uart":"UART2",
                   "peripherals":["gpio","usb","usdhc"],"tamago_soc":"...","tree":"boards/mk2/tree"}}],
 "count":1}
```

Empty results return `{"hits":[],"count":0,"note":"no board in the KB has this soc. hatch cannot propose a port for an soc with no package in the KB."}` —
the model must be told *why* it is empty, or it will improvise (`PRODUCT.md` non-goal:
"New SoC packages from a datasheet with nothing in the KB").

Every hit's `path` is logged to the read-log as *citable-on-read*, but a hit alone is not
a citation: a citation requires `kb.read` of that path (see 008).

**`kb.read`** — args `{path: string, max_bytes?: int}`. `Hatch.Sandbox.read(:kb, path)`.
Returns the content wrapped as:

```
<file path="boards/mk2/board.toml" bytes="412">
...contents...
</file>
```

The wrapper exists so the model can quote a path it is certain of. Errors pass through
the overview §8 shape; `:binary_file` and `:too_large` messages are the ones from 002.

**`ws.read`** — same, root `:tree`. **`ws.list`** — args `{path?: string, depth?: int 1..3}`,
returns JSON list from `Hatch.Sandbox.list/3` including `truncated`.

**`ws.diff`** — args `{}`. Runs `git -C <tree_root> diff --no-color` as an argv port
(I8), 10 s timeout, output truncated to 64 KiB with a trailing `... (truncated)` marker.
If the tree is not a git repo → `{:error, %{code: :not_a_repo}}`. This shows the model
what is *currently* uncommitted in the tree, which is how it sees the effect of an
applied patch on the next turn.

**`tamago.build`** — schema declared here, dispatch delegates to `Hatch.Build.Worker`
(010). Args `{package?: string}` defaulting to `"./..."`; `package` must match
`~r{^[A-Za-z0-9._/-]+$}` and must not start with `-` (no flag injection through a
package name). Returns `{"exit_status":0,"timed_out":false,"log":"..."}` with the log
tail-truncated to 32 KiB — compiler errors are at the end.

**`propose_patch`** — schema declared in 008.

### What must not exist

There is no tool for: fetching a URL, running a shell command, reading an absolute path,
listing anything outside the two roots, writing a file, git commit/checkout, or installing
anything. Adding one is a `PRODUCT.md` change, not a code change.

## Acceptance criteria

1. `schemas/1` returns exactly the tools above and no others; the list is asserted against
   a literal in the test, so adding a tool fails a test until someone updates it
   deliberately. **(closed world, enforced)**
2. With `tree_root: nil`, `schemas/1` contains no `ws.*` and no `tamago.build`; calling
   `ws.read` anyway returns `:no_tree`.
3. `kb.read` with `"../../etc/passwd"` returns `:outside_sandbox` and does not read.
   **(I2)**
4. `kb.search` with `{}` returns `:invalid_args`; with `{soc: "nope"}` returns the empty
   result **with the note**.
5. `call("web_fetch", "{}", ctx)` returns `:unknown_tool` and the message names the
   available tools and says there is no network. **(I3)**
6. Malformed JSON arguments return `:invalid_args` without raising.
7. A tool that raises internally is reported as `:tool_crashed`; the calling process
   survives.
8. `tamago.build` with `package: "--toolexec=/bin/sh"` is rejected by the arg validator
   before reaching the port. **(I8 — argv injection)**
9. Successful `kb.read` writes the path to the read-log; a failed one does not.
10. `ws.diff` in a non-repo directory returns `:not_a_repo` rather than hanging or
    raising.
11. Grep test over `lib/`: no `System.cmd` / `:os.cmd` / port spawn with a shell
    (`sh -c`), anywhere. Ports are `:spawn_executable` with an argv list only.

## Test plan

`test/hatch/tools_test.exs` driving `call/3` with the raw strings a model would send,
including hostile ones. Fixture KB and a fixture tree (a real `git init` in a tmp dir for
`ws.diff`, skipped if `git` is absent).

## Constraints

- Tool results are strings the model reads. Keep them small and stable: no timestamps, no
  absolute paths, no random ordering — a non-deterministic tool result poisons prompt
  caching and makes a session impossible to re-run.
- Never return an absolute path to the model. Always root-relative. **(I2, and it is what
  makes citations checkable.)**
