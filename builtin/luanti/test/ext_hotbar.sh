#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# [EXT_HOTBAR]: the extension's hotbar is the row both clients share -- the
# game's own hotbar_image and hotbar_selected_image on it, as many slots as
# the game asked for, in Luanti's own geometry. A VoxeLibre server is what
# reads it: it asks for nine slots, names a marker, and draws its own
# hotbar background as a HUD image element placed against official's row.
# Needs the Luanti checkout the way ext_error.sh does.
#
#   builtin/luanti/test/ext_hotbar.sh
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/ext_hotbar"; mkdir -p "$out"
luanti=~/projects/luanti
bin=${LUANTI_BIN:-$luanti/bin/luanti-refshots}
if check_pgrep buildat >/dev/null || pgrep -x luanti-refshots >/dev/null; then
	echo "SKIP: a client or a Luanti server is already running"; exit 77
fi
work="$out/luanti_world"
rm -rf "$work"; mkdir -p "$work/worldmods/hotbar"
cat > "$work/world.mt" <<MT
gameid = mineclone2
backend = sqlite3
player_backend = sqlite3
auth_backend = sqlite3
mod_storage_backend = sqlite3
world_name = hotbar
creative_mode = false
server_announce = false
MT
cat > "$work/worldmods/hotbar/init.lua" <<'LUA'
-- Something in the first slots, so that the row has pictures in it and the
-- empty ones beside them can be told apart
core.register_on_joinplayer(function(player)
	core.after(4, function()
		local inv = player:get_inventory()
		inv:set_stack("main", 1, "mcl_core:dirt 7")
		inv:set_stack("main", 3, "mcl_core:cobble 42")
		inv:set_stack("main", 9, "mcl_tools:pick_wood")
		core.log("action", "ext_hotbar: the stacks are set")
	end)
end)
LUA
printf 'name = hotbar\n' > "$work/worldmods/hotbar/mod.conf"
{ echo "fixed_map_seed = 5"; echo "time_speed = 0"; echo "enable_damage = false"
	echo "mute_sound = true"; } > "$out/luanti.conf"
port=30030
check_allow "udp://127.0.0.1:$port"
( cd "$luanti" && exec "$bin" --server --world "$work" --port "$port" \
	--config "$out/luanti.conf" > "$out/luanti_srv.log" 2>&1 ) &
srv=$!
trap 'kill "$srv" 2>/dev/null' EXIT
# "Server for gameid ... listening" is the server taking connections
for i in $(seq 1 600); do
	grep -q "Server for gameid" "$out/luanti_srv.log" 2>/dev/null && break
	kill -0 "$srv" 2>/dev/null || break
	sleep 0.2
done
grep -q "Server for gameid" "$out/luanti_srv.log" 2>/dev/null ||
	{ echo "the Luanti server did not come up" >&2; exit 1; }
# The row and the game's bar are said once each look, maybe before the
# textures line. The 2 s after them are for the stacks the fixture puts
# in 4 s after the join, which are only for the picture.
cat > "$out/cmds.txt" <<CMDS
wait_log 90000 voxel types have their own textures
wait_log_any 30000 hotbar: 9 slots
wait_log_any 30000 hud image lowest:
delay 2000
screenshot $out/hotbar.png
wait_log 20000 Wrote screenshot $out/hotbar.png
quit
CMDS
BUILDAT_LUANTI_ADDRESS="127.0.0.1:$port" BUILDAT_LUANTI_NAME=hb \
	BUILDAT_LUANTI_CONNECT=1 \
	"$here/Build/bin/buildat" -m luanti_client -w 1280x720 -l 3 \
	-c @"$out/cmds.txt" > "$out/cli.log" 2>&1 ||
	echo "the drive stopped: $(grep -a "Command sequence failed" "$out/cli.log" | tail -1)" >&2
kill "$srv" 2>/dev/null
# The server's exit, polled
for i in $(seq 1 150); do kill -0 "$srv" 2>/dev/null || break; sleep 0.2; done
python3 - "$out" <<'PYIN'
import re, sys
out = sys.argv[1]
log = open(out + "/cli.log", "rb").read().decode("utf-8", "replace")
row = None
for m in re.finditer(r'hotbar: (\d+) slots, image "(.*?)", marker "(.*?)", '
		r'row (-?\d+),(-?\d+) (\d+)x(\d+) in (\d+)x(\d+)', log):
	row = m
img = None
for m in re.finditer(r'hud image lowest: "(.*?)" at (-?\d+),(-?\d+) '
		r'(\d+)x(\d+)', log):
	img = m
if not row:
	print("FAIL: the client never said what it drew the hotbar as")
	sys.exit(1)
n, image, marker = int(row.group(1)), row.group(2), row.group(3)
rx, ry, rw, rh = (int(row.group(i)) for i in (4, 5, 6, 7))
print('%d slots, image "%s", marker "%s", row %d,%d %dx%d' % (
		n, image, marker, rx, ry, rw, rh))
ok = n == 9 and marker.startswith("mcl_inventory_hotbar_selected")
if img:
	ix, iy, iw, ih = (int(img.group(i)) for i in (2, 3, 4, 5))
	print('the game\'s own bar "%s" at %d,%d %dx%d' % (
			img.group(1), ix, iy, iw, ih))
	# The two bands have to overlap: the game placed its background against
	# official's row, so a row somewhere else is one its bars miss
	over = min(ry + rh, iy + ih) - max(ry, iy)
	print("the bands overlap by %d of the row's %d" % (over, rh))
	ok = ok and over > rh * 0.5
else:
	print("the game drew no image element")
	ok = False
print("PASS: the game's slot count, its marker and its own bar against the row"
		if ok else
		"FAIL: the row is not what the game asked for")
sys.exit(0 if ok else 1)
PYIN
