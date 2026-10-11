#!/bin/bash
# tier: full
# cost: ~5 min (2026-10-11)
# covers: src/client/app.cpp extensions/luanti_client/res/touch.lua extensions/luanti_client/res/form_session.lua builtin/luanti/lua/dig.lua apps/vanilla/main/client_lua/player.lua
# [TOUCH_PARITY]: vanilla on a touchscreen as Luanti's Android client, on
# the minimal game, by finger. A fixture puts the player on a platform in
# the air facing a wall with a marker in it right of the centre, gives the
# hand a pick's dig, and logs the inventory, the wield and the position.
# Natively (BUILDAT_TOUCH=1, 1000x500, finger_down/move/up):
#   - a tap on hotbar slot 3 wields it, and one on slot 1 back;
#   - a short tap on the marker places against it, away from the centre,
#     and a finger held there digs what it placed and the marker behind;
#   - the stick pushed half way walks about half as far as pushed fully;
#   - in the inventory a stack dragged to a slot is there, a tap on it and
#     a tap on another slot moves it, a dragged stack with a second
#     finger tapped puts one where the first is and the rest where it is
#     let go, stone and marker dragged into the craft grid craft sand,
#     taken by a tap and put by a tap;
#   - a single tap outside the inventory keeps it, a double tap closes it.
# The web client (Chrome as a phone, util/web_drive.sh's TOUCH=1; skipped
# without it or web/): the inventory's drag, tap-and-tap and second finger,
# the craft, the hotbar's tap, the place and dig at the finger and the
# double tap out.
#   util/touch_parity_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp touch_parity; t=$CHECK_TMP
cat > "$t/fixture.lua" <<'L'
local function stacks(inv, list)
	local out = {}
	for i, s in ipairs(inv:get_list(list) or {}) do
		if not s:is_empty() then
			out[#out + 1] = list .. i .. "=" .. s:get_name():gsub(".*:", "") ..
					"x" .. s:get_count()
		end
	end
	return table.concat(out, " ")
end
-- The inventory and the wield each time they change, and where the
-- player is four times a second
local last, wait = nil, 0
core.register_globalstep(function(dtime)
	wait = wait - dtime
	if wait > 0 then return end
	wait = 0.25
	for _, player in ipairs(core.get_connected_players()) do
		local inv = player:get_inventory()
		local now = stacks(inv, "main") .. " | " .. stacks(inv, "craft") ..
				" | " .. stacks(inv, "craftresult") .. " | wield " ..
				player:get_wield_index()
		if now ~= last then
			last = now
			core.log("action", "touch_parity state: " .. now)
		end
		local p = player:get_pos()
		core.log("action", string.format("touch_parity pos %.2f %.2f %.2f",
				core.get_us_time() / 1e6, p.x, p.z))
	end
end)
-- A hand that digs the floor's stone
core.register_item(":", {type = "none", wield_image = "floor_stone.png",
	tool_capabilities = {full_punch_interval = 1,
		groupcaps = {cracky = {times = {[3] = 0.5}, uses = 0}}}})
-- A platform in the air: a floor, a wall three ahead and a marker in it
-- one to the right at the eye's height, made as the player joins (at the
-- mods' load the mapgen wrote over it). The player spawns there, with no
-- gravity for a client that has not got the platform yet, and is put
-- back until it stays: a slow (web) client sends where it was.
local P = {x = 40, y = 30, z = 40}
local marker = vector.add(P, {x = 1, y = 1, z = 3})
local placed
core.settings:set("static_spawnpoint", "40,29.5,40")
local function platform()
	for x = -6, 6 do
		for z = -20, 3 do
			for y = -1, 4 do
				core.set_node(vector.add(P, {x = x, y = y, z = z}), {name =
						y == -1 and "floor:stone" or
						z == 3 and y <= 3 and "floor:stone" or "air"})
			end
		end
	end
	core.set_node(marker, {name = "floor:marker"})
end
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	local inv = player:get_inventory()
	inv:set_size("main", 32)
	inv:set_size("craft", 9)
	inv:set_width("craft", 3)
	inv:set_list("main", {})
	inv:set_stack("main", 1, "floor:stone 10")
	inv:set_stack("main", 2, "floor:marker 5")
	player:set_inventory_formspec("size[8,7.5]list[current_player;main;0,3.5;8,4;]" ..
			"list[current_player;craft;3,0;3,3;]" ..
			"list[current_player;craftpreview;7,1;1,1;]")
	platform()
	player:set_physics_override({gravity = 0})
	local function put()
		local pl = core.get_player_by_name(name)
		if not pl then return end
		local at = pl:get_pos()
		if math.abs(at.x - P.x) > 0.5 or math.abs(at.z - P.z) > 0.5 or
				math.abs(at.y - (P.y - 0.5)) > 1 then
			pl:set_pos({x = P.x, y = P.y - 0.5, z = P.z})
			pl:set_look_horizontal(0)
			pl:set_look_vertical(0)
			core.after(2, put)
			return
		end
		core.chat_send_player(name, "touch_parity: ready")
	end
	core.after(3, put)
end)
core.register_on_placenode(function(pos, node, placer, old, stack, pointed)
	placed = pos
	core.log("action", "touch_parity: placed " .. node.name ..
			(vector.equals(pointed.under, marker) and " against the marker" or
			" at " .. core.pos_to_string(pos)))
end)
core.register_on_dignode(function(pos, node)
	core.log("action", "touch_parity: dug " .. node.name ..
			(placed and vector.equals(pos, placed) and " that was placed" or ""))
end)
core.register_on_player_receive_fields(function(player, formname, fields)
	if formname == "" and fields.quit then
		core.log("action", "touch_parity: inventory closed")
	end
end)
L
server(){ # dir, extra args...
	local d=$1; shift
	mkdir -p "$d/apps/vanilla/saves/tp/luanti" "$d/shared"
	cp "$t/fixture.lua" "$d/shared/"
	# No damage: a fall before the teleport would respawn
	echo "enable_damage = false" > "$d/apps/vanilla/saves/tp/luanti/world.mt"
	BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=tp \
	BUILDAT_LUANTI_LUA="$d/shared/fixture.lua" start_server "$d.log" \
		"STATUS Listening" 120 auto "$here/Build/bin/buildat_server" \
		-u launcher=1 -A 127.0.0.1 -m "$here/apps/vanilla" -D "$d" \
		-C "$d.cache" -l 3 "$@" || fail "the server ($d.log)"
	CHECK_PIDS+=($SERVER_PID)
}
states(){ grep -a "touch_parity[: ]" "$1" | grep -v "touch_parity pos" | sed 's/.*touch_parity/tp/'; }
want(){ # log, line, what
	states "$1" | grep -qF "$2" || fail "$3: no \"$2\" in $(states "$1" | tail -4)"
}

# Natively. Window pixels at 1000x500, UI scale 1: the marker at
# (638, 267), hotbar slots 1 and 3 at (305, 467), (417, 467), the stick in
# the left third; the inventory's main row 1 at y 259 and row 2 at 317,
# columns from x 288 by 58.5, the craft grid's first row at y 70 from x
# 463, the preview at (697, 124)
drag(){ # x0 y0 x1 y1
	echo "finger_down 1 $1 $2"; echo "delay 150"
	for i in 1 2 3 4 5; do
		echo "finger_move 1 $(($1 + ($3 - $1) * i / 5)) $(($2 + ($4 - $2) * i / 5))"
		echo "delay 60"
	done
	echo "finger_up 1"; echo "delay 1500"
}
stick(){ # dy: down from (150, 300) for 2 s
	echo "finger_down 1 150 300"; echo "delay 100"
	echo "finger_move 1 150 $((300 + $1 / 2))"; echo "delay 50"
	echo "finger_move 1 150 $((300 + $1))"; echo "delay 2000"
	echo "finger_up 1"; echo "delay 1500"
}
{
	echo "wait_log 120000 chat: touch_parity: ready"; echo "delay 3000"
	echo "tap 417 467"; echo "delay 1000"; echo "tap 305 467"; echo "delay 1000"
	echo "tap 638 267"; echo "delay 1500"
	echo "finger_down 1 638 267"; echo "delay 4000"; echo "finger_up 1"; echo "delay 1500"
	stick 32
	stick 100
	echo "tap 748 94"; echo "delay 2000"
	drag 288 259 346 317
	echo "tap 346 317"; echo "delay 800"; echo "tap 404 259"; echo "delay 1500"
	echo "finger_down 1 404 259"; echo "delay 150"
	echo "finger_move 1 404 288"; echo "delay 60"; echo "finger_move 1 404 317"; echo "delay 300"
	echo "finger_down 2 800 400"; echo "delay 100"; echo "finger_up 2"; echo "delay 800"
	echo "finger_move 1 433 317"; echo "delay 60"; echo "finger_move 1 463 317"; echo "delay 300"
	echo "finger_up 1"; echo "delay 1500"
	drag 404 317 463 70
	drag 346 259 521 70
	echo "tap 697 124"; echo "delay 800"; echo "tap 522 259"; echo "delay 1500"
	echo "tap 150 150"; echo "delay 1500"
	echo "tap 150 150"; echo "delay 150"; echo "tap 150 150"; echo "delay 1500"
	echo "screenshot $t/native_end.png"
	echo quit
} > "$t/native.cmds"
server "$t/n"
BUILDAT_TOUCH=1 run_client 60 "$t/native.log" timeout 240 "$here/Build/bin/buildat" \
	-C "$t/nc" -D "$t/nu" -s 127.0.0.1:$SERVER_PORT -w 1000x500 -u 1 -l 3 \
	-o sound_mute=1 -c @"$t/native.cmds"
grep -a "Command sequence failed" "$t/native.log" && fail "the drive ($t/native.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
L=$t/n.log
want $L "wield 3" "the tap on hotbar slot 3"
want $L "placed floor:stone against the marker" "the short tap on the marker"
want $L "dug floor:stone that was placed" "the finger held on it"
want $L "dug floor:marker" "the finger held on"
want $L "main2=markerx6 main10=stonex10 |  |  | wield 1" "the drag main 1 to 10"
want $L "main2=markerx6 main3=stonex10 |" "the tap on main 10 and the tap on main 3"
want $L "main2=markerx6 main3=stonex9 main11=stonex1 |" "the second finger's tap"
want $L "main2=markerx6 main11=stonex1 main12=stonex9 |" "the drag let go after it"
want $L "main12=stonex9 | craft1=stonex1 craft2=markerx6 |" "the drags into the craft grid"
want $L "main5=sandx1 main12=stonex9 | craft2=markerx5 |" "the craft, taken and put by taps"
n=$(states $L | grep -c "inventory closed")
[ "$n" = 1 ] || fail "the taps outside closed the inventory $n times, not once"
# The stick: the distance walked in each push, from the positions
read -r half full < <(grep -a "touch_parity pos" $L | awk '{print $NF, $(NF-1)}' | python3 -c '
import sys
z = [float(l.split()[0]) for l in sys.stdin]
# The two walks are the two runs of moving positions after the dig
runs, cur = [], None
for a, b in zip(z, z[1:]):
    if abs(b - a) > 0.05:
        cur = cur if cur is not None else a
        end = b
    elif cur is not None:
        runs.append(abs(end - cur)); cur = None
print(*("%.1f" % r for r in runs[-2:]))')
[ -n "${full:-}" ] || fail "the stick did not walk twice ($half)"
python3 -c "import sys; r = $half / $full; sys.exit(0 if 0.35 < r < 0.65 and $full > 5 else 1)" ||
	fail "the stick: half way walked $half, fully $full"
echo "ok: native: the hotbar, the place and dig at the finger, the stick ($half and $full nodes), the inventory by finger, the double tap out"

# The web, in Chrome: headless Firefox draws no voxels of vanilla's
# (a WebGL warning, "Vertex fetch requires 144", 2026-10-11).
# CSS pixels at 800x400 and a density of 2 (the HUD and the forms at it,
# [HUD_DENSITY]): the marker at (510, 213), hotbar slots 1 and 3 at
# (204, 368), (316, 368); the inventory's main row 1 at y 206 and row 2
# at 254, columns from x 231 by 46.8, the craft grid's first row at y 56
# from x 371, the preview at (558, 99)
# The taps wait for the client's world, not only the server's ready: its
# first data can sit behind the map for over a minute, and the world is
# meshed again when it comes (2026-10-11)
if ! command -v "${CHROME:-google-chrome}" > /dev/null || [ ! -f "$here/web/buildat.wasm" ]; then
	echo "PASS: native; the web skipped (no Chrome or web/)"
	exit 0
fi
cat > "$t/web.json" <<'J'
[
 ["nav", "${URL}"],
 ["waitlog", "touch_parity: ready", 240],
 ["waitlog", "settle: \\d+ to mesh, ([2-9]\\d\\d|\\d{4,}) chunks in scene", 240],
 ["wait", 5000],
 ["tap", 316, 368], ["wait", 1000], ["tap", 204, 368], ["wait", 1000],
 ["tap", 510, 213], ["wait", 1500],
 ["hold", 510, 213, 4000], ["wait", 1500],
 ["tap", 673, 47], ["wait", 2000],
 ["drag", 231, 206, 278, 254, "touch"], ["wait", 1500],
 ["tap", 278, 254], ["wait", 800], ["tap", 324, 206], ["wait", 1500],
 ["carry", 324, 206, 324, 254, 700, 300, 371, 254], ["wait", 1500],
 ["drag", 324, 254, 371, 56, "touch"], ["wait", 1500],
 ["drag", 278, 206, 418, 56, "touch"], ["wait", 1500],
 ["tap", 558, 99], ["wait", 800], ["tap", 418, 206], ["wait", 1500],
 ["tap", 100, 100], ["wait", 1500],
 ["tap", 100, 100, 2], ["wait", 1500],
 ["shot", "${OUT}/web_end.png"]
]
J
server "$t/w" -W "$here/web"
TOUCH=1 WEB_DRIVE_VIEWPORT=800x400@2 WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/" \
	"$here/util/web_drive.sh" chrome vanilla "$t/web.json" "$t/drive" \
	> "$t/drive.txt" 2>&1 || fail "the web drive ($(tail -2 "$t/drive.txt"))"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
L=$t/w.log
want $L "wield 3" "web: the tap on hotbar slot 3"
want $L "placed floor:stone against the marker" "web: the short tap on the marker"
want $L "dug floor:stone that was placed" "web: the finger held on it"
want $L "main2=markerx6 main10=stonex10 |" "web: the drag main 1 to 10"
want $L "main2=markerx6 main3=stonex10 |" "web: the tap and the tap"
want $L "main2=markerx6 main3=stonex9 main11=stonex1 |" "web: the second finger's tap"
want $L "main2=markerx6 main11=stonex1 main12=stonex9 |" "web: the drag let go after it"
want $L "main5=sandx1 main12=stonex9 | craft2=markerx5 |" "web: the craft"
n=$(states $L | grep -c "inventory closed")
[ "$n" = 1 ] || fail "web: the taps outside closed the inventory $n times, not once"
echo "PASS: native and the web: the hotbar, the place and dig at the finger, the inventory by finger, the double tap out; natively the stick"
