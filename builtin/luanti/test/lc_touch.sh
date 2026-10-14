#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: broken
# broken: back to full; the drive; the same on dev (local/runs/dev_baseline)
# [LC_TOUCH]: luanti_client on a touchscreen, by the touch controls it
# shares with vanilla (extensions/luanti_client/res/touch.lua). Headless
# Firefox as a phone (web_drive.sh's TOUCH=1: a coarse pointer and touch
# events) on apps/play's page, bridged to a VoxeLibre server; everything
# by finger: the join, then the stick walks, a drag turns, a hotbar tap
# picks a slot, a finger held still digs, a tap places, and a form's field
# is typed into. A fixture mod on a dirt platform says what the server saw.
# Needs web/ from util/build_web.sh and the Luanti checkout's server.
#
#   builtin/luanti/test/lc_touch.sh
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
out="$here/local/lc_touch"
rm -rf "$out"; mkdir -p "$out"
PLAY=29721
LIST=29723
LUANTI=30051
luanti=~/projects/luanti
bin=${LUANTI_BIN:-$luanti/bin/luanti}
[ -x "$bin" ] || { echo "SKIP: no Luanti server at $bin"; exit 77; }
[ -f "$here/web/buildat.wasm" ] || { echo "SKIP: no web/ (util/build_web.sh)"; exit 77; }
pids=()
trap 'for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done' EXIT
fail() { echo "FAIL: $*"; exit 1; }

# The fixture: a platform where the player stands, dirt on stone a hand
# digs too slowly to get through, them on it looking down at it, stone in
# the third slot; what the player does, logged
mkdir -p "$out/world/worldmods/lc_touch"
printf 'gameid = mineclone2\nbackend = sqlite3\nserver_announce = false\ncreative_mode = false\nenable_damage = false\n%s\n' "$WEB_WORLD_MT" \
	> "$out/world/world.mt"
printf 'name = lc_touch\n' > "$out/world/worldmods/lc_touch/mod.conf"
cat > "$out/world/worldmods/lc_touch/init.lua" <<'EOF'
core.register_on_joinplayer(function(player)
	core.set_timeofday(0.5)
	player:get_inventory():set_stack("main", 3, "mcl_core:stone 10")
end)
-- Typed by the drive once the client has loaded: a teleport before that
-- is lost to the position the loading client goes on sending
core.register_chatcommand("lc_setup", {func = function(name)
	-- Where the player stands, which the client has drawn already: a
	-- teleport waits on blocks a web client is slow to get
	local player = core.get_player_by_name(name)
	local p = vector.round(player:get_pos())
	for x = -5, 5 do
		for z = -5, 5 do
			for y = -2, 4 do
				core.set_node(vector.add(p, {x = x, y = y, z = z}),
						{name = y == -2 and "mcl_core:stone" or
							y < 0 and "mcl_core:dirt" or "air"})
			end
		end
	end
	player:set_pos({x = p.x, y = p.y - 0.5, z = p.z})
	core.log("action", "lc_touch: platform under " .. core.pos_to_string(p))
	player:set_look_horizontal(0)
	player:set_look_vertical(math.rad(60))
	core.log("action", "lc_touch: ready")
	core.chat_send_player(name, "lc_touch: ready")
end})
local last = {}
core.register_globalstep(function()
	for _, player in ipairs(core.get_connected_players()) do
		local p = player:get_pos()
		local s = string.format("pos %.1f %.1f yaw %.0f pitch %.0f wield %d",
				p.x, p.z, math.deg(player:get_look_horizontal()),
				math.deg(player:get_look_vertical()), player:get_wield_index())
		if s ~= last[player] then
			last[player] = s
			core.log("action", "lc_touch: " .. s)
		end
	end
end)
core.register_on_punchnode(function(pos, node)
	core.log("action", "lc_touch: punched " .. node.name .. " at " ..
			core.pos_to_string(pos))
end)
core.register_on_dignode(function(pos, node)
	core.log("action", "lc_touch: dug " .. node.name)
end)
core.register_on_placenode(function(pos, node)
	core.log("action", "lc_touch: placed " .. node.name)
end)
core.register_chatcommand("lc_form", {func = function(name)
	core.show_formspec(name, "lc_touch", "formspec_version[6]size[8,4]" ..
			"field[0.5,1;7,0.8;txt;Name;]button_exit[2,2.5;4,0.8;ok;OK]")
end})
core.register_on_player_receive_fields(function(player, formname, fields)
	if formname == "lc_touch" then
		core.log("action", "lc_touch: fields txt=" .. tostring(fields.txt) ..
				" ok=" .. tostring(fields.ok))
	end
end)
EOF
printf 'mute_sound = true\n' > "$out/luanti.conf"
"$bin" --server --world "$out/world" --port $LUANTI --config "$out/luanti.conf" \
	> "$out/luanti.log" 2>&1 &
lpid=$!
pids+=($lpid)
mkdir -p "$out/list"
printf '{"list": []}' > "$out/list/list"
python3 -m http.server -b 127.0.0.1 -d "$out/list" $LIST > "$out/list.log" 2>&1 &
pids+=($!)
cd "$here"
BUILDAT_CONNECT_PORTS=$LIST BUILDAT_LUANTI_LIST=http://127.0.0.1:$LIST \
start_server "$out/play.log" "Listening at" 60 $PLAY \
	Build/bin/buildat_server -m apps/play -D "$out/playsrv" -l 3 ||
	fail "apps/play ($out/play.log)"
pids+=($SERVER_PID)
for _i in $(seq 600); do
	grep -q "Server for gameid" "$out/luanti.log" && break
	kill -0 $lpid 2>/dev/null || break
	sleep 0.2
done
grep -q "Server for gameid" "$out/luanti.log" || fail "the Luanti server ($out/luanti.log)"

# 1200x800 CSS pixels; the UI is at 1.5 under touch. A JSON step takes no
# comment, so the waits by step: those of 2 s at most right after a waitlog
# are settles, what the line said drawn in the frames after it (the menu
# after its rows, the field after the self-test, the dialog after its line,
# the chat line, the platform after "ready", the slot, the dug and the
# placed node, the form); the 1 s at the end is a settle after the OK's
# click, the fields it sent out before the browser closes.
# simplified: the stick's walk and the turning drag wait 2 s each for the
# server's answer to be drawn; no client line says the player moved or
# turned (one on the server's position or look reaching the client would
# replace them).
cat > "$out/steps.json" <<EOF
[
 ["nav", "\${URL}index.html"],
 ["waitlog", "launch_menu: [0-9]+ rows", 120],
 ["wait", 2000],
 ["tap", 600, 390],
 ["waitlog", "launch_menu: [^,]+, [0-9]+ rows", 10],
 ["wait", 1000],
 ["tap", 300, 455],
 ["waitlog", "launch_menu: locked ", 10],
 ["wait", 1000],
 ["tap", 920, 590],
 ["waitlog", "world: self-test ok", 30],
 ["wait", 1000],
 $(for _ in $(seq 20); do printf '["key", "Backspace"], '; done)
 ["type", "127.0.0.1:$LUANTI"],
 ["tap", 920, 697],
 ["waitlog", "Asking the user about udp://", 15],
 ["wait", 1000],
 ["tap", 600, 517],
 ["waitlog", "Logged in", 60],
 ["waitlog", "loading done", 300],
 ["hold", 978, 142, 300],
 ["waitlog", "chat: the line opened", 30],
 ["wait", 500],
 ["type", "/lc_setup"],
 ["key", "Enter"],
 ["waitlog", "lc_touch: ready", 30],
 ["wait", 2000],
 ["shot", "\${OUT}/01_ready.png"],
 ["drag", 150, 650, 150, 450, "touch"],
 ["wait", 2000],
 ["shot", "\${OUT}/02_walked.png"],
 ["drag", 600, 300, 900, 300, "touch"],
 ["wait", 2000],
 ["shot", "\${OUT}/03_turned.png"],
 ["hold", 492, 768, 300],
 ["waitlog", "touch: hotbar slot 3", 10],
 ["wait", 500],
 ["shot", "\${OUT}/04_slot.png"],
 ["hold", 600, 350, 4500],
 ["waitlog", "dug mcl_core:dirt", 10],
 ["wait", 500],
 ["shot", "\${OUT}/05_dug.png"],
 ["tap", 600, 350],
 ["waitlog", "predicted mcl_core:stone at", 10],
 ["wait", 1000],
 ["shot", "\${OUT}/06_placed.png"],
 ["hold", 978, 142, 300],
 ["waitlog", "chat: the line opened", 30],
 ["wait", 500],
 ["type", "/lc_form"],
 ["key", "Enter"],
 ["waitlog", "form lc_touch opened", 15],
 ["wait", 1000],
 ["shot", "\${OUT}/07_form.png"],
 ["tap", 597, 366],
 ["waitlog", "form: a left click", 10],
 ["type", "hello"],
 ["tap", 598, 446],
 ["waitlog", "form: a left click", 10],
 ["wait", 1000]
]
EOF
TOUCH=1 WEB_DRIVE_URL="http://127.0.0.1:$PLAY/" "$here/util/web_drive.sh" firefox play \
	"$out/steps.json" "$out/drive" > "$out/drive.txt" 2>&1 ||
	fail "the drive ($out/drive.txt, $out/drive)"
log=$(grep -a "lc_touch:" "$out/luanti.log")
echo "$log" | tail -20
# The first state after the setup, against the last
first=$(echo "$log" | sed -n '/lc_touch: ready/,$p' | grep -m1 " pos ")
last=$(echo "$log" | grep " pos " | tail -1)
read -r _ _ _ _ _ x0 z0 _ yaw0 _ <<< "$first"
read -r _ _ _ _ _ x1 z1 _ yaw1 _ _ _ wield <<< "$last"
[ "$x0 $z0" != "$x1 $z1" ] || fail "the stick did not walk ($first)"
[ "$yaw0" != "$yaw1" ] || fail "the drag did not turn ($first)"
[ "$wield" = 3 ] || fail "the hotbar tap did not pick slot 3 ($last)"
echo "$log" | grep -q "dug mcl_core:dirt" || fail "a held finger did not dig"
echo "$log" | grep -q "placed mcl_core:stone" || fail "a tap did not place"
echo "$log" | grep -q "fields txt=hello ok=OK" || fail "the form was not typed into"
echo "PASS"
