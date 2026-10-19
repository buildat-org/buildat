#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: broken
# needs: pixels
# broken: back to full; step 5 sent no awards=CHG:2 (dev); no "vl_inv: step
#   5" (the branch) (local/runs/dev_baseline)
# [VL_INV_PARITY]: VoxeLibre's survival inventory and the forms it opens,
# in both clients, beside official Luanti's own
# (local/luanti_inventory_reference/, the user's): the inventory, the
# recipe book, help, the achievements and their second entry. A fixture
# opens the inventory as the inventory key would, again each time the
# client asks for the next step, and the client clicks what a player
# would -- the recipe
# book's, help's and the achievements' buttons, then the list's second
# row -- and shoots each form the game answers with. The shots land in
# local/vl_inv/<client>/, each beside its reference in
# local/vl_inv/side_<n>.png (reference left, vanilla, luanti_client);
# what to compare is the eye's. Asserted: every form shot, and every
# click reached the game as the field it names, and the game's player
# inventory callbacks refused one drag and were told of the next. Needs the Luanti
# checkout and its server binary for luanti_client, as ext_hotbar.sh
# does.
#
#   builtin/luanti/test/vl_inv.sh [vanilla|ext]   (both by default)
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
out="$here/local/vl_inv"; mkdir -p "$out"
ref="$here/local/luanti_inventory_reference"
luanti=$LUANTI
bin=$LUANTI_SERVER_BIN
which=${1:-both}
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "SKIP: a client or a server is already running"; exit 77
fi
fixture='core.settings:set("creative_mode", "false")
core.settings:set("enable_damage", "false")
-- First of the handlers, once all are in: one of the game returns true
-- and ends the rest
core.register_on_mods_loaded(function()
	table.insert(core.registered_on_player_receive_fields, 1,
			function(player, formname, fields)
		local keys = {}
		for k, v in pairs(fields) do keys[#keys + 1] = k .. "=" .. v end
		table.sort(keys)
		core.log("action", "vl_inv: fields " .. table.concat(keys, " "))
	end)
end)
-- The game has its say on a move in the player inventory: the first drag
-- is refused, which keeps the tree where it was, and the second is told
local refused = false
core.register_allow_player_inventory_action(function(player, action, inv, info)
	if action == "move" and not refused then
		refused = true
		core.after(0.5, function()
			core.log("action", "vl_inv: refused, main 1 " ..
					inv:get_stack("main", 1):get_name())
		end)
		return 0
	end
end)
core.register_on_player_inventory_action(function(player, action, inv, info)
	core.log("action", "vl_inv: on " .. action .. " " .. info.from_list ..
			" " .. info.from_index .. " " .. info.to_list .. " " ..
			info.to_index .. " " .. info.count)
end)
core.register_on_joinplayer(function(player)
	core.set_timeofday(0.5)
	player:get_inventory():add_item("main", "mcl_core:tree")
end)
-- The next steps, asked for by the client with /vl_next once it has shot
-- the last. The inventory for steps 1-4 and 6; 5 is a click in the
-- achievements 4 opened, 7 one in the help 6 opened, so each comes with
-- the step before it: the client cannot chat with a form open
local groups, at = {{1}, {2}, {3}, {4, 5}, {6, 7}}, 0
core.register_chatcommand("vl_next", {func = function(name)
	local player = core.get_player_by_name(name)
	if not player or not groups[at + 1] then
		return true
	end
	at = at + 1
	for _, i in ipairs(groups[at]) do
		if i == 2 then
			-- Where step 1 dragged the tree to
			local inv = player:get_inventory()
			core.log("action", "vl_inv: main 1 " ..
					inv:get_stack("main", 1):get_name() .. ", main 10 " ..
					inv:get_stack("main", 10):get_name())
		end
		if i ~= 5 and i ~= 7 then
			core.show_formspec(name, "", player:get_inventory_formspec())
		end
		core.chat_send_player(name, "vl_inv: step " .. i)
	end
	return true
end})'
# Each step starts on the chat line the fixture sends with it (a line of
# this run's anywhere, as 5 and 7 come with 4 and 6). Where the
# inventory's buttons and the lists' rows are, at 1280x720, is the same
# in both clients; what the step's last click must send. A step's clicks
# are separated by ";", and "2x" before one doubles it: 6 opens help, its
# Blocks and the list's fifth entry, which is selected and nothing else
# ("sel": no form comes back, so the game is given a second and a half);
# 7 is a double click on the eighth, which opens it. Every other click is
# answered with a form, which the client logs as opened.
clicks=("" "698 318" "758 318" "878 318" "700 243" \
	"758 318;634 203;sel 300 170" "2x 300 202")
sent=("" "__mcl_craftguide=" "__mcl_doc=" "__mcl_achievements=" "awards=CHG:2" \
	"doc_catlist=CHG:5" "doc_catlist=DCL:8")
# The next steps asked for: the form closed (its quit is sent, which the
# checks do not read) and the chat line typed
next_step(){
	echo "keypress Escape"; echo "delay 300" # the form gone in the next frames
	echo "keypress T"; echo "wait_log 5000 chat: the line opened"
	echo "text /vl_next"; echo "keypress Return"
}
cmds(){ # out-dir ready-wait-lines...
	local i c o=$1
	shift
	printf '%s\n' "$@"
	echo "keypress T"; echo "wait_log 5000 chat: the line opened"
	echo "text /vl_next"; echo "keypress Return"
	for i in 1 2 3 4 5 6 7; do
		# The form shown with the line is drawn in the frames after it
		echo "wait_log_any 20000 chat: vl_inv: step $i"
		echo "delay 1000"
		IFS=';' read -ra cs <<< "${clicks[$((i - 1))]}"
		for c in "${cs[@]}"; do
			local at=${c#sel }
			at=${at#2x }
			# The click's frames: the hover read before the press
			echo "mouse_pos $at"; echo "delay 200"
			echo "mouse_click left"
			# A double click: the second within 300 ms
			if [ "${c#2x }" != "$c" ]; then echo "delay 100"; echo "mouse_click left"; fi
			# simplified: "sel" sends a field and gets no form back, so
			# it is given 1.5 s; a server line seen by the client would do
			if [ "${c#sel }" != "$c" ]; then echo "delay 1500"
			else echo "wait_log 10000 opened"; fi
		done
		# A settle after the line: the form drawn before the shot
		echo "delay 500"; echo "screenshot $o/s$i.png"
		if [ $i = 1 ]; then
			# The tree dragged from the hotbar row's first slot to the
			# first slot above: picked up by the press, put by the release.
			# Twice, as the game refuses the first.
			# simplified: the game's word on each drag is waited for by
			# time; nothing on the client says it has come
			# The 200-300 ms: the drag's frames between the moves
			for _ in 1 2; do
				echo "mouse_pos 400 578"; echo "delay 200"
				echo "mouse_down left"; echo "delay 300"
				echo "mouse_pos 400 388"; echo "delay 300"
				# simplified: the game's word, by time (above)
				echo "mouse_up left"; echo "delay 1500"
			done
		fi
		case $i in 1|2|3|5) next_step;; esac
	done
	echo quit
}
# Whether each click reached the game: the server log, the fields line
check_sent(){ # client server-log
	local i
	for i in 2 3 4 5 6 7; do
		grep -aq "vl_inv: fields .*${sent[$((i - 1))]}" "$2" ||
			failed+=("$1: step $i sent no ${sent[$((i - 1))]}")
	done
	grep -aq "vl_inv: main 1 , main 10 mcl_core:tree" "$2" ||
		failed+=("$1: the tree was not dragged to main 10")
	grep -aq "vl_inv: refused, main 1 mcl_core:tree" "$2" ||
		failed+=("$1: a refused move did not keep the tree in main 1")
	[ "$(grep -ac "vl_inv: on move main 1 main 10 1" "$2")" = 1 ] ||
		failed+=("$1: the move was not told once to the game")
}
failed=()
# The servers this run started, stopped at its exit however it ends
pids=()
trap 'kill "${pids[@]}" 2>/dev/null' EXIT

run_vanilla(){
	local o="$out/vanilla" save=buildat_test_vl_inv
	rm -rf "$o"; mkdir -p "$o"
	rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
	printf '%s\n' "$fixture" > "$o/fixture.lua"
	cd "$here/Build"
	BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE="$save" \
		BUILDAT_LUANTI_LUA="$o/fixture.lua" \
		start_server "$o/srv.log" "Mods loaded" 400 29797 \
		bin/buildat_server -u launcher=1 -m ../apps/vanilla -l 3 ||
		{ echo "FAIL: the server did not start"; exit 1; }
	local srv=$SERVER_PID
	pids+=($srv)
	cmds "$o" "wait_log 120000 the server put the player" \
		"wait_log 60000 scene, 0 undrawn within 2" > "$o/cmds.txt"
	timeout 180 bin/buildat -s localhost:29797 -w 1280x720 -l 3 \
		-o sound_mute=1 -c @"$o/cmds.txt" > "$o/cli.log" 2>&1 ||
		fail "vanilla: the drive ($o/cli.log): $(grep -ao 'Command sequence failed.*' "$o/cli.log" | head -1)"
	kill -INT "$srv" 2>/dev/null
	# a poll: the server's exit
	for _i in $(seq 1 300); do kill -0 "$srv" 2>/dev/null || break; sleep 0.2; done
	check_sent vanilla "$o/srv.log"
}

run_ext(){
	local o="$out/ext" work="$out/ext/world"
	[ -x "$bin" ] || { echo "SKIP: no Luanti server at $bin"; exit 77; }
	rm -rf "$o"; mkdir -p "$work/worldmods/vl_inv"
	printf 'gameid = mineclone2\nbackend = sqlite3\nplayer_backend = sqlite3\nauth_backend = sqlite3\nmod_storage_backend = sqlite3\nworld_name = vl_inv\ncreative_mode = false\nenable_damage = false\nserver_announce = false\n' \
		> "$work/world.mt"
	printf '%s\n' "$fixture" > "$work/worldmods/vl_inv/init.lua"
	printf 'name = vl_inv\n' > "$work/worldmods/vl_inv/mod.conf"
	printf 'fixed_map_seed = 1\nenable_damage = false\nmute_sound = true\n' \
		> "$o/luanti.conf"
	start_luanti_server "$work" "$o/luanti.conf" "$o/luanti_srv.log" ||
		fail "the Luanti server did not come up ($o/luanti_srv.log)"
	local srv=$LUANTI_PID port=$LUANTI_PORT
	pids+=($srv)
	cmds "$o" "wait_log 120000 voxel types have their own textures" > "$o/cmds.txt"
	BUILDAT_LUANTI_ADDRESS="127.0.0.1:$port" BUILDAT_LUANTI_NAME=vi \
		BUILDAT_LUANTI_CONNECT=1 timeout 240 \
		"$here/Build/bin/buildat" -m luanti_client -w 1280x720 -l 3 \
		-o sound_mute=1 -c @"$o/cmds.txt" > "$o/cli.log" 2>&1 ||
		fail "ext: the drive ($o/cli.log): $(grep -ao 'Command sequence failed.*' "$o/cli.log" | head -1)"
	kill "$srv" 2>/dev/null
	# a poll: the server's exit
	for _i in $(seq 1 150); do kill -0 "$srv" 2>/dev/null || break; sleep 0.2; done
	check_sent ext "$o/luanti_srv.log"
}

[ "$which" = ext ] || run_vanilla
[ "$which" = vanilla ] || run_ext
for f in "${failed[@]}"; do echo "FAIL: $f"; done
python3 - "$out" "$ref" <<'PY' || exit 1
import os, sys
from PIL import Image
out, ref = sys.argv[1], sys.argv[2]
missing = []
for n in range(1, 6):
    row = [Image.open("%s/screenshot_%d.png" % (ref, n)).convert("RGB")
            .resize((1280, 720))]
    for c in ("vanilla", "ext"):
        p = "%s/%s/s%d.png" % (out, c, n)
        if os.path.exists(p):
            row.append(Image.open(p).convert("RGB").resize((1280, 720)))
        elif os.path.isdir("%s/%s" % (out, c)):
            missing.append(p)
    side = Image.new("RGB", (1280 * len(row), 720))
    for i, im in enumerate(row):
        side.paste(im, (1280 * i, 0))
    side.save("%s/side_%d.png" % (out, n))
if missing:
    print("FAIL: not shot: " + ", ".join(missing))
    sys.exit(1)
# The entry a click in help's list picked is shown picked, by the client:
# the game is only told (step 6)
for c in ("vanilla", "ext"):
    p = "%s/%s/s6.png" % (out, c)
    if os.path.exists(p):
        px = Image.open(p).convert("RGB").getpixel((600, 172))
        if not (px[1] > 120 and px[1] > px[0] + 40 and px[1] > px[2] + 40):
            print("FAIL: %s: the picked entry is not shown picked (%s)" % (p, px))
            sys.exit(1)
print("PASS: the five forms shot, beside the reference in " + out)
PY
[ ${#failed[@]} -eq 0 ] || exit 1
