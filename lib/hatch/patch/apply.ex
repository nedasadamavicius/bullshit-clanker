defmodule Hatch.Patch.Apply do
  @moduledoc """
  Apply a patch to the working tree via git, gated by a permit (I4, I8).

  Behaviour + implementation. The only write path into tree_root.
  Uses git apply as an argv port with 30 second timeout.
  """

  require Logger

  # 30 seconds
  @timeout_ms 30 * 1000

  @spec apply_patch(Hatch.Proposal.t(), Hatch.Permit.t(), String.t()) ::
          {:ok, %{output: String.t(), files: [String.t()]}} | {:error, map()}
  def apply_patch(proposal, permit, tree_root) do
    # Permit check is first, before any filesystem access
    with :ok <- verify_permit(proposal, permit) do
      do_apply(proposal, tree_root)
    else
      {:error, reason} ->
        {:error, %{code: reason, message: error_message(reason)}}
    end
  end

  defp verify_permit(proposal, permit) do
    # Check proposal id matches
    if permit.proposal_id != proposal.id do
      {:error, :no_permit}
    else
      # Check patch hash matches (stale check)
      if permit.patch_hash != Hatch.Proposal.patch_hash(proposal) do
        {:error, :stale}
      else
        # Consume the permit (checks expiry and spent status)
        Hatch.Permit.consume(permit)
      end
    end
  end

  defp do_apply(proposal, tree_root) do
    # Re-parse patch and re-validate sandbox constraints
    with {:ok, parsed_files} <- Hatch.Proposal.Patch.parse(proposal.patch),
         :ok <- validate_sandbox(parsed_files, tree_root) do
      # Write patch to temp file
      with {:ok, tmpfile} <- write_temp_patch(proposal.patch) do
        try do
          # Run git apply --check
          with {:ok, _output} <- run_git_apply_check(tree_root, tmpfile),
               # Run git apply
               {:ok, _output} <- run_git_apply(tree_root, tmpfile) do
            files = Enum.map(parsed_files, & &1.path)
            {:ok, %{output: "Applied patch to #{length(files)} file(s)", files: files}}
          else
            {:error, reason} -> {:error, reason}
          end
        after
          File.rm(tmpfile)
        end
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_sandbox(parsed_files, tree_root) do
    # Validate each file path in the patch against sandbox constraints
    Enum.reduce_while(parsed_files, :ok, fn file, _acc ->
      # Check if the file path would be within the tree_root
      full_path = Path.join(tree_root, file.path)

      case Hatch.Sandbox.under?(:tree, full_path) do
        true ->
          {:cont, :ok}

        false ->
          {:halt,
           {:error, %{code: :outside_sandbox, message: "Patch targets file outside sandbox"}}}
      end
    end)
  end

  defp write_temp_patch(patch_text) do
    tmpfile = Path.join(System.tmp_dir!(), "patch_#{:erlang.unique_integer([:positive])}")

    case File.write(tmpfile, patch_text) do
      :ok ->
        {:ok, tmpfile}

      {:error, reason} ->
        {:error, %{code: :io_error, message: "Failed to write temp file: #{inspect(reason)}"}}
    end
  end

  defp run_git_apply_check(tree_root, tmpfile) do
    run_git_apply_internal(tree_root, tmpfile, true)
  end

  defp run_git_apply(tree_root, tmpfile) do
    run_git_apply_internal(tree_root, tmpfile, false)
  end

  defp run_git_apply_internal(tree_root, tmpfile, check_only) do
    git_path = System.find_executable("git") || "git"
    args = ["apply", "--whitespace=nowarn"] ++ ((check_only && ["--check"]) || []) ++ [tmpfile]

    port =
      Port.open({:spawn_executable, git_path}, [
        {:args, ["-C", tree_root] ++ args},
        :binary,
        :use_stdio,
        :exit_status
      ])

    receive_port_result(port, "", check_only, tmpfile)
  end

  defp receive_port_result(port, acc_output, check_only, tmpfile, timeout \\ @timeout_ms) do
    receive do
      {^port, {:data, data}} ->
        receive_port_result(port, acc_output <> data, check_only, tmpfile, timeout)

      {^port, {:exit_status, 0}} ->
        {:ok, acc_output}

      {^port, {:exit_status, status}} ->
        stage = if check_only, do: "patch check", else: "patch apply"

        {:error,
         %{
           code: :patch_conflict,
           message: "git #{stage} failed (status #{status}): #{acc_output}"
         }}
    after
      timeout ->
        Port.close(port)
        {:error, %{code: :timeout, message: "git apply timed out after #{timeout}ms"}}
    end
  end

  defp error_message(:no_permit), do: "No valid permit to apply patch"
  defp error_message(:spent), do: "Permit has already been used"
  defp error_message(:expired), do: "Permit has expired (valid for 5 minutes)"
  defp error_message(:stale), do: "Proposal has been superseded; permit is no longer valid"
  defp error_message(reason), do: "Apply failed: #{inspect(reason)}"
end
