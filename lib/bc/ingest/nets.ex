defmodule BC.Ingest.Nets do
  @moduledoc """
  Extract nets.json records from schematic/spec text. Records, not summaries.
  """

  @spec extract(String.t()) :: {:ok, [map()]} | {:error, %{code: atom(), message: String.t()}}
  def extract(text) when is_binary(text) do
    model_client = Application.get_env(:bc, :model_client, BC.Model.OpenAI)

    messages = [
      %{
        role: :user,
        content: nets_prompt(String.slice(text, 0, 12_000)),
        tool_calls: nil,
        tool_call_id: nil
      }
    ]

    case model_client.chat(messages, [temperature: 0.0, tools: []], fn _ -> :ok end) do
      {:ok, result} ->
        {:ok, parse_nets(result.text, text)}

      {:error, _} ->
        {:ok, []}
    end
  end

  defp nets_prompt(chunk) do
    """
    Extract named nets from this schematic or board text. Return JSON only:

    {"nets":[{"name":"UART2_TX","pins":[{"ref":"U1","pin":"12"}],"value":"unknown"}]}

    Rules:
    - Only include a net if the document names it.
    - pins[].ref and pins[].pin only when the document names a component ref and pin.
    - value is a voltage/net class if stated, otherwise "unknown".
    - Never invent nets from SoC knowledge.
    - If none, return {"nets":[]}.

    Text:
    ---
    #{chunk}
    ---
    """
  end

  defp parse_nets(response, source_text) do
    json = unwrap_json(response || "")

    case Jason.decode(json) do
      {:ok, %{"nets" => nets}} when is_list(nets) ->
        nets
        |> Enum.map(&normalize_net/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(fn net ->
          net.name != "unknown" and String.contains?(source_text, net.name)
        end)

      {:ok, nets} when is_list(nets) ->
        parse_nets(Jason.encode!(%{"nets" => nets}), source_text)

      _ ->
        []
    end
  end

  defp normalize_net(net) when is_map(net) do
    name = net["name"] || net[:name]

    if is_binary(name) and String.trim(name) != "" do
      %{
        name: String.trim(name),
        pins: normalize_pins(net["pins"] || net[:pins] || []),
        value: net["value"] || net[:value] || :unknown
      }
    end
  end

  defp normalize_net(_), do: nil

  defp normalize_pins(pins) when is_list(pins) do
    Enum.flat_map(pins, fn
      %{"ref" => ref, "pin" => pin} when is_binary(ref) and is_binary(pin) ->
        [%{ref: ref, pin: pin}]

      %{ref: ref, pin: pin} when is_binary(ref) and is_binary(pin) ->
        [%{ref: ref, pin: pin}]

      _ ->
        []
    end)
  end

  defp normalize_pins(_), do: []

  defp unwrap_json(text) do
    trimmed = String.trim(text)

    case Regex.run(~r/\{[\s\S]*\}/, trimmed) do
      [json] -> json
      _ -> trimmed
    end
  end
end
