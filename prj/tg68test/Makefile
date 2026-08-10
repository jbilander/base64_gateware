PRJ=tg68test
OBJ_DIR=obj_dir
IMPL_DIR=impl1

FIRMWARE = firmware/Firmware.hex

HDL_FILES = ../../fpga/icesugarpro_board_pkg.sv ../../rtl/sdram_pkg.sv ../../rtl/base64_m68k_pkg.sv ../../rtl/hostclocks.sv \
			../../rtl/cpu_pkg.sv ../../rtl/m68k_bridge.sv ../../rtl/cpu_probe.sv ../../rtl/tg68wrapper.sv virtualtoplevel.sv \
			Firmware_ROM.sv ../../rtl/peripherals/uart.sv ../../rtl/peripherals/spi.sv ../../rtl/sdram.sv \
			../../rtl/autoconfig/autoconfig.v 

HDL_FILES_SYNTH = $(HDL_FILES) ../../fpga/base64_icesugarpro_top.sv ../../pll/ecp5_14MHz_85MHz/clocks/clocks.sbx \
            ../../pll/ecp5_25MHz_100MHz/supervisorclk/supervisorclk.sbx \
			../../rtl/TG68K.C/TG68K_Pack.vhd ../../rtl/TG68K.C/TG68K_ALU.vhd ../../rtl/TG68K.C/TG68KdotC_Kernel.vhd \
			../../rtl/jtag/vjtag_ecp5.sv ../../rtl/jtag/vjtag_sync_fifo.sv ../../rtl/jtag/jcapture.sv \
			../../rtl/autoconfig/autoconfig_rom.vhd

HDL_FILES_SIM = $(HDL_FILES) ../../sim/clocks.sv ../../sim/jcapture.sv ../../sim/tg68.v \
			../../rtl/autoconfig/autoconfig_rom.v ../../sim/mt48lc16m16a2.v tb.sv

PROJ_FILE = $(PRJ).ldf
BIT_FILE = impl1/$(PRJ)_impl1.bit

all: info

../../site.mk: 
	$(info )
	$(info site.mk not found -)
	$(info copy ../../site.template to ../../site.mk, then edit site.mk to set tool paths)
	$(info )
	$(info )
	
include ../../site.mk

.phony info:
info: ../../site.mk
	$(info )
	$(info | > make sim - build and run a simulation of clocking using verilator.)
	$(info |              output file: sim.vcd)
	$(info |)
	$(info | > make bit - use lattice diamondc to build the bitstream from source.)
	$(info |)
	$(info | > make pgm - configure the FPGA using openFPGALoader)
	$(info |)
	$(info | > make cap - connect to the design using openOCD and capture a trace. )
	$(info |              output file: cap.vcd)
	$(info )

.phony sim_clean:
sim_clean:
	-rm tb
	-rm $(OBJ_DIR)/*

.phony firmware_clean:
firmware_clean:
	-make -C firmware clean

.phony synth_clean:
synth_clean:
	-rm $(IMPL_DIR)/*

.phony clean:
clean: sim_clean firmware_clean
	

# Project synthesis

bit: $(BIT_FILE)

$(BIT_FILE): $(HDL_FILES_SYNTH) $(FIRMWARE)
	echo prj_project open ${PROJ_FILE} \; prj_run Export -task Bitgen | $(DIAMOND_PATH)/diamondc

$(FIRMWARE):
	make -C ../../fw
	make -C firmware

# Configure FPGA
.phony pgm:
pgm: $(BIT_FILE)
	../../fpga/icesugarpro_pgm.sh $(BIT_FILE)


# Attempt to capture a trace from the running design

.phony cap:
cap: $(BIT_FILE)
	openocd -f ../../fpga/icesugarpro.cfg -f capture.tcl

.phony softkick:
softkick: $(BIT_FILE)
	openocd -f ../../fpga/icesugarpro.cfg -f softkick.tcl

# Simulation

${OBJ_DIR}/Vtb.cpp: ${HDL_FILES_SIM}
	verilator -cc -exe -MMD --no-timing --trace --top-module tb -cc tb.cpp ${HDL_FILES_SIM}

$(OBJ_DIR)/Vtb: ${OBJ_DIR}/Vtb.cpp tb.cpp
	make -j -C ${OBJ_DIR} -f Vtb.mk CXX=$(CXX)
	
sim: $(FIRMWARE) $(OBJ_DIR)/Vtb
	$(OBJ_DIR)/Vtb

../../sim/TG68KdotC_Kernel.v:
	make -C ../../sim



