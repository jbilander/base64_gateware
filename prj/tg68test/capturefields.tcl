# The total number of bits here must match the width defined in jcapture_pkg.vhd
set capture_fields {
	{ cpustate 2 }
	{ reset_n 1 }
	{ addr 32 }
	{ dtack 1 }
	{ state 4 }
	{ sel_autoconfig 1 }
	{ clkena 1 }
	{ rle 1 }
}
