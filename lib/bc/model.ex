defmodule BC.Model do
  @type message :: %{
          role: :system | :user | :assistant | :tool,
          content: String.t() | nil,
          tool_calls: [tool_call()] | nil,
          tool_call_id: String.t() | nil
        }

  @type tool_call :: %{id: String.t(), name: String.t(), arguments: String.t()}

  @type chunk ::
          {:text, String.t()}
          | {:tool_call, tool_call()}
          | {:done, %{finish_reason: String.t(), usage: map()}}

  @type opts :: [
          model: String.t(),
          tools: [map()],
          temperature: float(),
          max_tokens: pos_integer(),
          timeout_ms: pos_integer()
        ]

  @callback chat([message()], opts(), (chunk() -> any())) ::
              {:ok,
               %{
                 text: String.t(),
                 tool_calls: [tool_call()],
                 finish_reason: String.t(),
                 usage: map()
               }}
              | {:error, %{code: atom(), message: String.t()}}
end
