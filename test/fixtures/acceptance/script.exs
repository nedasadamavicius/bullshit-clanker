# Recorded acceptance script. Mechanism test, not a model eval.
# Model: gpt-4o  Date: 2026-09-11
#
# Ingest turn extracts only what the held-out markdown states.
# Session turns: closed-world probes, search, read, propose.

%{
  ingest: [
    [
      {:text,
       ~s({"soc":"imx6ul","evidence_soc":"i.MX6UL","goarch":"arm","evidence_goarch":"GOARCH=arm","goarm":"7","evidence_goarm":"GOARM=7","ram_start":"0x80000000","evidence_ram_start":"0x80000000","uart":"UART1","evidence_uart":"UART1","peripherals":["uart","gpio"],"evidence_peripherals":"uart console and a handful of GPIO","pinmux":[{"signal":"UART1_TX","pad":"UART1_TX_DATA","fn":"ALT0"},{"signal":"UART1_RX","pad":"UART1_RX_DATA","fn":"ALT0"},{"signal":"GPIO1_IO03","pad":"GPIO1_IO03","fn":"ALT5"}],"evidence_pinmux":"UART1_TX"})}
    ]
  ],
  session: [
    [
      {:tool_call, "web_fetch", %{"url" => "https://example.com/imx6ul"}},
      {:tool_call, "kb.read", %{"path" => "/etc/passwd"}}
    ],
    [
      {:tool_call, "kb.search", %{"soc" => "imx6ul"}}
    ],
    [
      {:tool_call, "kb.read", %{"path" => "boards/imx6ul_board_a/board.toml"}}
    ],
    [
      {:text,
       "Nearest same-SoC board is the UART1 sibling. Proposing a pinmux row for GPIO1_IO03 cited from the KB file just read."},
      {:tool_call, "propose_patch",
       %{
         "nearest_board_id" => "imx6ul_board_a",
         "summary" =>
           "Port imx6ul_board_a to the held-out board by adding the GPIO1_IO03 pinmux row. RAM start 0x80000000 and UART1 stay the same. RAM size is unknown in the spec.",
         "deltas" => [
           %{"field" => "pinmux", "from" => "board_a rows", "to" => "plus GPIO1_IO03"},
           %{"field" => "ram_size", "from" => "0x20000000", "to" => "unknown"}
         ],
         "citations" => [
           %{
             "path" => "boards/imx6ul_board_a/board.toml",
             "claim" => "UART1 at RAMStart 0x80000000; GPIO1_IO03 pad GPIO1_IO03 fn ALT5"
           }
         ],
         "patch" => File.read!(Path.join(__DIR__, "expected.patch"))
       }}
    ]
  ]
}
