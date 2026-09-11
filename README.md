# Hatch

TUI for **AI-assisted TamaGo board bring-up**, closed against a spec knowledge base you own.

You give it a new board spec and a KB of known boards. It names the nearest TamaGo tree, cites the files it actually read, and proposes a BSP patch. **You** apply it. The model cannot write, fetch the web, or leave `--kb` / `--tree`.

If a pin is not in the KB, the answer is `unknown`.

v1 is implemented. Product intent: [PRODUCT.md](PRODUCT.md). Implementer constraints: [AGENTS.md](AGENTS.md). Specs: [specs/](specs/).

---

## What you need

- Elixir **1.17+** (`elixir -v`) and Mix
- `git` on `PATH` (patches are applied with `git apply`, not a hand-rolled parser)
- An **OpenAI-compatible** chat API (OpenAI, xAI, a local server, …)
- A knowledge base directory with at least one real `boards/<id>/board.toml`
- Optional: a TamaGo working tree (the checkout the patch applies to) and `tamago-go` on `PATH`

```bash
git clone <this-repo>
cd bullshit-clanker
mix deps.get
mix test          # 253 tests; skip if you just want to run the app
```

---

## 1. Point it at a model

Hatch will **refuse to start** without these three:

```bash
export HATCH_API_KEY=sk-...                    # required
export HATCH_API_BASE=https://api.openai.com/v1
export HATCH_MODEL=gpt-4o
```

xAI example:

```bash
export HATCH_API_KEY=xai-...
export HATCH_API_BASE=https://api.x.ai/v1
export HATCH_MODEL=grok-4
```

Optional:

| Env | Default | What |
|-----|---------|------|
| `HATCH_MODEL_INGEST` | `$HATCH_MODEL` | Cheap model for turning markdown specs into `board.toml` fields |
| `HATCH_MODEL_BUILD` | unset | Unused in v1 unless you wire it |
| `HATCH_TAMAGO_GO` | `tamago-go` | Binary for `GOOS=tamago` builds |
| `HATCH_BUILD_TIMEOUT_MS` | `120000` | Build kill deadline |

`HATCH_API_BASE` is the OpenAI-style root (no trailing slash needed). There is no vendor SDK.

---

## 2. Build a knowledge base

`--kb` is required. The process does not start without it.

Layout:

```text
kb/
  boards/
    usbarmory-mk2/
      board.toml          # required — this is what search uses
      nets.json           # optional
      schematic.pdf       # optional; never queried live
      tree/               # optional known-good TamaGo overlay
    some-other-board/
      board.toml
```

Copy the template and fill it from a schematic / existing tree. Empty means **unknown** — do not invent addresses.

```bash
cp kb/boards/_example/board.toml kb/boards/my-board/board.toml
# edit id, soc, ram_*, uart, pinmux, tamago_* …
```

Directories whose names start with `_` (like `_example`) are skipped by the loader.

Minimum useful `board.toml`:

```toml
id = "usbarmory-mk2"
soc = "imx6ul"
goarch = "arm"
goarm = "7"
ram_start = "0x80000000"
ram_size = "0x20000000"
uart = "UART2"
peripherals = ["uart", "gpio", "usb"]
tamago_soc = "github.com/usbarmory/tamago/soc/nxp/imx6ul"
tamago_board = "github.com/usbarmory/tamago/board/usbarmory/mk2"
tree = "tree"

[[pinmux]]
signal = "UART2_TX"
pad = "CSI_DATA00"
fn = "ALT3"
```

v1 is **same SoC, new board**. A brand-new SoC with nothing in the KB is out of scope.

Lint what you wrote:

```bash
mix hatch.kb.lint --kb ./kb
```

---

## 3. Run the TUI

```bash
mix escript.build
./hatch --kb ./kb
```

With a working tree (the thing that will receive the patch) and a new-board spec:

```bash
./hatch --kb ./kb --tree ./tamago-overlay --spec ./notes/new-board.md
```

| Flag | Required | What |
|------|----------|------|
| `--kb PATH` | yes | Knowledge base root (must contain `boards/`) |
| `--tree PATH` | no | Git working tree the patch applies to |
| `--spec PATH` | no | Markdown or `board.toml` for the **new** board. Ingested once at startup. PDFs are rejected. |

You should see something like:

```text
hatch ready — kb=/…/kb boards=2 tree=/…/overlay model=gpt-4o
```

Then the TUI. Starts in **insert** mode (typing goes to the input).

### First bring-up loop

1. Put two (or more) known-good boards of the **same SoC** in `--kb`.
2. Point `--tree` at a git checkout of the nearest board’s overlay (or a TamaGo tree).
3. Pass `--spec` with notes for the new board (SoC, RAM map, UART, pinmux — leave gaps as unknown).
4. In the TUI, ask it to match the spec and propose a patch.
5. Read the patch pane: nearest board, deltas, citations, diff.
6. `Esc`, then `a`, then `y` to apply — or `r` to reject. The model cannot apply.
7. `b` to run `tamago.build` after apply (needs `HATCH_TAMAGO_GO` / `tamago-go` on `PATH`).

### Keys

**Insert** (default):

| Key | Action |
|-----|--------|
| type | edit the input line |
| Enter | send to the session |
| Esc | normal mode |
| Ctrl-C | quit |

**Normal** (`Esc` first):

| Key | Action |
|-----|--------|
| `i` | insert mode |
| `j` / `k` | scroll focused pane |
| Tab | cycle transcript → tool trace → patch |
| `a` then `y` | **accept** the pending patch (you are the only writer) |
| `a` then anything else | cancel accept |
| `r` | reject the pending patch |
| `b` | request a `tamago.build` |
| `c` | cancel the running turn |
| `q` / Ctrl-C | quit |

Apply is a keybind, not a tool. No patch reaches the tree unless you press `a` then `y`.

---

## Try it on the held-out fixture (no real hardware)

The v1 acceptance KB is three `imx6ul` boards plus one off-SoC decoy:

```bash
export HATCH_API_KEY=...
export HATCH_API_BASE=...
export HATCH_MODEL=...

mix escript.build
./hatch \
  --kb test/fixtures/acceptance/kb \
  --tree test/fixtures/acceptance/tree \
  --spec test/fixtures/acceptance/spec/held-out.md
```

Ask it to match the spec and propose a patch. Nearest should be `imx6ul_board_a` (the held-out board is in the KB but excluded from search). `ram_size` and `tamago_board` are deliberately unknown in the spec.

Offline, no model:

```bash
mix test --only acceptance
```

That is the scripted “is Hatch done?” check. It uses a recorded fake model and a fake `tamago-go`.

---

## Live acceptance (real model + real `tamago-go`)

Headless: ingest → one turn → auto-apply with a real permit → `GOOS=tamago` build. Not used in CI. This Mix task is the operator; it is the one place outside the TUI allowed to mint a write permit.

```bash
export HATCH_API_KEY=...          # required; refuses to start without it
# HATCH_MODEL defaults to gpt-4o here; HATCH_API_BASE to api.openai.com

mix hatch.accept \
  --kb test/fixtures/acceptance/kb \
  --spec test/fixtures/acceptance/spec/held-out.md \
  --tree test/fixtures/acceptance/tree
```

Copies `--tree` to a scratch dir so the fixture is never mutated. Exit 0 only if nearest board, citations, apply, and build all pass. Writes `acceptance.json`. `--runs N` repeats and appends `acceptance-history.jsonl`.

```bash
mix hatch.accept --help
```

---

## What Hatch will not do

- Start without `--kb`
- Call the web, MCP, or a shell
- Apply a patch without you (`a` `y`, or `mix hatch.accept`)
- Fill `unknown` fields from training data
- Port a SoC that has no package in the KB

If a bring-up fails, the response is not “add chrome”. Fix the KB or the tree.

---

## License

Undecided.
