# 005 — OpenAI-compatible model client

Build-order step 1 (second half). Parallel with 002 and 010.

Read [`000-overview.md`](000-overview.md) first. Enforces **I3**.

## Goal

One HTTP client, OpenAI-compatible chat completions with tool calling and streaming, no
vendor SDK, no vendor branching. `PRODUCT.md`: "OpenAI-compatible. Do not hardcode a
vendor."

## Scope

In: `BC.Model` behaviour, `BC.Model.OpenAI`, SSE parsing, tool-call assembly,
retries, `BC.Model.Fake` for tests.

Out: prompts (006), tool semantics (007).

## Design

Add deps `{:req, "~> 0.5"}`, `{:jason, "~> 1.4"}`.

### Behaviour

```elixir
defmodule BC.Model do
  @type message :: %{role: :system | :user | :assistant | :tool, content: String.t() | nil,
                     tool_calls: [tool_call()] | nil, tool_call_id: String.t() | nil}
  @type tool_call :: %{id: String.t(), name: String.t(), arguments: String.t()}  # raw JSON string
  @type chunk :: {:text, String.t()}
               | {:tool_call, tool_call()}          # emitted once, fully assembled
               | {:done, %{finish_reason: String.t(), usage: map()}}
  @type opts :: [model: String.t(), tools: [map()], temperature: float(),
                 max_tokens: pos_integer(), timeout_ms: pos_integer()]

  @callback chat([message()], opts(), (chunk() -> any())) ::
              {:ok, %{text: String.t(), tool_calls: [tool_call()], finish_reason: String.t(), usage: map()}}
            | {:error, %{code: atom(), message: String.t()}}
end
```

The callback both streams (via the callback fun, for the TUI's live tokens) and returns
the assembled result (for the session's transcript). Callers that do not want streaming
pass `&Function.identity/1`.

### `BC.Model.OpenAI`

- `POST #{api_base}/chat/completions`, `Authorization: Bearer #{api_key}`,
  `stream: true`, `stream_options: %{include_usage: true}`.
- `tools` are passed through verbatim as OpenAI function-tool objects (built in 007);
  `tool_choice: "auto"`.
- Streaming with `Req` `into:` a function; accumulate a buffer and split SSE on `\n\n`;
  each `data: ` line that is not `[DONE]` is `Jason.decode!`d. **Partial JSON across
  chunk boundaries must be handled** — buffer until a complete event is present.
- Tool-call deltas arrive keyed by `index` with `id`/`name` on the first delta and
  `arguments` in fragments. Accumulate into a map by index; emit `{:tool_call, call}`
  only when the stream finishes or another index starts. Never emit a half-built call.
- Malformed `arguments` JSON is **not** repaired here. It is returned as-is; 007 decides
  what to tell the model.
- Timeouts: connect 10 s, total from `:timeout_ms` (default 180 s). On timeout →
  `{:error, %{code: :timeout}}`.
- Retries: at most 2, exponential backoff (1 s, 4 s) with jitter, **only** on HTTP 429,
  5xx, and transport errors — never on 4xx, never after any bytes of a tool call have
  been emitted downstream (that would duplicate a tool call).
- Error mapping: 401/403 → `:unauthorized`, 404 → `:bad_model`, 400 → `:invalid_request`
  (include the upstream message body, truncated to 500 chars), 429 after retries →
  `:rate_limited`, else `:upstream`.
- **No redirects are followed** (`redirect: false`). A redirect off the configured base is
  exactly the hole I3 exists to close.
- The API key never appears in a log, an error message, or an event. Assert it.

### `BC.Model.Fake` (in `test/support/`)

Scripted client: configured with a list of canned responses (text and/or tool calls),
returns them in order, records the messages and tools it was handed. Everything about the
session and tool loop is tested against this, so no test hits a network.

```elixir
BC.Model.Fake.script([
  {:tool_call, "kb.search", %{soc: "imx6ul"}},
  {:text, "nearest board is mk2 ..."}
])
```

## Acceptance criteria

1. A `Req.Test`-stubbed SSE response producing `["Hel", "lo"]` yields streamed chunks in
   order and a final `text: "Hello"`.
2. An SSE body deliberately split mid-JSON across two transport chunks is parsed
   correctly (regression test for the buffering bug this always has).
3. A tool-call stream with `name` in delta 0 and `arguments` split over four deltas yields
   exactly one `{:tool_call, %{name: ..., arguments: "<full json>"}}`.
4. Two parallel tool calls (indexes 0 and 1) yield two assembled calls in index order.
5. HTTP 500 twice then 200 → success with 2 retries. HTTP 400 → immediate
   `:invalid_request`, zero retries.
6. A 302 to another host is **not** followed; the call errors. **(I3)**
7. `inspect/1` of the client's request options and every returned error contains no API
   key. **(I3)**
8. Timeout is honoured within 2× the configured value.
9. Nothing in `lib/` references a vendor name, a vendor-specific field, or a model id
   literal. Grep test: `lib/` contains no occurrence of a hardcoded provider hostname.

## Test plan

`test/bc/model/openai_test.exs` using `Req.Test` plugs for every case above — no live
HTTP, no `:httpc`. SSE fixture bodies in `test/fixtures/sse/*.txt`.

## Constraints

- One HTTP client (`Req`). Do not add a second.
- Do not add provider-specific shims (no Anthropic-native, no Bedrock). If a provider
  needs a quirk, it belongs in config the operator sets, not in a branch in this module.
- No `web_fetch`, no generic "call any URL" function. This module talks to
  `config.api_base` and nothing else, and that must be visible from the code.
