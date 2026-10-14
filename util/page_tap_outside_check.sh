#!/bin/bash
# tier: broken
# broken: back to full; touch: a look line before "placed floor:stone"; the
#   same on dev (local/runs/dev_baseline)
# cost: ~4 min (2026-10-11)
# covers: apps/vanilla/main/client_lua/pause.lua
# [PAGE_TAP_OUTSIDE]: a page over vanilla's world (the chat, My account,
# the pause menu) closes on a tap or a click outside it, as its Back or
# Escape does, and does nothing else. A fixture puts the player on a
# platform facing a wall with a marker in it, and logs the look as it
# changes and what is placed and dug. Natively by finger (BUILDAT_TOUCH=1,
# 1000x500) and in Chrome as a phone (skipped without it or web/): the
# touch controls' Chat, a tap inside on its log keeps it, a tap outside
# closes it with nothing placed and the view not turned, and a tap on the
# marker then places. Natively by mouse: the pause menu's Chat..., a click
# outside goes back to the menu and one more closes that.
# simplified: My account is not driven (it needs a public server and a
# login); it is an accounts page as the chat is.
#   util/page_tap_outside_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp page_tap_outside; t=$CHECK_TMP
trap check_cleanup EXIT
cat > "$t/fixture.lua" <<'L'
local P = {x = 40, y = 30, z = 40}
local marker = vector.add(P, {x = 1, y = 1, z = 3})
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
-- The look, each time it changes
local last
core.register_globalstep(function()
	for _, player in ipairs(core.get_connected_players()) do
		local look = string.format("%.2f %.2f", player:get_look_horizontal(),
				player:get_look_vertical())
		if look ~= last then
			last = look
			core.log("action", "page_tap: look " .. look)
		end
	end
end)
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	local inv = player:get_inventory()
	inv:set_list("main", {})
	inv:set_stack("main", 1, "floor:stone 10")
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
		core.log("action", "page_tap: ready")
		core.chat_send_player(name, "page_tap: ready")
	end
	core.after(3, put)
end)
-- The player's; the minimal game's own tests dig too. In the client's log
-- as chat too, for the drive to wait on
core.register_on_placenode(function(pos, node, placer)
	if placer and placer:is_player() then
		core.log("action", "page_tap: placed " .. node.name)
		core.chat_send_all("page_tap: placed " .. node.name)
	end
end)
core.register_on_dignode(function(pos, node, digger)
	if digger and digger:is_player() then
		core.log("action", "page_tap: dug " .. node.name)
		core.chat_send_all("page_tap: dug " .. node.name)
	end
end)
L
server(){ # dir, extra args...
	local d=$1; shift
	mkdir -p "$d/apps/vanilla/saves/tp/luanti" "$d/shared"
	cp "$t/fixture.lua" "$d/shared/"
	echo "enable_damage = false" > "$d/apps/vanilla/saves/tp/luanti/world.mt"
	BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=tp \
	BUILDAT_LUANTI_LUA="$d/shared/fixture.lua" start_server "$d.log" \
		"STATUS Listening" 60 auto "$here/Build/bin/buildat_server" \
		-u launcher=1 -A 127.0.0.1 -m "$here/apps/vanilla" -D "$d" \
		-C "$d.cache" -l 3 "$@" || fail "the server ($d.log)"
	CHECK_PIDS+=($SERVER_PID)
}
client(){ # name, env..., then the sequence on stdin
	local n=$1; shift
	cat > "$t/$n.cmds"
	env "$@" timeout 240 "$here/Build/bin/buildat" -C "$t/${n}c" -D "$t/${n}u" \
		-s 127.0.0.1:$SERVER_PORT -w 1000x500 -u 1 -l 3 -o sound_mute=1 \
		-c @"$t/$n.cmds" > "$t/$n.log" 2>&1 || fail "$n: the drive ($t/$n.log)"
}
# After the ready: the server's look, placed and dug lines, and the
# client's presses off a page, in the order they came (not the drive's
# waits for them)
presses(){ grep -av "command: \|wait_log" "$1" | grep -ao "pause: a press off the .*" | sed 's/pause: //'; }
after(){ # server log, client log
	sed -n '/page_tap: ready/,$p' "$1" | grep -ao "page_tap: \(look\|placed\|dug\).*" |
		sed 's/page_tap: //'
	presses "$2"
}
# 1000x500, UI scale 1: the touch controls' Chat at (850, 94), the chat's
# log at (500, 100), outside it at (900, 300), the marker at (638, 267).
# The world drawn in the frames after its line; a tap inside the chat has
# nothing to wait for but a second of no press off it; after the place,
# a second and a half for whatever else the tap did to reach the server
server "$t/n"
client touch BUILDAT_TOUCH=1 <<C
wait_log 60000 chat: page_tap: ready
wait_log_any 60000 scene, 0 undrawn within 2
delay 2000
tap 850 94
wait_log 10000 chat page: y
tap 500 100
wait_log_absent 1000 pause: a press off
tap 900 300
wait_log 10000 pause: a press off the page
tap 638 267
wait_log 10000 chat: page_tap: placed
delay 1500
quit
C
# Once off the page, the chat closed with nothing placed and the view as
# it was: the marker's tap after it places, once
want(){ # name, server log, client log, wanted lines
	local got
	got=$(after "$2" "$3" | tr '\n' ' ')
	[ "$got" = "$4" ] || fail "$1: \"$got\", not \"$4\" ($2, $3)"
}
want touch "$t/n.log" "$t/touch.log" "placed floor:stone a press off the page "
echo "ok: native by finger"
# By mouse: Escape's pause menu, its Chat..., a click on the log, one off
# the chat back to the menu and one off the menu
# The menu is back in the frames after the press off the chat
client mouse <<C
wait_log 60000 chat: page_tap: ready
keypress Escape
wait_log 10000 pause: the menu shown
click Button "Chat..."
wait_log 10000 chat page: y
mouse_pos 500 100
mouse_click left
wait_log_absent 1000 pause: a press off
mouse_pos 900 300
mouse_click left
wait_log 10000 pause: a press off the page
delay 500
mouse_click left
wait_log 10000 pause: a press off the menu
quit
C
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
got=$(presses "$t/mouse.log" | tr '\n' ' ')
[ "$got" = "a press off the page a press off the menu " ] || fail "mouse: \"$got\" ($t/mouse.log)"
echo "ok: native by mouse"
if ! command -v "${CHROME:-google-chrome}" > /dev/null || [ ! -f "$here/web/buildat.wasm" ]; then
	echo "PASS: native; the web skipped (no Chrome or web/)"
	exit 0
fi
# Chrome at 1000x500 CSS pixels and a density of 1; the web's UI is
# smaller: Chat at (907, 59), outside the chat at (960, 300). The taps wait
# for the client's world as touch_parity_check.sh's do. The waits that
# stay: settles of up to 2 s after a waitlog (the world drawn, the block
# placed before the shot), and the second after the tap inside the chat,
# the window in which nothing must happen (it must not close)
cat > "$t/web.json" <<'J'
[
 ["nav", "${URL}"],
 ["waitlog", "page_tap: ready", 120],
 ["waitlog", "settle: \\d+ to mesh, ([2-9]\\d\\d|\\d{4,}) chunks in scene", 180],
 ["wait", 2000],
 ["tap", 907, 59], ["waitlog", "chat page: y", 10],
 ["shot", "${OUT}/web_chat.png"],
 ["tap", 500, 100], ["wait", 1000],
 ["tap", 960, 300], ["waitlog", "pause: a press off the page", 10],
 ["tap", 638, 267], ["waitlog", "page_tap: placed", 10], ["wait", 1500],
 ["shot", "${OUT}/web_end.png"]
]
J
server "$t/w" -W "$here/web"
TOUCH=1 WEB_DRIVE_VIEWPORT=1000x500@1 WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/" \
	"$here/util/web_drive.sh" chrome vanilla "$t/web.json" "$t/drive" \
	> "$t/drive.txt" 2>&1 || fail "the web drive ($(tail -2 "$t/drive.txt"))"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
want web "$t/w.log" "$t/drive/page.log" "placed floor:stone a press off the page "
echo "PASS: a tap or a click off a page over the world closes it and does nothing else, natively and in Chrome"
