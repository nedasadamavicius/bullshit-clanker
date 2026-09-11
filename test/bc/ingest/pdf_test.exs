defmodule BC.Ingest.PdfTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias BC.Ingest.Pdf
  alias BC.KB.Loader
  alias BC.Model.Fake
  alias BC.Test.MiniPdf

  setup do
    Application.put_env(:bc, :model_client, BC.Model.Fake)
    Application.put_env(:bc, :fake_model, Fake.script([]))

    root = Path.join(System.tmp_dir!(), "bc_pdf_#{System.unique_integer([:positive])}")
    kb = Path.join(root, "kb")
    File.mkdir_p!(Path.join(kb, "boards"))

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, kb: kb}
  end

  test "extract_text/1 reads a text-layer PDF via pdftotext", %{root: root} do
    pdf = Path.join(root, "board.pdf")

    MiniPdf.write!(pdf, [
      "The board uses an i.MX6UL SoC.",
      "RAM start address: 0x80000000",
      "Debug console is UART2."
    ])

    assert {:ok, text} = Pdf.extract_text(pdf)
    assert text =~ "i.MX6UL"
    assert text =~ "0x80000000"
    assert text =~ "UART2"
  end

  test "extract_text/1 errors on missing pdftotext-able empty file", %{root: root} do
    pdf = Path.join(root, "empty.pdf")
    MiniPdf.write!(pdf, [])
    assert {:error, %{code: :empty}} = Pdf.extract_text(pdf)
  end

  test "ingest_file/3 writes board.toml and copies the schematic", %{root: root, kb: kb} do
    pdf = Path.join(root, "imx6ul-mk2.pdf")

    MiniPdf.write!(pdf, [
      "The board uses an i.MX6UL SoC.",
      "RAM start address: 0x80000000",
      "Debug console is UART2."
    ])

    Application.put_env(
      :bc,
      :fake_model,
      Fake.script([
        {:text,
         ~s({"soc":"i.MX6UL","evidence_soc":"i.MX6UL","ram_start":"0x80000000","evidence_ram_start":"0x80000000","uart":"UART2","evidence_uart":"UART2"})}
      ])
    )

    assert {:ok, result} = Pdf.ingest_file(pdf, kb, extract_nets: false)
    assert result.id == "imx6ul_mk2"
    assert result.board.soc == "i.MX6UL"
    assert result.board.uart == "UART2"
    assert result.board.ram_size == :unknown

    toml = Path.join(result.dest, "board.toml")
    schematic = Path.join(result.dest, "schematic.pdf")
    assert File.exists?(toml)
    assert File.exists?(schematic)

    {:ok, loaded, _} = Loader.load(toml)
    assert loaded.id == "imx6ul_mk2"
    assert loaded.soc == "i.MX6UL"
    assert loaded.uart == "UART2"
    assert loaded.ram_start == 0x80000000
    assert loaded.ram_size == :unknown
    refute File.exists?(Path.join(result.dest, "nets.json"))
  end

  test "ingest_file/3 refuses to overwrite without force", %{root: root, kb: kb} do
    pdf = Path.join(root, "dup.pdf")
    MiniPdf.write!(pdf, ["The board uses an i.MX6UL SoC."])

    Application.put_env(
      :bc,
      :fake_model,
      Fake.script([
        {:text, ~s({"soc":"i.MX6UL","evidence_soc":"i.MX6UL"})}
      ])
    )

    assert {:ok, _} = Pdf.ingest_file(pdf, kb, extract_nets: false)

    Application.put_env(
      :bc,
      :fake_model,
      Fake.script([
        {:text, ~s({"soc":"i.MX6UL","evidence_soc":"i.MX6UL"})}
      ])
    )

    assert {:error, %{code: :exists}} = Pdf.ingest_file(pdf, kb, extract_nets: false)
  end

  test "ingest_paths/3 ingests each PDF in a directory as its own board", %{root: root, kb: kb} do
    dir = Path.join(root, "datasheets")
    File.mkdir_p!(dir)
    MiniPdf.write!(Path.join(dir, "board_a.pdf"), ["The board uses an i.MX6UL SoC."])
    MiniPdf.write!(Path.join(dir, "board_b.pdf"), ["The silicon is STM32H7."])

    Application.put_env(
      :bc,
      :fake_model,
      Fake.script_many([
        [{:text, ~s({"soc":"i.MX6UL","evidence_soc":"i.MX6UL"})}],
        [{:text, ~s({"soc":"STM32H7","evidence_soc":"STM32H7"})}]
      ])
    )

    assert {:ok, results} = Pdf.ingest_paths([dir], kb, extract_nets: false)
    ids = Enum.map(results, & &1.id) |> Enum.sort()
    assert ids == ["board_a", "board_b"]
    assert File.exists?(Path.join([kb, "boards", "board_a", "board.toml"]))
    assert File.exists?(Path.join([kb, "boards", "board_b", "board.toml"]))
  end

  test "ingest_file/3 writes nets.json when the PDF names a net", %{root: root, kb: kb} do
    pdf = Path.join(root, "netted.pdf")
    MiniPdf.write!(pdf, ["UART2_TX on U1 pin 12. SoC i.MX6UL."])

    Application.put_env(
      :bc,
      :fake_model,
      Fake.script_many([
        [{:text, ~s({"soc":"i.MX6UL","evidence_soc":"i.MX6UL"})}],
        [
          {:text,
           ~s({"nets":[{"name":"UART2_TX","pins":[{"ref":"U1","pin":"12"}],"value":"unknown"}]})}
        ]
      ])
    )

    assert {:ok, result} = Pdf.ingest_file(pdf, kb, extract_nets: true)
    nets_path = Path.join(result.dest, "nets.json")
    assert File.exists?(nets_path)
    {:ok, decoded} = Jason.decode(File.read!(nets_path))
    assert hd(decoded["nets"])["name"] == "UART2_TX"
  end

  test "mix bc.kb.ingest --help does not require a key" do
    output =
      capture_io(fn ->
        assert {:halted, 0} == catch_throw(Mix.Tasks.BC.Kb.Ingest.run(["--help"]))
      end)

    assert output =~ "BC_API_KEY"
    assert output =~ "pdftotext"
  end

  test "mix bc.kb.ingest refuses to run without BC_API_KEY" do
    previous = %{
      "BC_API_KEY" => System.get_env("BC_API_KEY"),
      "XAI_API_KEY" => System.get_env("XAI_API_KEY"),
      "ANTHROPIC_API_KEY" => System.get_env("ANTHROPIC_API_KEY")
    }

    Enum.each(Map.keys(previous), &System.delete_env/1)

    output =
      capture_io(:stderr, fn ->
        assert {:halted, 1} == catch_throw(Mix.Tasks.BC.Kb.Ingest.run(["--kb", "./kb"]))
      end)

    assert output =~ "BC_API_KEY"

    Enum.each(previous, fn
      {k, nil} -> System.delete_env(k)
      {k, v} -> System.put_env(k, v)
    end)
  end
end
