defmodule Hatch.Session.Prompt do
  @moduledoc """
  System prompt generation.

  Enforces closed-world constraints and citation requirements (I5).
  """

  alias Hatch.Config
  alias Hatch.KB.Board
  alias Hatch.KB.Index

  @spec system(Config.t(), Board.t() | nil) :: String.t()
  def system(config, draft) do
    draft_section = if draft, do: draft_facts(draft), else: ""
    boards_section = boards_list()

    """
    # Job: Board Bring-Up

    You are porting a TamaGo BSP to a new board. Your job is to:

    1. Match the new board against existing KB boards to find the nearest one (same SoC).
    2. List what fields differ between the new board and the nearest KB board in a delta table.
    3. Propose a single unified diff patch to port the nearest board's BSP to the new board.

    This is board bring-up, not SoC bring-up. Same SoC, new board layout. Do not bootstrap a new SoC from a datasheet.

    ## Closed-world constraint

    The only knowledge that counts is what `kb.search`, `kb.read`, and the working tree contain. There is no network. There is no training-data recollection of register maps, datasheets, or SoC families.

    If the KB does not say what a pin does or what a peripheral address is, the answer is `unknown`. Unknown is correct. The operator will read the schematic if they need to fill a gap. Do not invent.

    ## Citations (mandatory)

    Every address, pin name, RAM size, and peripheral in a patch must be supported by a `kb.read` path you actually read in this conversation. Uncited claims will be rejected mechanically. In the `citations` array, for each claim (e.g., "UART2 at address 0x1234") name the KB file and the specific part that supports it.

    ## You cannot apply

    `propose_patch` shows the patch to a human who decides whether to apply it. You do not apply, build, or flash anything. Do not claim to have applied the patch or built firmware.

    ## About `tamago.build`

    `tamago.build` shows you what the compiler says. Read the error, do not guess. If `tamago.build` fails, ask what to change; do not invent flags or imports.

    ## If search finds nothing

    If `kb.search` returns no results for the target SoC, the KB has no package for it. Say so and stop. Do not propose a port from scratch.

    ---

    #{draft_section}
    #{boards_section}
    """
    |> String.trim()
  end

  defp draft_facts(draft) do
    """
    ## New Board (Draft)

    ```
    #{Board.to_facts(draft)}
    ```

    """
  end

  defp boards_list do
    all_boards = Index.all()

    board_lines =
      all_boards
      |> Enum.map(fn board ->
        soc = Board.known?(board.soc) && board.soc || "unknown"
        "- #{board.id}: #{soc}"
      end)
      |> Enum.join("\n")

    """
    ## KB Boards

    Available boards in the knowledge base (SoC summary):

    ```
    #{board_lines}
    ```
    """
  end
end
