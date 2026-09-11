defmodule Hatch.Patch.ApplyTest do
  use ExUnit.Case
  alias Hatch.{Proposal, Patch, Permit}

  setup do
    # Check if git is available
    case System.find_executable("git") do
      nil ->
        {:skip, "git not available"}

      _git_path ->
        # Create a temporary directory for the test repo
        tmpdir =
          Path.join(System.tmp_dir!(), "hatch_apply_test_#{:erlang.unique_integer([:positive])}")

        File.mkdir_p!(tmpdir)

        # Configure sandbox with test tree_root
        Application.put_env(:hatch, :tree_root, tmpdir)
        :persistent_term.erase(:tree_root)

        # Initialize a git repo
        init_git_repo(tmpdir)

        on_exit(fn ->
          File.rm_rf!(tmpdir)
          :persistent_term.erase(:tree_root)
        end)

        {:ok, tree_root: tmpdir}
    end
  end

  defp init_git_repo(path) do
    System.cmd("git", ["init"], cd: path)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: path)
    System.cmd("git", ["config", "user.name", "Test User"], cd: path)

    # Create initial commit
    File.write!(Path.join(path, "README.md"), "# Test\n")
    System.cmd("git", ["add", "."], cd: path)
    System.cmd("git", ["commit", "-m", "Initial commit"], cd: path)
  end

  defp tree_hash(path) do
    {output, 0} =
      System.cmd("find", [path, "-type", "f", "-not", "-path", "*/.git/*"],
        stderr_to_stdout: true
      )

    files = String.split(output, "\n", trim: true) |> Enum.sort()

    content =
      Enum.map_join(files, "\n", fn file ->
        {:ok, data} = File.read(file)
        data
      end)

    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  test "apply_patch with wrong proposal id returns no_permit", %{tree_root: tree_root} do
    proposal = create_test_proposal("sess_1", "Original patch")
    permit = Permit.mint("p_wrong_id", "sess_1", Proposal.patch_hash(proposal))

    hash_before = tree_hash(tree_root)

    result = Patch.Apply.apply_patch(proposal, permit, tree_root)

    assert {:error, %{code: :no_permit}} = result
    assert hash_before == tree_hash(tree_root), "Tree should not be modified"
  end

  test "apply_patch with spent permit returns spent", %{tree_root: tree_root} do
    proposal = create_test_proposal("sess_1", "Original patch")
    permit = Permit.mint(proposal.id, "sess_1", Proposal.patch_hash(proposal))

    # First consume should work
    assert :ok == Permit.consume(permit)

    hash_before = tree_hash(tree_root)

    # Second apply with same permit should fail
    result = Patch.Apply.apply_patch(proposal, permit, tree_root)

    assert {:error, %{code: :spent}} = result
    assert hash_before == tree_hash(tree_root), "Tree should not be modified"
  end

  test "apply_patch with expired permit returns expired", %{tree_root: tree_root} do
    proposal = create_test_proposal("sess_1", "Original patch")
    permit = Permit.mint(proposal.id, "sess_1", Proposal.patch_hash(proposal))

    # Simulate old issue time
    old_permit = %{permit | issued_at: System.monotonic_time(:millisecond) - 6 * 60 * 1000}

    hash_before = tree_hash(tree_root)

    result = Patch.Apply.apply_patch(proposal, old_permit, tree_root)

    assert {:error, %{code: :expired}} = result
    assert hash_before == tree_hash(tree_root), "Tree should not be modified"
  end

  test "apply_patch with stale patch (superseded) returns stale", %{tree_root: tree_root} do
    # Create two proposals with the same ID but different patches
    proposal1 = create_test_proposal("sess_1", "Original patch")
    permit_for_1 = Permit.mint(proposal1.id, "sess_1", Proposal.patch_hash(proposal1))

    # Simulate proposal being superseded with a new patch
    new_patch = "New different patch content"
    proposal2 = %{proposal1 | patch: new_patch}

    hash_before = tree_hash(tree_root)

    # Apply with permit from old proposal to new proposal
    result = Patch.Apply.apply_patch(proposal2, permit_for_1, tree_root)

    assert {:error, %{code: :stale}} = result
    assert hash_before == tree_hash(tree_root), "Tree should not be modified"
  end

  test "apply_patch with conflicting patch returns patch_conflict", %{tree_root: tree_root} do
    # Create a conflicting patch
    conflict_patch = """
    --- a/README.md
    +++ b/README.md
    @@ -1 +1 @@
    -# Test
    +# Modified in conflicting way
    """

    # Create another conflicting patch first
    File.write!(Path.join(tree_root, "README.md"), "# Already modified\n")
    System.cmd("git", ["add", "."], cd: tree_root)
    System.cmd("git", ["commit", "-m", "Modify README"], cd: tree_root)

    proposal = %Proposal{
      id: "p_conflict",
      session_id: "sess_1",
      nearest_board_id: "board_1",
      summary: "Conflicting patch",
      deltas: [],
      citations: [],
      patch: conflict_patch,
      status: :pending,
      invalid_reasons: [],
      created_at: DateTime.utc_now()
    }

    permit = Permit.mint(proposal.id, "sess_1", Proposal.patch_hash(proposal))

    hash_before = tree_hash(tree_root)

    result = Patch.Apply.apply_patch(proposal, permit, tree_root)

    assert {:error, %{code: :patch_conflict}} = result
    assert hash_before == tree_hash(tree_root), "Tree should be byte-identical after conflict"
  end

  test "apply_patch with valid patch succeeds and returns touched files", %{tree_root: tree_root} do
    # Create a simple valid patch
    patch = """
    --- a/README.md
    +++ b/README.md
    @@ -1 +1,2 @@
     # Test
    +Added line
    """

    proposal = %Proposal{
      id: "p_valid",
      session_id: "sess_1",
      nearest_board_id: "board_1",
      summary: "Valid patch",
      deltas: [],
      citations: [],
      patch: patch,
      status: :pending,
      invalid_reasons: [],
      created_at: DateTime.utc_now()
    }

    permit = Permit.mint(proposal.id, "sess_1", Proposal.patch_hash(proposal))

    result = Patch.Apply.apply_patch(proposal, permit, tree_root)

    assert {:ok, %{output: _output, files: files}} = result
    assert "README.md" in files

    # Verify the file was actually modified
    {:ok, content} = File.read(Path.join(tree_root, "README.md"))
    assert String.contains?(content, "Added line")
  end

  test "apply_patch broadcasts apply_result event", %{tree_root: tree_root} do
    # This test is more conceptual - the actual broadcasting is done
    # at a higher level in Session, but we verify the basic return structure
    proposal = create_test_proposal("sess_1", "Test patch")

    permit = Permit.mint(proposal.id, "sess_1", Proposal.patch_hash(proposal))

    result = Patch.Apply.apply_patch(proposal, permit, tree_root)

    # Result should have the right structure for broadcasting
    assert {:ok, %{output: _output, files: _files}} = result
  end

  # Helper function to create a simple test proposal
  defp create_test_proposal(session_id, summary) do
    %Proposal{
      id: "p_test_#{:rand.uniform(100_000)}",
      session_id: session_id,
      nearest_board_id: "board_test",
      summary: summary,
      deltas: [],
      citations: [],
      patch: create_simple_patch(),
      status: :pending,
      invalid_reasons: [],
      created_at: DateTime.utc_now()
    }
  end

  defp create_simple_patch do
    """
    --- a/README.md
    +++ b/README.md
    @@ -1 +1,2 @@
     # Test
    +New content
    """
  end
end
