#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: broken
# broken: back to full; the name screen has 0 fields; the same on dev
#   (local/runs/dev_baseline)
# [NEW_WORLD_FORM]: the new-world screen. A name that is already taken
# leaves the screen standing with the name, the seed and the toggles as
# they were, the seed is copied out of its field and pasted into the name
# with Ctrl+C and Ctrl+V, and the mapgen picked on the screen is the one
# written into the new world's world.mt. Needs VoxeLibre installed under
# user/shared/vanilla/games, which drive.sh's menu runs want too.
#
#   builtin/luanti/test/new_world.sh
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/new_world"; mkdir -p "$out"
saves="$BUILDAT_USER_PATH/apps/vanilla/saves"
if check_pgrep buildat >/dev/null || check_pgrep buildat_server >/dev/null; then
	echo "a client or a server is already running" >&2; exit 2
fi
# The name the screen is refused: a directory under the saves is enough,
# because storage refuses a name whose path is there
rm -rf "$saves/mgtest" "$saves/taken"
# storage tells a save by its save.sqlite, so an empty file is what makes
# the name taken
mkdir -p "$saves/taken"; : > "$saves/taken/save.sqlite"
fifo="$out/cmds.fifo"; rm -f "$fifo"; mkfifo "$fifo"
# **The menu by name, not by preference** (2026-09-24): this drives
# the launch menu's own screens, and a desk whose `launch_ui` is set
# to something else -- the room, the console -- booted that instead
# and the scan found no rows. `-m launch_menu` asks for the thing the
# check is about ([MENU_FALLBACK]: a launcher nobody drives is a
# launcher nobody notices breaking).
( cd "$here/Build" && exec bin/buildat -m launch_menu -w 1280x720 -l 3 -c - < "$fifo" \
	> "$out/cli.log" 2>&1 ) &
cli=$!
trap 'kill "$cli" 2>/dev/null; check_pkill buildat_server 2>/dev/null' EXIT
exec 3> "$fifo"
python3 "$me/new_world.py" "$out/cli.log" "$fifo" "$saves"
status=$?
exec 3>&-
# The client quits on the drive's last line
for i in $(seq 1 50); do kill -0 "$cli" 2>/dev/null || break; sleep 0.2; done
kill "$cli" 2>/dev/null
check_pkill buildat_server 2>/dev/null
for i in $(seq 1 150); do check_pgrep buildat_server >/dev/null || break; sleep 0.2; done
# What this run made goes with it
rm -rf "$saves/taken" "$saves/mgtest"
exit $status
