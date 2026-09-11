defmodule Hatch.Tools.KB do
  @moduledoc """
  KB search and read tools.
  """

  alias Hatch.Sandbox
  alias Hatch.Tools.Args
  alias Hatch.Tools.ReadLog

  @spec search(map(), Hatch.Tools.ctx()) ::
          {:ok, String.t()} | {:error, %{code: atom(), message: String.t()}}
  def search(args, ctx) do
    soc = Map.get(args, "soc")
    uart = Map.get(args, "uart")
    peripherals = Map.get(args, "peripherals", [])
    text = Map.get(args, "text")
    limit = Map.get(args, "limit", 5)

    with :ok <- validate_search_args(soc, uart, peripherals, text, limit),
         {:ok, limit_val} <- Args.integer_range(%{"limit" => limit}, "limit", 1, 20, 5) do
      exclude = search_exclude(args, ctx)

      query =
        %{}
        |> then(fn q -> if soc, do: Map.put(q, :soc, soc), else: q end)
        |> then(fn q -> if uart, do: Map.put(q, :uart, uart), else: q end)
        |> then(fn q ->
          if Enum.any?(peripherals), do: Map.put(q, :peripherals, peripherals), else: q
        end)
        |> then(fn q -> if text, do: Map.put(q, :text, text), else: q end)
        |> then(fn q -> if Enum.any?(exclude), do: Map.put(q, :exclude, exclude), else: q end)
        |> Map.put(:limit, limit_val)

      case Hatch.KB.Search.search(query) do
        {:ok, hits} ->
          # Log all hit paths to read-log
          Enum.each(hits, fn hit ->
            ReadLog.log(ctx.read_log, hit.board.source_path, "kb.search")
          end)

          result = build_search_result(hits, soc)
          {:ok, Jason.encode!(result)}

        {:error, err} ->
          {:error, err}
      end
    end
  end

  @spec read(map(), Hatch.Tools.ctx()) ::
          {:ok, String.t()} | {:error, %{code: atom(), message: String.t()}}
  def read(args, ctx) do
    with {:ok, path} <- Args.string(args, "path"),
         {:ok, max_bytes} <- Args.integer(args, "max_bytes", 256 * 1024) do
      case Sandbox.read(:kb, path, max_bytes: max_bytes) do
        {:ok, content} ->
          # Log successful read
          ReadLog.log(ctx.read_log, path, "kb.read")

          wrapped =
            "<file path=\"#{html_escape(path)}\" bytes=\"#{byte_size(content)}\">\n#{content}\n</file>"

          {:ok, wrapped}

        {:error, err} ->
          {:error, err}
      end
    else
      {:error, msg} ->
        {:error, %{code: :invalid_args, message: msg}}
    end
  end

  defp search_exclude(args, _ctx) do
    from_args = List.wrap(Map.get(args, "exclude") || [])
    from_env = List.wrap(Application.get_env(:hatch, :search_exclude, []))
    Enum.uniq(from_args ++ from_env)
  end

  # --- Helpers ---

  defp validate_search_args(soc, uart, peripherals, text, limit) do
    has_filter =
      soc != nil or
        uart != nil or
        Enum.any?(peripherals) or
        text != nil

    cond do
      not has_filter ->
        {:error,
         %{
           code: :invalid_args,
           message: "at least one of soc, uart, peripherals, or text is required"
         }}

      not is_integer(limit) or limit < 1 or limit > 20 ->
        {:error, %{code: :invalid_args, message: "limit must be an integer between 1 and 20"}}

      not (is_nil(soc) or is_binary(soc)) ->
        {:error, %{code: :invalid_args, message: "soc must be a string"}}

      not (is_nil(uart) or is_binary(uart)) ->
        {:error, %{code: :invalid_args, message: "uart must be a string"}}

      not (is_list(peripherals) and Enum.all?(peripherals, &is_binary/1)) ->
        {:error, %{code: :invalid_args, message: "peripherals must be a list of strings"}}

      not (is_nil(text) or is_binary(text)) ->
        {:error, %{code: :invalid_args, message: "text must be a string"}}

      true ->
        :ok
    end
  end

  defp build_search_result([], soc) do
    note =
      if soc do
        "no board in the KB has this soc. hatch cannot propose a port for an soc with no package in the KB."
      else
        "no matching board found in the KB."
      end

    %{
      "hits" => [],
      "count" => 0,
      "note" => note
    }
  end

  defp build_search_result(hits, _soc) do
    hit_list =
      Enum.map(hits, fn hit ->
        %{
          "id" => hit.board.id,
          "path" => hit.board.source_path,
          "soc" => format_value(hit.board.soc),
          "soc_match" => Atom.to_string(hit.soc_match),
          "score" => hit.score,
          "why" => hit.why,
          "facts" => board_facts(hit.board)
        }
      end)

    %{
      "hits" => hit_list,
      "count" => length(hit_list)
    }
  end

  defp board_facts(board) do
    %{}
    |> add_fact("ram_start", board.ram_start)
    |> add_fact("ram_size", board.ram_size)
    |> add_fact("uart", board.uart)
    |> add_fact("peripherals", if(Enum.any?(board.peripherals), do: board.peripherals))
    |> add_fact("tamago_soc", board.tamago_soc)
    |> add_fact("tree", board.tree)
  end

  defp add_fact(facts, _key, :unknown), do: facts
  defp add_fact(facts, _key, []), do: facts
  defp add_fact(facts, _key, nil), do: facts

  defp add_fact(facts, key, num) when is_integer(num) do
    Map.put(facts, key, "0x#{Integer.to_string(num, 16)}")
  end

  defp add_fact(facts, key, val) do
    Map.put(facts, key, val)
  end

  defp format_value(:unknown), do: "unknown"
  defp format_value(val), do: val

  defp html_escape(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
