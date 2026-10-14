#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# [OBJECT_SELECTION_BOX]: objbox.lua's pig, dropped item and player-shaped
# stand-in pointed at one by one in both clients; the box around each is
# in the shots, local/objbox/<client>/<what>.png, and a click on the
# stand-in has to punch it. Needs the Luanti
# checkout and its server binary for luanti_client, as inv_click.sh does.
#
#   builtin/luanti/test/objbox.sh [vanilla|ext]   (both by default)
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/objbox"; mkdir -p "$out"
luanti=~/projects/luanti
bin=${LUANTI_BIN:-$luanti/bin/luanti}
which=${1:-both}
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "SKIP: a client or a server is already running"; exit 77
fi
# From the eye, 1.6 over the feet three nodes west, to each one's middle.
# The delays: the stage's objects, and each look, drawn in the frames
# after; the 300 ms is the punch's hold
cmds(){ # out-dir
	echo "wait_log 120000 chat: objbox: ready"; echo "delay 2000"
	local s
	for s in "pig:3 -1.15 0" "item:3 -1.35 2" "dummy:3 -0.7 -2"; do
		# a settle: first person is aimed at once, the view drawn after it
		echo "look_dir ${s#*:}"; echo "delay 500"
		echo "screenshot $1/${s%%:*}.png"
	done
	# Still on the stand-in: a punch lands on it
	echo "mouse_down left"; echo "delay 300"; echo "mouse_up left"
	echo "wait_log_any 10000 chat: objbox: dummy punched"
	echo quit
}
failed=()
shots(){ # client dir server-log
	local n
	n=$(ls "$2"/*.png 2>/dev/null | wc -l)
	[ "$n" = 3 ] || failed+=("$1: $n shots of 3")
	grep -aq "objbox: dummy punched" "$3" || failed+=("$1: the punch did not land")
}

run_vanilla(){
	local o="$out/vanilla" save=buildat_test_objbox
	rm -rf "$o"; mkdir -p "$o"
	rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
	cd "$here/Build"
	BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE="$save" \
		BUILDAT_LUANTI_LUA="$me/objbox.lua" \
		start_server "$o/srv.log" "Mods loaded" 180 29797 \
		bin/buildat_server -u launcher=1 -m ../apps/vanilla -l 3 ||
		{ echo "FAIL: the server did not start"; exit 1; }
	local srv=$SERVER_PID
	cmds "$o" > "$o/cmds.txt"
	timeout 240 bin/buildat -s localhost:29797 -w 1280x720 -l 3 \
		-o sound_mute=1 -c @"$o/cmds.txt" > "$o/cli.log" 2>&1 ||
		failed+=("vanilla: the drive ($o/cli.log)")
	kill -INT "$srv" 2>/dev/null
	# The server's exit, polled
	for _i in $(seq 1 300); do kill -0 "$srv" 2>/dev/null || break; sleep 0.2; done
	shots vanilla "$o" "$o/srv.log"
}

run_ext(){
	local o="$out/ext" work="$out/ext/world" port=30033
	[ -x "$bin" ] || { echo "SKIP: no Luanti server at $bin"; exit 77; }
	rm -rf "$o"; mkdir -p "$work/worldmods/objbox"
	printf 'gameid = mineclone2\nbackend = sqlite3\nplayer_backend = sqlite3\nauth_backend = sqlite3\nmod_storage_backend = sqlite3\nworld_name = objbox\ncreative_mode = false\nenable_damage = false\nserver_announce = false\n' \
		> "$work/world.mt"
	cp "$me/objbox.lua" "$work/worldmods/objbox/init.lua"
	printf 'name = objbox\n' > "$work/worldmods/objbox/mod.conf"
	printf 'fixed_map_seed = 1\nenable_damage = false\nmute_sound = true\n' \
		> "$o/luanti.conf"
	check_allow "udp://127.0.0.1:$port"
	( cd "$luanti" && exec "$bin" --server --world "$work" --port "$port" \
		--config "$o/luanti.conf" > "$o/luanti_srv.log" 2>&1 ) &
	local srv=$!
	for _i in $(seq 1 600); do
		grep -q "Server for gameid" "$o/luanti_srv.log" 2>/dev/null &&
			port_taken $port && break
		kill -0 $srv 2>/dev/null || break
		sleep 0.2
	done
	cmds "$o" > "$o/cmds.txt"
	BUILDAT_LUANTI_ADDRESS="127.0.0.1:$port" BUILDAT_LUANTI_NAME=ob \
		BUILDAT_LUANTI_CONNECT=1 timeout 240 \
		"$here/Build/bin/buildat" -m luanti_client -w 1280x720 -l 3 \
		-o sound_mute=1 -c @"$o/cmds.txt" > "$o/cli.log" 2>&1 ||
		failed+=("ext: the drive ($o/cli.log)")
	kill "$srv" 2>/dev/null
	# The server's exit, polled
	for _i in $(seq 1 150); do kill -0 "$srv" 2>/dev/null || break; sleep 0.2; done
	shots ext "$o" "$o/luanti_srv.log"
}

[ "$which" = ext ] || run_vanilla
[ "$which" = vanilla ] || run_ext
for f in "${failed[@]}"; do echo "FAIL: $f"; done
[ ${#failed[@]} = 0 ] && echo "PASS: objbox: punched; the shots are in $out"
