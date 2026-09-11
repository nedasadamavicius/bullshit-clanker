# Implementing BC

You are building BC. Read `PRODUCT.md` first. If a change fights that document, the document wins unless a human updates it.

## What this is

Elixir TUI. AI-assisted TamaGo bring-up. Closed-world KB. Human applies patches.

## Hard rules

- Do not add `web_fetch`, HTTP tools, MCP, plugins, or unrestricted `bash`.
- Do not start the app without a KB path.
- Tools may only read under `--kb` and `--tree`. Writes to the tree go through `ws.apply`, which the TUI gates on an explicit human accept.
- Do not have the model apply patches autonomously.
- Do not replace `board.toml` search with embeddings over PDFs.
- Ingest emits structured records (`board.toml` / `nets.json` fields). Not prose summaries.
- One session process talks to the user. Fan-out is for ingest/search/build only.
- SoC/board packages are Go in the working tree. Elixir does not generate firmware by string-concatenating drivers in Mix modules.
- `tamago-go` / QEMU are ports with timeouts, not in-process.

## Stack

- Language: Elixir. OTP for session, ingest pool, build worker, PubSub to the TUI.
- TUI: pick one (Owl, Ratatouille, or raw ANSI) and stay there for v1.
- Models: OpenAI-compatible HTTP. No vendor SDK lock-in. Config via env.
- Index: sqlite from `board.toml`. ETS cache is fine.

## v1 order

1. Mix app + TUI chat, no tools.
2. `kb.search` / `kb.read`.
3. Patch pane + gated `ws.apply`.
4. `tamago.build`.
5. Held-out same-SoC board test (`PRODUCT.md` “V1 acceptance”). Stop expanding until that passes.

## Style

- Small modules. One OTP responsibility per process.
- Comments only for non-obvious constraints (sandbox paths, citation checks).
- No extra features, extra docs, or extra config layers beyond `PRODUCT.md` v1.

## MVP handoff (2026-09-11)

v1 specs 001–013 and the PDF ingest/TUI usability fixes are in.

**Run:** `mix bc --kb ./kb`. It compiles automatically. `mix compile` builds only.
The escript currently cannot load SQLite's native library; use the Mix launcher.
Terminal input has been checked on Linux (`stty` and `/proc` are used).

**PDF ingest:** `mix bc.kb.ingest /path/to/file.pdf --kb ./kb` (a directory also works).
Requires `pdftotext`. Writes structured records and reports unknown fields and conflicts.
Existing boards require `--force` to overwrite. Missing facts must remain unknown.

**Credentials:** copy `config/secrets.env.example` to gitignored `config/secrets.env`.
Default provider is Claude via API. Do not commit keys. Subscription/Claude Code support
was discussed but is not implemented; the current model backend remains HTTP.

**Mix task modules must be `Mix.Tasks.Bc.*`**, not `Mix.Tasks.BC.*`.

**Req 0.7:** `connect_options: [timeout: 10_000]` and `receive_timeout:`.
Streaming `into:` receives `{:data, data}, {req, resp}`; SSE state lives in an Agent.
The HTTP client maps dotted BC tool names to API-safe names in schemas and history,
and restores internal names on returned tool calls.

**Known limits:** live K1 ingest produced a thin record with unknown SoC/RAM/pinmux.
Do not fill these from model memory. K1 has no same-SoC TamaGo package in the KB.
Offline acceptance uses a fake model and toolchain; it is not proof of live bring-up.
