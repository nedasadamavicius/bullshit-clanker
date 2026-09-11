defmodule BC.Proposal.Patch do
  @moduledoc """
  Unified diff parser and validator (I2, I4).

  Pure parsing — this module does not apply anything.

  Rejects:
  - Absolute paths, .. segments, /dev/null on both sides
  - Rename/copy headers
  - Binary patches (GIT binary patch)
  - Paths under .git/
  - Patches larger than 256 KiB or touching more than 50 files
  """

  require Logger

  @max_patch_size 256 * 1024
  @max_files 50

  @type operation :: :modify | :add | :delete
  @type parsed_file :: %{op: operation, path: String.t(), hunks: pos_integer()}
  @type err :: %{code: atom(), message: String.t()}

  @spec parse(String.t()) :: {:ok, [parsed_file()]} | {:error, err()}
  def parse(patch_text) when is_binary(patch_text) do
    # Normalize line endings to \n and ensure trailing newline
    normalized = normalize_patch(patch_text)

    # Check size
    if byte_size(normalized) > @max_patch_size do
      {:error, %{code: :patch_too_large, message: "patch exceeds #{@max_patch_size} bytes"}}
    else
      # Parse and validate
      lines = String.split(normalized, "\n", trim: false)
      parse_lines(lines, %{files: [], current_file: nil, hunk_count: 0, errors: []})
    end
  end

  defp normalize_patch(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> then(fn t -> if String.ends_with?(t, "\n"), do: t, else: t <> "\n" end)
  end

  defp parse_lines([], acc) do
    if Enum.any?(acc.errors) do
      {:error, List.first(acc.errors)}
    else
      files = acc.files |> Enum.reverse() |> Enum.uniq_by(& &1.path)

      if length(files) > @max_files do
        {:error,
         %{code: :patch_too_large, message: "patch touches more than #{@max_files} files"}}
      else
        {:ok, files}
      end
    end
  end

  defp parse_lines([line | rest], acc) do
    cond do
      # diff --git header (may be multi-line, but we just track it)
      String.starts_with?(line, "diff --git") ->
        # Parse the paths from "diff --git a/path b/path"
        case parse_diff_git_line(line) do
          {:ok, _path_a, _path_b} ->
            # Continue, we'll get the actual file header next
            parse_lines(rest, acc)

          :skip ->
            parse_lines(rest, acc)

          {:error, err} ->
            parse_lines(rest, %{acc | errors: [err | acc.errors]})
        end

      # --- file headers
      String.starts_with?(line, "--- ") ->
        # Extract path from "--- a/path" or "--- /path"
        path = String.slice(line, 4..-1//1) |> String.trim_trailing()

        if String.starts_with?(path, "/dev/null") do
          # Might be a delete, continue to next line for confirmation
          parse_lines(rest, %{acc | current_file: nil})
        else
          # Remove the "a/" prefix if present
          path = remove_leading_a_or_b(path)

          # Validate the path
          case validate_path(path) do
            :ok ->
              parse_lines(rest, %{acc | current_file: {path, :pending}})

            {:error, err} ->
              parse_lines(rest, %{acc | errors: [err | acc.errors]})
          end
        end

      # +++ file headers (confirm operation type)
      String.starts_with?(line, "+++ ") ->
        path = String.slice(line, 4..-1//1) |> String.trim_trailing()

        cond do
          String.starts_with?(path, "/dev/null") ->
            # Delete operation
            case acc.current_file do
              {file_path, :pending} ->
                new_file = %{op: :delete, path: file_path, hunks: 1}
                parse_lines(rest, %{acc | files: [new_file | acc.files], current_file: nil})

              nil ->
                # Error: --- was /dev/null but +++ is not
                err = %{
                  code: :invalid_patch,
                  message: "invalid patch structure: --- /dev/null without --- header"
                }

                parse_lines(rest, %{acc | errors: [err | acc.errors]})
            end

          true ->
            path = remove_leading_a_or_b(path)

            case validate_path(path) do
              :ok ->
                # Determine operation
                op =
                  case acc.current_file do
                    nil -> :add
                    {_p, :pending} -> :modify
                  end

                new_file = %{op: op, path: path, hunks: 0}
                parse_lines(rest, %{acc | files: [new_file | acc.files], current_file: nil})

              {:error, err} ->
                parse_lines(rest, %{acc | errors: [err | acc.errors]})
            end
        end

      # Hunk headers @@ ... @@
      String.starts_with?(line, "@@") ->
        # Increment hunk count for current file
        updated_files =
          if acc.current_file do
            acc.files
          else
            case acc.files do
              [last | others] ->
                [%{last | hunks: last.hunks + 1} | others]

              [] ->
                []
            end
          end

        parse_lines(rest, %{acc | files: updated_files})

      # Skip diff preamble lines (new file mode, etc.)
      String.starts_with?(line, "new file mode") ->
        parse_lines(rest, acc)

      String.starts_with?(line, "deleted file mode") ->
        parse_lines(rest, acc)

      String.starts_with?(line, "index ") ->
        parse_lines(rest, acc)

      String.starts_with?(line, "similarity index") ->
        parse_lines(rest, acc)

      String.starts_with?(line, "rename from") ->
        # Reject rename/copy
        err = %{code: :invalid_patch, message: "renames and copies are not supported"}
        parse_lines(rest, %{acc | errors: [err | acc.errors]})

      String.starts_with?(line, "rename to") ->
        err = %{code: :invalid_patch, message: "renames and copies are not supported"}
        parse_lines(rest, %{acc | errors: [err | acc.errors]})

      String.starts_with?(line, "copy from") ->
        err = %{code: :invalid_patch, message: "renames and copies are not supported"}
        parse_lines(rest, %{acc | errors: [err | acc.errors]})

      String.starts_with?(line, "copy to") ->
        err = %{code: :invalid_patch, message: "renames and copies are not supported"}
        parse_lines(rest, %{acc | errors: [err | acc.errors]})

      # Detect binary patches
      String.starts_with?(line, "GIT binary patch") ->
        err = %{code: :invalid_patch, message: "binary patches are not supported"}
        parse_lines(rest, %{acc | errors: [err | acc.errors]})

      # Skip content lines (context, additions, deletions)
      String.starts_with?(line, " ") or
        String.starts_with?(line, "+") or
        String.starts_with?(line, "-") or
          String.match?(line, ~r/^\\ /) ->
        parse_lines(rest, acc)

      # Skip empty lines or unknown lines
      true ->
        parse_lines(rest, acc)
    end
  end

  defp parse_diff_git_line(line) do
    # Format: "diff --git a/path b/path"
    case String.match?(line, ~r/^diff --git a\/(.+) b\/(.+)$/) do
      true ->
        # We'll validate the paths when we see --- and +++ headers
        :skip

      false ->
        # Could be a malformed diff --git
        if String.starts_with?(line, "diff --git") do
          :skip
        else
          :skip
        end
    end
  end

  defp remove_leading_a_or_b(path) do
    cond do
      String.starts_with?(path, "a/") -> String.slice(path, 2..-1//1)
      String.starts_with?(path, "b/") -> String.slice(path, 2..-1//1)
      true -> path
    end
  end

  @spec validate_path(String.t()) :: :ok | {:error, err()}
  defp validate_path(path) do
    cond do
      # Absolute paths
      String.starts_with?(path, "/") ->
        {:error, %{code: :outside_sandbox, message: "absolute paths are not allowed"}}

      # .. segments
      String.contains?(path, "..") ->
        {:error, %{code: :outside_sandbox, message: ".. segments are not allowed"}}

      # .git paths
      String.starts_with?(path, ".git/") or String.starts_with?(path, ".git\\") ->
        {:error, %{code: :invalid_patch, message: ".git paths cannot be modified"}}

      true ->
        :ok
    end
  end
end
