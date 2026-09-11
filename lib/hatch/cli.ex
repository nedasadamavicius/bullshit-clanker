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
        Application.put_env(:hatch, :kb_root, config.kb_root)

        if config.tree_root do
          Application.put_env(:hatch, :tree_root, config.tree_root)
        end

        start_app()
        _ = Hatch.KB.Index.ensure_built()
        {:ok, session_id, _pid} = Hatch.BoardJob.Supervisor.start_session([])
        maybe_ingest_spec(session_id, config)
        board_count = count_boards(config.kb_root)

        tree_display =
          if config.tree_root, do: config.tree_root, else: "none"

        IO.puts(
          "hatch ready — kb=#{config.kb_root} boards=#{board_count} tree=#{tree_display} model=#{config.model}"
        )

        # Start the TUI event loop
        Hatch.TUI.run(session_id, config, board_count)

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
      --spec PATH        Path to board spec (markdown or board.toml)
      --help             Show this help message
      --version          Show version
    """)
  end

  defp maybe_ingest_spec(_session_id, %Hatch.Config{spec_text: nil}), do: :ok

  defp maybe_ingest_spec(session_id, %Hatch.Config{spec_text: spec_text}) do
    spec_id = "spec"

    case Hatch.Ingest.ingest(spec_text, spec_id) do
      {:ok, draft, _conflicts} ->
        Hatch.Session.set_draft(session_id, draft)

      {:error, err} ->
        IO.write(:stderr, "hatch: spec ingest failed: #{err.message}\n")
        :ok
    end
  end

  defp count_boards(kb_root) do
    kb_root
    |> Path.join("boards/*/board.toml")
    |> Path.wildcard()
    |> length()
  end
end
