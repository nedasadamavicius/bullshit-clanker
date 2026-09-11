package held_out

const RAMStart uint32 = 0x80000000
const RAMSize uint32 = 0x20000000
const UART = "UART1"

var Pinmux = [][3]string{
	{"UART1_TX", "UART1_TX_DATA", "ALT0"},
	{"UART1_RX", "UART1_RX_DATA", "ALT0"},
	{"GPIO1_IO03", "GPIO1_IO03", "ALT5"},
}
