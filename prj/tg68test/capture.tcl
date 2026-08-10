#! ./oocd.sh
#
# IceSugarPro demo JTAG script
#

init
scan_chain

# 16-bit project ID, so we can be sure we're capturing from the correct design
set projectid 0x68ff

# The total number of bits here must match the width defined in jcapture_pkg.vhd
source ./capturefields.tcl

set loc [file dirname [file normalize [info script]]]
source ${loc}/../../rtl/jtag/jcapture.tcl

# Enumerate user IR codes, starting at 0
set ::jcapture::usercodes {
	reset kickselect addr read write
}

proc sendreset { v } {
	::jcapture::usercmd reset $v
}

proc selkick { v } {
	::jcapture::usercmd kickselect $v
}

puts "Setting TAP, capture fields and length"

::jcapture::setup target.tap $capture_fields $projectid

# Ensure device is in reset

# sendreset 1

::jcapture::settrigger edge clkena 1
::jcapture::settrigger mask clkena 1
::jcapture::settrigger value clkena 1

::jcapture::settrigger edge screenwhite 0
::jcapture::settrigger mask screenwhite 0
::jcapture::settrigger value screenwhite 0

::jcapture::settrigger edge addr 0x00000000
::jcapture::settrigger mask addr 0x00020000
::jcapture::settrigger value addr 0x00e80000

::jcapture::settrigger edge cpustate 0
::jcapture::settrigger mask cpustate 0x3
::jcapture::settrigger value cpustate 0x2

::jcapture::setsubsample 0

puts "Recording to cap.vcd"
# 	sendreset 1
#	selkick 0
#	sendreset 0

	set chan [::jcapture::create_vcd cap.vcd 0]
	::jcapture::setleadin 1

	::jcapture::capture
	# Release reset, 
 	sendreset 2
	::jcapture::wait_fifofull
	::jcapture::fifo_to_vcd $chan 
	puts [::jcapture::getstatus]
exit


