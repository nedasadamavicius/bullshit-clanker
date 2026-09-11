defmodule Hatch.Acceptance.Report do
  @moduledoc """
  acceptance.json / acceptance-history.jsonl writer.
  """

  @fields [
    :nearest_board,
    :expected_board,
    :citations_ok,
    :uncited_tokens,
    :apply_ok,
    :build_exit,
    :duration_ms,
    :usage
  ]

  @spec new(map() | keyword()) :: map()
  def new(attrs) do
    attrs = Map.new(attrs)

    %{
      nearest_board: Map.get(attrs, :nearest_board),
      expected_board: Map.get(attrs, :expected_board),
      citations_ok: Map.get(attrs, :citations_ok, false),
      uncited_tokens: Map.get(attrs, :uncited_tokens, []),
      apply_ok: Map.get(attrs, :apply_ok, false),
      build_exit: Map.get(attrs, :build_exit, 1),
      duration_ms: Map.get(attrs, :duration_ms, 0),
      usage: Map.get(attrs, :usage, %{})
    }
  end

  @spec passed?(map()) :: boolean()
  def passed?(report) do
    report.nearest_board == report.expected_board and
      report.citations_ok == true and
      report.apply_ok == true and
      report.build_exit == 0
  end

  @spec write_json(Path.t(), map()) :: :ok
  def write_json(path, report) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(encode(report)))
    :ok
  end

  @spec append_history(Path.t(), map()) :: :ok
  def append_history(path, report) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(encode(report)) <> "\n", [:append])
    :ok
  end

  @spec read_json(Path.t()) :: {:ok, map()} | {:error, term()}
  def read_json(path) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body) do
      {:ok, decoded}
    end
  end

  @spec fields() :: [atom()]
  def fields, do: @fields

  defp encode(report) do
    Map.new(@fields, fn field -> {Atom.to_string(field), Map.get(report, field)} end)
  end
end
