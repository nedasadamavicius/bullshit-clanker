# BC

TUI for **AI-assisted TamaGo board bring-up**, closed against a spec knowledge base you own.

You give it a new board spec and a KB of known boards. It names the nearest TamaGo tree, cites the files it actually read, and proposes a BSP patch. **You** apply it. The model cannot write, fetch the web, or leave `--kb` / `--tree`. If a pin is not in the KB, the answer is `unknown`.

Product intent: [PRODUCT.md](PRODUCT.md). Implementer constraints: [AGENTS.md](AGENTS.md). Specs: [specs/](specs/).

---

## Run it

Need Elixir **1.17+**, Mix, `git` on `PATH`, and an Anthropic **console** API key ([console.anthropic.com/settings/keys](https://console.anthropic.com/settings/keys)). Claude.ai / Claude Code login is not an API key.

```bash
cd bullshit-clanker
mix deps.get

cp config/secrets.env.example config/secrets.env
# edit config/secrets.env — paste:
#   ANTHROPIC_API_KEY=sk-ant-...

mix escript.build
./bc --kb test/fixtures/acceptance/kb \
     --tree test/fixtures/acceptance/tree \
     --spec test/fixtures/acceptance/spec/held-out.md
```

`config/secrets.env` is gitignored. No `export`. Default provider is Claude (`claude-sonnet-4-5`). Same file is used by the TUI, `mix bc.kb.ingest`, and `mix bc.accept`. Run those commands from the repo root so the file is found.

You should see:

```text
bc ready — kb=…/kb boards=4 tree=…/tree model=claude-sonnet-4-5
```

Starts in **insert** mode (typing goes to the input). Ask it to match the spec and propose a patch. Nearest should be `imx6ul_board_a`.

Optional: `pdftotext` (poppler-utils) for PDF ingest; `tamago-go` on `PATH` to build after apply.

---

## Secrets

```bash
# config/secrets.env  (never commit this)
ANTHROPIC_API_KEY=sk-ant-...
```

Process env wins over the file. Alternate path: `BC_SECRETS=/somewhere/else.env`.

| Key | Default | What |
|-----|---------|------|
| `ANTHROPIC_API_KEY` | — | Claude console key (or `BC_API_KEY`) |
| `BC_PROVIDER` | `claude` | `claude` / `anthropic`, `xai` / `grok`, `openai` |
| `BC_MODEL` | `claude-sonnet-4-5` | Session model |
| `BC_API_BASE` | `https://api.anthropic.com/v1` | OpenAI-compat base |
| `BC_MODEL_INGEST` | `$BC_MODEL` | Cheap model for PDF → `board.toml` |
| `BC_TAMAGO_GO` | `tamago-go` | Binary for `GOOS=tamago` builds |
| `BC_BUILD_TIMEOUT_MS` | `120000` | Build kill deadline |

To use Grok later, put `BC_PROVIDER=xai` and `XAI_API_KEY=...` in the same file. One process, one provider. No vendor SDK — the preset fills base URL, default model, and extra headers (Anthropic needs `anthropic-version`).

---

## Knowledge base

`--kb` is required. The process does not start without it.

```text
kb/
  boards/
    usbarmory-mk2/
      board.toml          # required — this is what search uses
      nets.json           # optional
      schematic.pdf       # optional; never queried live
      tree/               # optional known-good TamaGo overlay
```

### From PDFs (offline ingest)

Each PDF becomes one board directory. BC extracts the text layer with `pdftotext`, runs the ingest model, and writes **records** (`board.toml`, copied `schematic.pdf`, and `nets.json` only when the document names nets). It does not OCR a scanned blob, and the TUI never reads the PDF again.

```bash
mix bc.kb.ingest ./datasheets/usbarmory.pdf             # → kb/boards/usbarmory/
mix bc.kb.ingest ./datasheets/                          # every *.pdf in the tree
mix bc.kb.ingest a.pdf b.pdf --force
# --kb defaults to ./kb
```

Board id is the filename, slugified (`USB Armory MK2.pdf` → `usb_armory_mk2`). Existing boards are left alone unless you pass `--force`. Fields the PDF does not state stay `unknown`.

`--spec some.pdf` on the TUI is rejected on purpose: ingest is this Mix task, not a live session tool.

### By hand

```bash
mkdir -p kb/boards/my-board
cp kb/boards/_example/board.toml kb/boards/my-board/board.toml
# edit id, soc, ram_*, uart, pinmux, tamago_* …
```

Directories whose names start with `_` (like `_example`) are skipped by the loader. Empty means **unknown** — do not invent addresses.

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

```bash
mix bc.kb.lint --kb ./kb
```

---

## TUI

```bash
./bc --kb ./kb
./bc --kb ./kb --tree ./tamago-overlay --spec ./notes/new-board.md
```

| Flag | Required | What |
|------|----------|------|
| `--kb PATH` | yes | Knowledge base root (must contain `boards/`) |
| `--tree PATH` | no | Git working tree the patch applies to |
| `--spec PATH` | no | Markdown or `board.toml` for the **new** board. Ingested once at startup. PDFs are rejected. |

### Bring-up loop

1. Put two (or more) known-good boards of the **same SoC** in `--kb`.
2. Point `--tree` at a git checkout of the nearest board’s overlay (or a TamaGo tree).
3. Pass `--spec` with notes for the new board (SoC, RAM map, UART, pinmux — leave gaps as unknown).
4. Ask it to match the spec and propose a patch.
5. Read the patch pane: nearest board, deltas, citations, diff.
6. `Esc`, then `a`, then `y` to apply — or `r` to reject. The model cannot apply.
7. `b` to run `tamago.build` after apply (needs `tamago-go` on `PATH`).

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

## Tests and live acceptance

Offline, no model (fake client + fake `tamago-go`):

```bash
mix test
mix test --only acceptance
```

The acceptance fixture is three `imx6ul` boards plus one off-SoC decoy. The held-out board is in the KB but excluded from search. `ram_size` and `tamago_board` are deliberately unknown in the spec.

Live (real Claude + real `tamago-go`), headless: ingest → one turn → auto-apply with a real permit → `GOOS=tamago` build. Not used in CI. This Mix task is the operator; it is the one place outside the TUI allowed to mint a write permit.

```bash
mix bc.accept \
  --kb test/fixtures/acceptance/kb \
  --spec test/fixtures/acceptance/spec/held-out.md \
  --tree test/fixtures/acceptance/tree
```

Copies `--tree` to a scratch dir so the fixture is never mutated. Exit 0 only if nearest board, citations, apply, and build all pass. Writes `acceptance.json`. `--runs N` repeats and appends `acceptance-history.jsonl`.

---

## What BC will not do

- Start without `--kb`
- Call the web, MCP, or a shell
- Apply a patch without you (`a` `y`, or `mix bc.accept`)
- Fill `unknown` fields from training data
- Port a SoC that has no package in the KB

If a bring-up fails, the response is not “add chrome”. Fix the KB or the tree.

---

## License

Undecided.
