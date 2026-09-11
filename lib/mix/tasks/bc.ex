defmodule Mix.Tasks.Bc do
  use Mix.Task

  @shortdoc "Build and run the BC TUI (requires --kb PATH)"
  @moduledoc """
  Start a conversation against your knowledge base:

      mix bc --kb ./kb
      mix bc --kb ./kb --tree ./tamago-overlay

  Uses the same options and secrets file as the `bc` executable.
  """

  @impl true
  def run(args) do
    Mix.Task.run("compile")
    BC.CLI.main(args)
  end
end
