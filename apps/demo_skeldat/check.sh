#!/bin/bash
# tier: full
# cost: ~13 min (2026-10-16)
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
# The fifth, a skeleton's marker skull: one on its first sight of a
# player, none on its next that day, the count kept in the save.
# The sixth, a night of 60 light skeletons in a fast clean world: more of
# them in the footprint given three markers by the sunrise, and bone
# blocks placed.
# The seventh, lanterns: no bones grow in a burning one's sphere, those
# there fall and a bone block goes; out of coal, the bones come back.
# The eighth, a burning lantern lures light skeletons and one takes it;
# the ninth, with a player: a skeleton beside one takes it, burns and
# leaves it where it died, dropping bones; a marker skull dug and placed.
# The tenth, the dig's crack: its frames by the dig's progress, gone
# when the dig ends or is cut off.
# The eleventh, the sizes: 512, 256 and 128 wide made and surveyed (the
# tops inside the height, the ores, the edge at full bones, the origin
# clean) as run 1's 1024 is.
# The twelfth, crafting more: the held result clicked again crafts another
# set onto it.
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
	timeout 480 "$b" -C "$t/c_$1" -D "$t/u_$1" -w 800x500 -l 3 \
		-o sound_mute=1 -s "127.0.0.1:$SERVER_PORT" -c @"$2" \
		> "$t/$1.log" 2>&1 &
	CLIENT=$!
	CHECK_PIDS+=($CLIENT)
}
placed='wait_log 300000 skeldat: placed at'

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
BUILDAT_SKELDAT_SURVEY=1 BUILDAT_SKELDAT_TEST="skeleton 0 20; boar 6 0; bones 1 0 8" \
	server "$t/srv1.log"
client a1 "$t/a1.cmds"; a=$CLIENT
wait_for_log "$t/srv1.log" "client1 joins" 330 || fail "client1 did not join ($t/a1.log)"
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
# A world's survey line ([SKELDAT_WORLD_SIZES]): <log> <lowest y>: the
# tops inside the height, each ore there, every edge column at full
# bones and the origin's none
surveyed()
{
	local line
	line=$(grep -a "skeldat: survey:" "$1" | tail -1)
	echo "$line" | awk -v y0="$2" '{
		split($0, a, "tops "); split(a[2], b, ","); split(b[1], t, "\\.\\.")
		for(i = 1; i <= NF; i++){
			if($i == "coal" || $i == "iron" || $i == "diamond") if($(i + 1) + 0 == 0) bad = 1
			if($i == "bones") { if($(i + 1) + 0 != $(i + 3) + 0) bad = 1 }
		}
		if(t[1] + 0 < y0 || t[2] + 0 > 62 || $NF != 0) bad = 1
		exit bad }' || fail "the world made: $line ($1)"
}
surveyed "$s" -64
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
BUILDAT_SKELDAT_WORLD=end BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="1 -1 0" BUILDAT_SKELDAT_FILL=1 \
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
BUILDAT_SKELDAT_WORLD=end BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="1 -1 0" \
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
# 6. A night: 60 light skeletons in a clean world, footprint (0, 0) given
# three markers, a day of 60 s and a step every 0.02 s: from the sunset
# to the sunrise more of them are in (0, 0), and they placed bone blocks
log10="$t/srv10.log"
BUILDAT_SKELDAT_WORLD=night BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="2 -1 0" BUILDAT_SKELDAT_DAY=60 \
	BUILDAT_SKELDAT_TIME=0.6 BUILDAT_SKELDAT_SKELETONS=60 \
	BUILDAT_SKELDAT_MARKERS="0 0 3" BUILDAT_SKELDAT_LIGHT_STEP=0.02 \
	start_server "$log10" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/demo_skeldat" \
	-D "$t/srv10" -C "$t/srv.cache" -l 3 || fail "the server ($log10)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$log10" ": sunset: " 60 || fail "no sunset ($log10)"
for i in $(seq 120); do
	sed -n '/: sunset: /,$p' "$log10" | grep -aq ": sunrise: " && break
	sleep 0.5
done
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
# "sunset K 0" and "sunrise K B": K in (0, 0), B the night's bone blocks
night=$(sed -n '/: sunset: /,$p' "$log10" | grep -a ": sunset: \|: sunrise: " |
	sed -n '1p;/sunrise/{p;q}' |
	sed 's/.*: \(sun[a-z]*\): .* has \([0-9]*\); \([0-9]*\) bone.*/\1 \2 \3/')
echo "$night" | awk 'NR == 1 { a = $2 } NR == 2 { b = $2; n = $3 }
	END { exit !(b > a && n > 0) }' ||
	fail "the night: $(echo $night) ($log10)"
# 5. A marker skull: a skeleton 8 voxels from a player at midnight places
# one; the player gone and another come, the same skeleton sees it and
# places none that day; the count is in the save
mark() # <log>: the small world "mark" at midnight, MARK_TEST its test
{
	local log=$1
	BUILDAT_SKELDAT_WORLD=mark BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="2 -1 0" \
		BUILDAT_SKELDAT_TIME=0 BUILDAT_SKELDAT_TEST="${MARK_TEST:-}" \
		start_server "$log" "STATUS Listening" 300 auto \
		"$here/Build/bin/buildat_server" -m "$here/apps/demo_skeldat" \
		-D "$t/srv8" -C "$t/srv.cache" -l 3 || fail "the server ($log)"
	CHECK_PIDS+=($SERVER_PID)
}
MARK_TEST="skeleton 0 8" mark "$t/srv8.log"
printf '%s\n' "$placed" "delay 4000" quit > "$t/mark.cmds"
for c in mark1 mark2; do
	client $c "$t/mark.cmds"
	wait $CLIENT || fail "the drive by the marker's skeleton ($t/$c.log)"
done
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
[ "$(grep -ac "skeldat: a skeleton (1) places a marker skull" "$t/srv8.log")" = 1 ] ||
	fail "not one marker skull placed ($t/srv8.log)"
grep -aq "skeldat: a skeleton (1) sees client[0-9]*, its marker placed today" \
	"$t/srv8.log" || fail "the second sight not seen, or a second marker ($t/srv8.log)"
mark "$t/srv9.log"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
grep -aq "skeldat: 1 marker skulls in the world" "$t/srv9.log" ||
	fail "the marker's count not in the save ($t/srv9.log)"

# 4. The skeletons over the world ([SKELDAT_SKELETON_SIM]), in 4 x 2 x 4
# sections. A clean world, a game hour every 2 s from 19:12: the count
# grows at night toward its target and no further.
log5="$t/srv5.log"
BUILDAT_SKELDAT_WORLD=sim BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="2 -1 0" BUILDAT_SKELDAT_DAY=48 \
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
BUILDAT_SKELDAT_WORLD=sim BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="2 -1 0" BUILDAT_SKELDAT_FILL=1 \
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
grep -aE "skeldat: [0-9]+ skeletons, [0-9]+ full, [1-9][0-9]* woken" "$log6" | grep -q . ||
	fail "no skeleton woke by the player ($log6)"
last=$(grep -a "skeletons, [0-9]* full" "$log6" | tail -1)
echo "$last" | grep -qE "skeldat: (2[0-9][0-9]) skeletons, 0 full" ||
	fail "after the player: $last ($log6)"
grep -a "skeletons, the target" "$log6" | tail -1 | grep -q "the target 125 (1.000" ||
	fail "the flooded world's target ($log6)"
# 7. Lanterns ([SKELDAT_FIGHT_BACK]) in 2 x 2 x 2 sections at seed 2,
# the bones at full at x >= 0 and none at x < 0, a section's expansion
# every 0.3 s and a coal 40 s: one lantern on the clean side with coal
# for the run, its sphere never gets bones while the clean side's do; one
# in the bones with one coal and a bone block beside it: the bones fall,
# the block goes, and once it is out the bones come back
log11="$t/srv11.log"
BUILDAT_SKELDAT_WORLD=lantern BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="1 -1 0" \
	BUILDAT_SKELDAT_FILL=half BUILDAT_SKELDAT_EXPAND=0.3 BUILDAT_SKELDAT_DAY=240 \
	BUILDAT_SKELDAT_LANTERNS="-12 0 9; 12 0 1 1" \
	start_server "$log11" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/demo_skeldat" \
	-D "$t/srv11" -C "$t/srv.cache" -l 3 || fail "the server ($log11)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$log11" "lantern at 12,[0-9]*,0 out: .* mean ([5-9]|1[0-5])\." 180 ||
	fail "the lantern in the bones: not out, or no bones back ($log11)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
grep -a "lantern at -12,[0-9]*,0 burning" "$log11" | grep -qv " 0 with bones" &&
	fail "bones in the clean side's lantern's sphere ($log11)"
f0=$(grep -a "columns flooded" "$log11" | head -1 | sed 's/.*(\([0-9.]*\) of.*/\1/')
f1=$(grep -a "columns flooded" "$log11" | tail -1 | sed 's/.*(\([0-9.]*\) of.*/\1/')
awk -v a="$f0" -v b="$f1" 'BEGIN { exit !(b > a) }' ||
	fail "the clean side did not flood: $f0 to $f1 ($log11)"
grep -aq "a bone block at 14,[0-9]*,0 goes" "$log11" ||
	fail "the bone block in the lantern's sphere stayed ($log11)"
# Its first report, 10 s or some 30 expansions in: the sphere clear, the
# full bones gone in 5 ([SKELDAT_LANTERN_RATE])
grep -a "lantern at 12,[0-9]*,0 burning" "$log11" | head -1 |
	grep -aq " 0 with bones, mean 0.00, 0 bone blocks" ||
	fail "the lantern's sphere not cleared at its first report: $(grep -a "lantern at 12,[0-9]*,0 burning" "$log11" | head -1 | sed 's/.*burning: //') ($log11)"
lantern="clean side flooded $f0 to $f1; $(grep -a "lantern at 12,[0-9]*,0 burning" "$log11" |
	tail -1 | sed 's/.*mean \([0-9.]*\).*/burning, mean \1/'); $(grep -a "lantern at 12,[0-9]*,0 out" "$log11" |
	tail -1 | sed 's/.*mean \([0-9.]*\).*/out, mean \1/')"
# 8. A burning lantern lures light skeletons as five marker skulls at the
# sunset, and one of them takes it
log12="$t/srv12.log"
BUILDAT_SKELDAT_WORLD=lure BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="2 -1 0" \
	BUILDAT_SKELDAT_DAY=60 BUILDAT_SKELDAT_TIME=0.6 BUILDAT_SKELDAT_SKELETONS=60 \
	BUILDAT_SKELDAT_LIGHT_STEP=0.02 BUILDAT_SKELDAT_LANTERNS="20 20 9" \
	start_server "$log12" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/demo_skeldat" \
	-D "$t/srv12" -C "$t/srv.cache" -l 3 || fail "the server ($log12)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$log12" "takes the lantern at 20," 90 ||
	fail "no skeleton took the lantern ($log12)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
grep -aq "the one with the most markers (5, at 0 0)" "$log12" ||
	fail "the lantern did not lure as five markers ($log12)"
# 9. With a player at noon: a skeleton beside a lantern takes it, burns
# and leaves it where it died, its bones dropped; the player digs a
# marker skull and places it again
log13="$t/srv13.log"
BUILDAT_SKELDAT_WORLD=take BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="2 -1 0" \
	BUILDAT_SKELDAT_TIME=0.5 BUILDAT_SKELDAT_SPAWN="0 0" \
	BUILDAT_SKELDAT_LANTERNS="4 0 2" BUILDAT_SKELDAT_TEST="skeleton 4 1; marker 0 1" \
	start_server "$log13" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/demo_skeldat" \
	-D "$t/srv13" -C "$t/srv.cache" -l 3 || fail "the server ($log13)"
CHECK_PIDS+=($SERVER_PID)
printf '%s\n' "$placed" "delay 1500" "look 0 -60" "delay 500" "mouse_down left" \
	"delay 600" "mouse_up left" "delay 800" "look 90 -60" "delay 500" \
	"mouse_down right" "delay 150" "mouse_up right" "delay 800" \
	"screenshot $t/take.png" "delay 14000" quit > "$t/take.cmds"
client take "$t/take.cmds"
wait $CLIENT || fail "the drive by the lantern ($t/take.log)"
wait_for_log "$log13" "the lantern left at" 30 ||
	fail "the lantern not left where the skeleton died ($log13)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
grep -aq "a skeleton (1) takes the lantern at 4," "$log13" ||
	fail "the skeleton beside the lantern did not take it ($log13)"
grep -aq "the skeleton (1) dies at .*, drops \[skeldat:bone" "$log13" ||
	fail "the dead skeleton dropped no bones ($log13)"
grep -aq "client1 digs skeldat:marker_skull" "$log13" &&
	grep -aq "client1 places skeldat:marker_skull" "$log13" ||
	fail "the marker skull not dug and placed ($log13)"
# The last three counts: before the dig, after it and after the place
grep -a "marker skulls in the footprint" "$log13" | sed 's/.*: \([0-9]*\) marker.*/\1/' |
	tail -3 | awk '{ c[NR] = $1 } END { exit !(NR == 3 && c[2] == c[1] - 1 && c[3] == c[1]) }' ||
	fail "the footprint's marker count: $(grep -a "marker skulls in the footprint" "$log13" | sed 's/.*: //' | tr '\n' ';') ($log13)"
# 10. The dig's crack ([SKELDAT_DIG_LOOK]): a voxel dug by hand, its
# crack's frames climbing to the last ones and gone with the dig; the
# next dig cut off by looking at the sky, its crack gone and no dig
log14="$t/srv14.log"
BUILDAT_SKELDAT_WORLD=dig BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="2 -1 0" \
	BUILDAT_SKELDAT_TIME=0.5 BUILDAT_SKELDAT_SPAWN="0 0" \
	start_server "$log14" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/demo_skeldat" \
	-D "$t/srv14" -C "$t/srv.cache" -l 3 || fail "the server ($log14)"
CHECK_PIDS+=($SERVER_PID)
printf '%s\n' "$placed" "delay 1500" "look 0 -60" "delay 500" "mouse_down left" \
	"delay 2500" "mouse_up left" "delay 500" "mouse_down left" "delay 200" \
	"look 0 60" "delay 500" "mouse_up left" "delay 500" quit > "$t/dig.cmds"
client dig "$t/dig.cmds"
wait $CLIENT || fail "the dig's drive ($t/dig.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
# "f N" a frame, "done" a dig sent, "gone": each crack's frames climb and
# it goes; one gone after a "done" a dig (the held button digs on into
# the next voxel), as many as the server's digs, and one cut off
crack=$(grep -a "dig: the crack\|dig: done" "$t/dig.log" | sed 's/.*frame \([0-9]*\) .*/f \1/; s/.*the crack gone/gone/; s/.*dig: done.*/done/' | tr '\n' ' ')
digs=$(grep -ac "client1 digs " "$log14")
echo "$crack" | awk -v digs="$digs" '{ n = split($0, w, " "); last = -1; d = 0
	for(i = 1; i <= n; i++){
		if(w[i] == "f"){ f = w[++i] + 0; if(f < last) bad = 1; last = f; continue }
		if(w[i] == "done"){ d = 1; continue }
		if(d) done++; else cut++
		last = -1; d = 0
	}
	exit !(!bad && last == -1 && done >= 1 && done == digs && cut >= 1) }' ||
	fail "the crack's frames: $crack; $digs digs ($t/dig.log, $log14)"
# 11. The sizes ([SKELDAT_WORLD_SIZES]) besides run 1's 1024: 512 x 128
# x 512, 256 x 64 x 256 and 128 x 64 x 128 made at seed 2, each surveyed
sizes=
for size in "512 4 -1 0" "256 2 0 0" "128 1 0 0"; do
	set -- $size
	w=$1
	shift
	BUILDAT_SKELDAT_WORLD=s$w BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="$*" \
		BUILDAT_SKELDAT_SURVEY=1 start_server "$t/size$w.log" "STATUS Listening" \
		300 auto "$here/Build/bin/buildat_server" -m "$here/apps/demo_skeldat" \
		-D "$t/size$w" -C "$t/srv.cache" -l 3 || fail "the server ($t/size$w.log)"
	CHECK_PIDS+=($SERVER_PID)
	wait_for_log "$t/size$w.log" "skeldat: the world is in" 300 ||
		fail "the $w world not in ($t/size$w.log)"
	rss=$(ps -o rss= -p $SERVER_PID)
	kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
	surveyed "$t/size$w.log" $(($2 * 64))
	sizes="$sizes $w: $(grep -a "the world is in" "$t/size$w.log" | sed 's/.*in, //'), $((rss / 1024)) MB;"
done
echo "sizes:$sizes"
# 12. Crafting more ([SKELDAT_CRAFT_MORE]): planks in the 2x2 grid's left
# column, 3 each; the result clicked four times: held 4, 8 and 12 sticks,
# the fourth refused (the grid empty); the 12 placed whole in main 10.
# The slots' centres for 800x500 (scale 2): the result 508,169, main 10
# 256,255 (ui.lua's layout; the logs below say if a click missed)
log15="$t/srv15.log"
BUILDAT_SKELDAT_WORLD=craft BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="2 -1 0" \
	BUILDAT_SKELDAT_TIME=0.5 BUILDAT_SKELDAT_SPAWN="0 0" \
	BUILDAT_SKELDAT_TEST="craft 1 skeldat:wood 3; craft 4 skeldat:wood 3" \
	start_server "$log15" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/demo_skeldat" \
	-D "$t/srv15" -C "$t/srv.cache" -l 3 || fail "the server ($log15)"
CHECK_PIDS+=($SERVER_PID)
printf '%s\n' "$placed" "delay 1500" "keypress E" \
	"wait_log 5000 inventory: inventory opened" "delay 500" "mouse_pos 508 169" \
	"delay 200" "mouse_click left" "delay 700" "mouse_click left" "delay 700" \
	"mouse_click left" "delay 700" "mouse_click left" "delay 700" \
	"mouse_pos 256 255" "delay 200" "mouse_click left" "delay 700" \
	"screenshot $t/craft.png" quit > "$t/craft.cmds"
client craft "$t/craft.cmds"
wait $CLIENT || fail "the crafting drive ($t/craft.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
[ "$(grep -a "client1 crafts" "$log15" | sed 's/.*the result //' | tr '\n' ' ')" = \
	"skeldat:stick 4 skeldat:stick 8 skeldat:stick 12 " ] &&
	[ $(grep -ac "inventory: craft more" "$t/craft.log") = 3 ] &&
	grep -aq "inventory: move 12 skeldat:stick craftresult:1 -> main:10" "$t/craft.log" ||
	fail "crafting more: $(grep -a "client1 crafts" "$log15" | sed 's/.*the result //' | tr '\n' ';') ($log15, $t/craft.log)"
echo "a night: $(echo $night)"
echo "lanterns: $lantern"
echo "skeletons: clean: $clean; flooded, after the player: $(echo "$last" | sed 's/.*skeldat: //'); the world with 2000 added: $light"
echo "run 1: $(grep -ac "pulled back" "$t/srv1.log") pull backs; run 2: $mobs mobs back"
echo "PASS: skeldat's rules, the movement check, the chat's report and mute, the admin's menu and map, the bones zone, the world's end, the skeletons' count, sleep and wake, a marker skull, a night's walk and bone blocks, lanterns lit, luring and taken, a marker dug and placed, the dig's crack, the world sizes, crafting more"
# vim: set noet ts=4 sw=4:
