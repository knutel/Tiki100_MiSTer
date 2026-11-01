#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Save a MAME snapshot of the Tiki 100 screen after a given number of frames.
#
# Usage: mame_snap.sh <rompath> <output.png> <frame> [disk image for drive A]
#
# The snapshot is the visible 1024 x 256 area. Expansion slots are emptied,
# as in mame_trace.sh.

set -e
ROMPATH=$(realpath "$1")
OUT=$(realpath "$2")
FRAME=$3

DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT

# MAME writes changes back to the image, so give it a copy
FLOP=""
if [ -n "$4" ]; then cp "$4" "$DIR/disk.dsk"; FLOP="-flop1 $DIR/disk.dsk"; fi
cat > "$DIR/snap.lua" <<EOF
local frames = 0
sub = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  if frames == $FRAME then
    manager.machine.video:snapshot()
    manager.machine:exit()
  end
end)
EOF

SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy mame tiki100 \
	-rompath "$ROMPATH" -slot1 "" -slot2 "" $FLOP \
	-autoboot_script "$DIR/snap.lua" -autoboot_delay 0 \
	-video none -sound none -nothrottle -skip_gameinfo \
	-snapshot_directory "$DIR/snap" -seconds_to_run 60 2>&1 | grep -v ALSA || true

cp "$DIR"/snap/tiki100/0000.png "$OUT"
