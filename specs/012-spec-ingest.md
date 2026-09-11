# 012 — Spec ingest (new board draft)

Build-order step 2/5 boundary. Depends on 003 and 005.

Read [`000-overview.md`](000-overview.md) first. Enforces **I6**, **I7**.

## Goal

The first arrow of the core loop: `new board spec → structured extract (SoC, RAM, UART,
PHY, pinmux, citations)`. Turn what the operator pastes or attaches into a `%Board{}`
draft with `unknown` where the document is silent.

`PRODUCT.md`: "Ingest workers emit **records**, not summaries. Summaries drop addresses."

## Scope

In: `Hatch.Ingest` (API), `Hatch.Ingest.Worker` (bounded fan-out), the extraction prompt,
the draft-to-session handoff, `hatch` CLI flag for attaching a spec file.

Out: PDF/schematic ingest into `nets.json` — explicitly deferred until after the V1
acceptance test passes (`AGENTS.md` v1 order step 5). `nets.json` is *read* by 003; this
spec does not generate it.

## Design

### Entry points

1. `--spec PATH` on the CLI (a markdown file or a `board.toml` draft), read through
   `Hatch.Sandbox`-equivalent checks — a spec file may live outside the KB, so it is
   opened directly by the operator's own path, read once at startup, and never re-read.
   This is operator input, not a model-reachable path: no tool can read it again.
2. Pasting text into the TUI prefixed with a `/spec` command line, which sends the buffer
   to ingest instead of to the session.

### Two paths, chosen by content

- **If the input parses as TOML with an `id` or `soc` key** → `Hatch.KB.Loader` semantics
  directly (003). No model call. A `board.toml` draft is already a record; running it
  through an LLM can only lose information.
- **Otherwise (markdown, datasheet excerpt, notes)** → model extraction below.

### Model extraction

Uses `config.ingest_model` (cheap slot) via the 005 client, `temperature: 0`.

- The document is split into chunks of ≤ 6 000 characters on paragraph boundaries with a
  200-character overlap.
- Chunks are processed with `Task.async_stream(..., max_concurrency: 4, timeout: 60_000,
  on_timeout: :kill_task)` under the board job's `Task.Supervisor`. Fan-out here is
  sanctioned (I7: "Fan-out is for ingest/search/build only"); the cap is because the
  budget is dollars and wall-clock, not process count.
- Each worker is asked for **one JSON object** with the `board.toml` field names from 003,
  plus, for every field it fills, a `evidence` string: the verbatim substring of the chunk
  the value came from. A field with no verbatim support must be omitted.
- The extraction prompt states: omit what is not in this text; never infer a register
  address, RAM size or pad name from knowledge of the SoC; `peripherals` only when the
  document names them.
- No tools are offered to the ingest model. It gets text and returns JSON.

### Merge

`Hatch.Ingest.Merge.merge([chunk_result]) :: {Board.t(), [conflict()]}`

- Scalar fields: first non-conflicting value wins; **two different values for the same
  field is a conflict** → the field becomes `:unknown` and the conflict is reported with
  both values and both evidence strings. Silently picking one is how a wrong RAM size
  gets into a patch.
- `peripherals`: union.
- `pinmux`: union keyed by `signal`; conflicting `pad`/`fn` for one signal → that row is
  dropped into conflicts, not merged.
- Hex strings are parsed by 003's parser; unparseable → `:unknown` + conflict.
- Everything not extracted stays `:unknown`. **(I6)**

The result is `{%Board{id: <from --spec filename or operator-supplied>, ...}, conflicts}`.

### Handoff

`Hatch.Session.set_draft/2` stores it; the system prompt (006) renders it with
`Board.to_facts/1`. Conflicts are shown in the TUI as warnings and are included in the
prompt as an explicit list: the model must treat a conflicted field as `unknown` and say
so rather than resolve it.

Optionally `hatch` writes the draft to `<kb>/boards/<id>/board.toml` — **only** on an
explicit operator action (a `/save-draft` command), never automatically. The KB has one
writer and it is the human (`PRODUCT.md`).

## Acceptance criteria

1. A `board.toml` draft input produces a `%Board{}` with **zero model calls** (assert the
   fake client received nothing).
2. A markdown spec naming `i.MX6UL`, `0x80000000` RAM start, `UART2` produces those three
   fields; every field the document does not mention is `:unknown`. **(I6)**
3. Every extracted field's `evidence` substring is present verbatim in the source chunk;
   a fabricated evidence string causes the field to be dropped (assert with a scripted
   fake that returns unsupported evidence).
4. Two chunks giving different `ram_size` → the field is `:unknown` and a conflict lists
   both values with their evidence. **(the merge rule that matters)**
5. Pinmux rows merge by signal; a conflicting row is reported, not merged.
6. Concurrency is capped at 4 and a hanging chunk is killed at 60 s without failing the
   whole ingest (the remaining chunks' results are used, the killed one is a conflict
   entry). **(`PRODUCT.md`: "a bad PDF page must not kill the session")**
7. A 200-page document does not exceed the concurrency cap (assert max observed
   in-flight).
8. The ingest model is given no tools (assert what `Fake` received).
9. The draft reaches the session and appears in the system prompt with `unknown`s intact.
10. Ingest never writes to the KB; `/save-draft` writes exactly one file and only when
    invoked.
11. No PDF is opened anywhere in this spec's code path. A `--spec foo.pdf` is refused with
    "schematics are ingested offline; v1 takes markdown or board.toml".

## Test plan

`test/hatch/ingest_test.exs` with scripted `Hatch.Model.Fake` responses per chunk,
including a conflicting pair, a fabricated-evidence case and a hanging chunk.
`test/hatch/ingest/merge_test.exs` as a pure table test.

## Constraints

- Records, not prose. There is no "summary" field anywhere in this pipeline, and no path
  by which chunk text reaches the session model as prose. **(`PRODUCT.md` failure mode:
  "Summarizing schematics into prose for the session".)**
- No OCR, no PDF library, no embeddings.
- The ingest model never sees the KB and never sees tools; it reads the operator's
  document and emits fields.
