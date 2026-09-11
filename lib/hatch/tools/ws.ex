defmodule Hatch.Tools.WS do
  @moduledoc """
  Working tree read tools: ws.read, ws.list, ws.diff.
  """

  alias Hatch.Sandbox
  alias Hatch.Tools.Args

  @spec read(map(), Hatch.Tools.ctx()) ::
          {:ok, String.t()} | {:error, %{code: atom(), message: String.t()}}
  def read(args, _ctx) do
    with {:ok, path} <- Args.string(args, "path"),
         {:ok, max_bytes} <- Args.integer(args, "max_bytes", 256 * 1024) do
      case Sandbox.read(:tree, path, max_bytes: max_bytes) do
        {:ok, content} ->
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

  @spec list(map(), Hatch.Tools.ctx()) ::
          {:ok, String.t()} | {:error, %{code: atom(), message: String.t()}}
  def list(args, _ctx) do
    with {:ok, path} <- Args.string(args, "path", "."),
         {:ok, depth} <- Args.integer_range(args, "depth", 1, 3, 1) do
      case Sandbox.list(:tree, path, depth: depth) do
        {:ok, entries} ->
          result = %{
            "entries" =>
              Enum.map(entries, fn e ->
                %{
                  "path" => e.path,
                  "type" => Atom.to_string(e.type),
                  "size" => e.size
                }
              end)
          }

          {:ok, Jason.encode!(result)}

        {:error, err} ->
          {:error, err}
      end
    else
      {:error, msg} ->
        {:error, %{code: :invalid_args, message: msg}}
    end
  end

  @spec diff(map(), Hatch.Tools.ctx()) ::
          {:ok, String.t()} | {:error, %{code: atom(), message: String.t()}}
  def diff(_args, _ctx) do
    config = Application.get_env(:hatch, :config)

    case config.tree_root do
      nil ->
        {:error, %{code: :no_tree, message: "Tree root is not configured"}}

      tree_root ->
        run_git_diff(tree_root)
    end
  end

  # --- Helpers ---

  defp run_git_diff(tree_root) do
    timeout_ms = 10_000
    max_output = 64 * 1024

    # Spawn git diff as a port (I8: no shell)
    cmd = "git"
    args = ["-C", tree_root, "diff", "--no-color"]

    try do
      case spawn_port(cmd, args, timeout_ms) do
        {:ok, output} ->
          if byte_size(output) > max_output do
            truncated =
              String.slice(output, 0, max_output) <>
                "\n... (truncated)\n"

            {:ok, truncated}
          else
            {:ok, output}
          end

        {:error, %{code: :not_a_repo}} ->
          {:error, %{code: :not_a_repo, message: "Tree is not a git repository"}}

        {:error, err} ->
          {:error, err}
      end
    rescue
      _e ->
        {:error, %{code: :tool_crashed, message: "Failed to run git diff"}}
    end
  end

  defp spawn_port(cmd, args, timeout_ms) do
    executable = System.find_executable(cmd)

    case executable do
      nil ->
        {:error, %{code: :not_found, message: "Command not found: #{cmd}"}}

      exe_path ->
        try do
          port = Port.open({:spawn_executable, exe_path}, [:binary, :exit_status, args: args])

          output =
            receive do
              {^port, {:data, data}} ->
                data

              {^port, {:exit_status, status}} ->
                if status == 128 do
                  # git returns 128 when not a repo
                  :not_a_repo
                else
                  ""
                end
            after
              timeout_ms ->
                try do
                  Port.close(port)
                rescue
                  _e -> :ok
                end

                {:error, %{code: :timeout, message: "git diff timed out after #{timeout_ms}ms"}}
            end

          case output do
            :not_a_repo ->
              {:error, %{code: :not_a_repo, message: "Not a git repository"}}

            {:error, _} = err ->
              err

            data ->
              {:ok, data}
          end
        rescue
          _e ->
            {:error, %{code: :tool_crashed, message: "Failed to spawn git"}}
        end
    end
  end

  defp html_escape(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
