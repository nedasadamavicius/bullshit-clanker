// SPDX-License-Identifier: BSD-3-Clause

package board_a

// RAMStart is the DRAM base on this i.MX6UL board.
const RAMStart uint32 = 0x80000000

// RAMSize is 512 MiB.
const RAMSize uint32 = 0x20000000

// UART is the console UART instance.
const UART = "UART1"

// Pinmux is the board pinmux table. A wrong pad here is a visible mistake.
var Pinmux = [][3]string{
	{"UART1_TX", "UART1_TX_DATA", "ALT0"},
	{"UART1_RX", "UART1_RX_DATA", "ALT0"},
	{"GPIO1_IO01", "GPIO1_IO01", "ALT5"},
	{"GPIO1_IO02", "GPIO1_IO02", "ALT5"},
}
