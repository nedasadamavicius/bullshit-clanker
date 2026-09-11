# Hatch

TUI for **AI-assisted TamaGo board bring-up**, closed against a spec knowledge base you own.

New board spec in. Nearest known TamaGo `soc/` + `board/` trees out of the KB. Model proposes a patch with citations. You apply it.

This is not OpenCode. The agent cannot see the web or the rest of your disk. If a pin is not in the KB, the answer is `unknown`.

Read **[PRODUCT.md](PRODUCT.md)** before writing code. **[AGENTS.md](AGENTS.md)** is the constraint list for implementers.

## Status

Vision only. No Mix app yet.

## Shape (target)

```text
hatch --kb ./kb [--tree ./tamago-overlay]
```

- `--kb` is required. The process must not start without it.
- `--tree` is the working copy the patch applies to (a TamaGo checkout or overlay).
- Model via env: `HATCH_MODEL`, `HATCH_MODEL_INGEST`, OpenAI-compatible `HATCH_API_KEY` + `HATCH_API_BASE`.

## Knowledge base

See `PRODUCT.md`. v1 is a directory of `boards/<id>/board.toml` plus optional `nets.json` and a known-good tree.

## License

Undecided.
