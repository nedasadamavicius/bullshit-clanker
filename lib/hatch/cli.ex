defmodule Hatch.CLI do
  @spec main([String.t()]) :: no_return()
  def main(argv) do
    case Hatch.Config.from_argv(argv) do
      {:halt, code, :help} ->
        print_help()
        do_halt(code)

      {:halt, code, :version} ->
        version = Mix.Project.config()[:version]
        IO.puts(version)
        do_halt(code)

      {:ok, config} ->
        Hatch.Config.put(config)
        start_app()
        {:ok, _session_id, _pid} = Hatch.BoardJob.Supervisor.start_session([])
        board_count = count_boards(config.kb_root)

        tree_display =
          if config.tree_root, do: config.tree_root, else: "none"

        IO.puts(
          "hatch ready — kb=#{config.kb_root} boards=#{board_count} tree=#{tree_display} model=#{config.model}"
        )

        do_halt(0)

      {:error, %{message: message}} ->
        IO.write(:stderr, "hatch: #{message}\n")
        do_halt(2)
    end
  end

  defp start_app do
    :ok = Application.ensure_started(:hatch)
  end

  defp do_halt(code) do
    halt_fn = Application.get_env(:hatch, :halt, &System.halt/1)
    halt_fn.(code)
  end

  defp print_help do
    IO.puts("""
    Hatch — AI-assisted TamaGo bring-up

    Usage: hatch [OPTIONS]

    Options:
      --kb PATH          Path to knowledge base (required)
      --tree PATH        Path to working tree (optional)
      --help             Show this help message
      --version          Show version
    """)
  end

  defp count_boards(kb_root) do
    kb_root
    |> Path.join("boards/*/board.toml")
    |> Path.wildcard()
    |> length()
  end
end
