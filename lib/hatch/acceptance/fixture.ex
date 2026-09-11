defmodule Hatch.Acceptance.Fixture do
  @moduledoc """
  Paths and scratch copies for the v1 held-out acceptance fixture.
  """

  @held_out_id "imx6ul_held_out"
  @off_soc_id "imx8m_offsoc"

  @spec root() :: Path.t()
  def root, do: Path.expand("test/fixtures/acceptance")

  @spec kb_path() :: Path.t()
  def kb_path, do: Path.join(root(), "kb")

  @spec tree_path() :: Path.t()
  def tree_path, do: Path.join(root(), "tree")

  @spec spec_path() :: Path.t()
  def spec_path, do: Path.join(root(), "spec/held-out.md")

  @spec script_path() :: Path.t()
  def script_path, do: Path.join(root(), "script.exs")

  @spec fake_tamago_go() :: Path.t()
  def fake_tamago_go, do: Path.join(root(), "bin/tamago-go")

  @spec held_out_id() :: String.t()
  def held_out_id, do: @held_out_id

  @spec off_soc_id() :: String.t()
  def off_soc_id, do: @off_soc_id

  @spec load_script() :: map()
  def load_script do
    {script, _binding} = Code.eval_file(script_path())
    script
  end

  @spec prepare_tree(Path.t()) :: Path.t()
  def prepare_tree(source \\ tree_path()) do
    scratch =
      Path.join(System.tmp_dir!(), "hatch_accept_tree_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.dirname(scratch))
    File.cp_r!(source, scratch)
    git_init!(scratch)
    scratch
  end

  @spec prepare_kb(Path.t()) :: Path.t()
  def prepare_kb(source \\ kb_path()) do
    scratch =
      Path.join(System.tmp_dir!(), "hatch_accept_kb_#{System.unique_integer([:positive])}")

    File.cp_r!(source, scratch)
    scratch
  end

  @spec tree_hash(Path.t()) :: String.t()
  def tree_hash(path) do
    path
    |> list_files()
    |> Enum.sort()
    |> Enum.map(fn file ->
      rel = Path.relative_to(file, path)
      {:ok, data} = File.read(file)
      rel <> "\0" <> data
    end)
    |> Enum.join("\n")
    |> then(fn blob -> :crypto.hash(:sha256, blob) |> Base.encode16(case: :lower) end)
  end

  @spec git_init!(Path.t()) :: :ok
  def git_init!(dir) do
    git = System.find_executable("git") || "git"

    {_, 0} = System.cmd(git, ["init"], cd: dir, stderr_to_stdout: true)
    {_, 0} = System.cmd(git, ["config", "user.email", "hatch@example.test"], cd: dir)
    {_, 0} = System.cmd(git, ["config", "user.name", "Hatch"], cd: dir)
    {_, 0} = System.cmd(git, ["add", "-A"], cd: dir)
    {_, 0} = System.cmd(git, ["commit", "-m", "acceptance fixture"], cd: dir)
    :ok
  end

  defp list_files(path) do
    Path.wildcard(Path.join(path, "**/*"), match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(&String.contains?(&1, "/.git/"))
  end
end
