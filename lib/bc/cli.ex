defmodule BC.CLI do
  @spec main([String.t()]) :: no_return()
  def main(argv) do
    case BC.Config.from_argv(argv) do
      {:halt, code, :help} ->
        print_help()
        do_halt(code)

      {:halt, code, :version} ->
        version = Application.spec(:bc, :vsn)
        IO.puts(version)
        do_halt(code)

      {:ok, config} ->
        BC.Config.put(config)
        Application.put_env(:bc, :kb_root, config.kb_root)

        if config.tree_root do
          Application.put_env(:bc, :tree_root, config.tree_root)
        end

        start_app()
        _ = BC.KB.Index.ensure_built()
        {:ok, session_id, _pid} = BC.BoardJob.Supervisor.start_session([])
        maybe_ingest_spec(session_id, config)
        board_count = count_boards(config.kb_root)

        tree_display =
          if config.tree_root, do: config.tree_root, else: "none"

        IO.puts(
          "bc ready — kb=#{config.kb_root} boards=#{board_count} tree=#{tree_display} model=#{config.model}"
        )

        # Start the TUI event loop
        BC.TUI.run(session_id, config, board_count)

        do_halt(0)

      {:error, %{message: message}} ->
        IO.write(:stderr, "bc: #{message}\n")
        do_halt(2)
    end
  end

  defp start_app do
    {:ok, _} = Application.ensure_all_started(:bc)
    :ok
  end

  defp do_halt(code) do
    halt_fn = Application.get_env(:bc, :halt, &System.halt/1)
    halt_fn.(code)
  end

  defp print_help do
    IO.puts("""
    BC — AI-assisted TamaGo bring-up

    Usage: bc [OPTIONS]

    Options:
      --kb PATH          Path to knowledge base (required)
      --tree PATH        Path to working tree (optional)
      --spec PATH        Path to board spec (markdown or board.toml)
      --help             Show this help message
      --version          Show version

    Model:
      Default provider is Claude. Put ANTHROPIC_API_KEY in
      config/secrets.env (copy config/secrets.env.example).
      Env vars still override the file.

      BC_PROVIDER     claude (default) | xai | openai
      BC_API_KEY      or ANTHROPIC_API_KEY / XAI_API_KEY
      BC_MODEL / BC_API_BASE   defaults per provider
    """)
  end

  defp maybe_ingest_spec(_session_id, %BC.Config{spec_text: nil}), do: :ok

  defp maybe_ingest_spec(session_id, %BC.Config{spec_text: spec_text}) do
    spec_id = "spec"

    case BC.Ingest.ingest(spec_text, spec_id) do
      {:ok, draft, _conflicts} ->
        BC.Session.set_draft(session_id, draft)

      {:error, err} ->
        IO.write(:stderr, "bc: spec ingest failed: #{err.message}\n")
        :ok
    end
  end

  defp count_boards(kb_root) do
    kb_root
    |> Path.join("boards/*/board.toml")
    |> Path.wildcard()
    |> Enum.reject(&(Path.basename(Path.dirname(&1)) |> String.starts_with?("_")))
    |> length()
  end
end
