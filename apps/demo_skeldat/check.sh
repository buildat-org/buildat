#!/bin/bash
# tier: full
# cost: ~2 min (2026-10-15)
# covers: apps/demo_skeldat/** builtin/chat/** src/interface/voxel_path.h src/impl/voxel_path.cpp
# [SKELDAT]: skeldat's rules by their own tests (game.h, bones.h,
# move_check.h, and the engine pathfinder's with its time a search), then
# two runs of one world at seed 2 (valleys: a dry spawn, no steps
# over one voxel ahead), noon.
# The first, two players: player1 walks and jumps unchecked by the
# movement check, and is pulled back once a drive forces fly, fast and
# noclip; digs a voxel without bones, which drops; a test skeleton burns in
# the sun and dies. player2 says a line, and player1 reports player2.
# The second, restarted with the save as if long away (the sections catch
# up) and the client the launcher's own (an admin): the test boar is back
# from the save; the admin mutes player2 from the report and sets who may
# talk, gives and takes an item (the audit log has both), flies into the
# bones zone unchecked, where the fog, the danger music and a skeleton come
# and a dug voxel drops nothing. player2's line is refused, muted.
#   apps/demo_skeldat/check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
check_tmp skeldat; t=$CHECK_TMP
b="$here/Build/bin/buildat"
m="$here/apps/demo_skeldat/main"

# The rules
cc="g++ -std=c++11 -Wno-pragma-once-outside-header -I$here/src"
$cc -DSKELDAT_GAME_TEST -x c++ "$m/game.h" -o "$t/game" && "$t/game" ||
	fail "game.h's self test"
$cc -DSKELDAT_BONES_TEST -x c++ "$m/bones.h" -o "$t/bones" && "$t/bones" ||
	fail "bones.h's self test"
$cc -DSKELDAT_MOVE_TEST -x c++ "$m/move_check.h" -x none \
	"$here/src/impl/voxel_path.cpp" -o "$t/move" && "$t/move" ||
	fail "move_check.h's self test"
path=
g++ -O2 -std=c++14 -I"$here/src" "$here/util/voxel_path_test.cpp" \
	"$here/src/impl/voxel_path.cpp" -o "$t/path" && path=$("$t/path") ||
	fail "the pathfinder's test: $path"
echo "$path" | tail -1

[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display for the runs"
server() # <log> [args]: the world "w" at seed 2, noon
{
	local log=$1
	shift
	BUILDAT_SKELDAT_WORLD=w BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_TIME=0.5 \
		start_server "$log" "STATUS Listening" 300 auto \
		"$here/Build/bin/buildat_server" -m "$here/apps/demo_skeldat" \
		-D "$t/srv" -C "$t/srv.cache" -l 3 "$@" || fail "the server ($log)"
	CHECK_PIDS+=($SERVER_PID)
}
client() # <name> <cmds>, in the background: its PID in $CLIENT
{
	timeout 300 "$b" -C "$t/c_$1" -D "$t/u_$1" -w 800x500 -l 3 \
		-o sound_mute=1 -s "127.0.0.1:$SERVER_PORT" -c @"$2" \
		> "$t/$1.log" 2>&1 &
	CLIENT=$!
	CHECK_PIDS+=($CLIENT)
}
placed='wait_log 180000 skeldat: placed at'

# 1. Two players
cat > "$t/a1.cmds" <<EOF
$placed
wait_log 60000 chat: <player2> hello from player2
keypress Escape
wait_log 5000 pause: the menu shown
delay 500
click Button "Who's in the chat..."
wait_log 5000 chat: the menu shown
delay 1000
click Button "Report player2"
delay 1000
click Button "Close"
wait_log 5000 pause: the menu shown
delay 500
keypress Escape
wait_log 5000 pause: the menu closed
delay 1000
look 0 0
keydown W
keydown Space
delay 2500
keyup Space
keyup W
delay 2000
event skeldat_modes fly
keydown Space
delay 2500
keyup Space
delay 1500
event skeldat_modes fast
keydown W
keydown Space
delay 2500
keyup Space
keyup W
delay 1500
event skeldat_modes fly noclip
keydown Left Shift
delay 2500
keyup Left Shift
delay 1500
event skeldat_modes
delay 1500
look 0 -70
mouse_down left
delay 2500
mouse_up left
quit
EOF
cat > "$t/b1.cmds" <<EOF
$placed
delay 2000
keypress T
delay 800
text hello from player2
keypress Return
delay 500
keypress Escape
delay 15000
quit
EOF
BUILDAT_SKELDAT_TEST="skeleton 0 20; boar 6 0" server "$t/srv1.log"
client a1 "$t/a1.cmds"; a=$CLIENT
wait_for_log "$t/srv1.log" "player1 joins" 240 || fail "player1 did not join ($t/a1.log)"
client b1 "$t/b1.cmds"; bpid=$CLIENT
wait $a || fail "player1's drive ($t/a1.log)"
wait $bpid
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
s="$t/srv1.log"
grep -aq "player1 is a player" "$s" || fail "player1 was not a player ($s)"
first_pull=$(grep -a "pulled back" "$s" | head -1 | awk '{print $3}')
cheat=$(grep -a "modes set by the drive: fly" "$t/a1.log" | head -1 | awk '{print $3}')
[ -n "$cheat" ] || fail "the drive set no modes ($t/a1.log)"
[ -n "$first_pull" ] && [[ ! "$first_pull" < "$cheat" ]] ||
	fail "an honest walk was pulled back, or nothing was: first at $first_pull, the cheat at $cheat ($s)"
for why in "in the air" "too far" "in a wall"; do
	grep -aq "pulled back .*: $why" "$s" || fail "no pull back for \"$why\" ($s)"
done
grep -aE "player1 digs skeldat:[a-z_]+ at [-0-9,]+, bones [0-3]$" "$s" | grep -q . ||
	fail "no dig without bones that drops ($s)"
grep -aq "the skeleton ([0-9]*) burns" "$s" && grep -aq "the skeleton .* dies" "$s" ||
	fail "the test skeleton did not burn to death ($s)"
grep -aq "<player2> hello from player2" "$s" || fail "player2's line ($s)"
grep -aq "player1 reports player2" "$s" || fail "no report ($s, $t/a1.log)"

# 2. The admin, the save as if a day away
cat > "$t/a2.cmds" <<EOF
$placed
wait_log_any 5000 skeldat: role admin
delay 2000
keypress Escape
wait_log 5000 pause: the menu shown
delay 500
click Button "Who's in the chat..."
wait_log 5000 chat: the menu shown
delay 5000
click Button "Mute player2"
delay 1500
click DropDownList "▼"
delay 500
keypress Down
keypress Return
delay 1500
click Button "Close"
wait_log 5000 pause: the menu shown
delay 500
click Button "Admin..."
wait_log 30000 pause: admin got players
delay 500
click Button "player1"
wait_log 30000 pause: admin got inv player1
delay 500
click Button "Give a stack"
wait_log 30000 pause: admin got inv player1
delay 500
click Button "Take*"
wait_log 30000 pause: admin got inv player1
delay 500
click Button "Back"
wait_log 30000 pause: admin got players
delay 500
click Button "The audit log"
wait_log 30000 pause: admin got audit
delay 500
screenshot $t/audit.png
click Button "Back"
delay 500
click Button "Back"
wait_log 5000 pause: the menu shown
delay 500
keypress Escape
wait_log 5000 pause: the menu closed
look 180 0
keypress K
keydown Space
delay 1500
keyup Space
keypress H
keypress J
keydown W
delay 2200
keyup W
keypress J
keypress H
keypress K
delay 2000
look 180 -70
mouse_down left
delay 2500
mouse_up left
delay 1000
screenshot $t/zone.png
delay 12000
quit
EOF
cat > "$t/b2.cmds" <<EOF
$placed
delay 2000
keypress T
delay 800
text can anyone hear me
keypress Return
delay 2000
quit
EOF
BUILDAT_SKELDAT_AWAY=86400 server "$t/srv2.log" -u launcher=1
client a2 "$t/a2.cmds"; a=$CLIENT
wait_for_log "$t/srv2.log" "mutes player2" 300 || fail "no mute ($t/a2.log)"
client b2 "$t/b2.cmds"; bpid=$CLIENT
wait $a || fail "the admin's drive ($t/a2.log)"
wait $bpid
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
s="$t/srv2.log"
mobs=$(grep -a 'the world "w" starts' "$s" | sed 's/.*furnaces, \([0-9]*\) mobs.*/\1/')
[ "${mobs:-0}" -ge 1 ] || fail "no mob back from the save ($s)"
caught=$(grep -a "caught up" "$s" | tail -1 | sed 's/.*, \([0-9]*\) caught up.*/\1/')
[ "${caught:-0}" -ge 1 ] || fail "no section caught up ($s)"
grep -aq "player1 is an admin" "$s" || fail "the launcher's client was no admin ($s)"
grep -aq "player1 mutes player2, upholding a report" "$s" || fail "the mute ($s)"
grep -aq "the lowest level that may talk is member" "$s" || fail "who may talk ($s)"
grep -aq "player1 gives player1: " "$s" && grep -aq "player1 takes player1: " "$s" ||
	fail "the admin's give and take ($s)"
grep -aq "pause: admin got audit" "$t/a2.log" || fail "the audit log page ($t/a2.log)"
grep -aq "player2's line refused: muted" "$s" || fail "the muted line went out ($s)"
grep -aq "pulled back" "$s" && fail "the admin was pulled back ($s)"
grep -aE "skeldat: fog for danger (0\.[5-9]|1)" "$t/a2.log" | grep -q . ||
	fail "no fog in the zone ($t/a2.log)"
grep -aq "skeldat: mood danger" "$t/a2.log" || fail "no danger music ($t/a2.log)"
grep -aE "a skeleton \([0-9]*\) spawns at .*, danger (0\.[5-9]|1)" "$s" | grep -q . ||
	fail "no skeleton spawned in the zone ($s)"
grep -aq "player1 digs .*, dropping nothing" "$s" ||
	fail "no dig in the zone that drops nothing ($s)"
echo "run 1: $(grep -ac "pulled back" "$t/srv1.log") pull backs; run 2: $mobs mobs back, $caught caught up"
echo "PASS: skeldat's rules, the movement check, the chat's report and mute, the admin's menu, the bones zone"
# vim: set noet ts=4 sw=4:
