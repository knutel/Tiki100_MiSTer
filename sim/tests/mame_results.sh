#!/bin/sh
# Run a test ROM in MAME in place of the boot ROM and log what it writes to
# port FF (the result port), one hex byte per line.
#
# Usage: mame_results.sh <test.rom> <boot1.rom> <output.txt> [seconds] [sound.wav]
#
# Both serial ports get MAME's RS-232 loopback plug (TxD to RxD). MAME
# complains about the ROM's checksum, which is expected.

set -e
ROM=$(realpath "$1")
PROM=$(realpath "$2")
OUT=$(realpath "$3")
SECONDS_TO_RUN=${4:-1}
SOUND="-sound none"
if [ -n "$5" ]; then SOUND="-sound none -samplerate 48000 -wavwrite $5"; fi

DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
mkdir "$DIR/tiki100"
cp "$ROM" "$DIR/tiki100/tikirom-2.03w.u10"
cp "$PROM" "$DIR/tiki100/53ls140.u4"

cat > "$DIR/results.lua" <<LUA
local out = assert(io.open("$OUT", "w"))
local space = manager.machine.devices[":z80"].spaces["io"]
-- OUT (n),A puts A on the upper address lines, so watch the whole space
results_tap = space:install_write_tap(0x0000, 0xffff, "results", function(offset, data, mask)
	if (offset & 0xff) == 0xff then
		out:write(string.format("%02X\n", data & 0xff))
		out:flush()
	end
end)
LUA

SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy mame tiki100 \
	-rompath "$DIR" -slot1 "" -slot2 "" -rs232a loopback -rs232b loopback \
	-autoboot_script "$DIR/results.lua" -autoboot_delay 0 \
	-video none $SOUND -nothrottle -skip_gameinfo \
	-seconds_to_run "$SECONDS_TO_RUN" 2>&1 | grep -v -e ALSA -e "WRONG CHECKSUMS" -e "EXPECTED:" -e "FOUND:" -e "incorrect length" || true
