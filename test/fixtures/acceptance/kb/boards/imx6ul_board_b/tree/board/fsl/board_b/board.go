package board_b

const RAMStart uint32 = 0x80000000
const RAMSize uint32 = 0x20000000
const UART = "UART2"

var Pinmux = [][3]string{
	{"UART2_TX", "UART2_TX_DATA", "ALT0"},
	{"UART2_RX", "UART2_RX_DATA", "ALT0"},
}
