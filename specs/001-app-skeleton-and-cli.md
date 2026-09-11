# 001 — Mix app, config, CLI entrypoint

Build-order step 1 (first half). No model calls, no tools, no TUI yet.

Read [`000-overview.md`](000-overview.md) first.

## Goal

`hatch --kb ./kb` starts a supervised OTP application and prints a one-line readiness
banner. `hatch` with no `--kb` refuses to start. This is V1 acceptance criterion 1.

## Scope

In: Mix project, application + supervision tree, `Hatch.Config`, `Hatch.CLI`, escript
packaging, `Hatch.BoardJob.Supervisor` skeleton, PubSub.

Out: anything that talks to a model, KB parsing, tools, TUI rendering.

## Design

### Project

`mix new hatch --sup` at the repo root, so the Mix project lives beside `PRODUCT.md`
(`lib/`, `test/`, `mix.exs` at top level; `kb/` stays where it is).

`mix.exs`:

- `app: :hatch`, `elixir: "~> 1.17"`.
- `escript: [main_module: Hatch.CLI, name: "hatch"]`.
- deps: `{:phoenix_pubsub, "~> 2.1"}` only. Later specs add their own lines from
  overview §3.
- `elixirc_paths(:test)` includes `test/support`.

### `Hatch.Config`

```elixir
@spec from_argv([String.t()]) :: {:ok, t()} | {:error, %{code: atom, message: String.t()}}
@spec from_env(map(), keyword()) :: {:ok, t()} | {:error, ...}   # env map injected for tests
```

Resolution rules:

- `--kb PATH` **required**. Missing → `{:error, %{code: :missing_kb, message: ...}}`.
- `--kb` is expanded with `Path.expand/1`, then must be an existing directory containing
  a `boards/` directory → else `:bad_kb`. (It may contain zero boards; an empty KB is
  legal, an absent `boards/` is not.)
- `--tree PATH` optional, expanded, must be an existing directory if given → else
  `:bad_tree`. `nil` when absent; tools that need a tree return `:no_tree` (spec 007).
- Env, read once at startup: `HATCH_MODEL` (required), `HATCH_API_BASE` (required),
  `HATCH_API_KEY` (required), `HATCH_MODEL_INGEST` (defaults to `HATCH_MODEL`),
  `HATCH_MODEL_BUILD` (optional, `nil`), `HATCH_TAMAGO_GO` (default `"tamago-go"`),
  `HATCH_BUILD_TIMEOUT_MS` (default `120_000`, must parse as a positive integer).
- Missing required env → `{:error, %{code: :missing_env, message: "HATCH_API_KEY is not set"}}`
  listing every missing name at once, not one per run.
- `api_base` is normalised by stripping a trailing `/`.
- The struct's `inspect` implementation **must** redact `api_key` (`@derive {Inspect, except: [:api_key]}`).
  The key must never reach a log line or the TUI.

`--help` prints the usage from `README.md` "Shape (target)". `--version` prints
`Mix.Project.config()[:version]`. Unknown switches are an error, not ignored.

### `Hatch.CLI`

```elixir
@spec main([String.t()]) :: no_return()
```

- `--help` / `--version`: print, exit 0.
- Config error: print `hatch: <message>` to stderr, exit **2**.
- Success: ensure `:hatch` started, store the config (below), start a board job, print
  `hatch ready — kb=<kb_root> boards=<n> tree=<tree_root|none> model=<model>` and, for
  this spec, return/exit 0. Spec 011 replaces that tail with the TUI event loop; the
  banner text stays as the non-TUI `--version`-style path is dropped then.

Board count for the banner is `Path.wildcard(kb_root <> "/boards/*/board.toml") |> length()`
— deliberately not a KB parse, which is spec 003's job.

### Config storage

The escript builds a `%Config{}` before the supervision tree needs it, so:
`Hatch.Config.put/1` writes to `:persistent_term` under `{:hatch, :config}`, and
`Hatch.Config.get/0` reads it, raising if unset. Rationale for `:persistent_term`: read
by every tool call on the hot path, written exactly once at boot. Document that in a
one-line comment.

### Supervision tree

`Hatch.Application.start/2` starts, in order:

```elixir
{Phoenix.PubSub, name: Hatch.PubSub},
{Registry, keys: :unique, name: Hatch.Registry},
{DynamicSupervisor, name: Hatch.BoardJob.DynamicSupervisor, strategy: :one_for_one}
```

`Hatch.BoardJob.Supervisor` — one per spec/session, started under the DynamicSupervisor:

```elixir
@spec start_session(keyword()) :: {:ok, session_id :: String.t(), pid()}
```

It is a `Supervisor` with `strategy: :one_for_one` and, for now, **no children**; specs
006, 010 and 012 add `Hatch.Session`, `Hatch.Build.Worker` and the ingest task
supervisor as children here. It registers as `{:via, Registry, {Hatch.Registry, {:board_job, session_id}}}`.
`session_id` is `"s_" <> 8 lowercase hex` from `:crypto.strong_rand_bytes/1`.

Restart policy: the job supervisor is `:transient`. A crashing child must not take down
the VM or the TUI (`PRODUCT.md`: "A hung QEMU or a bad PDF page must not kill the session").

### Events

`Hatch.Events` helper, used by every later spec so nobody re-derives the topic string:

```elixir
@spec topic(String.t()) :: String.t()            # "session:" <> session_id
@spec broadcast(String.t(), map()) :: :ok        # wraps in {:hatch_event, event}, injects :session_id
@spec subscribe(String.t()) :: :ok
```

## Acceptance criteria

1. `mix deps.get && mix compile` succeeds with no warnings (`--warnings-as-errors` in CI
   task if one is added; at minimum, a clean `mix compile`).
2. `mix escript.build` produces `./hatch`.
3. `./hatch` with no arguments exits with status 2 and prints a message naming `--kb`.
   **(I1, V1 acceptance 1.)**
4. `./hatch --kb ./does-not-exist` exits 2. `./hatch --kb .` (no `boards/`) exits 2.
5. With the four required env vars set, `./hatch --kb ./kb` exits 0 and prints the ready
   banner with `boards=1` (the repo's `_example`).
6. `--tree ./nope` exits 2; `--tree .` is accepted.
7. `inspect(config)` does not contain the API key value.
8. `Hatch.BoardJob.start_session/1` returns a session id and pid; killing that pid leaves
   the application running.
9. `Hatch.Events.broadcast/2` reaches a subscriber of the same session and not a
   subscriber of a different session id.

## Test plan

`test/hatch/config_test.exs` — table of argv/env combinations against the error codes
above, env injected via `from_env/2`, no `System.put_env` in tests.
`test/hatch/cli_test.exs` — `Hatch.CLI.main/1` behind a `:no_halt` option or by capturing
`ExUnit.CaptureIO` plus a trapped exit; asserting exit codes is enough, do not shell out.
`test/hatch/events_test.exs` — subscribe/broadcast isolation.

## Constraints

- No HTTP client, no shell-outs, no file writes outside `Mix`'s own.
- Do not add a `config/runtime.exs` layer for things already handled by env (`AGENTS.md`:
  no extra config layers).
