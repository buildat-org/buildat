#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~3 min (2026-10-12)
# covers: extensions/luanti_client/init.lua extensions/luanti_client/itemdef.lua builtin/luanti/client_lua/client.lua apps/vanilla/main/client_lua/init.lua builtin/luanti/client_lua/module.lua builtin/luanti/lua/dig.lua
# [DIG_SWING_SOUND]: vanilla's swing sounds, by the client's log (no
# audio here). dig_swing.lua's stage in VoxeLibre (named dig sounds) and
# minetest_game ("__group"): stone with a pickaxe and dirt by hand, the
# button held 2.5 s, which digs the node once and swings on at nothing:
# - a swing line about every 1/3.5 s, the first at 0.15 of the first
#   swing, and the swing finished after the button is let go;
# - the node's dig sound on each swing while it is dug, the game's file;
# - its dug sound once.
# "ext" is luanti_client on a Luanti server, VoxeLibre, the same stage.
#
#   builtin/luanti/test/dig_swing.sh [mineclone2|minetest_game|ext]   (all by default)
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
. "$me/../../../util/check_lib.sh"
out="$here/local/dig_swing"
mkdir -p "$out"
cd "$here/Build"
trap check_cleanup EXIT
holds(){
	for what in stone dirt; do
		printf 'keypress T\nwait_log 5000 chat: the line opened\ntext swing %s\nkeypress Return\n' $what
		printf 'wait_log 30000 chat: dig_swing: %s ready\ndelay 1500\n' $what
		# Down at the node one ahead: straight down is the player's own feet
		printf 'look_dir 0.6 -1 0\ndelay 500\n'
		# The hold, and the swing finishing after the button is let go
		printf 'mouse_down left\ndelay 2500\nmouse_up left\ndelay 1000\n'
	done
	echo quit
}
verdict(){ # name cli-log srv-log
	python3 - "$2" "$3" "$1" <<'PY'
import re, sys
cli = open(sys.argv[1], errors="replace").read().splitlines()
srv = open(sys.argv[2], errors="replace").read()
game = sys.argv[3]
def secs(l):
    h, m, s = l.split()[2].split(":")
    return int(h) * 3600 + int(m) * 60 + float(s)
# The two holds, from the chat line that says each is ready
parts, cur = {}, None
for l in cli:
    m = re.search(r"chat: dig_swing: (\w+) ready", l)
    if m:
        cur = m.group(1)
        parts[cur] = {"swings": [], "dug": 0, "digs": []}
    elif cur:
        m = re.search(r"swing: at ([\d.]+), dig (\S+), use (\S+)", l)
        if m:
            parts[cur]["swings"].append((secs(l), float(m.group(1)), m.group(2)))
        # vanilla's "luanti: dug <name>: <file>", luanti_client's "dug ..."
        if re.search(r": (luanti: )?dug [\w:]+: ", l):
            parts[cur]["dug"] += 1
        m = re.search(r"dig: (\S+) takes (\S+) s", l)
        if m:
            parts[cur]["digs"].append((m.group(1), m.group(2)))
bad = []
for what in ("stone", "dirt"):
    p = parts.get(what)
    if not p:
        bad.append(what + ": no mark")
        continue
    sw = p["swings"]
    gaps = [b[0] - a[0] for a, b in zip(sw, sw[1:])]
    gaps.sort()
    mid = gaps[len(gaps) // 2] if gaps else 0
    dig_files = sorted(set(s[2] for s in sw if s[2] != "nil"))
    print("%s %s: %d swings, the first at %.2f, %.3f s apart (median), "
          "dig sounds %s, dug %d, digs %s" % (game, what, len(sw),
          sw[0][1] if sw else -1, mid, ",".join(dig_files) or "none",
          p["dug"], p["digs"]))
    if not 7 <= len(sw) <= 11:
        bad.append("%s: %d swings in 2.5 s" % (what, len(sw)))
    # 0.15 and the frame it was crossed in, up to a tenth of a second
    if sw and not 0.15 <= sw[0][1] < 0.5:
        bad.append("%s: the first swing at %.2f" % (what, sw[0][1]))
    if not 0.24 <= mid <= 0.34:
        bad.append("%s: swings %.3f s apart" % (what, mid))
    if not dig_files:
        bad.append("%s: no dig sound" % what)
    if p["dug"] != 1:
        bad.append("%s: %d dug sounds" % (what, p["dug"]))
dugs = re.findall(r"dig_swing: dug (\S+)", srv)
print("%s: the server dug %s" % (game, dugs))
if len(dugs) != 2:
    bad.append("%d digs on the server" % len(dugs))
assert not bad, "; ".join(bad)
PY
}
run_ext(){
	local luanti=$LUANTI work="$out/ext_world" port
	local bin=${LUANTI_BIN:-$luanti/bin/luanti}
	[ -x "$bin" ] || skip "no Luanti server at $bin"
	rm -rf "$work"; mkdir -p "$work/worldmods/dig_swing"
	printf 'gameid = mineclone2\nbackend = sqlite3\nplayer_backend = sqlite3\nauth_backend = sqlite3\nmod_storage_backend = sqlite3\nworld_name = dig_swing\ncreative_mode = false\nenable_damage = false\nserver_announce = false\n' \
		> "$work/world.mt"
	cp "$me/dig_swing.lua" "$work/worldmods/dig_swing/init.lua"
	printf 'name = dig_swing\n' > "$work/worldmods/dig_swing/mod.conf"
	printf 'fixed_map_seed = 1\nenable_damage = false\nmute_sound = true\n' > "$out/ext.conf"
	for _i in $(seq 50); do port=$((29700 + RANDOM % 300)); port_taken $port || break; done
	check_allow "udp://127.0.0.1:$port"
	( cd "$luanti" && exec "$bin" --server --world "$work" --port "$port" \
		--config "$out/ext.conf" > "$out/ext.srv.log" 2>&1 ) &
	CHECK_PIDS+=($!)
	local lpid=$!
	for _i in $(seq 600); do
		grep -aq "Server for gameid" "$out/ext.srv.log" && break
		kill -0 $lpid 2>/dev/null || break
		sleep 0.2
	done
	grep -aq "Server for gameid" "$out/ext.srv.log" ||
		fail "the Luanti server ($out/ext.srv.log)"
	{
		echo "wait_log 120000 chat: dig_swing: the stage is laid"
		# The stage's blocks round the player drawn: the client says so each
		# time they come to be, the first after the world is in
		echo "wait_log 60000 loading: drawn within 2 blocks round the player"
		holds
	} > "$out/cmds.txt"
	BUILDAT_LUANTI_ADDRESS="127.0.0.1:$port" BUILDAT_LUANTI_NAME=ds \
		BUILDAT_LUANTI_CONNECT=1 run_client 60 "$out/ext.cli.log" timeout 240 \
		bin/buildat -m luanti_client -w 640x400 -l 5 -o sound_mute=1 -c @"$out/cmds.txt" ||
		fail "the ext drive ($out/ext.cli.log)"
	kill "${CHECK_PIDS[-1]}" 2>/dev/null
	verdict ext "$out/ext.cli.log" "$out/ext.srv.log" || fail "ext ($out/ext.cli.log)"
}
for GAME in ${1:-mineclone2 minetest_game ext}; do
	[ "$GAME" = ext ] && { run_ext; continue; }
	[ -d "$BUILDAT_USER_PATH/shared/vanilla/games/$GAME" ] || skip "$GAME is not installed"
	save=buildat_test_dig_swing
	rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
	mkdir -p "$BUILDAT_USER_PATH/apps/vanilla/saves/$save/luanti"
	echo "enable_damage = false" > "$BUILDAT_USER_PATH/apps/vanilla/saves/$save/luanti/world.mt"
	BUILDAT_LUANTI_GAME=$GAME BUILDAT_LUANTI_SAVE="$save" \
		BUILDAT_LUANTI_LUA="$me/dig_swing.lua" \
		start_server "$out/$GAME.srv.log" "Mods loaded" 120 auto \
		bin/buildat_server -u launcher=1 -m ../apps/vanilla -l 3 ||
		fail "the $GAME server ($out/$GAME.srv.log)"
	CHECK_PIDS+=($SERVER_PID)
	{
		echo "wait_log 120000 load: the world is in"
		echo "wait_log 60000 chat: dig_swing: the stage is laid"
		# The world's first sending done: a chunk still on its way from
		# before a dig shows the dug node again, and it is dug twice
		echo "wait_log 120000 scene, 0 undrawn within 2"
		echo "delay 2000"
		holds
	} > "$out/cmds.txt"
	run_client 60 "$out/$GAME.cli.log" timeout 240 bin/buildat -s "localhost:$SERVER_PORT" \
		-w 640x400 -l 5 -o sound_mute=1 -c @"$out/cmds.txt" ||
		fail "the $GAME drive ($out/$GAME.cli.log)"
	kill "$SERVER_PID" 2>/dev/null
	verdict "$GAME" "$out/$GAME.cli.log" "$out/$GAME.srv.log" || fail "$GAME ($out/$GAME.cli.log)"
done
echo "PASS: a swing every 1/3.5 s from 0.15, the node's dig sound on each while it is dug, its dug sound once"
