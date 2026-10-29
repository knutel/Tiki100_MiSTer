# Tiki 100 core simulation
#
#   make            build the simulator
#   make trace      run the boot ROM in the simulator and in MAME and compare traces
#   make frame      compare a video frame (FRAME, default 100) with a MAME snapshot
#   make iotest     run the CTC/DART/PIO test ROM in the simulator and in MAME
#                   and compare the results
#   make kbdtest    replay key presses into the keyboard test ROM in the
#                   simulator and in MAME and compare the key matrix scans
#
# Needs: verilator, ghdl, make, python3, z80asm, and mame for the references.
# ROMSET is a MAME tiki100 or kontiki romset zip (not committed to git).

ROMSET ?= $(firstword $(wildcard ../tiki100.zip ../kontiki.zip))
INSTRUCTIONS ?= 1000000
MAME_SECONDS ?= 2
FRAME ?= 100

OBJ  = obj
T80  = ../rtl/T80
T80_SRC = $(T80)/T80_Pack.vhd $(T80)/T80_ALU.vhd $(T80)/T80_MCode.vhd \
          $(T80)/T80_Reg.vhd $(T80)/T80.vhd $(T80)/T80pa.vhd
GHDL_FLAGS = --std=93c -fexplicit -fsynopsys --workdir=$(OBJ)

RTL = sim_top.sv ../rtl/tiki100.sv ../rtl/tiki100_video.sv ../rtl/tiki100_keyboard.sv ../rtl/z80ctc.sv \
      ../rtl/z80dart.sv ../rtl/z80pio.sv

.PHONY: all trace frame iotest kbdtest roms clean

all: $(OBJ)/Vsim_top

# Verilator can't read VHDL, so convert the T80 CPU to a Verilog netlist.
# This file is only used for simulation; Quartus builds from the VHDL.
$(OBJ)/T80pa.v: $(T80_SRC)
	mkdir -p $(OBJ)
	ghdl -a $(GHDL_FLAGS) $(T80_SRC)
	ghdl --synth $(GHDL_FLAGS) --out=verilog T80pa > $@.tmp 2> $(OBJ)/ghdl.log || (cat $(OBJ)/ghdl.log; exit 1)
	python3 -I fix_ghdl_verilog.py $@.tmp $@
	rm $@.tmp

$(OBJ)/Vsim_top: $(RTL) $(OBJ)/T80pa.v sim_main.cpp
	verilator --cc --exe --build -j 0 -O3 --top-module sim_top \
		-Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN +1364-2005ext+v \
		--Mdir $(OBJ)/verilated -o ../Vsim_top \
		$(abspath $(RTL) $(OBJ)/T80pa.v sim_main.cpp)

roms: $(OBJ)/boot.rom

$(OBJ)/boot.rom: $(ROMSET)
	@test -n "$(ROMSET)" || (echo "Set ROMSET=path/to/tiki100.zip"; exit 1)
	python3 -I extract_roms.py $(ROMSET) $(OBJ)

$(OBJ)/sim_trace.txt: $(OBJ)/Vsim_top $(OBJ)/boot.rom
	$(OBJ)/Vsim_top $(OBJ)/boot.rom $(OBJ)/boot1.rom --trace $@ --instructions $(INSTRUCTIONS)

$(OBJ)/mame_trace.log: $(ROMSET)
	mkdir -p $(OBJ)
	cd $(OBJ) && sh ../mame_trace.sh $(dir $(abspath $(ROMSET))) mame_trace.log $(MAME_SECONDS)

trace: $(OBJ)/sim_trace.txt $(OBJ)/mame_trace.log
	python3 -I compare_trace.py $(OBJ)/mame_trace.log $(OBJ)/sim_trace.txt

frame: $(OBJ)/Vsim_top $(OBJ)/boot.rom $(OBJ)/mame_frame_$(FRAME).png
	$(OBJ)/Vsim_top $(OBJ)/boot.rom $(OBJ)/boot1.rom --frames $$(($(FRAME) + 1)) --dump $(FRAME) --outdir $(OBJ)
	python3 -I compare_frame.py $(OBJ)/mame_frame_$(FRAME).png $(OBJ)/frame_$$(printf %04d $(FRAME)).ppm $(OBJ)/diff_$(FRAME).png

$(OBJ)/mame_frame_%.png: $(ROMSET)
	mkdir -p $(OBJ)
	sh mame_snap.sh $(dir $(abspath $(ROMSET))) $@ $*

$(OBJ)/iotest.rom: tests/iotest.asm
	mkdir -p $(OBJ)
	z80asm -o $@ $<

iotest: $(OBJ)/Vsim_top $(OBJ)/boot.rom $(OBJ)/iotest.rom
	$(OBJ)/Vsim_top $(OBJ)/iotest.rom $(OBJ)/boot1.rom --frames 20 --loopback 1 --results $(OBJ)/iotest_sim.txt
	sh tests/mame_results.sh $(OBJ)/iotest.rom $(OBJ)/boot1.rom $(OBJ)/iotest_mame.txt 1
	diff $(OBJ)/iotest_mame.txt $(OBJ)/iotest_sim.txt
	@echo "iotest: $$(wc -l < $(OBJ)/iotest_sim.txt) results, all match MAME"

$(OBJ)/kbdtest.rom: tests/kbdtest.asm
	mkdir -p $(OBJ)
	z80asm -o $@ $<

kbdtest: $(OBJ)/Vsim_top $(OBJ)/boot.rom $(OBJ)/kbdtest.rom
	$(OBJ)/Vsim_top $(OBJ)/kbdtest.rom $(OBJ)/boot1.rom --frames 80 --keys tests/keys_kbdtest.txt --results $(OBJ)/kbdtest_sim.txt
	python3 -I tests/mame_keys.py .. tests/keys_kbdtest.txt 80 --results $(OBJ)/kbdtest_mame.txt --rom $(OBJ)/kbdtest.rom --prom $(OBJ)/boot1.rom
	diff $(OBJ)/kbdtest_mame.txt $(OBJ)/kbdtest_sim.txt
	@echo "kbdtest: $$(grep -c A5 $(OBJ)/kbdtest_sim.txt) key matrix states, all match MAME"

clean:
	rm -rf $(OBJ)
