# Hatch

Working name. Rename when it bothers you.

A TUI for **AI-assisted TamaGo board bring-up**, closed against a spec knowledge base you own.

Not a general coding agent. Not a Linux distro porter. Not autopilot firmware.

---

## One sentence

You give Hatch a new board spec and a knowledge base of known boards. It matches the new board against that KB, cites the nearest TamaGo trees, and proposes a BSP diff. You apply it.

## Problem

TamaGo bring-up is analogical: copy the nearest `soc/` + `board/` package, change RAM map, UART, pinmux, PHY, link flags (`-T`, `-R`). The knowledge lives in schematics, datasheets, and existing trees. A general clanker will invent `0x400A8000` from training data and brick the board. A human without a copilot greps three repos and a 40-page PDF.

The missing tool is a copilot that **may only know what is in the KB**, and a human who is the only writer.

## Product

OpenCode’s loop, one job, one data source.

| Keep from OpenCode | Throw away | Add |
|---|---|---|
| Session + streaming chat in a TUI | Web, MCP, plugins, generic bash | Board record as the unit of knowledge |
| Tool calls | Search the internet / the whole disk | `kb.search` / `kb.read` only |
| Model-agnostic API | Autopilot merge | Patch + citations, human apply |
| Permission on writes | Skills, LSP, desktop | `tamago build` as eval |

Hatch refuses to start without a KB path. Tools that can leave that path do not exist.

---

## Who it is for

Two people bringing up TamaGo boards who already have (or will build) a library of schematics and known-good trees. The operator knows enough to accept or reject a pinmux diff. The model does the matching and the first patch.

## Non-goals (v1)

- New SoC packages from a datasheet with nothing in the KB
- Linux / Yocto / Buildroot
- Fully autonomous apply-and-flash
- MCP, plugins, marketplace
- Schematic PDF OCR as the online path (ingest offline into records)
- Parallel “summarizer agents” that pass prose to the session
- Feature parity with OpenCode

A brand-new SoC with no package in the KB is out of scope. That is writing a silicon manual in Go. Hatch’s job is **same SoC, new board** (or a close variant).

---

## Core loop

```
new board spec
  → structured extract (SoC, RAM, UART, PHY, pinmux, citations)
  → kb.search (same SoC, closest peripheral set — not embedding-over-PDF)
  → session proposes: nearest board, deltas, patch against that tree
  → human accept / reject / edit
  → tamago build (and later UART/QEMU)
  → fail closed or done
```

Ingest and search may fan out. **One session** talks to the user. **The human** is the only writer of `soc/` and `board/`.

## Knowledge base

Not a folder of PDFs in a vector store. Each board is a record plus files.

```
kb/
  boards/
    <id>/
      board.toml      # structured facts (source of truth for search)
      nets.json       # optional; ingested from schematic
      schematic.pdf   # optional; not queried live
      tree/           # known-good TamaGo overlay, or a pointer to one
  index.sqlite        # generated from board.toml
```

`board.toml` fields (v1):

- `id`, `soc`, `goarch`, `goarm` (if any)
- `ram_start`, `ram_size`
- `uart`
- `peripherals` (list)
- `pinmux` (list of `{signal, pad, fn}` or a path to a table)
- `schematic`, `tree` (paths)
- `tamago_board`, `tamago_soc` (import paths)
- `notes` (human; never a substitute for fields)

Search is structured: same `soc`, then overlap on UART / PHY / flash / peripherals. Cosine similarity over a datasheet is how you put a Pi UART on an i.MX8.

If a schematic is only a PDF, ingest it **once** into `board.toml` + `nets.json`. The session reads records and Go. It does not OCR a blob every turn.

Unknown is a valid value. Missing nets stay `unknown`. The model may not fill them from memory.

## Tools (closed world)

The session may call only:

| Tool | Does |
|---|---|
| `kb.search` | Query the index (soc, peripherals, text in `board.toml` / `nets.json`) |
| `kb.read` | Read a KB file by path under the KB root |
| `ws.read` | Read a file in the working tree |
| `ws.list` | List the working tree (TamaGo checkout you are porting into) |
| `ws.diff` | Show the proposed or current diff |
| `ws.apply` | Apply a patch — **requires explicit human accept in the TUI** |
| `tamago.build` | `GOOS=tamago` build of the working tree; returns log + exit |

No `web_fetch`. No unrestricted `bash`. No network except the model API you configured. A sandbox (or simply: those tools do not exist) is the product.

Every MMIO / pin / RAM claim in a proposal must cite a `kb.read` path.

## Human in the loop

AI-assisted, not autonomous.

- Output of a bring-up turn is a **patch + citation list**, not a merged tree.
- Apply is a keybind, not a tool the model can fire on its own.
- Build runs after apply (or on demand) so you review a compiler, not a vibe.

## Models

OpenAI-compatible. Do not hardcode a vendor.

| Slot | Config key | Role |
|---|---|---|
| Ingest | `HATCH_MODEL_INGEST` | Page/net extract → JSON. Cheap, bounded, parallel. |
| Session | `HATCH_MODEL` | Match + first patch. Opus / Sol / Grok / whatever. |
| Build-fix | `HATCH_MODEL_BUILD` optional | Iterate on compiler logs. Can be the session model. |

Bring-up is two jobs: datasheet-shaped matching (careful, `unknown` allowed) and terminal-shaped `tamago build` loops. Route them if you want; v1 can use one session model.

Ingest workers emit **records**, not summaries. Summaries drop addresses.

## Elixir architecture

Hatch is a job machine with backpressure, not a swarm of chatbots.

```
BoardJob.Supervisor          one per spec / session
  Ingest.Worker pool         Task.async_stream, max_concurrency small
  KB.Index                   sqlite + ETS
  Session                    GenServer: transcript, tool calls, no write token
  Build.Worker               port to tamago-go / qemu, timeout, 1–2 at a time
  TUI                        subscriber via PubSub
```

- Cheap processes: page extract, KB lookup, compile.
- One conversational process.
- Write permit lives in the TUI (the human).
- A hung QEMU or a bad PDF page must not kill the session.
- Cap concurrency. Efficiency is wall-clock to UART and dollars of tokens, not process count.

TUI v1: scrollback, input, tool trace, patch pane. Ugly is fine. Ratatouille / Owl / raw ANSI — pick one and do not shop.

## V1 acceptance

Held-out board, **same SoC** as two boards already in the KB.

1. `hatch --kb ./kb` starts. Refuses without `--kb`.
2. Operator pastes or attaches a new spec (markdown / `board.toml` draft).
3. Hatch may only read that KB and the working tree. No web.
4. It names the nearest board and shows deltas with citations.
5. It proposes a patch against that tree.
6. Operator applies.
7. `GOOS=tamago` build succeeds (QEMU/UART is v2).

If this fails, do not add chrome, MCP, or a second agent.

## V2 (not now)

- UART / QEMU golden-string eval
- Distributed Erlang: session on a laptop, toolchain on a Linux box
- Multi-board jobs in one TUI
- Richer pinmux tables, netlist diff
- New-SoC *scaffolding* only when a sibling SoC package exists and the KB says what is shared

## Build order

1. Mix app `hatch`. TUI that chats with `HATCH_MODEL` (OpenAI-compat). No tools.
2. KB loader + `board.toml` index. Tools: `kb.search`, `kb.read`. Still no writes.
3. Patch pane + `ws.apply` gated on a keybind. Citations required in the system prompt and checked cheaply (paths must be under KB).
4. `tamago.build` port. Show the log in the TUI.
5. Freeze features. Run the held-out same-SoC test. Only then ingest helpers (PDF → `nets.json`).

## What would make this fail

- Shipping a general agent with a “boards” prompt
- Vector search over schematic PDFs as the matcher
- Model-applied merges
- Summarizing schematics into prose for the session
- Building Phoenix before a held-out tree compiles
- Treating Elixir as the place to parse Altium or write SoC packages (those are files + ports)
