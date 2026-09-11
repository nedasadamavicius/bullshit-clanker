defmodule Hatch.KB.Nets do
  @moduledoc """
  Load nets.json from a board directory.
  """

  alias Hatch.Sandbox

  @type net :: %{
          name: String.t(),
          pins: [%{ref: String.t(), pin: String.t()}],
          value: String.t() | :unknown
        }
  @type err :: %{code: atom(), message: String.t()}

  @spec load(Path.t()) :: {:ok, %{nets: [net()], source: String.t()}} | {:error, err()}
  def load(nets_json_path) do
    case Sandbox.read(
           :kb,
           Path.relative_to(nets_json_path, Application.get_env(:hatch, :kb_root, "/"))
         ) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, decoded} ->
            nets = parse_nets(decoded)
            {:ok, %{nets: nets, source: nets_json_path}}

          {:error, _} ->
            {:error, %{code: :invalid_args, message: "Invalid JSON in nets.json"}}
        end

      {:error, %{code: :not_found}} ->
        {:error, %{code: :not_found, message: "nets.json not found"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Internal helpers ---

  defp parse_nets(data) when is_list(data) do
    data
    |> Enum.filter(&is_map/1)
    |> Enum.map(&parse_net/1)
  end

  defp parse_nets(data) when is_map(data) do
    case Map.get(data, "nets") do
      nets when is_list(nets) -> parse_nets(nets)
      _ -> []
    end
  end

  defp parse_nets(_), do: []

  defp parse_net(net_map) when is_map(net_map) do
    %{
      name: Map.get(net_map, "name", "unknown"),
      pins: parse_pins(Map.get(net_map, "pins", [])),
      value: Map.get(net_map, "value", :unknown)
    }
  end

  defp parse_net(_), do: %{name: "unknown", pins: [], value: :unknown}

  defp parse_pins(pins) when is_list(pins) do
    pins
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn pin_map ->
      %{ref: Map.get(pin_map, "ref", ""), pin: Map.get(pin_map, "pin", "")}
    end)
  end

  defp parse_pins(_), do: []
end
