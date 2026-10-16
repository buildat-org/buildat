#!/bin/bash
# tier: full
# cost: ~7 min (2026-10-16)
# covers: apps/demo_skeldat/** builtin/chat/** src/interface/voxel_path.h src/impl/voxel_path.cpp
# [SKELDAT]: skeldat's rules by their own tests (game.h, bones.h,
# move_check.h, and the engine pathfinder's with its time a search), then
# two runs of one world at seed 2 (valleys: a dry spawn, no steps
# over one voxel ahead), noon.
# The first, two players: client1 walks and jumps unchecked by the
# movement check, and is pulled back once a drive forces fly, fast and
# noclip; digs a voxel without bones, which drops; a test skeleton burns in
# the sun and dies. client2 says a line, and client1 reports client2. The
# map makes bone piles in the zone in sight.
# The second, restarted with the save and the client the launcher's own
# (an admin): the test boar is back
# from the save; the admin mutes client2 from the report and sets who may
# talk, gives and takes an item (the audit log has both), flies into the
# bones zone unchecked, where the fog, the danger music and a skeleton come
# and a dug voxel drops nothing. client2's line is refused, muted. The
# admin writes the world's map.
# The third, a world of 2 x 2 x 2 sections made with every voxel at full
# bones (BUILDAT_SKELDAT_FILL): it ends, and started again it stays ended
# and says so to its player.
# The fourth, the skeletons over a world of 4 x 2 x 4 sections: a clean
# one's count grows at night to its target, no further; a flooded one
# has a higher target, and a player among 200 light skeletons wakes some,
# which sleep again when it leaves, none lost. 2000 light
# skeletons added to the first world, restarted headless: their step time.
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
# The spawn at (0, 290): clean ground, the bones zone from z 300 on
# (seed 2's, biased away from the origin: bones.h's danger()); run 1 walks
# along it (-x: open grass, where -z has a cave's crack), the admin of run
# 2 flies into it (+z, 15 degrees to +x: from where run 1 left it, x -16,
# into the zone's core round x 0)
server() # <log> [args]: the world "w" at seed 2, noon
{
	local log=$1
	shift
	BUILDAT_SKELDAT_WORLD=w BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_TIME=0.5 \
		BUILDAT_SKELDAT_SPAWN="0 290" \
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
wait_log 60000 chat: <client2> hello from client2
keypress Escape
wait_log 5000 pause: the menu shown
delay 500
click Button "Who's in the chat..."
wait_log 5000 chat: the menu shown
delay 1000
click Button "Report client2"
delay 1000
click Button "Close"
wait_log 5000 pause: the menu shown
delay 500
keypress Escape
wait_log 5000 pause: the menu closed
delay 1000
look -90 0
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
look -90 -70
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
text hello from client2
keypress Return
delay 500
keypress Escape
delay 2000
look 0 0
keydown W
delay 2500
keyup W
delay 10000
quit
EOF
# Both spawn at one place: bones at 8 beside it make client2 look like a
# skeleton to client1 until it walks off (7 and the box: bones.h's self test)
BUILDAT_SKELDAT_TEST="skeleton 0 20; boar 6 0; bones 1 0 8" server "$t/srv1.log"
client a1 "$t/a1.cmds"; a=$CLIENT
wait_for_log "$t/srv1.log" "client1 joins" 240 || fail "client1 did not join ($t/a1.log)"
client b1 "$t/b1.cmds"; bpid=$CLIENT
wait $a || fail "client1's drive ($t/a1.log)"
wait $bpid
# The whole world in memory ([SKELDAT_BOUNDED_WORLD]): the server's size
rss=$(ps -o rss= -p $SERVER_PID)
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
s="$t/srv1.log"
# Made at seed 2, the world's surface inside its 128 voxels of height:
# the highest voxel the generator made under the top (63)
top=$(grep -a "512 of 512 sections loaded" "$s" | sed 's/.*sections loaded, \([0-9.]*\) s, the highest voxel made at y \(-*[0-9]*\)/\1 \2/')
[ -n "$top" ] && [ "${top#* }" -lt 60 ] ||
	fail "the world not all in, or made over its top: $top ($s)"
echo "the world: 512 sections in ${top% *} s, the highest voxel at y ${top#* }, the server $((rss / 1024)) MB"
grep -aq "client1 is a player" "$s" || fail "client1 was not a player ($s)"
first_pull=$(grep -a "pulled back" "$s" | head -1 | awk '{print $3}')
cheat=$(grep -a "modes set by the drive: fly" "$t/a1.log" | head -1 | awk '{print $3}')
[ -n "$cheat" ] || fail "the drive set no modes ($t/a1.log)"
[ -n "$first_pull" ] && [[ ! "$first_pull" < "$cheat" ]] ||
	fail "an honest walk was pulled back, or nothing was: first at $first_pull, the cheat at $cheat ($s)"
for why in "in the air" "too far" "in a wall"; do
	grep -aq "pulled back .*: $why" "$s" || fail "no pull back for \"$why\" ($s)"
done
grep -aE "client1 digs skeldat:[a-z_]+ at [-0-9,]+, bones [0-3]$" "$s" | grep -q . ||
	fail "no dig without bones that drops ($s)"
grep -aq "the skeleton ([0-9]*) burns" "$s" && grep -aq "the skeleton .* dies" "$s" ||
	fail "the test skeleton did not burn to death ($s)"
grep -aq "<client2> hello from client2" "$s" || fail "client2's line ($s)"
grep -aq "client1 reports client2" "$s" || fail "no report ($s, $t/a1.log)"
grep -a "skeldat: client2 looks like a" "$t/a1.log" | tail -2 | sed 's/.*looks like a //' |
	tr '\n' ' ' | grep -qx "skeleton player " ||
	fail "client2 did not look like a skeleton by the bones and then a player ($t/a1.log)"

# 2. The admin
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
click Button "Mute client2"
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
click Button "client1"
wait_log 30000 pause: admin got inv client1
delay 500
click Button "Give a stack"
wait_log 30000 pause: admin got inv client1
delay 500
click Button "Take*"
wait_log 30000 pause: admin got inv client1
delay 500
click Button "Back"
wait_log 30000 pause: admin got players
delay 500
click Button "The audit log"
wait_log 30000 pause: admin got audit
delay 500
screenshot $t/audit.png
click Button "Back"
wait_log 30000 pause: admin got players
delay 500
click Button "The world's map"
wait_log 60000 pause: admin got map
delay 500
click Button "Back"
delay 500
click Button "Back"
wait_log 5000 pause: the menu shown
delay 500
keypress Escape
wait_log 5000 pause: the menu closed
look 15 0
keypress K
keydown Space
delay 1500
keyup Space
keypress H
keypress J
keydown W
delay 3200
keyup W
keypress J
keypress H
keypress K
delay 2000
look 15 -70
mouse_down left
delay 6000
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
server "$t/srv2.log" -u launcher=1
client a2 "$t/a2.cmds"; a=$CLIENT
wait_for_log "$t/srv2.log" "mutes client2" 300 || fail "no mute ($t/a2.log)"
client b2 "$t/b2.cmds"; bpid=$CLIENT
wait $a || fail "the admin's drive ($t/a2.log)"
wait $bpid
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
s="$t/srv2.log"
mobs=$(grep -a 'the world "w" starts' "$s" | sed 's/.*furnaces, \([0-9]*\) mobs.*/\1/')
[ "${mobs:-0}" -ge 1 ] || fail "no mob back from the save ($s)"
grep -aq "client1 is an admin" "$s" || fail "the launcher's client was no admin ($s)"
grep -aq "client1 mutes client2, upholding a report" "$s" || fail "the mute ($s)"
grep -aq "the lowest level that may talk is member" "$s" || fail "who may talk ($s)"
grep -aq "client1 gives client1: " "$s" && grep -aq "client1 takes client1: " "$s" ||
	fail "the admin's give and take ($s)"
grep -aq "pause: admin got audit" "$t/a2.log" || fail "the audit log page ($t/a2.log)"
map="$t/srv/apps/demo_skeldat/saves/w/map.png"
grep -aq "skeldat: the map written to $map" "$s" &&
	[ "$(python3 -I -c 'import struct,sys; d=open(sys.argv[1],"rb").read(24); print(*struct.unpack(">II", d[16:24]))' "$map")" = "1024 1024" ] ||
	fail "the admin's map not written, 1024 x 1024 ($s)"
grep -aq "client2's line refused: muted" "$s" || fail "the muted line went out ($s)"
grep -aE "skeldat: the first bone piles, [1-9]" "$t/srv1.log" | grep -q . ||
	fail "no bone piles generated ($t/srv1.log)"
grep -aq "pulled back" "$s" && fail "the admin was pulled back ($s)"
grep -aE "skeldat: fog for danger (0\.[5-9]|1)" "$t/a2.log" | grep -q . ||
	fail "no fog in the zone ($t/a2.log)"
grep -aq "skeldat: mood danger" "$t/a2.log" || fail "no danger music ($t/a2.log)"
grep -aE "a skeleton \([0-9]*\) spawns at .*, danger (0\.[5-9]|1)" "$s" | grep -q . ||
	fail "no skeleton spawned in the zone ($s)"
grep -aq "client1 digs .*, dropping nothing" "$s" ||
	fail "no dig in the zone that drops nothing ($s)"
# 3. The end: a world of 2 x 2 x 2 sections, every voxel made with bones,
# ends; started again, it is still ended, and its player told
log3="$t/srv3.log"
BUILDAT_SKELDAT_WORLD=end BUILDAT_SKELDAT_SIZE="1 -1 0" BUILDAT_SKELDAT_FILL=1 \
	start_server "$log3" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/demo_skeldat" \
	-D "$t/srv3" -C "$t/srv.cache" -l 3 || fail "the server ($log3)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$log3" "every voxel has bones: the world ends after" 60 ||
	fail "the filled world did not end ($log3)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
# The notice comes with the placing, before a wait_log after it would look
printf '%s\n' "$placed" "delay 1000" "screenshot $t/end.png" quit \
	> "$t/end.cmds"
log3="$t/srv4.log"
BUILDAT_SKELDAT_WORLD=end BUILDAT_SKELDAT_SIZE="1 -1 0" \
	start_server "$log3" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/demo_skeldat" \
	-D "$t/srv3" -C "$t/srv.cache" -l 3 || fail "the server ($log3)"
CHECK_PIDS+=($SERVER_PID)
client end "$t/end.cmds"
wait $CLIENT || fail "the ended world's drive ($t/end.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
grep -aq "skeldat: Every voxel has bones. The world ended after" "$t/end.log" ||
	fail "the ended world's player not told ($t/end.log)"
grep -aq 'the world "end" ended after' "$log3" ||
	fail "the end not kept in the save ($log3)"
# The world again, headless, with 2000 light skeletons more: their step
# time, two reports after the world is in
BUILDAT_SKELDAT_SKELETONS=2000 server "$t/srv7.log"
wait_for_log "$t/srv7.log" "2000 skeletons added" 300 ||
	fail "the 2000 skeletons not added ($t/srv7.log)"
for i in $(seq 60); do
	[ "$(sed -n '/skeletons added/,$p' "$t/srv7.log" |
		grep -ac "skeletons, [0-9]* full")" -ge 2 ] && break
	sleep 0.5
done
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
light=$(grep -a "skeletons, [0-9]* full" "$t/srv7.log" | tail -1 | sed 's/.*skeldat: //')

# 4. The skeletons over the world ([SKELDAT_SKELETON_SIM]), in 4 x 2 x 4
# sections. A clean world, a game hour every 2 s from 19:12: the count
# grows at night toward its target and no further.
log5="$t/srv5.log"
BUILDAT_SKELDAT_WORLD=sim BUILDAT_SKELDAT_SIZE="2 -1 0" BUILDAT_SKELDAT_DAY=48 \
	BUILDAT_SKELDAT_TIME=0.8 start_server "$log5" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/demo_skeldat" \
	-D "$t/srv5" -C "$t/srv.cache" -l 3 || fail "the server ($log5)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$log5" "skeldat: 1[0-9] skeletons, the target" 60 ||
	fail "the clean world's count did not grow ($log5)"
sleep 6
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
clean=$(grep -a "skeletons, the target" "$log5" | tail -1 | sed 's/.*skeldat: //')
grep -a "skeletons, the target" "$log5" | awk '$8 > $12 + 0 { bad = 1 } END { exit !bad }' &&
	fail "the count went past the target ($log5)"
# Every voxel flooded, a higher target; 200 light skeletons at midnight
# (the dying is in the morning), a player among them a while: some wake
# and sleep again, none lost
log6="$t/srv6.log"
BUILDAT_SKELDAT_WORLD=sim BUILDAT_SKELDAT_SIZE="2 -1 0" BUILDAT_SKELDAT_FILL=1 \
	BUILDAT_SKELDAT_SKELETONS=200 BUILDAT_SKELDAT_TIME=0 BUILDAT_SKELDAT_DAY=240 \
	start_server "$log6" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/demo_skeldat" \
	-D "$t/srv6" -C "$t/srv.cache" -l 3 || fail "the server ($log6)"
CHECK_PIDS+=($SERVER_PID)
printf '%s\n' "$placed" "delay 12000" quit > "$t/sim.cmds"
client sim "$t/sim.cmds"
wait $CLIENT || fail "the drive among the skeletons ($t/sim.log)"
n=$(grep -ac "skeletons, [0-9]* full" "$log6")
for i in $(seq 60); do
	[ "$(grep -ac "skeletons, [0-9]* full" "$log6")" -gt "$n" ] && break
	sleep 0.5
done
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
grep -aE "skeldat: [0-9]+ skeletons, [1-9][0-9]* full" "$log6" | grep -q . ||
	fail "no skeleton woke by the player ($log6)"
last=$(grep -a "skeletons, [0-9]* full" "$log6" | tail -1)
echo "$last" | grep -qE "skeldat: (2[0-9][0-9]) skeletons, 0 full" ||
	fail "after the player: $last ($log6)"
grep -a "skeletons, the target" "$log6" | tail -1 | grep -q "the target 125 (1.000" ||
	fail "the flooded world's target ($log6)"
echo "skeletons: clean: $clean; flooded, after the player: $(echo "$last" | sed 's/.*skeldat: //'); the world with 2000 added: $light"
echo "run 1: $(grep -ac "pulled back" "$t/srv1.log") pull backs; run 2: $mobs mobs back"
echo "PASS: skeldat's rules, the movement check, the chat's report and mute, the admin's menu and map, the bones zone, the world's end, the skeletons' count, sleep and wake"
# vim: set noet ts=4 sw=4:
