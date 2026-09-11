# 003 — Board records: schema, loader, validation

Build-order step 2 (first half).

Read [`000-overview.md`](000-overview.md) first. Enforces **I6** (unknown is a value).

## Goal

Turn `kb/boards/<id>/board.toml` into a `%BC.KB.Board{}` with typed fields, where
absent means `:unknown` and never means "guess". Plus a `bc kb lint`-style validation
pass the operator can run before trusting a KB.

## Scope

In: `BC.KB.Board` struct, `BC.KB.Loader`, `BC.KB.Nets` (nets.json reader),
validation and the `mix bc.kb.lint` task.

Out: indexing and search (004), ingest from a spec document (012).

## Design

Add dep `{:toml, "~> 0.7"}`.

### `BC.KB.Board`

Struct exactly as in overview §5. Helpers:

```elixir
@spec known?(term()) :: boolean()            # false for :unknown and []
@spec fetch(t(), atom()) :: {:ok, term()} | :unknown
@spec to_facts(t()) :: String.t()            # deterministic, model-facing rendering
```

`to_facts/1` renders the record as a compact key/value block with `unknown` spelled out
for missing fields — the model must *see* that a field is unknown rather than see it
absent, or it will fill the gap from training data. Hex numbers render as `0x...` with
the original casing normalised to lowercase digits.

### `BC.KB.Loader`

```elixir
@spec load_all(Path.t()) :: {:ok, [Board.t()], [warning()]} | {:error, err()}
@spec load(Path.t()) :: {:ok, Board.t(), [warning()]} | {:error, err()}
@type warning :: %{board_id: String.t(), field: atom(), message: String.t()}
```

- `load_all/1` globs `<kb>/boards/*/board.toml`, skipping directories whose name starts
  with `_` (so `_example/` is a template, not a board — the repo's example must not
  pollute a real search).
- Every file is parsed with `Toml.decode/2`. A parse error is a **warning plus a skipped
  board**, never a crash of the whole load: one bad file must not blind the operator to
  the rest of the KB. It is an error only if *every* board fails.
- `id`: taken from the file's `id` key; if absent, from the directory name. If both exist
  and disagree → warning, directory name wins (the path is what citations quote).
- `ram_start` / `ram_size`: accept `"0x..."`, `"0X..."`, decimal strings and integers.
  Unparseable → `:unknown` + warning. Never coerce a bad value to 0.
- `goarch`: must be one of `arm`, `arm64`, `riscv64` (TamaGo's targets) → otherwise
  `:unknown` + warning. `goarm`: `"5".."7"` as string.
- `peripherals`: list of strings, downcased, trimmed, deduped, sorted. Non-list → `[]` +
  warning.
- `pinmux`: list of tables each with `signal`, `pad`, `fn` (all required; a row missing
  one is dropped with a warning). A **string** value for `pinmux` is treated as a
  KB-relative path to a pinmux table file and is *not* followed here — stored as-is in
  `raw` and surfaced as a warning "pinmux table files are not supported in v1".
- `soc`, `uart`: trimmed; `soc` also normalised with `normalize_soc/1` (downcase, strip
  `-`/`_`/spaces) into a separate `soc_key` used by search. Keep the original in `soc`
  for display; put `soc_key` on the struct.
- `schematic`, `tree`: kept as KB-relative paths, **validated through `BC.Sandbox.resolve(:kb, _)`**
  and warned (not failed) if they do not exist.
- Unknown top-level keys are preserved in `raw` and produce one warning each, so the
  operator learns about typos like `ram_base` instead of silently losing the field.

### `BC.KB.Nets`

```elixir
@spec load(Path.t()) :: {:ok, %{nets: [net()], source: String.t()}} | {:error, err()}
@type net :: %{name: String.t(), pins: [%{ref: String.t(), pin: String.t()}], value: String.t() | :unknown}
```

`nets.json` is optional. Schema is minimal on purpose: a name, the pins it touches, an
optional value. Anything else in the file is preserved untouched under `:extra`.
Missing file → `{:error, :not_found}`, which callers treat as "no netlist", not a failure.

### `mix bc.kb.lint`

`mix bc.kb.lint --kb ./kb` prints, per board: id, soc, and every warning; then a
summary line `N boards, M warnings`. Exit 1 if any board failed to parse, 0 otherwise
(warnings do not fail — an incomplete KB is normal, `unknown` is legal).

## Acceptance criteria

1. The repo's `kb/boards/_example/board.toml` is **excluded** from `load_all/1`.
2. A board.toml with only `id` and `soc` loads, with every other field `:unknown` /
   `[]`, and produces no error. **(I6)**
3. `ram_start = "0x80000000"` → `2147483648`. `ram_start = "eighty"` → `:unknown` plus a
   warning naming the field. No field is ever defaulted to a plausible value.
4. Two boards, one with malformed TOML: `load_all/1` returns the good board and a warning
   for the bad one, not an error.
5. `peripherals = ["USB", "usb", " gpio "]` → `["gpio", "usb"]`.
6. A `[[pinmux]]` row missing `fn` is dropped with a warning; well-formed rows survive in
   order.
7. `soc = "i.MX6UL"` and `soc = "imx6ul"` produce the same `soc_key`.
8. `schematic = "nope.pdf"` loads with a warning and does not raise; a `schematic` that
   escapes the KB (`"../../x.pdf"`) is `:unknown` plus a warning. **(I2)**
9. `to_facts/1` output contains the literal word `unknown` for every absent field and is
   byte-identical across runs for the same input.
10. `mix bc.kb.lint --kb ./kb` runs against the repo KB and exits 0.

## Test plan

`test/bc/kb/loader_test.exs` with fixture KBs under `test/fixtures/kb_*/`. At least
one fixture is deliberately broken (bad TOML, bad hex, escaping paths, unknown keys).
`test/bc/kb/board_test.exs` for `to_facts/1` determinism (compare two calls and a
golden string).

## Constraints

- The loader never writes. Nothing here mutates the KB.
- No inference. If the SoC is absent, it is `:unknown`, even when `tamago_soc` would
  imply it — record what the operator wrote. (Cross-field *suggestions* belong in lint
  warnings, not in the record.)
