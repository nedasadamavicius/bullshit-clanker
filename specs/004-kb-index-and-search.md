# 004 — KB index and structured search

Build-order step 2 (second half). Depends on 003.

Read [`000-overview.md`](000-overview.md) first.

## Goal

`PRODUCT.md`: "Search is structured: same `soc`, then overlap on UART / PHY / flash /
peripherals. Cosine similarity over a datasheet is how you put a Pi UART on an i.MX8."
This spec is the matcher, and the thing that makes matches explainable.

## Scope

In: `BC.KB.Index` (GenServer owning sqlite + ETS), `BC.KB.Search` (ranking),
`BC.KB.Delta` (field-by-field comparison).

Out: the `kb.search` tool wrapper (007), embeddings (never).

## Design

Add dep `{:exqlite, "~> 0.23"}`.

### `BC.KB.Index`

Started by `BC.Application` after config is available.

```elixir
@spec ensure_built() :: {:ok, %{boards: non_neg_integer(), rebuilt: boolean()}} | {:error, err()}
@spec all() :: [Board.t()]
@spec get(String.t()) :: {:ok, Board.t()} | {:error, :not_found}
@spec fts(String.t(), pos_integer()) :: [String.t()]   # board ids, best first
@spec reload() :: {:ok, map()}
```

- On start: `BC.KB.Loader.load_all/1`, write records into ETS table `:bc_kb`
  (`:named_table, :protected, read_concurrency: true`), keyed by board id. Reads go
  straight to ETS from the caller's process — the GenServer is the writer only.
- Persist to `<kb_root>/index.sqlite`:

```sql
CREATE TABLE boards (
  id TEXT PRIMARY KEY, source_path TEXT NOT NULL, soc TEXT, soc_key TEXT,
  goarch TEXT, goarm TEXT, ram_start INTEGER, ram_size INTEGER, uart TEXT,
  tamago_soc TEXT, tamago_board TEXT, tree TEXT, schematic TEXT, notes TEXT,
  sha256 TEXT NOT NULL, json TEXT NOT NULL);
CREATE TABLE peripherals (board_id TEXT NOT NULL, name TEXT NOT NULL);
CREATE TABLE pinmux (board_id TEXT NOT NULL, signal TEXT, pad TEXT, fn TEXT);
CREATE VIRTUAL TABLE boards_fts USING fts5(id, soc, uart, peripherals, notes, content='');
CREATE TABLE meta (k TEXT PRIMARY KEY, v TEXT);   -- schema_version, built_at
```

- Rebuild rule: compare each `board.toml`'s sha256 against `boards.sha256`; rebuild the
  whole file if any differ, if the set of ids differs, or if `meta.schema_version` differs
  from the compiled-in constant. The index is a **cache** — deleting `index.sqlite` must
  change nothing but startup time, and that is an acceptance criterion.
- Rebuild is transactional (single `BEGIN`/`COMMIT`) so a crash mid-build cannot leave a
  half index that then looks fresh.
- If sqlite cannot be opened (read-only KB, for instance), log one warning and continue
  **with ETS only**. Search must not depend on the file existing; only `fts/2` degrades,
  falling back to a case-insensitive substring scan over the same fields.
- Load warnings from 003 are kept and exposed as `warnings/0` for the TUI to show once at
  startup.

### `BC.KB.Search`

```elixir
@type query :: %{
  optional(:soc) => String.t(),
  optional(:goarch) => String.t(),
  optional(:uart) => String.t(),
  optional(:peripherals) => [String.t()],
  optional(:text) => String.t(),
  optional(:exclude) => [String.t()],     # board ids, for held-out tests
  optional(:limit) => pos_integer()       # default 5, max 20
}

@spec search(query()) :: {:ok, [Hit.t()]} | {:error, err()}
@spec from_board(Board.t(), keyword()) :: {:ok, [Hit.t()]}   # "nearest to this draft"
```

**Gating, before scoring.** If `:soc` is given:

1. Candidates are boards with an equal `soc_key` → `soc_match: :exact`.
2. If none, candidates are boards whose `soc_key` shares a family prefix with the query
   (longest common alphabetic-then-digit prefix of at least 4 characters, e.g. `imx6ul`
   vs `imx6ull`) → `soc_match: :family`, and every such hit carries the `why` entry
   `"different soc (imx6ull vs imx6ul) — verify every register"`.
3. If still none → `{:ok, []}`. **Never fall through to unrelated boards.** An empty
   result is the correct answer to "brand new SoC" (`PRODUCT.md` non-goal) and the
   session must report it as such.

If `:soc` is absent, all boards are candidates and no hit may claim `soc_match: :exact`.

**Scoring** over candidates, deterministic, no floats beyond one decimal in output:

| Contribution | Points |
|---|---|
| `soc_match == :exact` | 10.0 |
| `soc_match == :family` | 4.0 |
| same `uart` (case-insensitive) | 3.0 |
| peripheral Jaccard `|A∩B| / |A∪B|` | × 5.0 |
| each of `eth`/`phy`, `usb`, `flash`/`qspi`/`usdhc`/`nand` present in both | +0.5 each (capped 2.0) |
| same `goarch` | 1.0 |
| same `goarm` | 0.5 |
| board has a `tree` that exists | 1.0 |
| FTS/text hit | 1.0 |
| `ram_size` equal | 1.0 |

Ties break on board id ascending, so results are reproducible.

Each hit's `why` is a human-readable list of the contributions that fired, in descending
point order — this is the material the session turns into "nearest board + deltas", and
the operator's audit trail for a match. A contribution that did not fire is never listed.
`why` must also list what is **unknown on both sides** (e.g. `"pinmux unknown on both"`),
because an unknown is the operator's cue to go read the schematic.

### `BC.KB.Delta`

```elixir
@spec compare(Board.t(), Board.t()) :: [Delta.t()]   # draft, kb board
```

Compares `soc, goarch, goarm, ram_start, ram_size, uart, peripherals, pinmux, tamago_soc,
tamago_board` and classifies each as `:same | :differs | :unknown_in_draft | :unknown_in_kb`.
Peripherals differ as added/removed sets; pinmux differs per `signal`.
Ordering is fixed (the list above), so a diff of two diffs is meaningful.

`@spec render([Delta.t()]) :: String.t()` produces the table the session and TUI show;
`:unknown_*` rows render as `unknown` and are never omitted — a silently dropped unknown
is how a pin gets invented.

## Acceptance criteria

Fixture KB: 3 boards on `imx6ul`, 1 on `imx6ull`, 1 on `imx8m`.

1. `search(%{soc: "imx6ul"})` returns only the three `imx6ul` boards, all
   `soc_match: :exact`, ordered by score, `limit` respected.
2. `search(%{soc: "i.MX6UL"})` returns the same set (normalisation via `soc_key`).
3. `search(%{soc: "imx6ull"})` with no exact match returns the `imx6ul` boards as
   `soc_match: :family`, each carrying the "different soc" warning in `why`.
4. `search(%{soc: "stm32h7"})` returns `{:ok, []}` — no i.MX board leaks in. **(matcher
   invariant; this is the test that stops a Pi UART landing on an i.MX8.)**
5. Scores are deterministic across runs and across index rebuilds; two runs produce
   identical ordering including ties.
6. `why` for the top hit lists same-soc, same-uart and the peripheral overlap with
   counts, and lists at least one "unknown on both" entry when the fixture has one.
7. `exclude: ["held-out"]` removes that board from candidates (used by spec 013).
8. Deleting `index.sqlite` and restarting produces identical search results; the file is
   recreated.
9. Touching one `board.toml` triggers exactly one rebuild on `ensure_built/0`; touching
   nothing triggers none (assert via `rebuilt: false`).
10. With the KB directory made read-only, the index starts, warns once, and search still
    works. **(A KB on a read-only mount is a normal way to run this.)**
11. `Delta.compare/2` of a draft with `uart: :unknown` against a board with `uart: "UART2"`
    yields `kind: :unknown_in_draft` — not `:differs`, and not a silent match.

## Test plan

`test/bc/kb/search_test.exs` (ranking table, gating, determinism),
`test/bc/kb/index_test.exs` (rebuild detection, sqlite absence, read-only KB),
`test/bc/kb/delta_test.exs`. Fixtures under `test/fixtures/kb_imx/`.

## Constraints

- No embeddings, no vector store, no cosine similarity anywhere in this module or its
  tests. (`AGENTS.md` hard rule.)
- No network. No model call — ranking is arithmetic the operator can re-derive by hand.
- The index is generated; it is never the source of truth. `board.toml` is.
