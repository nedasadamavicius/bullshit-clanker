# 013 — V1 acceptance harness

Build-order step 5. Depends on everything.

Read [`000-overview.md`](000-overview.md) first.

## Goal

Mechanise `PRODUCT.md` "V1 acceptance" so it can be re-run, and so that the project has a
single command that answers "is Hatch done?". `AGENTS.md`: "Stop expanding until that
passes."

## Scope

In: the fixture KB with a held-out board, the fixture working tree, the scripted and
(optionally) live end-to-end runs, `mix hatch.accept`.

Out: new product behaviour. If this spec needs a feature, that is a bug in 001–012.

## Design

### The fixture

`test/fixtures/acceptance/`:

- `kb/boards/` — **three** boards on one SoC (use `imx6ul`: it is what `PRODUCT.md`'s
  example uses and TamaGo really supports), each with a complete `board.toml`, plausible
  pinmux rows, and a small `tree/` overlay containing a real-shaped
  `board/<vendor>/<name>/board.go` + `init.go`. Two are the KB's knowledge; the third is
  the **held-out** board.
- `kb/boards/` also contains one board on a different SoC, which must never appear in a
  result.
- `spec/held-out.md` — the held-out board written as a fresh operator spec: markdown,
  prose, with the SoC, RAM map, UART and a handful of pinmux rows stated, and at least
  **two facts deliberately absent** (so the correct answer contains `unknown`).
- `tree/` — a git repo seeded with the *nearest* board's overlay, i.e. the state an
  operator would start from, plus a `go.mod`. This is what the patch applies to.
- The held-out board's own directory is excluded from the index at query time via
  `exclude:` (004) so the KB cannot simply contain the answer.

Building the fixture is most of the work in this spec. It must be real enough that a
compiler can run on it and that a wrong pinmux is a visible mistake.

### Run A — scripted (always, in CI)

`mix test --only acceptance`. Uses `Hatch.Model.Fake` with a recorded script that a real
model produced once (checked in under `test/fixtures/acceptance/script.exs`, with a note
on which model and date). Asserts the **mechanism**, not the model:

1. `Hatch.CLI.main(["--kb", fixture_kb])` with no `--tree` → starts; with no `--kb` →
   exit 2. (V1 acceptance 1.)
2. `--spec spec/held-out.md` ingests to a draft whose absent facts are `:unknown`.
   (V1 acceptance 2.)
3. The session's tool list contains only the closed set; a scripted attempt to call
   `web_fetch` and to `kb.read` an absolute path both fail. (V1 acceptance 3.)
4. The scripted turn names the nearest board — asserted against the id that
   `Hatch.KB.Search.from_board/2` independently ranks first, not against a hardcoded
   string — and the `:proposal` event carries a non-empty delta table and citations that
   pass the 008 check. (V1 acceptance 4, 5.)
5. A minted permit applies the patch; the fixture tree changes exactly as expected.
   (V1 acceptance 6.)
6. `tamago.build` runs. In CI, `HATCH_TAMAGO_GO` points at the fake toolchain from 010
   and must be invoked with `GOOS=tamago` and the draft's `GOARCH`/`GOARM`; the assertion
   is on the invocation and the exit-status plumbing.

### Run B — live (`mix hatch.accept`)

The real thing, run by a human with a real model and a real `tamago-go`. Not in CI.

```
mix hatch.accept --kb test/fixtures/acceptance/kb --spec ... --tree <scratch copy>
```

- Copies the fixture tree to a scratch dir so the repo's fixture is never mutated.
- Runs the loop headlessly: ingest → one session turn → the proposal → auto-accept **with
  a real permit** (this task is the human; it is the one place outside the TUI allowed to
  mint one, and it is a Mix task under `lib/mix/tasks/`, excluded from the 009 grep test
  by name — state that exclusion in both specs' code comments).
- Runs the real `GOOS=tamago` build.
- Prints a report: nearest board and why, the delta table, citations with claims, the
  patch, apply result, build exit status, elapsed wall-clock, and token usage from 005.
- Exit 0 only if: nearest board is the expected one, every citation passes, apply is
  clean, **and the build exits 0**. (V1 acceptance 7.)
- `--runs N` repeats it and reports how many passed. Bring-up quality is a pass rate, not
  a single green tick; record it in the report, not in the exit code.

### Reporting

Both runs write `acceptance.json`: `{nearest_board, expected_board, citations_ok,
uncited_tokens, apply_ok, build_exit, duration_ms, usage}`. The live task appends to
`acceptance-history.jsonl` so a model or prompt change is visible as a regression instead
of a vibe.

## Acceptance criteria

1. `mix test --only acceptance` passes offline, with no network and no toolchain.
2. The fixture KB's off-SoC board never appears in any result during the run.
3. The scripted run fails loudly if any 008 citation check is bypassed — verify by
   mutating the script to invent an address and asserting the suite goes red.
   **(the test of the test)**
4. The fixture tree is identical before and after `mix test` (the scratch-copy rule).
5. `mix hatch.accept --help` documents the env it needs and refuses to run with a missing
   `HATCH_API_KEY` rather than half-running.
6. The live task's exit code is 0 only when all four conditions hold; a build exit 2
   produces exit 1 with the compiler log in the report.
7. `acceptance.json` is written in both modes and contains every field above.
8. The held-out board's `board.toml` is present in the fixture KB but excluded from
   search during the run — assert that removing the `exclude:` makes the task report
   `nearest == held-out` (i.e. the exclusion is real and the test is not cheating).

## Test plan

This spec *is* the test plan. Its own unit tests cover the fixture builder and the report
writer.

## Constraints

- If this fails, the response is to fix 001–012 or to change `PRODUCT.md` — **not** to add
  chrome, MCP, a second agent, or a retry loop that hides the failure (`PRODUCT.md`: "If
  this fails, do not add chrome, MCP, or a second agent").
- Do not weaken an assertion to make the suite green. A pass rate below 100% on Run B is
  a number to report, not a threshold to lower.
