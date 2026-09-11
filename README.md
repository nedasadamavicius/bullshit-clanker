# BC

BC is an Elixir terminal app for **AI-assisted TamaGo board bring-up**. Give it a knowledge base (KB) of known boards and a new board specification. It searches structured board records, cites supporting files, and proposes a patch for you to review and apply.

The MVP targets **a new board using a SoC already represented in your KB**. It does not generate a new SoC implementation from a datasheet. The model has no web or unrestricted shell tools, and tree changes require your acceptance in the TUI.

## 1. Install and build

Use a Linux terminal for the current MVP. Terminal input uses `stty` and `/proc`.

You need:

- Elixir **1.17+**, a compatible Erlang/OTP installation, and Mix.
- Git.
- Poppler's `pdftotext` command for PDF ingestion.
- A provider API key for chat and PDF extraction.
- `tamago-go` only if you want to compile firmware from BC.

Clone the repo and fetch dependencies:

```bash
git clone https://github.com/nedasadamavicius/bullshit-clanker.git
cd bullshit-clanker
mix deps.get
mix compile
```

Check your tools with `elixir --version`, `mix --version`, and `pdftotext -v`.
On Debian/Ubuntu, the PDF utility is available with `sudo apt install poppler-utils`.
If a native dependency needs to compile from source, install your system's C compiler and `make`.

**Run all commands below from the repository root.** Use `mix bc` to launch: it compiles changes automatically. The standalone `./bc` escript currently cannot load SQLite's native library.

## 2. Configure your provider

Create your local configuration once:

```bash
cp config/secrets.env.example config/secrets.env
```

Open `config/secrets.env` in your editor and use **one** of the following configurations, replacing the placeholder key. This file is gitignored; do not commit it. BC reads it for both PDF ingestion and the TUI, so you do not need to run `export` commands.

### Claude (default)

```dotenv
BC_PROVIDER=claude
ANTHROPIC_API_KEY=YOUR_ANTHROPIC_API_KEY
BC_MODEL=claude-sonnet-4-5
```

BC's current Claude backend requires an API key. Claude subscription / Claude Code login support is **not implemented** in this MVP.

### Grok / xAI

```dotenv
BC_PROVIDER=xai
XAI_API_KEY=YOUR_XAI_API_KEY
BC_MODEL=grok-4
```

### OpenAI

```dotenv
BC_PROVIDER=openai
OPENAI_API_KEY=YOUR_OPENAI_API_KEY
BC_MODEL=gpt-4o
```

These model names are the presets in this repository. Set `BC_MODEL` to a model available to your account that supports chat completions and tool calls.

### Another OpenAI-compatible endpoint

```dotenv
BC_PROVIDER=compat
BC_API_BASE=https://your-provider.example/v1
BC_API_KEY=YOUR_API_KEY
BC_MODEL=YOUR_MODEL_ID
```

The client calls `/chat/completions` and expects streaming responses and function tool calls. Compatibility depends on the endpoint.

### Optional settings

| Setting | Purpose |
| --- | --- |
| `BC_MODEL_INGEST` | Use a different model for extraction; defaults to `BC_MODEL`. It uses the same provider and credentials. |
| `BC_API_BASE` | Override the provider's base URL. Leave it unset when using a built-in preset unless you need an override. |
| `BC_API_KEY` | Generic key override; takes precedence over the provider-specific key. |

Shell environment variables override values in `config/secrets.env`. When switching providers, remove stale `BC_API_KEY`, `BC_API_BASE`, and model overrides. To use a different secrets file, launch with `BC_SECRETS=/path/to/secrets.env mix bc --kb ./kb`.

## 3. Convert a PDF into a KB entry

Replace the example path with a PDF you own:

```bash
mix bc.kb.ingest "/path/to/My Board.pdf" --kb ./kb
```

This command extracts the PDF's text with `pdftotext`, sends text chunks to your configured ingest model, and writes a board record. **Ingestion makes model API calls**, so it requires provider credentials. It happens before chat; the TUI searches the resulting records instead of reprocessing PDFs on every turn.

For `My Board.pdf`, the output is:

```text
kb/
  boards/
    my_board/
      board.toml       # structured facts used by search
      schematic.pdf    # copy of your input PDF
      nets.json        # written only when nets were extracted
```

The filename determines the board ID: `My Board.pdf` becomes `my_board`. The command creates the destination directories. `--kb` defaults to `./kb` for ingestion.

You can also ingest multiple files or a directory:

```bash
mix bc.kb.ingest ./datasheets/ --kb ./kb
mix bc.kb.ingest ./board-a.pdf ./board-b.pdf --kb ./kb
```

Directory ingestion searches recursively for `.pdf` files, including uppercase extensions. Each PDF becomes a separate entry; multiple documents are not automatically combined into one board.

If the board already exists, ingestion stops with an error. To deliberately replace its generated record:

```bash
mix bc.kb.ingest "/path/to/My Board.pdf" --kb ./kb --force
```

### Review the extracted record

Ingest reports missing fields and conflicts. Open `kb/boards/my_board/board.toml` and compare the extracted facts with your source document. Unknown scalar fields are omitted from the generated TOML; missing facts must stay unknown.

```bash
mix bc.kb.lint --kb ./kb
```

Lint checks record structure and reports warnings. It does not verify hardware facts against the PDF. A sparse record is possible, especially for datasheets that do not specify a board's RAM layout, pinmux, or TamaGo import paths.

Scanned PDFs need a text layer added before ingestion; BC does not perform OCR. Passing a PDF to the TUI's `--spec` option is not supported.

### Create an entry manually instead

```bash
mkdir -p kb/boards/my-board
cp kb/boards/_example/board.toml kb/boards/my-board/board.toml
```

Edit the copied record, including its `id`. Directories starting with `_` are ignored by the loader. See the [example record](kb/boards/_example/board.toml) for fields. Known-good TamaGo Go files can live under an entry's `tree/` directory; PDF ingestion does not create those files for you.

## 4. Start the TUI and chat

After configuring a provider and adding an entry:

```bash
mix bc --kb ./kb
```

`--kb` is required for the TUI and must point to a directory containing `boards/`. Use the same KB path you used for ingestion. Restart the TUI after adding or editing records so it reloads the KB.

You should see a startup message like:

```text
bc ready — kb=/path/to/kb boards=1 tree=none model=claude-sonnet-4-5
```

BC starts in **insert mode**. Type a question and press **Enter**, for example:

```text
Find the my_board entry in the KB. Read its board.toml and tell me which fields are known and which are missing, citing the file.
```

Replace `my_board` with your entry's ID. **After sending, BC switches to normal mode. Press `i` before typing your next message.** Press `Esc`, then `q` to quit.

If you want to try chat before importing a PDF, use the included fixture KB:

```bash
mix bc --kb test/fixtures/acceptance/kb
```

This still uses your configured model API. The fixtures are test data, not proof of working firmware.

### Keys

| Mode | Key | Action |
| --- | --- | --- |
| Insert | Type / Backspace | Edit your message |
| Insert | Enter | Send and switch to normal mode |
| Insert | Esc | Switch to normal mode |
| Normal | `i` | Start typing |
| Normal | `j` / `k` | Scroll the focused pane |
| Normal | Tab | Cycle transcript, tool trace, and patch focus |
| Normal | `a`, then `y` | Accept and apply a pending patch |
| Normal | `r` | Reject the pending patch |
| Normal | `b` | Request a firmware build |
| Normal | `c` | Cancel the current model turn |
| Normal | `q` | Quit |
| Either | Ctrl-C | Quit |

## 5. Propose and build a board patch (optional)

For bring-up, add known-good boards using the same SoC to your KB and prepare a Git checkout of the TamaGo tree you want to modify. Provide a new-board specification as Markdown or a `board.toml` draft:

```bash
mix bc --kb ./kb \
  --tree /path/to/tamago-checkout \
  --spec /path/to/new-board.md
```

| Flag | Purpose |
| --- | --- |
| `--kb PATH` | Required knowledge base root |
| `--tree PATH` | Optional Git working tree for reads, patches, and builds |
| `--spec PATH` | Optional Markdown or TOML specification, ingested once at startup |

Ask BC to find the nearest same-SoC board, explain the differences, and propose a patch with citations. Review the patch and its evidence. In normal mode, press `a`, then `y` to apply it. The model cannot apply it autonomously.

To compile after applying, install `tamago-go` and press `b`. The build worker uses `GOOS=tamago`. `BC_TAMAGO_GO` selects the binary and `BC_BUILD_TIMEOUT_MS` sets the timeout (default: `120000` ms). These build settings are read from the process environment, so pass them when launching if needed:

```bash
BC_TAMAGO_GO=/path/to/tamago-go mix bc --kb ./kb --tree /path/to/tamago-checkout
```

A PDF entry alone does not supply a working SoC package or board overlay. v1 requires an existing same-SoC implementation to adapt.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Missing API key | Create `config/secrets.env`, select the provider, and replace the placeholder key. Run from the repo root. |
| Provider rejects the model | Set `BC_MODEL` to an available model; check for stale environment overrides. |
| `pdftotext` not found | Install Poppler's command-line utilities and check `pdftotext -v`. |
| No extractable PDF text | Add a text layer to the PDF before ingesting. |
| Board already exists | Review the existing record; use `--force` only to replace it. |
| `boards=0` | Check the KB path and add a record. The `_example` directory does not count. |
| Typing does nothing after sending | Press `i` to return to insert mode. |
| SQLite NIF error from `./bc` | Launch with `mix bc --kb ./kb` instead. |
| Build reports no toolchain | Install `tamago-go` or pass `BC_TAMAGO_GO` in the process environment. |

## Development and validation

Start with [PRODUCT.md](PRODUCT.md), then [AGENTS.md](AGENTS.md). Implementation specs are under [specs/](specs/).

Run the offline suite, which uses a fake model and toolchain and does not require API credentials:

```bash
mix test
mix test --only acceptance
```

The acceptance fixtures exercise same-SoC matching, citations, patch application, and the build flow. Passing these tests is not a successful live hardware bring-up.

The optional live harness makes model API calls and requires a real `tamago-go`:

```bash
mix bc.accept \
  --kb test/fixtures/acceptance/kb \
  --spec test/fixtures/acceptance/spec/held-out.md \
  --tree test/fixtures/acceptance/tree
```

It copies the tree to a scratch directory and automatically applies the proposal there as part of the test, then builds. It writes `acceptance.json`; `--runs N` repeats the test and appends history. Normal TUI use always requires human acceptance to apply a patch.

## License

Undecided.
