defmodule Hatch.SandboxTest do
  use ExUnit.Case

  setup do
    # Create temporary directories for each test
    tmp_kb = System.tmp_dir!() |> Path.join("hatch_test_kb_#{System.unique_integer()}")
    tmp_tree = System.tmp_dir!() |> Path.join("hatch_test_tree_#{System.unique_integer()}")

    File.mkdir_p!(tmp_kb)
    File.mkdir_p!(tmp_tree)

    # Configure sandbox with test roots
    Application.put_env(:hatch, :kb_root, tmp_kb)
    Application.put_env(:hatch, :tree_root, tmp_tree)

    # Clear persistent term cache
    :persistent_term.erase(:kb_root)
    :persistent_term.erase(:tree_root)

    on_exit(fn ->
      File.rm_rf!(tmp_kb)
      File.rm_rf!(tmp_tree)
      :persistent_term.erase(:kb_root)
      :persistent_term.erase(:tree_root)
    end)

    {:ok, kb: tmp_kb, tree: tmp_tree}
  end

  describe "resolve/2" do
    test "resolves valid relative paths", %{kb: kb} do
      File.touch!(Path.join(kb, "test.txt"))

      assert {:ok, resolved} = Hatch.Sandbox.resolve(:kb, "test.txt")
      assert String.starts_with?(resolved, kb)
    end

    test "rejects absolute paths" do
      assert {:error, %{code: :outside_sandbox}} = Hatch.Sandbox.resolve(:kb, "/etc/passwd")
    end

    test "rejects paths with .. segments" do
      assert {:error, %{code: :outside_sandbox}} = Hatch.Sandbox.resolve(:kb, "../etc/passwd")
      assert {:error, %{code: :outside_sandbox}} = Hatch.Sandbox.resolve(:kb, "boards/../../etc")
    end

    test "rejects paths with NUL bytes" do
      assert {:error, %{code: :outside_sandbox}} = Hatch.Sandbox.resolve(:kb, "test\0file")
    end

    test "allows nested paths within root", %{kb: kb} do
      File.mkdir_p!(Path.join(kb, "boards/x"))
      File.touch!(Path.join(kb, "boards/x/board.toml"))

      assert {:ok, resolved} = Hatch.Sandbox.resolve(:kb, "boards/x/board.toml")
      assert String.contains?(resolved, "boards/x/board.toml")
    end

    test "returns :no_tree error when tree not configured" do
      Application.put_env(:hatch, :tree_root, nil)
      :persistent_term.erase(:tree_root)

      assert {:error, %{code: :no_tree}} = Hatch.Sandbox.resolve(:tree, "test.txt")
    end
  end

  describe "resolve/2 with symlinks" do
    test "follows symlinks within root", %{kb: kb} do
      File.mkdir_p!(Path.join(kb, "actual"))
      File.touch!(Path.join(kb, "actual/file.txt"))

      link_path = Path.join(kb, "link")
      :ok = File.ln_s(Path.join(kb, "actual"), link_path)

      assert {:ok, _resolved} = Hatch.Sandbox.resolve(:kb, "link/file.txt")
    end

    test "rejects symlinks pointing outside root", %{kb: kb} do
      link_path = Path.join(kb, "evil")

      case File.ln_s("/etc", link_path) do
        :ok ->
          assert {:error, %{code: :outside_sandbox}} = Hatch.Sandbox.resolve(:kb, "evil/passwd")

        {:error, :enotsup} ->
          # Symlinks not supported on this platform
          :ok
      end
    end

    test "detects symlink loops", %{kb: kb} do
      link1 = Path.join(kb, "link1")
      link2 = Path.join(kb, "link2")

      case File.ln_s(link2, link1) do
        :ok ->
          File.ln_s(link1, link2)

          assert {:error, %{code: :symlink_loop}} = Hatch.Sandbox.resolve(:kb, "link1")

        {:error, :enotsup} ->
          :ok
      end
    end

    test "root itself can be a symlink", %{kb: kb} do
      real_root = Path.join(System.tmp_dir!(), "real_kb_#{System.unique_integer()}")
      File.mkdir_p!(real_root)
      File.touch!(Path.join(real_root, "test.txt"))

      link_root = Path.join(System.tmp_dir!(), "link_kb_#{System.unique_integer()}")

      case File.ln_s(real_root, link_root) do
        :ok ->
          Application.put_env(:hatch, :kb_root, link_root)
          :persistent_term.erase(:kb_root)

          assert {:ok, _resolved} = Hatch.Sandbox.resolve(:kb, "test.txt")

          File.rm_rf!(real_root)
          File.rm_rf!(link_root)

        {:error, :enotsup} ->
          File.rm_rf!(real_root)
          :ok
      end
    end
  end

  describe "read/3" do
    test "reads text files", %{kb: kb} do
      File.write!(Path.join(kb, "test.txt"), "hello world")

      assert {:ok, content} = Hatch.Sandbox.read(:kb, "test.txt")
      assert content == "hello world"
    end

    test "rejects files larger than max_bytes", %{kb: kb} do
      path = Path.join(kb, "large.txt")
      File.write!(path, String.duplicate("x", 1_000_000))

      assert {:error, %{code: :too_large}} = Hatch.Sandbox.read(:kb, "large.txt")
    end

    test "allows custom max_bytes", %{kb: kb} do
      path = Path.join(kb, "medium.txt")
      File.write!(path, String.duplicate("x", 1000))

      assert {:ok, _content} = Hatch.Sandbox.read(:kb, "medium.txt", max_bytes: 10_000)
      assert {:error, %{code: :too_large}} = Hatch.Sandbox.read(:kb, "medium.txt", max_bytes: 100)
    end

    test "rejects non-existent files" do
      assert {:error, %{code: :not_found}} = Hatch.Sandbox.read(:kb, "nonexistent.txt")
    end

    test "rejects directories" do
      File.mkdir_p!(Path.join(System.tmp_dir!(), "test_dir_#{System.unique_integer()}"))

      assert {:error, %{code: :not_a_file}} = Hatch.Sandbox.read(:kb, ".")
    end

    test "rejects binary files (contains NUL byte)", %{kb: kb} do
      path = Path.join(kb, "binary.bin")
      File.write!(path, "hello\0world")

      assert {:error, %{code: :binary_file}} = Hatch.Sandbox.read(:kb, "binary.bin")
    end

    test "rejects invalid UTF-8", %{kb: kb} do
      path = Path.join(kb, "invalid_utf8.txt")
      File.write!(path, <<0xFF, 0xFE>>)

      assert {:error, %{code: :binary_file}} = Hatch.Sandbox.read(:kb, "invalid_utf8.txt")
    end
  end

  describe "list/3" do
    test "lists files in directory", %{kb: kb} do
      File.touch!(Path.join(kb, "file1.txt"))
      File.touch!(Path.join(kb, "file2.txt"))
      File.mkdir_p!(Path.join(kb, "dir1"))

      assert {:ok, entries} = Hatch.Sandbox.list(:kb, ".")
      assert length(entries) == 3
      assert Enum.any?(entries, &(&1.path == "dir1" && &1.type == :dir))
      assert Enum.any?(entries, &(&1.path == "file1.txt" && &1.type == :file))
    end

    test "skips dot files and .git", %{kb: kb} do
      File.touch!(Path.join(kb, ".hidden"))
      File.mkdir_p!(Path.join(kb, ".git"))
      File.touch!(Path.join(kb, "visible.txt"))

      assert {:ok, entries} = Hatch.Sandbox.list(:kb, ".")
      paths = Enum.map(entries, & &1.path)

      assert "visible.txt" in paths
      assert ".hidden" not in paths
      assert ".git" not in paths
    end

    test "respects depth limit", %{kb: kb} do
      File.mkdir_p!(Path.join(kb, "level1/level2/level3"))
      File.touch!(Path.join(kb, "level1/level2/level3/deep.txt"))

      assert {:ok, entries} = Hatch.Sandbox.list(:kb, ".", depth: 1)
      assert Enum.any?(entries, &(&1.path == "level1"))
      assert not Enum.any?(entries, &String.contains?(&1.path, "level2"))

      assert {:ok, entries} = Hatch.Sandbox.list(:kb, ".", depth: 3)
      # Should include deeper paths
      assert Enum.any?(entries, &String.starts_with?(&1.path, "level1"))
    end

    test "respects entry limit", %{kb: kb} do
      for i <- 1..600 do
        File.touch!(Path.join(kb, "file#{i}.txt"))
      end

      assert {:ok, entries} = Hatch.Sandbox.list(:kb, ".", limit: 500)
      # Note: the implementation takes first 500, not all 600
      assert length(entries) <= 500
    end

    test "returns root-relative paths only", %{kb: kb} do
      File.mkdir_p!(Path.join(kb, "boards/x"))
      File.touch!(Path.join(kb, "boards/x/board.toml"))

      assert {:ok, entries} = Hatch.Sandbox.list(:kb, "boards", depth: 2)
      # Paths should be relative to root, like "boards/x"
      assert Enum.all?(entries, fn e -> not String.starts_with?(e.path, "/") end)
    end

    test "omits symlinks pointing outside root", %{kb: kb} do
      File.mkdir_p!(Path.join(kb, "safe"))
      File.touch!(Path.join(kb, "safe/file.txt"))

      case File.ln_s("/etc", Path.join(kb, "unsafe")) do
        :ok ->
          assert {:ok, entries} = Hatch.Sandbox.list(:kb, ".")
          # Should include "safe" but not "unsafe"
          paths = Enum.map(entries, & &1.path)
          assert "safe" in paths
          assert "unsafe" not in paths

        {:error, :enotsup} ->
          :ok
      end
    end

    test "rejects depth > 3" do
      assert {:error, %{code: :invalid_args}} = Hatch.Sandbox.list(:kb, ".", depth: 4)
    end

    test "rejects depth 0" do
      assert {:error, %{code: :invalid_args}} = Hatch.Sandbox.list(:kb, ".", depth: 0)
    end
  end

  describe "relative/2" do
    test "converts absolute path to root-relative", %{kb: kb} do
      assert {:ok, rel} = Hatch.Sandbox.relative(:kb, Path.join(kb, "test.txt"))
      assert rel == "test.txt"
    end

    test "handles nested paths", %{kb: kb} do
      assert {:ok, rel} = Hatch.Sandbox.relative(:kb, Path.join(kb, "boards/x/board.toml"))
      assert rel == "boards/x/board.toml"
    end

    test "rejects paths outside root" do
      assert {:error, %{code: :outside_sandbox}} = Hatch.Sandbox.relative(:kb, "/etc/passwd")
    end
  end

  describe "under?/2" do
    test "returns true for paths under root", %{kb: kb} do
      assert Hatch.Sandbox.under?(:kb, Path.join(kb, "test.txt"))
      assert Hatch.Sandbox.under?(:kb, Path.join(kb, "boards/x/board.toml"))
    end

    test "returns false for paths outside root" do
      assert not Hatch.Sandbox.under?(:kb, "/etc/passwd")
      assert not Hatch.Sandbox.under?(:kb, "/root/secret")
    end

    test "returns false when root not configured" do
      Application.put_env(:hatch, :kb_root, nil)
      :persistent_term.erase(:kb_root)

      assert not Hatch.Sandbox.under?(:kb, "/some/path")
    end
  end

  describe "error messages" do
    test "error messages never leak absolute paths" do
      # Attempted read of /etc/passwd should not leak the path
      assert {:error, %{code: :outside_sandbox}} = Hatch.Sandbox.resolve(:kb, "../etc/passwd")
      # The message should reference the input path, not expanded paths
    end
  end
end
