defmodule BC.Sandbox do
  @moduledoc """
  Path confinement and file operations within sandboxed roots.

  Enforces invariant I2: no tool can read outside kb_root or tree_root; symlinks out are denied.
  """

  @type root :: :kb | :tree
  @type err :: %{code: atom(), message: String.t()}
  @type entry :: %{path: String.t(), type: :file | :dir, size: non_neg_integer()}

  @max_read_bytes 256 * 1024
  @max_list_entries 500
  @max_symlink_depth 16

  @spec resolve(root(), String.t()) :: {:ok, Path.t()} | {:error, err()}
  def resolve(root, input) do
    with {:ok, root_path} <- get_root(root),
         :ok <- validate_input(input),
         expanded <- Path.expand(input, root_path),
         {:ok, resolved} <- resolve_symlinks(expanded, root_path, 0, root_path),
         :ok <- check_confinement(resolved, root_path) do
      {:ok, resolved}
    end
  end

  @spec read(root(), String.t(), keyword()) :: {:ok, String.t()} | {:error, err()}
  def read(root, path, opts \\ []) do
    max_bytes = Keyword.get(opts, :max_bytes, @max_read_bytes)

    with {:ok, abs_path} <- resolve(root, path),
         {:ok, stat} <- safe_file_stat(abs_path),
         :ok <- check_is_file(stat),
         :ok <- check_size(stat.size, max_bytes, path),
         {:ok, content} <- File.read(abs_path),
         :ok <- check_binary_content(content, path) do
      {:ok, content}
    end
  end

  @spec list(root(), String.t(), keyword()) :: {:ok, [entry()]} | {:error, err()}
  def list(root, path, opts \\ []) do
    depth = Keyword.get(opts, :depth, 1)
    limit = Keyword.get(opts, :limit, @max_list_entries)

    with {:ok, root_path} <- get_root(root),
         {:ok, abs_path} <- resolve(root, path),
         {:ok, _stat} <- safe_file_stat(abs_path),
         :ok <- validate_depth(depth) do
      entries = list_entries(abs_path, root_path, depth, limit)
      {:ok, entries}
    end
  end

  @spec relative(root(), Path.t()) :: {:ok, String.t()} | {:error, err()}
  def relative(root, abs_path) do
    with {:ok, root_path} <- get_root(root),
         :ok <- check_confinement_strict(abs_path, root_path) do
      rel = Path.relative_to(abs_path, root_path)
      {:ok, rel}
    end
  end

  @spec under?(root(), Path.t()) :: boolean()
  def under?(root, abs_path) do
    case get_root(root) do
      {:ok, root_path} ->
        case check_confinement(abs_path, root_path) do
          :ok -> true
          {:error, _} -> false
        end

      {:error, _} ->
        false
    end
  end

  # --- Internal helpers ---

  defp get_root(:kb) do
    case Application.get_env(:bc, :kb_root) do
      nil -> {:error, %{code: :no_kb, message: "KB root not configured"}}
      kb_root -> {:ok, resolve_and_memoize_root(kb_root, :kb_root)}
    end
  end

  defp get_root(:tree) do
    case Application.get_env(:bc, :tree_root) do
      nil -> {:error, %{code: :no_tree, message: "Tree root not configured"}}
      tree_root -> {:ok, resolve_and_memoize_root(tree_root, :tree_root)}
    end
  end

  # Resolve root once per input path and memoize in persistent_term to handle
  # symlinked roots. Keyed by {key, path} — not just key — since kb_root/tree_root
  # can differ across sessions/tests within the same node.
  defp resolve_and_memoize_root(path, key) do
    cache_key = {key, path}

    case :persistent_term.get(cache_key, nil) do
      nil ->
        expanded = Path.expand(path)

        case resolve_symlinks_for_root(expanded, 0) do
          {:ok, resolved} ->
            :persistent_term.put(cache_key, resolved)
            resolved

          {:error, _} ->
            # If root resolution fails, use expanded path
            :persistent_term.put(cache_key, expanded)
            expanded
        end

      resolved ->
        resolved
    end
  end

  # Resolve symlinks for the root itself (no sandbox boundary check needed)
  defp resolve_symlinks_for_root(_path, depth) when depth >= @max_symlink_depth do
    {:error, %{code: :symlink_loop, message: "Too many symlink levels"}}
  end

  defp resolve_symlinks_for_root(path, depth) do
    case :file.read_link_all(path) do
      {:ok, target_path} ->
        parent = Path.dirname(path)
        expanded_target = Path.expand(target_path, parent)
        resolve_symlinks_for_root(expanded_target, depth + 1)

      {:error, :einval} ->
        # Not a symlink
        {:ok, path}

      {:error, _} ->
        # Some other error, return as is
        {:ok, path}
    end
  end

  defp validate_input(input) do
    cond do
      String.contains?(input, "\0") ->
        {:error, %{code: :outside_sandbox, message: "Path cannot contain NUL bytes"}}

      Path.type(input) != :relative ->
        {:error, %{code: :outside_sandbox, message: "Absolute paths are not allowed"}}

      has_parent_segment?(input) ->
        {:error, %{code: :outside_sandbox, message: "Path cannot contain .. segments"}}

      true ->
        :ok
    end
  end

  defp has_parent_segment?(path) do
    Path.split(path) |> Enum.any?(&(&1 == ".."))
  end

  defp resolve_symlinks(_path, _root_path, depth, _original_root)
       when depth >= @max_symlink_depth do
    {:error, %{code: :symlink_loop, message: "Too many symlink levels"}}
  end

  defp resolve_symlinks(path, _root_path, depth, original_root) do
    # Try to resolve symlinks in the path hierarchy
    case resolve_path_components(path, original_root, depth) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, _} = err -> err
    end
  end

  # Resolve symlinks by checking each path component
  defp resolve_path_components(path, root, depth) when depth >= @max_symlink_depth do
    {:error, %{code: :symlink_loop, message: "Too many symlink levels"}}
  end

  defp resolve_path_components(path, root, depth) do
    case :file.read_link_all(path) do
      {:ok, target_path} ->
        # Path itself is a symlink
        parent = Path.dirname(path)
        expanded_target = Path.expand(target_path, parent)

        case check_confinement(expanded_target, root) do
          :ok ->
            # Continue resolving the target
            resolve_path_components(expanded_target, root, depth + 1)

          {:error, _} ->
            {:error, %{code: :outside_sandbox, message: "Symlink points outside sandbox"}}
        end

      {:error, :einval} ->
        # Not a symlink; check parent for symlinks
        parent = Path.dirname(path)

        if parent == path do
          # Reached the root
          {:ok, path}
        else
          # Resolve parent, then re-append the child component
          case resolve_path_components(parent, root, depth + 1) do
            {:ok, resolved_parent} ->
              {:ok, Path.join(resolved_parent, Path.basename(path))}

            {:error, _} = err ->
              err
          end
        end

      {:error, _other} ->
        # Some other error, treat as non-existent symlink
        {:ok, path}
    end
  end

  defp check_confinement(abs_path, root_path) do
    root_segments = Path.split(root_path)
    path_segments = Path.split(abs_path)

    cond do
      # Exact match
      root_segments == path_segments ->
        :ok

      # Path is under root (has root as prefix and continues with /)
      match_prefix(path_segments, root_segments) ->
        :ok

      true ->
        {:error, %{code: :outside_sandbox, message: "Path is outside sandbox"}}
    end
  end

  defp check_confinement_strict(abs_path, root_path) do
    case check_confinement(abs_path, root_path) do
      :ok -> :ok
      {:error, _} = err -> err
    end
  end

  defp match_prefix(path_segments, root_segments) do
    case Enum.split(path_segments, length(root_segments)) do
      {prefix, [_ | _]} -> prefix == root_segments
      _ -> false
    end
  end

  defp safe_file_stat(path) do
    case File.stat(path) do
      {:ok, stat} -> {:ok, stat}
      {:error, :enoent} -> {:error, %{code: :not_found, message: "File not found"}}
      {:error, _} -> {:error, %{code: :not_found, message: "File not found"}}
    end
  end

  defp check_is_file(%File.Stat{type: :regular}), do: :ok

  defp check_is_file(%File.Stat{type: :directory}) do
    {:error, %{code: :not_a_file, message: "Path is a directory, not a file"}}
  end

  defp check_is_file(_), do: {:error, %{code: :not_a_file, message: "Path is not a regular file"}}

  defp check_size(size, max_bytes, _path) when size > max_bytes do
    {:error,
     %{
       code: :too_large,
       message:
         "File is #{size} bytes; max #{max_bytes}. Read a smaller file or ask for a specific section."
     }}
  end

  defp check_size(_size, _max_bytes, _path), do: :ok

  defp check_binary_content(content, _path) do
    case is_text_content(content) do
      true ->
        :ok

      false ->
        {:error,
         %{
           code: :binary_file,
           message:
             "File is not text. Schematics are ingested offline into board.toml / nets.json; they are not read live."
         }}
    end
  end

  defp is_text_content(content) do
    sniff = String.slice(content, 0..8191)

    case String.valid?(sniff) do
      false ->
        false

      true ->
        # Check for NUL bytes
        not String.contains?(sniff, "\0")
    end
  end

  defp validate_depth(depth) when depth > 0 and depth <= 3 do
    :ok
  end

  defp validate_depth(_), do: {:error, %{code: :invalid_args, message: "Depth must be 1-3"}}

  defp list_entries(dir, root, depth, limit) do
    do_list_entries(dir, root, depth, limit, [])
    |> Enum.sort_by(fn entry -> {entry.type == :dir, entry.path} end, :desc)
    |> Enum.take(limit)
  end

  defp do_list_entries(_dir, _root, depth, limit, acc) when depth <= 0 or length(acc) >= limit do
    acc
  end

  defp do_list_entries(dir, root, depth, limit, acc) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&(not String.starts_with?(&1, ".")))
        |> Enum.reduce(acc, fn name, current_acc ->
          path = Path.join(dir, name)

          case File.lstat(path) do
            {:ok, lstat} ->
              # For symlinks, check if target is within root
              skip? = lstat.type == :symlink && is_symlink_outside_root?(path, root)

              if skip? do
                current_acc
              else
                # Use File.stat to get info about target (for directories and regular files)
                case File.stat(path) do
                  {:ok, stat} ->
                    rel_path = Path.relative_to(path, root)
                    type = if stat.type == :directory, do: :dir, else: :file
                    entry = %{path: rel_path, type: type, size: stat.size}
                    new_acc = [entry | current_acc]

                    if stat.type == :directory and depth > 1 and length(new_acc) < limit do
                      do_list_entries(path, root, depth - 1, limit, new_acc)
                    else
                      new_acc
                    end

                  :error ->
                    # File.stat failed (maybe broken symlink), skip it
                    current_acc
                end
              end

            :error ->
              current_acc
          end
        end)

      {:error, _} ->
        acc
    end
  end

  defp is_symlink_outside_root?(symlink_path, root) do
    case :file.read_link_all(symlink_path) do
      {:ok, target} ->
        parent = Path.dirname(symlink_path)
        expanded = Path.expand(target, parent)

        case check_confinement(expanded, root) do
          :ok -> false
          {:error, _} -> true
        end

      {:error, _} ->
        false
    end
  end
end
