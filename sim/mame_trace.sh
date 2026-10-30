#!/bin/sh
# Record a MAME instruction trace of the Tiki 100 boot.
#
# Usage: mame_trace.sh <rompath> <output.log> [seconds] [machine [options]]
#
# The machine defaults to tiki100 (TIKI ROM 2.03w); "tiki100 -bios v135"
# runs ROM 1.35 and "kontiki" ROM 1.30.
#
# Runs MAME headless with the debugger enabled and traces the Z80 from reset.
# The expansion slots are emptied (MAME's default fits an 8088 card and a
# hard disk controller) so the machine matches the core.

set -e
ROMPATH=$(realpath "$1")
OUT=$(realpath "$2")
SECONDS_TO_RUN=${3:-2}
MACHINE=${4:-tiki100}

LUA=$(mktemp --suffix=.lua)
trap 'rm -f "$LUA"' EXIT
cat > "$LUA" <<EOF
manager.machine.debugger:command("trace $OUT,:z80,noloop")
manager.machine.debugger.execution_state = "run"
EOF

SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy mame $MACHINE \
	-rompath "$ROMPATH" -slot1 "" -slot2 "" \
	-debug -debugger none -autoboot_script "$LUA" -autoboot_delay 0 \
	-video none -sound none -nothrottle -skip_gameinfo \
	-seconds_to_run "$SECONDS_TO_RUN" 2>&1 | grep -v ALSA || true
