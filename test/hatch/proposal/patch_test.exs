defmodule Hatch.Proposal.PatchTest do
  use ExUnit.Case
  alias Hatch.Proposal.Patch

  test "parses a simple unified diff" do
    patch = """
    --- a/src/main.go
    +++ b/src/main.go
    @@ -10,3 +10,4 @@
     func main() {
     \tfmt.Println("hello")
    +\tfmt.Println("world")
     }
    """

    assert {:ok, files} = Patch.parse(patch)
    assert length(files) == 1

    file = hd(files)
    assert file.path == "src/main.go"
    assert file.op == :modify
    assert file.hunks == 1
  end

  test "parses a new file" do
    patch = """
    diff --git a/newfile.go b/newfile.go
    new file mode 100644
    index 0000000..e69de29
    --- /dev/null
    +++ b/newfile.go
    @@ -0,0 +1,3 @@
    +package main
    +
    +func Test() {}
    """

    assert {:ok, files} = Patch.parse(patch)
    file = hd(files)
    assert file.path == "newfile.go"
    assert file.op == :add
  end

  test "parses a deleted file" do
    patch = """
    diff --git a/oldfile.go b/oldfile.go
    deleted file mode 100644
    index abc123..0000000
    --- a/oldfile.go
    +++ /dev/null
    @@ -1,3 +0,0 @@
    -package main
    -
    -func Old() {}
    """

    assert {:ok, files} = Patch.parse(patch)
    file = hd(files)
    assert file.path == "oldfile.go"
    assert file.op == :delete
  end

  test "rejects absolute paths" do
    patch = """
    --- a//etc/passwd
    +++ b//etc/passwd
    @@ -1 +1 @@
    -root:x:0:0:::
    +hacked:x:0:0:::
    """

    assert {:error, err} = Patch.parse(patch)
    assert err.code == :outside_sandbox
  end

  test "rejects .. segments" do
    patch = """
    --- a/../../../etc/passwd
    +++ b/../../../etc/passwd
    """

    assert {:error, err} = Patch.parse(patch)
    assert err.code == :outside_sandbox
  end

  test "rejects .git paths" do
    patch = """
    --- a/.git/config
    +++ b/.git/config
    """

    assert {:error, err} = Patch.parse(patch)
    assert err.code == :invalid_patch
  end

  test "rejects binary patches" do
    patch = """
    diff --git a/image.png b/image.png
    GIT binary patch
    literal 1234
    zcmeAS@N?(olHy`uVBq!ia0vp0wx3...
    """

    assert {:error, err} = Patch.parse(patch)
    assert err.code == :invalid_patch
  end

  test "rejects rename patches" do
    patch = """
    diff --git a/old.go b/new.go
    similarity index 100%
    rename from old.go
    rename to new.go
    """

    assert {:error, err} = Patch.parse(patch)
    assert err.code == :invalid_patch
  end

  test "rejects copy patches" do
    patch = """
    diff --git a/original.go b/copy.go
    similarity index 95%
    copy from original.go
    copy to copy.go
    """

    assert {:error, err} = Patch.parse(patch)
    assert err.code == :invalid_patch
  end

  test "rejects patches larger than 256 KiB" do
    # Create a patch with content > 256 KiB
    large_content = String.duplicate("x", 257 * 1024)

    patch = """
    --- a/file.go
    +++ b/file.go
    @@ -1 +1 @@
    +#{large_content}
    """

    assert {:error, err} = Patch.parse(patch)
    assert err.code == :patch_too_large
  end

  test "rejects patches with more than 50 files" do
    # Create a patch that touches 51 files
    lines =
      Enum.map(1..51, fn i ->
        """
        --- a/file#{i}.go
        +++ b/file#{i}.go
        @@ -1 +1 @@
        -old
        +new
        """
      end)

    patch = Enum.join(lines, "\n")

    assert {:error, err} = Patch.parse(patch)
    assert err.code == :patch_too_large
  end

  test "normalizes line endings" do
    patch = "--- a/file.go\r\n+++ b/file.go\r\n@@ -1 +1 @@\r\n+line\r\n"

    assert {:ok, files} = Patch.parse(patch)
    assert length(files) == 1
  end

  test "ensures trailing newline" do
    patch = "--- a/file.go\n+++ b/file.go\n@@ -1 +1 @@\n+line"

    # Should not crash and should parse successfully
    assert {:ok, files} = Patch.parse(patch)
    assert length(files) == 1
  end

  test "parses multiple hunks in single file" do
    patch = """
    --- a/file.go
    +++ b/file.go
    @@ -10,3 +10,4 @@
     line10
     line11
    +added1
     line12
    @@ -20,3 +21,4 @@
     line20
     line21
    +added2
     line22
    """

    assert {:ok, files} = Patch.parse(patch)
    file = hd(files)
    assert file.hunks == 2
  end

  test "handles empty patch" do
    patch = ""

    assert {:ok, files} = Patch.parse(patch)
    assert files == []
  end
end
