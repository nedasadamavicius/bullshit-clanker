# 006 — Session process and turn loop

Build-order steps 1–2. Depends on 005 (model) and 007/008 (tools).

Read [`000-overview.md`](000-overview.md) first. Enforces **I7**, and carries **I5** in
the prompt.

## Goal

"One session process talks to the user." A GenServer holding the transcript, running the
model↔tool loop, broadcasting events, and holding **no write token**.

## Scope

In: `Hatch.Session`, `Hatch.Session.Prompt`, `Hatch.Session.Transcript`.

Out: the TUI (011), tool implementations (007/008), build (010).

## Design

### `Hatch.Session`

Child of `Hatch.BoardJob.Supervisor`, registered as
`{:via, Registry, {Hatch.Registry, {:session, session_id}}}`.

```elixir
@spec send_message(String.t(), String.t()) :: :ok          # async; events carry the result
@spec cancel(String.t()) :: :ok
@spec transcript(String.t()) :: [Model.message()]
@spec set_draft(String.t(), Board.t()) :: :ok              # from 012
@spec note_applied(String.t(), Proposal.t(), [String.t()]) :: :ok  # from 009
@spec note_rejected(String.t(), Proposal.t(), String.t() | nil) :: :ok  # from 009/011
@spec note_build(String.t(), map()) :: :ok                        # from 010
```

State: `session_id`, `config`, `messages`, `read_log` (ETS, 007), `draft` (the new
board's `%Board{}` once ingested, or `nil`), `turn` (`nil | %{task: Task.t(), step: n}`),
`cancelled?`.

### Turn loop

`send_message/2` casts; the GenServer starts the turn **in a `Task` under the board job's
`Task.Supervisor`**, monitored, so a model hang or a tool crash cannot wedge the
GenServer. The GenServer stays responsive to `cancel/1`, `transcript/1` and events.

Loop, max `@max_steps 12`:

1. Append the user message, broadcast `:user_message`.
2. Call `model.chat(messages, [model:, tools: Hatch.Tools.schemas(config)], callback)`.
   The callback broadcasts `:assistant_delta` per text chunk.
3. On `{:ok, %{tool_calls: []}}` → append assistant message, broadcast
   `:assistant_message`, `:turn_finished, reason: :ok`. Done.
4. On tool calls → for each, in order:
   - broadcast `:tool_call_started`,
   - `Hatch.Tools.call/3`,
   - append a `tool` role message with the result string,
   - broadcast `:tool_call_finished` with a one-line `summary` (never the full payload —
     the trace pane is a trace, not a dump).
   Then loop to 2.
5. At `@max_steps` → append a system note "step limit reached", broadcast
   `:turn_finished, reason: :max_steps`. Do not silently continue.
6. Model error → broadcast `:error` with `stage: :model` and `:turn_finished,
   reason: :error`. The transcript keeps the user message so the operator can retry.

**Tool calls run sequentially within a turn.** Fan-out is for ingest/search/build (I7);
inside a conversational turn, ordering is what makes the trace readable and the read-log
meaningful.

`cancel/1` kills the task, appends a note to the transcript, broadcasts
`:turn_finished, reason: :cancelled`. A cancelled turn must leave the transcript
well-formed: **every `tool_calls` assistant message must have a matching `tool` message**,
or the next request to an OpenAI-compatible endpoint is a 400. Synthesise
`{"error":{"code":"cancelled"}}` results for calls that never ran.

### `Hatch.Session.Transcript`

- Message list, oldest first. System prompt is index 0 and is never dropped.
- Bounding: when the estimated token count (chars/4) exceeds `@budget 120_000`, drop from
  the **oldest non-system** message, always dropping a complete assistant+tool group
  together (never orphan a tool message), and insert one `system` marker noting how many
  messages were elided. Never summarise into prose — `PRODUCT.md`: "Summaries drop
  addresses."
- `@spec append/2`, `@spec bound/2`, `@spec estimate_tokens/1`.

### `Hatch.Session.Prompt`

One function, `system(config, draft)`, returning the system message. It must state, in
plain language:

- Job: match a new board against the KB, name the nearest board, list deltas, propose one
  patch. Same SoC, new board — not new-SoC bring-up from a datasheet.
- **Closed world**: the only knowledge that counts is what `kb.search`/`kb.read` return
  and what is in the working tree. There is no network. Training-data recollection of a
  register map is not evidence and must not appear in a patch.
- **`unknown` is a valid and preferred answer.** If the KB does not say what a pad is,
  the answer is `unknown` and the operator will go read the schematic. Do not fill a gap.
- **Citations**: every address, pin, RAM size and peripheral name in a patch must be
  supported by a `kb.read` path passed in `citations`. Uncited claims are rejected
  mechanically. (I5)
- **You cannot apply anything.** `propose_patch` shows a patch to a human who decides.
  Do not claim to have applied, built, or flashed anything.
- `tamago.build` is the eval; read the compiler, do not guess.
- Output shape for a bring-up turn: nearest board + delta table + one `propose_patch`.
- If `kb.search` returns nothing for the SoC, say the KB has no package for it and stop.
  Do not propose a port.

Plus the rendered draft (`Board.to_facts/1`) when one is set, and a list of KB board ids
with their SoCs (cheap, ≤ 200 boards) so the model does not have to search to learn the
KB's shape.

The prompt is a single module attribute–backed heredoc, not assembled from fragments
scattered across modules — it is the product's most load-bearing text and must be
readable in one place, and diffable.

## Acceptance criteria

Driven entirely by `Hatch.Model.Fake` (005). No network in any test.

1. A scripted text-only response produces `:assistant_delta` events then one
   `:assistant_message` and `:turn_finished, :ok`.
2. A scripted `kb.search` tool call produces `:tool_call_started` / `:tool_call_finished`,
   appends a `tool` message, and issues a second model call whose messages include that
   tool result.
3. Tool calls inside a turn execute in the order the model emitted them.
4. A model that loops tool calls forever stops at 12 steps with `reason: :max_steps`.
5. A tool that crashes yields a tool message containing the error and the loop continues;
   the session process pid is unchanged. **(I7)**
6. A model error yields `:error` + `:turn_finished, :error`, and the session still
   answers `transcript/1`.
7. `cancel/1` mid-turn leaves a transcript where every assistant `tool_calls` message has
   matching `tool` messages (assert structurally).
8. Transcript bounding over the budget drops whole assistant+tool groups, keeps the
   system prompt, and inserts the elision marker.
9. `Hatch.Tools.schemas/1` is what gets passed to the model — asserted by inspecting what
   `Fake` received — and contains no write tool. **(I4)**
10. The system prompt contains the words `unknown`, `cite`/`citation`, and a sentence
    saying it cannot apply patches. Assert with a test so nobody quietly softens it.
11. Two sessions run concurrently without sharing transcript, read-log or events.

## Test plan

`test/hatch/session_test.exs` with `Fake` scripts per case, subscribing to the session
topic and asserting the event sequence. `test/hatch/session/transcript_test.exs` for
bounding. `test/hatch/session/prompt_test.exs` for the prompt obligations.

## Constraints

- One conversational process. Do not spawn "summarizer agents" or a second chat process
  (`PRODUCT.md` non-goal, explicitly).
- The session holds no write permit and calls nothing that writes (I4).
- No auto-retry of a whole turn on model error — the operator decides; a silent retry
  doubles token spend and hides a broken endpoint.
