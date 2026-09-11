# BC specs

End-to-end implementation specs for the product described in [`PRODUCT.md`](../PRODUCT.md),
under the constraints in [`AGENTS.md`](../AGENTS.md). If a spec fights `PRODUCT.md`,
`PRODUCT.md` wins.

Each numbered spec is **self-contained and implementable on its own branch**. Every spec
assumes [`000-overview.md`](000-overview.md) has been read — that file holds the shared
contracts (module map, structs, event names, dependency list, error shapes) so that
specs implemented in parallel do not invent conflicting ones.

## Order

`PRODUCT.md` "Build order" and `AGENTS.md` "v1 order" are the spine. The specs refine it:

| # | Spec | Build-order step | Depends on |
|---|---|---|---|
| 001 | [Mix app, config, CLI entrypoint](001-app-skeleton-and-cli.md) | 1 | — |
| 002 | [Path sandbox](002-path-sandbox.md) | 1 | 001 |
| 003 | [Board records: schema, loader, validation](003-kb-board-records.md) | 2 | 001, 002 |
| 004 | [KB index and structured search](004-kb-index-and-search.md) | 2 | 003 |
| 005 | [OpenAI-compatible model client](005-model-client.md) | 1 | 001 |
| 006 | [Session process and turn loop](006-session.md) | 1–2 | 005, 008 |
| 007 | [Closed-world tool registry](007-tools.md) | 2 | 002, 004 |
| 008 | [Proposals, patches, citation enforcement](008-proposals-and-citations.md) | 3 | 007 |
| 009 | [Human-gated apply (`ws.apply`)](009-gated-apply.md) | 3 | 008 |
| 010 | [`tamago.build` port worker](010-tamago-build.md) | 4 | 001 |
| 011 | [TUI](011-tui.md) | 1, 3, 4 | 006, 009, 010 |
| 012 | [Spec ingest (new board draft)](012-spec-ingest.md) | 2 | 003, 005 |
| 013 | [V1 acceptance harness](013-v1-acceptance.md) | 5 | all |

**Freeze after 013.** `PRODUCT.md`: "If this fails, do not add chrome, MCP, or a second
agent." PDF → `nets.json` ingest is deliberately not specified here; it comes after the
held-out test passes.

## Parallelisation

001 lands alone (it creates the project). After that:

- Wave A, no overlap: **002**, **005**, **010**.
- Wave B: **003** (needs 002), then **004**.
- Wave C: **007** (needs 002+004), then **008**, then **006** and **009**.
- Wave D: **011**, **012**.
- Last: **013**.

Two specs in the same wave never edit the same file. Where a later spec must touch a file
an earlier one created, the spec says so explicitly.

## Definition of done for the set

`PRODUCT.md` "V1 acceptance", mechanised in spec 013.
