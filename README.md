# BC

An Elixir TUI for AI-assisted TamaGo board bring-up. Import board PDFs into a structured knowledge base, chat against it, and review proposed patches. You decide what gets applied.

## Setup

Requires Linux, Elixir **1.17+**, Mix, Git, and `pdftotext` (Poppler).

```bash
git clone https://github.com/nedasadamavicius/bullshit-clanker.git
cd bullshit-clanker
mix deps.get
cp config/secrets.env.example config/secrets.env
```

Edit `config/secrets.env` with your provider and API key. For Claude:

```dotenv
BC_PROVIDER=claude
ANTHROPIC_API_KEY=YOUR_API_KEY
```

Other provider settings:

| Provider | `BC_PROVIDER` | Key variable |
| --- | --- | --- |
| Grok | `xai` | `XAI_API_KEY` |
| OpenAI | `openai` | `OPENAI_API_KEY` |
| OpenAI-compatible endpoint | `compat` | `BC_API_KEY` |

Optionally set `BC_MODEL`. Custom endpoints also require `BC_API_BASE` and `BC_MODEL`.

The secrets file is gitignored. Shell environment variables override it. This MVP uses API credentials; Claude subscription login is not implemented.

## Import PDFs

Run from the repo root, using your own PDF path:

```bash
mix bc.kb.ingest "/path/to/My Board.pdf" --kb ./kb
```

This uses your configured model to write `kb/boards/my_board/board.toml`, a copy of the PDF, and `nets.json` when nets are extracted. You can pass a directory instead of a file.

Review the generated record. Missing facts stay unknown. Scanned PDFs need a text layer first. Use `--force` only to replace an existing entry.

```bash
mix bc.kb.lint --kb ./kb
```

## Chat

```bash
mix bc --kb ./kb
```

This compiles and starts the TUI. Type a question and press **Enter**. Press **`i`** to type your next message. **Esc, then `q`** quits.

Try: “Read the my_board record and explain what is known and missing, citing the file.”

For patch proposals, add your TamaGo Git checkout and a Markdown or TOML board spec:

```bash
mix bc --kb ./kb --tree /path/to/tamago --spec /path/to/board.md
```

In normal mode, **`a`, then `y`** applies a reviewed patch; **`b`** builds it (requires `tamago-go`). The MVP adapts boards using an existing same-SoC implementation.

Use `mix bc`, not `./bc`: the escript currently has a SQLite native-library issue.

## Development

Run `mix test` for offline tests. Read [PRODUCT.md](PRODUCT.md) and [AGENTS.md](AGENTS.md) before making changes.
