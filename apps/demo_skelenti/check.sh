#!/bin/bash
# tier: full
# cost: ~2 min (2026-10-14)
# covers: apps/demo_skelenti/** builtin/luanti/client_lua/client.lua builtin/luanti/client_lua/module.lua
# [LUANTI_APP_EXAMPLE]: skelenti packed (its size reported), then played
# on a fresh server at seed 3, midnight: the world dialog creates the
# world; a test skeleton 3 nodes off is punched to death and drops its
# things, which the player walks up to and picks up; the fog follows the
# place's danger, and the client has the danger field to draw; the
# sounds are made with blip and the skeleton's played; Escape opens the pause menu and Continue closes it. The server started again lists the world,
# plays it, and has the test boar back from the save.
#   apps/demo_skelenti/check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp skelenti; t=$CHECK_TMP
b="$here/Build/bin/buildat"

cp -r "$here/apps/demo_skelenti" "$t/app"
"$b" aitta keygen "$t/key" > /dev/null || fail "keygen"
zip=$("$b" aitta pack "$t/app" "$t/key" "$t/out") || fail "pack"
size=$(stat -c %s "$zip")

# The seed, in the save's place before the save is made (no save yet:
# the dialog lists none). v7, which the test's places were picked on:
# under valleys seed 3 spawns at -277,-23, whose nodes reach the game ~20 s
# after the join, and the test's skeleton dies over "ignore"
w="$t/srv/apps/demo_skelenti/saves/world/luanti"
mkdir -p "$w" && printf 'fixed_map_seed = 3\nmg_name = v7\n' > "$w/world.mt"
export BUILDAT_SKELENTI_TEST="skeleton 0 3; boar 4 3" BUILDAT_LUANTI_FORCE_TIME=0
BUILDAT_SKELENTI_WORLD= start_server "$t/srv.log" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/demo_skelenti" \
	-D "$t/srv" -C "$t/srv.cache" -l 3 || fail "the server ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
{
	printf '%s\n' "wait_log 120000 worlds: the dialog shown, 0 worlds" \
		'click Button "Create"' "wait_log 180000 load: the world is in" \
		"delay 3000" "look 0 -5" "delay 300"
	# A held press: a click in one frame is no punch
	for i in $(seq 1 26); do
		printf '%s\n' "mouse_down left" "delay 250" "mouse_up left" "delay 250"
	done
	# Up to the drops: within 2 nodes they are picked up
	printf '%s\n' "keydown w" "delay 1500" "keyup w" "delay 1500"
	printf '%s\n' "keypress Escape" "wait_log 3000 pause: the menu shown" \
		'click Button "Continue"' "wait_log 3000 pause: the menu closed" \
		"screenshot $t/shot.png" "quit"
} > "$t/cmds"
run_client 60 "$t/cli.log" timeout 300 "$b" -C "$t/c" \
	-D "$t/u" -w 800x500 -l 3 -o sound_mute=1 -s "127.0.0.1:$SERVER_PORT" \
	-c @"$t/cmds" || fail "the drive ($t/cli.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
grep -aq 'skelenti: the world "world" starts' "$t/srv.log" ||
	fail "the dialog's Create did not start the world ($t/srv.log)"
died=$(grep -a "skelenti: the skeleton .* dies" "$t/srv.log" | tail -1)
[ -n "$died" ] || fail "no skeleton died: $(grep -ac "hits the skeleton" \
	"$t/srv.log") hits ($t/srv.log)"
grep -aq "fog for danger" "$t/srv.log" || fail "no fog ($t/srv.log)"
grep -aq "skelenti: [0-9]* sounds made" "$t/cli.log" &&
	grep -aq "skelenti: sound skeleton_hurt .*: blip" "$t/cli.log" ||
	fail "no blip sounds made or played ($t/cli.log)"
grep -aq "skelenti: the danger field at" "$t/cli.log" ||
	fail "no danger field on the client ($t/cli.log)"
picked=$(grep -a "skelenti: .* picks up" "$t/srv.log" | sed 's/.*picks up //' | tr '\n' ' ')
[ -n "$picked" ] || fail "nothing picked up ($t/srv.log)"

# Again: the dialog lists the world and plays it, the boar in its save
unset BUILDAT_SKELENTI_TEST
BUILDAT_SKELENTI_WORLD= start_server "$t/srv2.log" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/demo_skelenti" \
	-D "$t/srv" -C "$t/srv.cache" -l 3 || fail "the restart ($t/srv2.log)"
CHECK_PIDS+=($SERVER_PID)
printf '%s\n' "wait_log 120000 worlds: the dialog shown, 1 worlds" \
	'click Button "Play world"' "wait_log 180000 load: the world is in" \
	"quit" > "$t/cmds2"
run_client 60 "$t/cli2.log" timeout 300 "$b" -C "$t/c" \
	-D "$t/u" -w 800x500 -l 3 -o sound_mute=1 -s "127.0.0.1:$SERVER_PORT" \
	-c @"$t/cmds2" || fail "the second drive ($t/cli2.log)"
up=$(grep -a "skelenti: the world is up" "$t/srv2.log" | sed 's/.*is up, //')
[ "${up%% *}" -ge 1 ] 2>/dev/null || fail "no mobs saved: $up ($t/srv2.log)"
echo "packed $size bytes (50 kB the aim); ${died#*skelenti: }; picked up $picked; restarted with $up"
echo "PASS: skelenti's world dialog, a skeleton's death, the fog, the pause menu and the save"
# vim: set noet ts=4 sw=4:
