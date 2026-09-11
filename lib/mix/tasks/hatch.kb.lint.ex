defmodule Mix.Tasks.Hatch.Kb.Lint do
  @moduledoc """
  Lints the KB, checking board.toml files for parse errors and warnings.

  Usage:

      mix hatch.kb.lint --kb ./kb

  Prints per-board id, soc, and warnings; then a summary line.
  Exit 1 if any board failed to parse, 0 otherwise (warnings do not fail).
  """

  use Mix.Task

  alias Hatch.KB.Loader

  @shortdoc "Lint the KB"

  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [kb: :string])

    case Keyword.get(opts, :kb) do
      nil ->
        Mix.raise("--kb is required")

      kb_root ->
        lint_kb(kb_root)
    end
  end

  defp lint_kb(kb_root) do
    kb_abs = Path.expand(kb_root)

    case Loader.load_all(kb_abs) do
      {:ok, boards, warnings} ->
        print_results(boards, warnings)
        exit_code = if Enum.empty?(boards), do: 1, else: 0
        System.halt(exit_code)

      {:error, err} ->
        Mix.shell().error("Error: #{err.message}")
        System.halt(1)
    end
  end

  defp print_results(boards, warnings) do
    boards
    |> Enum.each(fn board ->
      IO.write("#{board.id}")

      if board.soc != :unknown do
        IO.write(" [#{board.soc}]")
      else
        IO.write(" [unknown soc]")
      end

      IO.write("\n")

      board_warnings = Enum.filter(warnings, &(&1.board_id == board.id))

      if Enum.empty?(board_warnings) do
        IO.write("  No warnings\n")
      else
        board_warnings
        |> Enum.each(fn w ->
          IO.write("  #{Atom.to_string(w.field)}: #{w.message}\n")
        end)
      end

      IO.write("\n")
    end)

    board_count = length(boards)
    warning_count = length(warnings)

    IO.write("#{board_count} boards, #{warning_count} warnings\n")
  end
end
