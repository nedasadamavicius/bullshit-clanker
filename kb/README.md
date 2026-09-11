# Knowledge base

Each board is a directory `boards/<id>/` with `board.toml` (required). Optional: `nets.json`, `schematic.pdf`, `tree/` (known-good TamaGo overlay).

BC indexes `board.toml`. It does not live-query PDFs. Ingest a schematic into fields and `nets.json` once.

See `_example/board.toml` and `PRODUCT.md`.
