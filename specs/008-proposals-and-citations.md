# 008 — Proposals, patches, citation enforcement

Build-order step 3 (first half). Depends on 007.

Read [`000-overview.md`](000-overview.md) first. Enforces **I5**.

## Goal

The output of a bring-up turn is "a **patch + citation list**, not a merged tree"
(`PRODUCT.md`). This spec defines that object, the `propose_patch` tool that produces it,
and the cheap mechanical check that every address/pin/RAM claim points at a KB file that
was actually read.

## Scope

In: `Hatch.Proposal` (struct + per-session store), `Hatch.Tools.Propose`,
`Hatch.Proposal.Citations`, `Hatch.Proposal.Patch` (validation only).

Out: applying anything (009), rendering (011).

## Design

### `propose_patch` tool

The only way a proposal is created. Schema:

```json
{"name":"propose_patch","description":"Propose a BSP patch for the new board. The human reviews and applies it; you cannot apply it yourself.",
 "parameters":{"type":"object","required":["nearest_board_id","summary","patch","citations"],
  "properties":{
   "nearest_board_id":{"type":"string","description":"id of the KB board this port is derived from"},
   "summary":{"type":"string","description":"what changes and why, 1-5 sentences"},
   "deltas":{"type":"array","items":{"type":"object","required":["field","from","to"],
     "properties":{"field":{"type":"string"},"from":{"type":"string"},"to":{"type":"string"}}}},
   "patch":{"type":"string","description":"unified diff against the working tree, paths relative to the tree root"},
   "citations":{"type":"array","items":{"type":"object","required":["path","claim"],
     "properties":{"path":{"type":"string","description":"KB path you read with kb.read"},
                   "claim":{"type":"string","description":"the specific address, pin, size or name this file supports"}}}}}}}
```

Handling, in order — each failure returns a tool **error** to the model (so it can fix
and retry) and broadcasts `:proposal_invalid`; it never raises and never half-stores:

1. `nearest_board_id` exists in the index → else `:not_found` listing near ids.
2. `patch` parses as a unified diff (below) → else `:invalid_patch` with the offending
   line number.
3. Every diff target path resolves under `tree_root` → else `:outside_sandbox`. **(I2)**
4. Citations check (below) → else `:uncited_claim`.
5. Store as `%Proposal{status: :pending}`, broadcast `:proposal`, and return to the model:
   `"proposal <id> recorded and shown to the operator. It is NOT applied. Wait for the
   operator's decision; do not repeat the patch."`

Only one proposal may be `:pending` per session. A new `propose_patch` while one is
pending supersedes it: the old one becomes `:rejected` with reason `"superseded"` and the
TUI is told. Rationale: two pending patches means two apply keybinds and an operator who
applies the wrong one.

### Patch validation (`Hatch.Proposal.Patch`)

Pure parsing — this module does **not** apply anything.

```elixir
@spec parse(String.t()) :: {:ok, [%{op: :modify | :add | :delete, path: String.t(), hunks: pos_integer()}]} | {:error, err()}
```

- Accept standard unified diff with `--- a/x` / `+++ b/x` headers and `@@` hunks; also
  accept `diff --git` preambles and `new file mode` / `deleted file mode`.
- Reject: absolute paths, `..` segments, `/dev/null` on both sides, rename/copy
  headers (v1 does not need them and they are hard to review), binary patches
  (`GIT binary patch`), and any path under `.git/`.
- Reject a patch larger than 256 KiB or touching more than 50 files (`:patch_too_large`).
  A bring-up delta is small; anything bigger is a runaway.
- Normalise line endings to `\n` and ensure a trailing newline, or `git apply` will
  reject the patch for reasons that have nothing to do with its content.

### Citation check (`Hatch.Proposal.Citations`)

```elixir
@spec check(Proposal.t(), ctx()) :: :ok | {:error, err()}
```

Rules, all mechanical — this is a **cheap** check by design (`AGENTS.md`: "citations
required in the system prompt and checked cheaply (paths must be under KB)"):

1. `citations` is non-empty.
2. Every `path` resolves under `kb_root` (`Hatch.Sandbox.resolve(:kb, _)`) and exists.
3. Every `path` was returned by a successful `kb.read` **in this session** (read-log,
   007). A path the model merely saw in a `kb.search` result is not enough — it must have
   read the file.
4. The patch's added lines are scanned for **claim tokens**: hex literals (`0x[0-9a-f]{3,}`),
   pin/pad identifiers (`~r/\b[A-Z][A-Z0-9_]{3,}\b/` restricted to lines that also match
   pinmux/pad/uart keywords), and RAM/size constants. If the patch contains at least one
   claim token, at least one citation is required — and the union of the citation `claim`
   strings must mention at least one of the tokens found, verbatim. Mismatch →
   `:uncited_claim` naming up to 5 uncited tokens.
5. A patch with no claim tokens at all (a comment, a build tag, a `go.mod` line) still
   needs one citation, but rule 4's token matching is skipped.

Rule 4 is intentionally shallow: it catches the failure that matters — a number appearing
in generated Go that appears nowhere in a file the model read. It is a tripwire, not a
prover. Say so in a comment; do not let a later change try to make it clever.

The error message tells the model exactly how to recover:
`"claim(s) 0x400a8000, UART3_TX appear in the patch but in no cited file. Read the KB file that supports them with kb.read and cite it, or set the field to unknown and say so."`

### Store

`Hatch.Proposal.Store` — ETS table owned by the session's supervisor (survives a session
crash so a pending patch is not lost):

```elixir
@spec put(Proposal.t()) :: :ok
@spec pending(String.t()) :: {:ok, Proposal.t()} | :none
@spec get(String.t(), String.t()) :: {:ok, Proposal.t()} | {:error, :not_found}
@spec set_status(String.t(), String.t(), :applied | :rejected | :invalid, [String.t()]) :: :ok
```

### Prompt obligations (implemented in 006, asserted here)

The system prompt must state: cite a `kb.read` path for every address, pin, size and
peripheral name; `unknown` is an acceptable value and a preferred one to a guess; you
cannot apply patches.

## Acceptance criteria

1. A well-formed proposal citing a file read earlier in the session is stored `:pending`,
   broadcasts `:proposal`, and the model's tool result says it was **not** applied.
2. A proposal whose patch contains `0x400a8000` with no citation containing that token is
   rejected `:uncited_claim`, is **not** stored as pending, and the message names the
   token. **(I5 — the "invent an address from training data" case from `PRODUCT.md`.)**
3. A proposal citing `../../etc/passwd` → `:outside_sandbox`. **(I2)**
4. A proposal citing a KB path that exists but was never `kb.read` in this session →
   `:uncited_claim` with a message saying to read it first.
5. A proposal citing a path seen only in a `kb.search` hit → same rejection.
6. A patch touching `../outside.go` or `/etc/x` or `.git/config` → `:invalid_patch` /
   `:outside_sandbox`; nothing is stored.
7. A binary patch, a rename patch, a 300 KiB patch, a 60-file patch → each rejected with
   its specific code.
8. A second `propose_patch` supersedes the first: first becomes `:rejected` reason
   `"superseded"`, only one `:pending` remains.
9. Patch parsing accepts a real `git diff` of a Go file including `diff --git` and a new
   file; round-trips path lists correctly.
10. Nothing in this spec applies, writes or mutates the working tree — assert the tree's
    mtime set is unchanged after a full proposal cycle. **(I4)**

## Test plan

`test/hatch/proposal/citations_test.exs` with a table of patch/citation combinations
including the `PRODUCT.md` failure case verbatim (`0x400A8000` invented).
`test/hatch/proposal/patch_test.exs` with real `git diff` output fixtures under
`test/fixtures/patches/`.
`test/hatch/tools/propose_test.exs` driving the tool through `Hatch.Tools.call/3`.

## Constraints

- The check is a tripwire, not a verifier. Do not add an LLM-based citation judge, do not
  fetch anything, do not parse Go.
- The model never learns the absolute path of anything, including in rejection messages.
