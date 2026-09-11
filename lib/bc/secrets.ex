defmodule BC.Secrets do
  @moduledoc """
  Local KEY=VALUE file for API keys. Never committed.

  Default path: `config/secrets.env` (cwd). Override with `BC_SECRETS`.
  Process env always wins over the file.
  """

  @default_rel "config/secrets.env"

  @spec default_path() :: Path.t()
  def default_path do
    Path.expand(System.get_env("BC_SECRETS") || @default_rel)
  end

  @spec load(Path.t() | nil) :: map()
  def load(path \\ nil) do
    path = path || default_path()

    case File.read(path) do
      {:ok, body} -> parse(body)
      {:error, _} -> %{}
    end
  end

  @spec parse(String.t()) :: map()
  def parse(body) when is_binary(body) do
    body
    |> String.split(["\n", "\r\n"], trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      line =
        line
        |> String.trim()
        |> String.replace_prefix("export ", "")
        |> String.trim()

      cond do
        line == "" ->
          acc

        String.starts_with?(line, "#") ->
          acc

        true ->
          case String.split(line, "=", parts: 2) do
            [k, v] -> Map.put(acc, normalize_key(k), strip_quotes(v))
            _ -> acc
          end
      end
    end)
  end

  defp normalize_key(k) do
    case k |> String.trim() |> String.upcase() do
      "API_KEY" -> "BC_API_KEY"
      other -> other
    end
  end

  defp strip_quotes(v) do
    v = String.trim(v)

    if String.length(v) >= 2 do
      first = String.first(v)
      last = String.last(v)

      if first == last and first in ["\"", "'"] do
        String.slice(v, 1..-2//1)
      else
        v
      end
    else
      v
    end
  end
end
