# 000 — Shared contracts

Read this before implementing any numbered spec. It fixes the names, shapes and
dependencies that specs share, so parallel branches do not collide.

Nothing here is a feature on its own. Do not implement this file; implement 001–013.

---

## 1. Product constraints that are load-bearing in code

From `AGENTS.md`, restated as testable invariants. Every spec that can violate one names
it in its acceptance criteria.

| # | Invariant | Enforced in |
|---|---|---|
| I1 | The process does not start without a KB path. | 001 |
| I2 | No tool can read outside `kb_root` or `tree_root`. Symlinks out are denied. | 002, 007 |
| I3 | No HTTP is performed except to the configured model API base. No `web_fetch`, no MCP, no unrestricted shell. | 005, 007 |
| I4 | The model cannot write. The only write to the tree is `Hatch.Patch.Apply`, and it requires a permit minted by a human keypress. | 009, 011 |
| I5 | Every MMIO / pin / RAM claim in a proposal cites a KB path that was actually read this session. | 008 |
| I6 | Unknown is a valid value. Absent `board.toml` fields load as `:unknown` and are never filled by the model. | 003, 012 |
| I7 | One session process talks to the user. Fan-out is ingest/search/build only. | 006, 012 |
| I8 | External programs (`tamago-go`, `git`, QEMU later) run as ports with timeouts, never in-process, never with a shell. | 009, 010 |

## 2. Design decisions made here (deviations flagged)

1. **`ws.apply` is not in the model's tool list.** `PRODUCT.md`'s tool table lists it;
   the same document also says "Apply is a keybind, not a tool the model can fire on its
   own" and "Write permit lives in the TUI". The two are reconciled by exposing
   `propose_patch` to the model and keeping `ws.apply` as an internal operation the TUI
   invokes on human accept (spec 009). The name `ws.apply` is kept for the operation and
   for the event stream.
2. **TUI library: Ratatouille.** Picked once, per `AGENTS.md` "pick one and do not shop".
   It gives the four panes and the modal keybinds v1 needs. If `ex_termbox` will not
   build on the target OTP, fall back to raw ANSI behind the same `Hatch.TUI` boundary —
   that is the only sanctioned substitution, and it changes no other spec.
3. **Search ranks in Elixir over ETS; SQLite is the persisted index.** `PRODUCT.md` says
   "sqlite + ETS". v1 KBs are tens of boards, so ranking is a fold over records; SQLite
   holds the generated index (and FTS5 for the optional `text` filter) so it is
   reproducible and inspectable outside the app.
4. **Patches are unified diffs applied with `git apply`.** The working tree is a TamaGo
   checkout or overlay, i.e. a git repo. `git apply` is run as an argv port in
   `tree_root` (I8) — not a shell, not a hand-written patch parser.
5. **No Ecto, no Phoenix (web).** `phoenix_pubsub` is used as a plain library.

## 3. Dependencies

`mix.exs` deps for the whole v1. A spec adds only the lines it needs; nobody changes a
version another spec pinned.

```elixir
{:toml, "~> 0.7"},              # board.toml            (003)
{:exqlite, "~> 0.23"},          # index.sqlite          (004)
{:req, "~> 0.5"},               # model HTTP + SSE      (005)
{:jason, "~> 1.4"},             # tool args / results   (005, 007)
{:phoenix_pubsub, "~> 2.1"},    # session -> TUI        (001)
{:ratatouille, "~> 0.5"}        # TUI                   (011)
```

Test-only: none. Test doubles are behaviour implementations selected through
`Application.get_env/3` (section 7), not a mocking library.

## 4. Module map

One OTP responsibility per process (`AGENTS.md` "Style").

```
Hatch.Application            supervisor: PubSub, KB.Index, BoardJob.Supervisor
Hatch.CLI                    argv parsing, refuses without --kb          (001)
Hatch.Config                 %Config{} struct, env resolution            (001)
Hatch.Sandbox                path confinement                            (002)

Hatch.KB.Board               %Board{} struct + :unknown semantics        (003)
Hatch.KB.Loader              boards/<id>/board.toml -> %Board{}          (003)
Hatch.KB.Index               GenServer: sqlite + ETS, rebuild on change  (004)
Hatch.KB.Search              ranking, %Hit{}                             (004)
Hatch.KB.Delta               draft vs board field deltas                 (004)

Hatch.Model                  behaviour: chat/3                           (005)
Hatch.Model.OpenAI           Req + SSE + tool-call assembly              (005)

Hatch.BoardJob.Supervisor    one supervision tree per session            (001)
Hatch.Session                GenServer: transcript, tool loop            (006)
Hatch.Session.Prompt         system prompt, closed-world rules           (006)
Hatch.Session.Transcript     message list, token-bounded                 (006)

Hatch.Tools                  registry, JSON schemas, dispatch            (007)
Hatch.Tools.KB               kb.search, kb.read                          (007)
Hatch.Tools.WS               ws.read, ws.list, ws.diff                   (007)
Hatch.Tools.Propose          propose_patch                               (008)

Hatch.Proposal               %Proposal{}, store, validation              (008)
Hatch.Proposal.Citations     citation check against read-log             (008)
Hatch.Permit                 single-use write permit                     (009)
Hatch.Patch.Apply            git apply port                              (009)

Hatch.Build.Worker           GenServer: tamago-go port, 1 at a time      (010)
Hatch.TUI                    Ratatouille app + runtime wiring            (011)
Hatch.TUI.Model              pure state + update/2 (this is what is tested) (011)
Hatch.Ingest                 spec text -> %Board{} draft                 (012)
```

## 5. Core structs

Defined by the spec in brackets; other specs only read them.

```elixir
# [001]
%Hatch.Config{
  kb_root: Path.t(),            # absolute, required
  tree_root: Path.t() | nil,    # absolute
  model: String.t(),            # HATCH_MODEL
  ingest_model: String.t(),     # HATCH_MODEL_INGEST, defaults to model
  build_model: String.t() | nil,# HATCH_MODEL_BUILD
  api_base: String.t(),         # HATCH_API_BASE
  api_key: String.t(),          # HATCH_API_KEY
  tamago_go: String.t(),        # HATCH_TAMAGO_GO, default "tamago-go"
  build_timeout_ms: pos_integer # HATCH_BUILD_TIMEOUT_MS, default 120_000
}

# [003] every field may be :unknown except id and source_path
%Hatch.KB.Board{
  id: String.t(),
  source_path: Path.t(),        # kb-relative, e.g. "boards/mk2/board.toml"
  soc: String.t() | :unknown,
  goarch: String.t() | :unknown,
  goarm: String.t() | :unknown,
  ram_start: non_neg_integer() | :unknown,   # parsed from "0x..."
  ram_size: non_neg_integer() | :unknown,
  uart: String.t() | :unknown,
  peripherals: [String.t()],                  # [] means unknown
  pinmux: [%{signal: String.t(), pad: String.t(), fn: String.t()}],
  tamago_soc: String.t() | :unknown,
  tamago_board: String.t() | :unknown,
  schematic: Path.t() | :unknown,             # kb-relative
  tree: Path.t() | :unknown,                  # kb-relative
  notes: String.t() | :unknown,
  raw: map()                                  # decoded toml, verbatim
}

# [004]
%Hatch.KB.Hit{
  board: %Hatch.KB.Board{},
  score: float(),
  soc_match: :exact | :family,
  why: [String.t()]             # "same soc imx6ul", "uart UART2", "4/5 peripherals"
}

# [004]
%Hatch.KB.Delta{field: atom(), draft: term(), board: term(), kind: :same | :differs | :unknown_in_draft | :unknown_in_kb}

# [008]
%Hatch.Proposal{
  id: String.t(),               # "p_" <> 8 hex
  session_id: String.t(),
  nearest_board_id: String.t(),
  summary: String.t(),
  deltas: [%Hatch.KB.Delta{}],
  citations: [%{path: String.t(), claim: String.t()}],
  patch: String.t(),            # unified diff
  status: :pending | :applied | :rejected | :invalid,
  invalid_reasons: [String.t()],
  created_at: DateTime.t()
}
```

## 6. Event contract

`Phoenix.PubSub` named `Hatch.PubSub`. Topic: `"session:" <> session_id`.
Every message is `{:hatch_event, event}` where `event` is a map with `:type` and
`:session_id`. Producers may add fields; consumers must ignore unknown ones.

| `:type` | Fields | Producer |
|---|---|---|
| `:user_message` | `text` | 006 |
| `:assistant_delta` | `text` | 006 |
| `:assistant_message` | `text` | 006 |
| `:tool_call_started` | `call_id, name, args` | 006 |
| `:tool_call_finished` | `call_id, name, ok, summary, duration_ms` | 006 |
| `:proposal` | `proposal_id, nearest_board_id, summary, citations, deltas, patch` | 008 |
| `:proposal_invalid` | `proposal_id, reasons` | 008 |
| `:apply_result` | `proposal_id, ok, output` | 009 |
| `:build_started` | `build_id, argv` | 010 |
| `:build_log` | `build_id, chunk` | 010 |
| `:build_finished` | `build_id, exit_status, duration_ms, timed_out` | 010 |
| `:turn_finished` | `reason` (`:ok \| :max_steps \| :error`) | 006 |
| `:error` | `stage, message` | any |

## 7. Test seams

No mocking library. Each external boundary is a behaviour whose implementation is read
from application env at call time:

```elixir
Application.get_env(:hatch, :model_client, Hatch.Model.OpenAI)   # 005
Application.get_env(:hatch, :patch_applier, Hatch.Patch.Apply)   # 009
Application.get_env(:hatch, :builder, Hatch.Build.Worker)        # 010
```

Tests set these in `test/support/`. Production config never sets them.

## 8. Errors

Tool and operation results are `{:ok, term}` or `{:error, %{code: atom, message: String.t()}}`.
Codes used across specs: `:not_found`, `:outside_sandbox`, `:binary_file`, `:too_large`,
`:invalid_args`, `:no_tree`, `:busy`, `:timeout`, `:upstream`, `:no_permit`,
`:uncited_claim`, `:patch_conflict`.

An `{:error, _}` from a tool is serialised to the model as a JSON tool result
`{"error": {"code": "...", "message": "..."}}` — never as a crash, never as an empty
result. The model is allowed to see its own mistakes and retry.

## 9. Style

`AGENTS.md`: small modules, one OTP responsibility per process, comments only for
non-obvious constraints (sandbox paths, citation checks), no config layers beyond
`PRODUCT.md` v1. `mix format` with the default `.formatter.exs`. Public functions on
modules listed in section 4 carry `@spec`.
