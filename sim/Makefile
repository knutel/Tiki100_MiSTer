# Tiki 100 core simulation
#
#   make            build the simulator
#   make trace      run the boot ROM in the simulator and in MAME and compare traces
#                   (BOOTROM=1 for TIKI ROM 1.35, BOOTROM=2 for 1.30; default 0, 2.03w)
#   make frame      compare a video frame (FRAME, default 100) with a MAME snapshot
#   make iotest     run the CTC/DART/PIO test ROM in the simulator and in MAME
#                   and compare the results
#   make sound      run the AY-3-8912 test ROM in the simulator and in MAME:
#                   compare register read-back and the recorded sound
#   make tiko       boot TIKO from a disk image (DISK, default the 400K TIKO
#                   2.08r image) and compare frame TIKO_FRAME with MAME (up to
#                   16 pixels may differ: the cursor blinks in its own phase).
#                   TIKO_KEYS=file replays key presses in both.
#   make tikodir    boot TIKO, choose B (file list) from its menu and compare
#                   the directory listing at frame 900
#   make kbdtest    replay key presses into the keyboard test ROM in the
#                   simulator and in MAME and compare the key matrix scans
#
# Needs: verilator, ghdl, make, python3, z80asm, and mame for the references.
# ROMSET is a MAME tiki100 or kontiki romset zip (not committed to git).

ROMSET ?= $(firstword $(wildcard ../tiki100.zip ../kontiki.zip))
INSTRUCTIONS ?= 1000000
MAME_SECONDS ?= 2
FRAME ?= 100
DISK ?= $(OBJ)/tiko208r-400k.dsk
TIKO_FRAME ?= 600
TIKO_KEYS ?=
BOOTROM ?= 0
MAME_MACHINE = $(if $(filter 1,$(BOOTROM)),tiki100 -bios v135,$(if $(filter 2,$(BOOTROM)),kontiki,tiki100))
TRACE_SUFFIX = $(if $(filter 0,$(BOOTROM)),,_rom$(BOOTROM))
BOOTROM_ARGS = $(if $(filter 0,$(BOOTROM)),,--boot2 $(OBJ)/boot2.rom --boot3 $(OBJ)/boot3.rom --bootrom $(BOOTROM))

OBJ  = obj
T80  = ../rtl/T80
T80_SRC = $(T80)/T80_Pack.vhd $(T80)/T80_ALU.vhd $(T80)/T80_MCode.vhd \
          $(T80)/T80_Reg.vhd $(T80)/T80.vhd $(T80)/T80pa.vhd
GHDL_FLAGS = --std=93c -fexplicit -fsynopsys --workdir=$(OBJ)

RTL = sim_top.sv ../rtl/tiki100.sv ../rtl/tiki100_video.sv ../rtl/tiki100_keyboard.sv ../rtl/wd1793.sv $(OBJ)/ym2149.sv ../rtl/z80ctc.sv \
      ../rtl/z80dart.sv ../rtl/z80pio.sv

.PHONY: all trace frame iotest kbdtest sound tiko tikodir roms clean

all: $(OBJ)/Vsim_top

# Verilator can't read VHDL, so convert the T80 CPU to a Verilog netlist.
# This file is only used for simulation; Quartus builds from the VHDL.
$(OBJ)/T80pa.v: $(T80_SRC)
	mkdir -p $(OBJ)
	ghdl -a $(GHDL_FLAGS) $(T80_SRC)
	ghdl --synth $(GHDL_FLAGS) --out=verilog T80pa > $@.tmp 2> $(OBJ)/ghdl.log || (cat $(OBJ)/ghdl.log; exit 1)
	python3 -I fix_ghdl_verilog.py $@.tmp $@
	rm $@.tmp

# ym2149.sv initialises an unpacked wire array in its declaration (the
# volume table). Quartus accepts that; Verilator 5.0 doesn't, so simulate a
# copy where the table is a localparam.
$(OBJ)/ym2149.sv: ../rtl/ym2149.sv Makefile
	mkdir -p $(OBJ)
	sed 's/^wire \[7:0\] volTable\[64\] = /localparam bit [7:0] volTable[64] = /' $< > $@

$(OBJ)/Vsim_top: $(RTL) $(OBJ)/T80pa.v sim_main.cpp
	verilator --cc --exe --build -j 0 -O3 --top-module sim_top \
		-Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN +1364-2005ext+v \
		--Mdir $(OBJ)/verilated -o ../Vsim_top \
		$(abspath $(RTL) $(OBJ)/T80pa.v sim_main.cpp)

roms: $(OBJ)/boot.rom

$(OBJ)/boot.rom: $(ROMSET)
	@test -n "$(ROMSET)" || (echo "Set ROMSET=path/to/tiki100.zip"; exit 1)
	python3 -I extract_roms.py $(ROMSET) $(OBJ)

$(OBJ)/sim_trace$(TRACE_SUFFIX).txt: $(OBJ)/Vsim_top $(OBJ)/boot.rom
	$(OBJ)/Vsim_top $(OBJ)/boot.rom $(OBJ)/boot1.rom $(BOOTROM_ARGS) --trace $@ --instructions $(INSTRUCTIONS)

$(OBJ)/mame_trace$(TRACE_SUFFIX).log: $(ROMSET)
	mkdir -p $(OBJ)
	cd $(OBJ) && sh ../mame_trace.sh $(dir $(abspath $(ROMSET))) mame_trace$(TRACE_SUFFIX).log $(MAME_SECONDS) "$(MAME_MACHINE)"

trace: $(OBJ)/sim_trace$(TRACE_SUFFIX).txt $(OBJ)/mame_trace$(TRACE_SUFFIX).log
	python3 -I compare_trace.py $(OBJ)/mame_trace$(TRACE_SUFFIX).log $(OBJ)/sim_trace$(TRACE_SUFFIX).txt

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

$(OBJ)/sound.rom: tests/sound.asm
	mkdir -p $(OBJ)
	z80asm -o $@ $<

sound: $(OBJ)/Vsim_top $(OBJ)/boot.rom $(OBJ)/sound.rom
	$(OBJ)/Vsim_top $(OBJ)/sound.rom $(OBJ)/boot1.rom --frames 100 --results $(OBJ)/sound_sim.txt --wav $(OBJ)/sound_sim.wav
	sh tests/mame_results.sh $(OBJ)/sound.rom $(OBJ)/boot1.rom $(OBJ)/sound_mame.txt 2 $(abspath $(OBJ)/sound_mame.wav)
	diff $(OBJ)/sound_mame.txt $(OBJ)/sound_sim.txt
	@echo "sound: register read-back matches MAME"
	python3 -I tests/compare_sound.py $(OBJ)/sound_mame.wav $(OBJ)/sound_sim.wav

# Disk images come from MAME's tiki100 software list (not committed to git)
$(OBJ)/%.dsk: ../%.zip
	mkdir -p $(OBJ)
	python3 -I -c "import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extract(sys.argv[2], sys.argv[3])" $< $*.dsk $(OBJ)

tiko: $(OBJ)/Vsim_top $(OBJ)/boot.rom $(DISK)
	$(OBJ)/Vsim_top $(OBJ)/boot.rom $(OBJ)/boot1.rom --disk0 $(DISK) --frames $$(($(TIKO_FRAME) + 1)) --dump $(TIKO_FRAME) --outdir $(OBJ) \
		$(if $(TIKO_KEYS),--keys $(TIKO_KEYS))
	$(if $(TIKO_KEYS),python3 -I tests/mame_keys.py .. $(TIKO_KEYS) $(TIKO_FRAME) --snapshot $(OBJ)/mame_tiko_$(TIKO_FRAME).png --disk $(DISK),sh mame_snap.sh .. $(OBJ)/mame_tiko_$(TIKO_FRAME).png $(TIKO_FRAME) $(DISK))
	python3 -I compare_frame.py --allow 16 $(OBJ)/mame_tiko_$(TIKO_FRAME).png $(OBJ)/frame_$$(printf %04d $(TIKO_FRAME)).ppm $(OBJ)/diff_tiko_$(TIKO_FRAME).png

tikodir:
	$(MAKE) tiko TIKO_KEYS=tests/keys_tiko_dir.txt TIKO_FRAME=900

clean:
	rm -rf $(OBJ)
