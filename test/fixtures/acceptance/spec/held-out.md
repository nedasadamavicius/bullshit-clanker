# Held-out bring-up notes

Operator notes for a new i.MX6UL board. This is not a `board.toml`; it is the
kind of markdown a human pastes into BC.

## SoC and toolchain

The silicon is an i.MX6UL. Build with GOARCH=arm and GOARM=7.

## Memory map

On-chip DRAM is mapped at 0x80000000. The exact size is not in this document
and must stay unknown — do not invent a RAM size from the SoC family.

## Console

Debug console is UART1.

The board exposes a uart console and a handful of GPIO lines. There is no PHY
described here.

## Pinmux (from the schematic, incomplete)

| signal     | pad           | fn   |
|------------|---------------|------|
| UART1_TX   | UART1_TX_DATA | ALT0 |
| UART1_RX   | UART1_RX_DATA | ALT0 |
| GPIO1_IO03 | GPIO1_IO03    | ALT5 |

TamaGo import paths for this board are not known yet.
