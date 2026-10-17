#!/bin/bash
# tier: full
# cost: ~21 min (2026-10-17)
# covers: apps/skeldat/** extensions/luanti_client/res/touch.lua builtin/chat/** src/interface/voxel_path.h src/impl/voxel_path.cpp
# [SKELDAT]: skeldat's rules by their own tests (game.h, bones.h,
# move_check.h, and the engine pathfinder's with its time a search), then
# two runs of one world, 256 wide, at seed 2 (valleys: a dry spawn, no steps
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
# The third, a world of 2 x 2 x 2 sections made with full bones on its
# surface alone (BUILDAT_SKELDAT_FILL=surface): it ends with the deep
# stone bare, and started again it stays ended and says so to its player.
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
# clean). No run makes a 1024 world ([SKELDAT_CHECKS_512]): slow, and
# nothing in it a 512 does not show.
# The twelfth, crafting more: the held result clicked again crafts another
# set onto it.
# The thirteenth, invulnerability: the admin's toggle, kept over a rejoin.
# The fourteenth, items on the ground: a full inventory's dig, the drop
# key, a death's half; lying a game day, kept over a restart, picked up.
# The fifteenth, a respawn far from the spawn: the world there drawn.
# The sixteenth, a new world's skeletons there from the start.
# The seventeenth, the bodiless skeletons drawn out to the view.
# The eighteenth, the world's edge: a hillside, a wall nothing digs.
# The nineteenth, a skeleton's body following its light form.
#   apps/skeldat/check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
check_tmp skeldat; t=$CHECK_TMP
b="$here/Build/bin/buildat"
m="$here/apps/skeldat/main"

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
luajit -e "assert(dofile('$m/client_lua/hand.lua').self_test())" ||
	fail "hand.lua's self test (the bow's shape)"
luajit -e "dofile('$m/client_lua/player.lua')" ||
	fail "player.lua's self test (the walk's and the board's)"

[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display for the runs"
# The spawn at (0, 72) in a 256 world: clean ground, half way to the
# edge's bones (seed 2's, biased away from the origin: bones.h's
# danger()); run 1 walks -x on open grass, the admin of run 2 flies into
# the danger's patch round (100, 10), 118 degrees from +z to +x from
# where run 1 left it (-17, 72)
server() # <log> [args]: the world "w" at seed 2, noon, 256 x 64 x 256
{
	local log=$1
	shift
	BUILDAT_SKELDAT_WORLD=w BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_TIME=0.5 \
		BUILDAT_SKELDAT_SIZE="2 0 0" BUILDAT_SKELDAT_SPAWN="0 72" \
		start_server "$log" "STATUS Listening" 300 auto \
		"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
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
# The opening dialog holds a new player's keys: off but in its own run (28)
export BUILDAT_SKELDAT_INTRO=0 BUILDAT_SKELDAT_STARTER=0

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
text t
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
# skeleton to client1 until it walks off (7 and the box: bones.h's self test).
# The skeleton on the clean side, 20 off: it comes at the players, and in
# the zone the bones would shade it from the sun
BUILDAT_SKELDAT_SURVEY=1 BUILDAT_SKELDAT_TEST="skeleton 0 -20 marked; boar 6 0; bones 1 0 8" \
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
# Made at seed 2, the world's surface inside its 64 voxels of height:
# the highest voxel the generator made under the top (63)
top=$(grep -a "16 of 16 sections loaded" "$s" | sed 's/.*sections loaded, \([0-9.]*\) s, the highest voxel made at y \(-*[0-9]*\)/\1 \2/')
[ -n "$top" ] && [ "${top#* }" -lt 60 ] ||
	fail "the world not all in, or made over its top: $top ($s)"
echo "the world: 16 sections in ${top% *} s, the highest voxel at y ${top#* }, the server $((rss / 1024)) MB"
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
			if($i == "origin'\''s" && $(i + 1) + 0 != 0) bad = 1
			# Every trunk on grass ([SKELDAT_TREE_DEPTH])
			if($i == "grass" && ($(i + 1) + 0 != $NF + 0 || $NF + 0 == 0)) bad = 1
		}
		if(t[1] + 0 < y0 || t[2] + 0 > 62) bad = 1
		exit bad }' || fail "the world made: $line ($1)"
}
surveyed "$s" 0
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
# T and its letter in one frame, as a real press: the letter not in the
# line ([CHAT_OPEN_KEY_TYPED])
grep -aq "<client2> hello from client2" "$s" || fail "client2's line, or a t before it ($s)"
grep -aq "client1 reports client2" "$s" || fail "no report ($s, $t/a1.log)"
grep -a "skeldat: client2 looks like a" "$t/a1.log" | tail -2 | sed 's/.*looks like a //' |
	tr '\n' ' ' | grep -qx "skeleton player " ||
	fail "client2 did not look like a skeleton by the bones and then a player ($t/a1.log)"

# 2. The admin, invulnerable on its own page, as the zone's skeletons shoot
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
click Button "Invulnerable*"
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
look 118 0
keypress K
keydown Space
delay 1500
keyup Space
keypress H
keypress J
keydown W
delay 6600
keyup W
keypress J
keypress H
keypress K
delay 2000
look 118 -70
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
map="$t/srv/apps/skeldat/saves/w/map.png"
grep -aq "skeldat: the map written to $map" "$s" &&
	[ "$(python3 -I -c 'import struct,sys; d=open(sys.argv[1],"rb").read(24); print(*struct.unpack(">II", d[16:24]))' "$map")" = "256 256" ] ||
	fail "the admin's map not written, 256 x 256 ($s)"
grep -aq "client2's line refused: muted" "$s" || fail "the muted line went out ($s)"
grep -aE "skeldat: the first bone piles, [1-9]" "$t/srv1.log" | grep -q . ||
	fail "no bone piles generated ($t/srv1.log)"
grep -aq "pulled back" "$s" && fail "the admin was pulled back ($s)"
grep -aE "skeldat: fog for danger (0\.[5-9]|1)" "$t/a2.log" | grep -q . ||
	fail "no fog in the zone ($t/a2.log)"
grep -aq "skeldat: mood danger" "$t/a2.log" || fail "no danger music ($t/a2.log)"
# Spawned there, or one of the populated world's woken by the player
# ([SKELDAT_START_SKELETONS]: the zone's own count can leave no room)
grep -aE "a skeleton \([0-9]*\) spawns at .*, danger (0\.[5-9]|1)|skeletons, [1-9][0-9]* full" "$s" |
	grep -q . || fail "no skeleton spawned or woken in the zone ($s)"
grep -aq "client1 digs .*, dropping nothing" "$s" ||
	fail "no dig in the zone that drops nothing ($s)"
# 3. The end: a world of 2 x 2 x 2 sections made with bones on its
# surface alone (each voxel with air over it), the deep stone bare, ends;
# started again, it is still ended, and its player told
log3="$t/srv3.log"
BUILDAT_SKELDAT_WORLD=end BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="1 -1 0" BUILDAT_SKELDAT_FILL=surface \
	BUILDAT_SKELDAT_SPEED=2 \
	start_server "$log3" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
	-D "$t/srv3" -C "$t/srv.cache" -l 3 || fail "the server ($log3)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$log3" "every column's top has bones: the world ends after" 60 ||
	fail "the filled world did not end ($log3)"
grep -aq "the world ends after [0-9.]* days at 2x" "$log3" ||
	fail "the score does not name the speed ($log3)"
under=$(grep -a "the world ends after" "$log3" | sed 's/.*; \([0-9]*\) voxels under.*/\1/')
[ "${under:-0}" -gt 100000 ] || fail "the end waited on the deep stone: ${under:-none} bare under the tops ($log3)"
echo "the end: $under voxels bare under the tops"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
# The notice comes with the placing, before a wait_log after it would look
printf '%s\n' "$placed" "delay 1000" "screenshot $t/end.png" quit \
	> "$t/end.cmds"
log3="$t/srv4.log"
BUILDAT_SKELDAT_WORLD=end BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="1 -1 0" \
	start_server "$log3" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
	-D "$t/srv3" -C "$t/srv.cache" -l 3 || fail "the server ($log3)"
CHECK_PIDS+=($SERVER_PID)
client end "$t/end.cmds"
wait $CLIENT || fail "the ended world's drive ($t/end.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
grep -aq "skeldat: The bones cover the whole surface. The world ended after" "$t/end.log" ||
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
	"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
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
		"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
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
# grows at night toward its target and no further (SKELETONS=0: not
# populated at the start, sixteen's)
log5="$t/srv5.log"
BUILDAT_SKELDAT_WORLD=sim BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="2 -1 0" BUILDAT_SKELDAT_DAY=48 \
	BUILDAT_SKELDAT_SKELETONS=0 \
	BUILDAT_SKELDAT_TIME=0.8 start_server "$log5" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
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
	"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
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
	BUILDAT_SKELDAT_LANTERNS="-12 0 9; 12 0 1 1" BUILDAT_SKELDAT_SKELETONS=0 \
	start_server "$log11" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
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
	"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
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
	BUILDAT_SKELDAT_LANTERNS="4 0 2" BUILDAT_SKELDAT_TEST="skeleton 4 1 marked; marker 0 1" \
	start_server "$log13" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
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
	BUILDAT_SKELDAT_TIME=0.5 BUILDAT_SKELDAT_SPAWN="0 0" BUILDAT_SKELDAT_SKELETONS=0 \
	start_server "$log14" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
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
# 11. The sizes ([SKELDAT_WORLD_SIZES]): 512 x 128
# x 512, 256 x 64 x 256 and 128 x 64 x 128 made at seed 2, each surveyed
sizes=
for size in "512 4 -1 0" "256 2 0 0" "128 1 0 0"; do
	set -- $size
	w=$1
	shift
	BUILDAT_SKELDAT_WORLD=s$w BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="$*" \
		BUILDAT_SKELDAT_SURVEY=1 start_server "$t/size$w.log" "STATUS Listening" \
		300 auto "$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
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
# 256,255 (ui.lua's layout; the logs below say if a click missed). Then
# no fall damage ([SKELDAT_NO_FALL_DAMAGE]): fast flight up 1.5 s, the
# flight off (an admin's, the launcher's client), a landing at over the
# old tolerance (14) and no hp lost
log15="$t/srv15.log"
BUILDAT_SKELDAT_WORLD=craft BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="2 -1 0" \
	BUILDAT_SKELDAT_TIME=0.5 BUILDAT_SKELDAT_SPAWN="0 0" \
	BUILDAT_SKELDAT_TEST="craft 1 skeldat:wood 3; craft 4 skeldat:wood 3" \
	start_server "$log15" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
	-D "$t/srv15" -C "$t/srv.cache" -l 3 -u launcher=1 || fail "the server ($log15)"
CHECK_PIDS+=($SERVER_PID)
printf '%s\n' "$placed" "delay 1500" "keypress E" \
	"wait_log 5000 inventory: inventory opened" "delay 500" "mouse_pos 508 169" \
	"delay 200" "mouse_click left" "delay 700" "mouse_click left" "delay 700" \
	"mouse_click left" "delay 700" "mouse_click left" "delay 700" \
	"mouse_pos 256 255" "delay 200" "mouse_click left" "delay 700" \
	"screenshot $t/craft.png" "keypress E" "delay 500" "keypress K" \
	"keypress J" "keydown Space" "delay 1500" "keyup Space" "keypress J" \
	"keypress K" "delay 6000" quit > "$t/craft.cmds"
client craft "$t/craft.cmds"
wait $CLIENT || fail "the crafting drive ($t/craft.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
[ "$(grep -a "client1 crafts" "$log15" | sed 's/.*the result //' | tr '\n' ' ')" = \
	"skeldat:stick 4 skeldat:stick 8 skeldat:stick 12 " ] &&
	[ $(grep -ac "inventory: craft more" "$t/craft.log") = 3 ] &&
	grep -aq "inventory: move 12 skeldat:stick craftresult:1 -> main:10" "$t/craft.log" ||
	fail "crafting more: $(grep -a "client1 crafts" "$log15" | sed 's/.*the result //' | tr '\n' ';') ($log15, $t/craft.log)"
landed=$(grep -a "client1 lands at" "$log15" | sed 's/.*lands at \([0-9]*\).*/\1/' | sort -n | tail -1)
[ -n "$landed" ] && [ "$landed" -gt 14 ] && ! grep -aq "client1 .* hp left" "$log15" ||
	fail "a fall hurt, or none landed hard: ${landed:-none} ($log15)"
# 13. Invulnerable ([SKELDAT_INVULNERABLE]): the launcher's client, an
# admin, in water to over its head, turns itself invulnerable before its
# 10 s of breath are gone: it drowns unhurt; rejoined, still unhurt, turns
# it off, and the drowning hurts. Every damage goes through hurt(), the
# drowning stands for the arrow.
log16="$t/srv16.log"
toggle() # the admin page's toggle, from the game
{
	printf '%s\n' "keypress Escape" "wait_log 5000 pause: the menu shown" \
		"delay 500" 'click Button "Admin..."' \
		"wait_log 30000 pause: admin got players" "delay 500" \
		'click Button "client1"' "wait_log 30000 pause: admin got inv client1" \
		"delay 500" 'click Button "Invulnerable*"' \
		"wait_log 30000 pause: admin got inv client1" "delay 500" \
		"screenshot $t/invulnerable.png" 'click Button "Back"' "delay 500" 'click Button "Back"' \
		"wait_log 5000 pause: the menu shown" "delay 500" "keypress Escape" \
		"wait_log 5000 pause: the menu closed"
}
{ echo "$placed"; toggle; echo "delay 8000"; echo quit; } > "$t/inv1.cmds"
{ echo "$placed"; echo "delay 3000"; toggle; echo "delay 4000"; echo quit; } > "$t/inv2.cmds"
# A guest's name goes by its connection: the rejoin, client1 again, on
# the server started again. The water from the feet to over the head,
# placed from the top (each one's ground found under the air)
water="marker 0 0 skeldat:water_source 3; marker 0 0 skeldat:water_source 2; marker 0 0 skeldat:water_source 1"
for n in 1 2; do
	BUILDAT_SKELDAT_WORLD=inv BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="2 -1 0" \
		BUILDAT_SKELDAT_TIME=0.5 BUILDAT_SKELDAT_SPAWN="0 0" BUILDAT_SKELDAT_SKELETONS=0 \
		BUILDAT_SKELDAT_TEST="$([ $n = 1 ] && echo "$water")" \
		start_server "$t/srv16_$n.log" "STATUS Listening" 300 auto \
		"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
		-D "$t/srv16" -C "$t/srv.cache" -l 3 -u launcher=1 ||
		fail "the server ($t/srv16_$n.log)"
	CHECK_PIDS+=($SERVER_PID)
	client inv$n "$t/inv$n.cmds"
	wait $CLIENT || fail "the invulnerable drive ($t/inv$n.log)"
	kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
	cat "$t/srv16_$n.log" >> "$log16"
done
drowns=$(grep -a "client1 drowns" "$log16" | sed 's/.*drowns, //' | sort | uniq -c | tr -s ' \n' ' ')
grep -aq "client1 sets client1: invulnerable on" "$log16" &&
	grep -aq "client1 sets client1: invulnerable off" "$log16" &&
	grep -a "client1 drowns" "$log16" | sed 's/.*drowns, //; s/[0-9]* hp left/hurt/' |
		uniq | tr '\n' ';' | grep -qx "invulnerable;hurt;" ||
	fail "invulnerability: the drowning $drowns ($log16)"
# 14. Drops ([SKELDAT_DEATH_DROPS]), a game day 40 s: the launcher's
# client with 36 stacks of stone digs (the dirt to the ground, no room),
# drops one stone ahead (Q) and waits out the day (both gone); in water
# over its head, it drowns, half its stacks (18) dropped. The server
# started again: 18 on the ground; the respawn at the same column picks
# them all up.
log17="$t/srv17.log"
printf '%s\n' "$placed" "delay 2000" "look 0 -60" "mouse_down left" \
	"delay 2500" "mouse_up left" "delay 1000" "look 0 0" "keypress Q" \
	"delay 1500" "look 0 -40" "delay 500" "screenshot $t/drops.png" \
	"wait_log 60000 pause: the death screen shown" "delay 25000" quit \
	> "$t/drops1.cmds"
printf '%s\n' "wait_log 300000 pause: the death screen shown" "delay 1000" \
	'click Button "Respawn"' "delay 3000" quit > "$t/drops2.cmds"
for n in 1 2; do
	BUILDAT_SKELDAT_WORLD=drops BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="2 -1 0" \
		BUILDAT_SKELDAT_TIME=0.25 BUILDAT_SKELDAT_SPAWN="0 0" BUILDAT_SKELDAT_DAY=40 \
		BUILDAT_SKELDAT_TEST="$([ $n = 1 ] && echo "give skeldat:stone 99 36; $water")" \
		start_server "$t/srv17_$n.log" "STATUS Listening" 300 auto \
		"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
		-D "$t/srv17" -C "$t/srv.cache" -l 3 -u launcher=1 ||
		fail "the server ($t/srv17_$n.log)"
	CHECK_PIDS+=($SERVER_PID)
	client drops "$t/drops$n.cmds"
	wait $CLIENT || fail "the drops' drive $n ($t/drops.log)"
	kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
	cat "$t/srv17_$n.log" >> "$log17"
done
grep -aq "a drop of skeldat:dirt at" "$t/srv17_1.log" ||
	fail "the dig with a full inventory dropped nothing ($t/srv17_1.log)"
grep -aq "a drop of skeldat:stone at" "$t/srv17_1.log" &&
	grep -aq "the drop of skeldat:stone at .* is gone" "$t/srv17_1.log" ||
	fail "the drop key's stone not dropped, or not gone in a day ($t/srv17_1.log)"
grep -aq "client1 dies at .*, dropping 18 of 36 stacks" "$t/srv17_1.log" &&
	[ $(grep -acE "a drop of skeldat:stone 9[89] at" "$t/srv17_1.log") = 18 ] ||
	fail "the death's drops ($t/srv17_1.log)"
grep -aq "skeldat: 18 drops on the ground" "$t/srv17_2.log" &&
	[ $(grep -acE "client1 picks up 9[89] skeldat:stone" "$t/srv17_2.log") = 18 ] ||
	fail "the drops not kept over the restart, or not picked up ($t/srv17_2.log)"
# 15. A respawn 250 voxels from the death ([SKELDAT_RESPAWN_LOAD]), in
# 512 x 128 x 512: the player's range follows it, the chunks within 2 of
# the eye drawn within 30 s (a join's 2.5 s; before, not until the player
# walked into another section); the death by drowning there
log18="$t/srv18.log"
BUILDAT_SKELDAT_WORLD=respawn BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="4 -1 0" \
	BUILDAT_SKELDAT_TIME=0.4 BUILDAT_SKELDAT_SPAWN="0 0" \
	BUILDAT_SKELDAT_TEST="place 0 250; $water" \
	start_server "$log18" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
	-D "$t/srv18" -C "$t/srv.cache" -l 3 -u launcher=1 || fail "the server ($log18)"
CHECK_PIDS+=($SERVER_PID)
printf '%s\n' "wait_log 300000 skeldat: the chunks within 2 drawn" \
	"wait_log 60000 pause: the death screen shown" \
	"delay 1000" 'click Button "Respawn"' \
	"wait_log 30000 skeldat: the chunks within 2 drawn" quit > "$t/respawn.cmds"
client respawn "$t/respawn.cmds"
wait $CLIENT || fail "the respawn's world not drawn ($t/respawn.log, $log18)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
respawn=$(grep -a "skeldat: the chunks within 2 drawn [0-9]" "$t/respawn.log" | tail -1 | sed "s/.*drawn //")
# 16. A new world populated ([SKELDAT_START_SKELETONS]): 256 x 64 x 256
# in the morning, once it is in, at its target at once; started again,
# the same skeletons loaded and no second populating
for n in 1 2; do
	BUILDAT_SKELDAT_WORLD=pop BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="2 0 0" \
		BUILDAT_SKELDAT_TIME=0.3 start_server "$t/srv19_$n.log" "STATUS Listening" \
		300 auto "$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
		-D "$t/srv19" -C "$t/srv.cache" -l 3 || fail "the server ($t/srv19_$n.log)"
	CHECK_PIDS+=($SERVER_PID)
	wait_for_log "$t/srv19_$n.log" "skeldat: the world is in" 300 ||
		fail "the world not in ($t/srv19_$n.log)"
	kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
done
pop=$(grep -a "skeldat: populated: " "$t/srv19_1.log" | sed 's/.*populated: //')
echo "$pop" | awk '{ exit !($1 > 0 && $1 == $4 && $4 == $NF) }' ||
	fail "the new world not populated to its target: $pop ($t/srv19_1.log)"
grep -aq "skeldat: populated" "$t/srv19_2.log" &&
	fail "populated again ($t/srv19_2.log)"
grep -aq "the world \"pop\" starts, seed 2, 0 furnaces, $(echo "$pop" | awk "{ print \$4 }") mobs" \
	"$t/srv19_2.log" || fail "not the same skeletons loaded: $pop ($t/srv19_2.log)"
# 17. Far skeletons ([SKELDAT_FAR_SKELETONS]): nine light skeletons in a
# row 52 voxels ahead (past WAKE), their steps slowed to 30 s: the client
# draws as many as the server sends; started again at midnight (by day
# the woken burn) with the player placed 7 from them, they wake, have
# bodies, and the far list is empty
log20="$t/srv20.log"
T=; for x in -16 -12 -8 -4 0 4 8 12 16; do T="$T skeleton $x 52;"; done
for n in 1 2; do
	BUILDAT_SKELDAT_WORLD=far BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="2 -1 0" \
		BUILDAT_SKELDAT_TIME=$([ $n = 1 ] && echo 0.5 || echo 0) \
		BUILDAT_SKELDAT_SPAWN="0 0" BUILDAT_SKELDAT_FAR=1 BUILDAT_SKELDAT_LIGHT_STEP=30 \
		BUILDAT_SKELDAT_TEST="$([ $n = 1 ] && echo "$T" || echo "place 0 45")" \
		start_server "$t/srv20_$n.log" "STATUS Listening" 300 auto \
		"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
		-D "$t/srv20" -C "$t/srv.cache" -l 3 || fail "the server ($t/srv20_$n.log)"
	CHECK_PIDS+=($SERVER_PID)
	printf '%s\n' "$placed" "wait_log 30000 far skeletons drawn" "delay 3000" \
		quit > "$t/far.cmds"
	[ $n = 1 ] && sed -i 's/^delay 3000$/look 0 -8\ndelay 1500\nscreenshot '"${t//\//\\/}"'\/far.png/' "$t/far.cmds"
	client far$n "$t/far.cmds"
	wait $CLIENT || fail "the far skeletons' drive $n ($t/far$n.log)"
	kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
	cat "$t/srv20_$n.log" >> "$log20"
done
drawn=$(grep -a "skeldat: [0-9]* far skeletons drawn" "$t/far1.log" | tail -1 | sed 's/.*skeldat: \([0-9]*\) far.*/\1/')
sent=$(grep -a "far skeletons to client1" "$t/srv20_1.log" | tail -1 | sed 's/.*skeldat: \([0-9]*\) far.*/\1/')
[ "$drawn" = 9 ] && [ "$sent" = 9 ] ||
	fail "the far skeletons: $drawn drawn, $sent sent, not 9 ($t/far1.log, $t/srv20_1.log)"
# (the nine may then shoot the player dead, and asleep again be far)
grep -aq "skeldat: 0 far skeletons to client1" "$t/srv20_2.log" &&
	grep -aq "skeldat: a skeleton ([0-9]*) is here" "$t/far2.log" ||
	fail "the near skeletons not woken out of the far list ($t/srv20_2.log)"
far="9 drawn and sent; $(grep -a "skeldat: [0-9]* far skeletons drawn" "$t/far1.log" | tail -1 | sed 's/.*(//; s/)//')"
# 18. The edge ([SKELDAT_EDGE_RIDGE]) in 128 x 64 x 128 at dusk: made
# once (the hillside's blocks and the outermost column's wall); with a
# diamond pick, on the outermost column a dig straight down does nothing,
# two columns in it digs a bone block; the backdrop built; a frame from the crest outward
for n in 1 2; do
	BUILDAT_SKELDAT_WORLD=edge BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="1 0 0" \
		BUILDAT_SKELDAT_TIME=0.74 BUILDAT_SKELDAT_SPAWN="0 30" \
		BUILDAT_SKELDAT_TEST="place 0 $([ $n = 1 ] && echo 63 || echo 61); give skeldat:diamond_pick 1 1" \
		start_server "$t/srv21_$n.log" "STATUS Listening" 300 auto \
		"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
		-D "$t/srv21" -C "$t/srv.cache" -l 3 || fail "the server ($t/srv21_$n.log)"
	CHECK_PIDS+=($SERVER_PID)
	# The test's placing, not the join's
	printf '%s\n' "wait_log 300000 $([ $n = 1 ] && echo 63 || echo 61).0)" \
		"wait_log 30000 skeldat: the chunks within 2 drawn" \
		"delay 1000" "look 0 -10" "delay 1000" "screenshot $t/edge$n.png" \
		"look 0 -90" "delay 500" "mouse_down left" "delay 3500" "mouse_up left" \
		"delay 500" quit > "$t/edge.cmds"
	client edge$n "$t/edge.cmds"
	wait $CLIENT || fail "the edge's drive $n ($t/edge$n.log)"
	kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
done
grep -aE "skeldat: the edge made: [1-9][0-9]* bone blocks, [1-9][0-9]* wall" "$t/srv21_1.log" |
	grep -q . && ! grep -aq "skeldat: the edge made" "$t/srv21_2.log" ||
	fail "the edge not made once ($t/srv21_1.log, $t/srv21_2.log)"
grep -aq "client1 digs" "$t/srv21_1.log" &&
	fail "the outermost column's wall was dug ($t/srv21_1.log)"
grep -aq "client1 digs skeldat:bone_block" "$t/srv21_2.log" ||
	fail "the hillside's bone block not dug ($t/srv21_2.log)"
# The backdrop's rim under the lowest edge column's top, so no sky
# between ([SKELDAT_BACKDROP_LOW])
rim=$(grep -a "skeldat: the backdrop beyond the edge at 64" "$t/edge1.log" | head -1)
echo "$rim" | sed 's/.*its rim at \([-0-9.]*\), the lowest edge column \([-0-9]*\).*/\1 \2/' |
	awk '{ exit !($1 < $2) }' ||
	fail "no backdrop, or its rim over the lowest edge column: ${rim#*: } ($t/edge1.log)"
# 19. The body follows the light form ([SKELDAT_LIGHT_PRIMARY]): a
# skeleton 12 voxels from a player at midnight; its light form closes to
# a bow's distance and its body walks after it: awake, shooting, and no
# body put back on its light form over two reports
log22="$t/srv22.log"
BUILDAT_SKELDAT_WORLD=body BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="2 -1 0" \
	BUILDAT_SKELDAT_TIME=0 BUILDAT_SKELDAT_SPAWN="0 0" BUILDAT_SKELDAT_DAY=2400 \
	BUILDAT_SKELDAT_TEST="skeleton 0 12" \
	start_server "$log22" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
	-D "$t/srv22" -C "$t/srv.cache" -l 3 || fail "the server ($log22)"
CHECK_PIDS+=($SERVER_PID)
printf '%s\n' "$placed" "delay 21000" quit > "$t/body.cmds"
client body "$t/body.cmds"
wait $CLIENT || fail "the body's drive ($t/body.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
body=$(grep -a "skeletons, [0-9]* full" "$log22" | grep -v "0 full" | sed 's/.*full, //' | tr '\n' ';')
grep -aq "a skeleton shoots at client1" "$log22" &&
	[ $(grep -a "skeletons, [0-9]* full" "$log22" | grep -vc "0 full") -ge 1 ] &&
	! grep -a "skeletons, [0-9]* full" "$log22" | grep -v "0 full" | grep -qv " 0 bodies put back" ||
	fail "the body did not follow its light form: $body ($log22)"
# 20. No sun in the bones ([SKELDAT_SUN_IN_BONES]): at noon on clean
# ground two skeletons: one 6 from a player, at a bow's distance where
# it stands, beside a bone block, which does not burn; one 20 off with no
# bones round it, which does as it walks in. Both marked, as the marker
# skull a skeleton puts in the next column on seeing a player would keep
# the sun off it too
log23="$t/srv23.log"
BUILDAT_SKELDAT_WORLD=sun BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="2 -1 0" \
	BUILDAT_SKELDAT_TIME=0.5 BUILDAT_SKELDAT_SPAWN="0 0" BUILDAT_SKELDAT_DAY=2400 \
	BUILDAT_SKELDAT_TEST="skeleton 0 6 marked; marker 1 6 skeldat:bone_block; skeleton 0 -20 marked" \
	start_server "$log23" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
	-D "$t/srv23" -C "$t/srv.cache" -l 3 || fail "the server ($log23)"
CHECK_PIDS+=($SERVER_PID)
printf '%s\n' "$placed" "delay 10000" quit > "$t/sun.cmds"
client sun "$t/sun.cmds"
wait $CLIENT || fail "the sun's drive ($t/sun.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
safe=$(grep -a "test: a skeleton (" "$log23" | sed -n 1p | sed 's/.*(\([0-9]*\)).*/\1/')
open=$(grep -a "test: a skeleton (" "$log23" | sed -n 2p | sed 's/.*(\([0-9]*\)).*/\1/')
grep -aq "test: skeldat:bone_block at" "$log23" && [ -n "$safe" ] &&
	! grep -aq "the skeleton ($safe) burns" "$log23" &&
	grep -aq "the skeleton ($open) burns" "$log23" ||
	fail "the bone block did not keep the sun off ($log23)"
# 21. Water ([SKELDAT_SKELETON_WATER]): at midnight a skeleton put in a
# pool dies at once, its drops on the ground; one 12 off across a pond's
# row 10 off, wanting a bow's distance (9), is held by the water, not in it
log24="$t/srv24.log"
pond=$(for x in -4 -3 -2 -1 0 1 2 3 4; do printf 'marker %d 10 skeldat:water_source; ' $x; done)
BUILDAT_SKELDAT_WORLD=water BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="2 -1 0" \
	BUILDAT_SKELDAT_TIME=0 BUILDAT_SKELDAT_SPAWN="0 0" BUILDAT_SKELDAT_DAY=2400 \
	BUILDAT_SKELDAT_TEST="${pond}marker 0 -6 skeldat:water_source; skeleton 0 12 marked; skeleton 0 -6 marked" \
	start_server "$log24" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
	-D "$t/srv24" -C "$t/srv.cache" -l 3 || fail "the server ($log24)"
CHECK_PIDS+=($SERVER_PID)
printf '%s\n' "$placed" "delay 20000" quit > "$t/water.cmds"
client water "$t/water.cmds"
wait $CLIENT || fail "the water's drive ($t/water.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
across=$(grep -a "test: a skeleton (" "$log24" | sed -n 1p | sed 's/.*(\([0-9]*\)).*/\1/')
pool=$(grep -a "test: a skeleton (" "$log24" | sed -n 2p | sed 's/.*(\([0-9]*\)).*/\1/')
[ -n "$pool" ] && grep -aq "the skeleton ($pool) is in water" "$log24" &&
	grep -aA1 "the skeleton ($pool) is in water" "$log24" | grep -aq "a drop of" ||
	fail "the skeleton in the pool did not die ($log24)"
grep -aq "a skeleton shoots at client1" "$log24" &&
	! grep -aq "the skeleton ($across) is in water" "$log24" ||
	fail "the skeleton went into the pond ($log24)"
# 22. Ways built of bone ([SKELDAT_BONE_BRIDGES]), at night, the player
# taken off past waking range so the light forms walk: two skeletons whose
# night's block is across a pond 6 wide build one bridge of 6 blocks and
# then walk across; one lured to a lantern on a platform 5 up builds a
# stair and takes it; one whose block is behind a wall it can walk round
# builds nothing
log25="$t/srv25.log"
ways=$(for z in $(seq -7 7); do for x in 3 4 5 6 7 8; do
	printf 'marker %d %d skeldat:water_source -1; ' $x $z; done; done
for z in -1 0 1; do for x in -9 -8 -7; do printf 'marker %d %d skeldat:stone 4; ' $x $z; done; done
for x in -3 -2 -1 0 1 2 3; do for y in 0 1 2; do printf 'marker %d -14 skeldat:stone %d; ' $x $y; done; done)
BUILDAT_SKELDAT_WORLD=ways BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="2 -1 0" \
	BUILDAT_SKELDAT_TIME=0.8 BUILDAT_SKELDAT_SPAWN="0 0" BUILDAT_SKELDAT_DAY=600 \
	BUILDAT_SKELDAT_LIGHT_STEP=0.2 \
	BUILDAT_SKELDAT_TEST="${ways}lantern -8 0 3; skeleton 1 0 marked seed 11 0 4; skeleton -4 1 marked seed 11 0 4; skeleton -3 0 marked lure; skeleton 0 -11 marked seed 0 -17 1; place 100 0" \
	start_server "$log25" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
	-D "$t/srv25" -C "$t/srv.cache" -l 3 || fail "the server ($log25)"
CHECK_PIDS+=($SERVER_PID)
printf '%s\n' "$placed" "delay 60000" quit > "$t/ways.cmds"
client ways "$t/ways.cmds"
wait $CLIENT || fail "the ways' drive ($t/ways.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
keys=$(grep -a "test: a skeleton (" "$log25" | sed 's/.*(\([0-9]*\)).*/\1/' | tr '\n' ' ')
set -- $keys
bridge=$(grep -a "skeleton ($1) builds\|skeleton ($2) builds" "$log25" | sed 's/.* at //' | sort -u)
echo "ways: the bridge $(echo $bridge)"
[ $(echo "$bridge" | grep -c .) = 6 ] && [ $(echo "$bridge" | cut -d, -f3 | sort -u | wc -l) = 1 ] &&
	grep -aq "skeleton ($1) places its night's block at 11,\|skeleton ($2) places its night's block at 11," "$log25" ||
	fail "no bridge of 6 in a line, crossed ($log25)"
grep -aq "skeleton ($3) builds" "$log25" && grep -aq "a skeleton ($3) takes the lantern" "$log25" ||
	fail "no stair to the lantern ($log25)"
grep -aq "skeleton ($4) finds a way to .*, 0 bone blocks" "$log25" &&
	! grep -aq "skeleton ($4) builds" "$log25" ||
	fail "a block built where a walking way is ($log25)"
# 23. The bow ([SKELDAT_BOW]): the launcher's client, invulnerable, a
# bow and 6 arrows, a skeleton 6 ahead at midnight. A full draw (1.2 s)
# shoots at the bow's speed, a half (0.5 s) at half, a tap nothing; two
# more full ones and the skeleton is dead. Held looking down the bow digs
# nothing: the arrow shot into the ground at its feet is picked up. Five
# presses far off: two or more shots, then with none left (the
# skeleton's misses picked up too) a press draws nothing. Left 60 s, a far
# one is a stuck-arrow voxel; the server started again, the player put on
# it picks it up. Frames of the hand at rest, half and full drawn.
log26="$t/srv26.log"
shot()
{
	printf '%s\n' "mouse_down left" "delay $1" ${2:+"screenshot $2"} \
		"mouse_up left" "delay 1500"
}
{ echo "$placed"; toggle; echo "look 0 0"; echo "delay 1000"
	echo "screenshot $t/bow_rest.png"
	shot 1200 "$t/bow_full.png"; shot 450 "$t/bow_half.png"; shot 50
	shot 1200; shot 1200
	echo "look 0 -60"; shot 2500
	echo "look 90 0"; shot 1200; shot 1200; shot 1200; shot 1200; shot 1200
	echo "delay 66000"; echo quit; } > "$t/bow1.cmds"
printf '%s\n' "$placed" "delay 3000" quit > "$t/bow2.cmds"
for n in 1 2; do
	BUILDAT_SKELDAT_WORLD=bow BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="2 -1 0" \
		BUILDAT_SKELDAT_TIME=0 BUILDAT_SKELDAT_SPAWN="0 0" BUILDAT_SKELDAT_DAY=2400 \
		BUILDAT_SKELDAT_TEST="$([ $n = 1 ] && echo "give skeldat:bow 1 1; give skeldat:arrow 6 1; skeleton 0 6 marked" || echo "place ${kept:-0 0}")" \
		start_server "$t/srv26_$n.log" "STATUS Listening" 300 auto \
		"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
		-D "$t/srv26" -C "$t/srv.cache" -l 3 -u launcher=1 ||
		fail "the server ($t/srv26_$n.log)"
	CHECK_PIDS+=($SERVER_PID)
	client bow$n "$t/bow$n.cmds"
	wait $CLIENT || fail "the bow's drive $n ($t/bow$n.log)"
	kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
	cat "$t/srv26_$n.log" >> "$log26"
	[ $n = 1 ] && kept=$(grep -a "a stuck arrow kept at" "$t/srv26_1.log" | head -1 |
		sed 's/.*kept at \([-0-9]*\),[-0-9]*,\([-0-9]*\),.*/\1 \2/')
done
s1="$t/srv26_1.log"
speeds=$(grep -a "client1 shoots an arrow at" "$s1" | sed 's/.* at \([0-9.]*\) .*/\1/' | tr '\n' ' ')
echo "the bow: speeds $speeds"
set -- $speeds
draws=$(grep -ac "client1 draws the bow" "$s1")
[ $# -ge 7 ] && [ $draws = $(($# + 1)) ] && [ $draws -lt 11 ] &&
	awk -v f="$1" -v h="$2" 'BEGIN { exit !(f >= 29 && h >= 12 && h <= 18) }' &&
	[ $(grep -ac "client1 lets the bow go undrawn" "$s1") = 1 ] ||
	fail "the bow's draws: $speeds ($s1)"
grep -aq "the skeleton (1) dies" "$s1" && grep -aq "an arrow from client1 hits the skeleton (1)" "$s1" ||
	fail "no arrow killed the skeleton ($s1)"
! grep -aq "client1 digs" "$s1" || fail "the bow dug ($s1)"
grep -aq "client1 picks up an arrow" "$s1" || fail "the arrow at the feet not picked up ($s1)"
[ -n "$kept" ] && grep -aq "client1 picks up an arrow at ${kept% *}.0,[-0-9.]*,${kept#* }.0" "$t/srv26_2.log" ||
	fail "no stuck-arrow voxel, or not picked up after the restart: ${kept:-none} ($t/srv26_2.log)"
# 24. The board ([SKELDAT_SKATEBOARD]) on a course of stone (TEST
# course, main.cpp): walked onto its slope of 12, client1 is on the board
# by itself, gets the drop's speed and keeps it on the flat, flies off a
# ramp of 2 and lands, lying flat (Shift held from the boarding on) goes
# through a wall's hole one high, and a wall of 3 stops it; walked off the side down
# 8 onto a flat, S stops it within the brake's reach. The camera looks
# back over the first ride, which goes on straight ([SKELDAT_BOARD_KEYS]). The server pulls
# back none of it, and pulls back a board the drive forces to 35 on the
# flat. client2 sees client1 on a board and lying flat.
log27="$t/srv27.log"
cat > "$t/board1.cmds" <<EOF
$placed
wait_log 60000 skeldat: placed at (-40.0,
delay 1500
look 90 0
delay 1000
keydown W
wait_log 5000 skeldat: on the board
keyup W
look 270 0
keydown Left Shift
wait_log 20000 skeldat: walking
keyup Left Shift
delay 1000
look 0 0
delay 500
keydown W
wait_log 5000 skeldat: on the board
keyup W
delay 1600
keydown S
wait_log 10000 skeldat: walking
keyup S
delay 1500
event skeldat_board 35
delay 3000
quit
EOF
printf '%s\n' "$placed" "wait_log 60000 skeldat: client1 lies flat" \
	"delay 500" quit > "$t/board2.cmds"
BUILDAT_SKELDAT_WORLD=board BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="2 -1 2" \
	BUILDAT_SKELDAT_TIME=0.5 BUILDAT_SKELDAT_SPAWN="0 0" BUILDAT_SKELDAT_SKELETONS=0 \
	BUILDAT_SKELDAT_TEST="course -40 -20" \
	start_server "$log27" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
	-D "$t/srv27" -C "$t/srv.cache" -l 3 || fail "the server ($log27)"
CHECK_PIDS+=($SERVER_PID)
client board1 "$t/board1.cmds"; a=$CLIENT
wait_for_log "$log27" "skeldat: test: a course" 330 || fail "no course ($log27)"
client board2 "$t/board2.cmds"; bpid=$CLIENT
wait $a || fail "the board's drive ($t/board1.log)"
wait $bpid || fail "client2's drive ($t/board2.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
c1="$t/board1.log"
top=$(awk '/skeldat: walking at/ { exit } /skeldat: board speed/ { l = $0 } END { print l }' "$c1" |
	sed 's/.*top \([0-9.]*\).*/\1/')
flew=$(grep -a "skeldat: the board flew" "$c1" | head -1 | sed 's/.*flew \([0-9.]*\) s.*/\1/')
wall=$(grep -a "skeldat: walking at" "$c1" | head -1 | sed 's/.*at (\([-0-9.]*\),.*/\1/')
brake=$(grep -a "skeldat: braking at" "$c1" | head -1 |
	sed 's/.*braking at \([0-9.]*\) at .*, \([-0-9.]*\))$/\1 \2/')
stop=$(grep -a "skeldat: walking at" "$c1" | sed -n 2p | sed 's/.*, \([-0-9.]*\))$/\1/')
echo "the board: top speed ${top:-none} (the drop's 22.1), flew ${flew:-no} s, stopped by the wall at x ${wall:-none}, braked from ${brake% *} in $(awk -v b="${brake#* }" -v s="${stop:-0}" 'BEGIN { printf "%.1f", s - b }')"
awk -v top="${top:-0}" -v flew="${flew:-0}" -v wall="${wall:-0}" -v v="${brake% *}" \
	-v b="${brake#* }" -v s="${stop:-0}" 'BEGIN { exit !(top >= 20 && top <= 22.5 &&
		flew >= 0.5 && wall > 20 && wall < 29.5 && v > 10 && s - b >= 0 &&
		s - b <= v * v / 48 + 1.5) }' ||
	fail "the board's run: top $top, flew $flew, the wall at $wall, braked from $brake to $stop ($c1)"
cheat=$(grep -a "the board forced to" "$c1" | head -1 | awk '{print $3}')
first_pull=$(grep -a "pulled back" "$log27" | head -1 | awk '{print $3}')
[ -n "$cheat" ] && [ -n "$first_pull" ] && [[ ! "$first_pull" < "$cheat" ]] &&
	grep -aq "pulled back .*: too far (on the board)" "$log27" ||
	fail "an honest board pulled back, or the forced one not: first at $first_pull, the cheat at $cheat ($log27)"
# [SKELDAT_BOARD_SOUND] The roll's self test, and its stream 3 to 4 chunks
# (30 to 40 ms, [SKELDAT_BOARD_SOUND_LAG]) ahead after each feed over the
# ride, with no underrun said
grep -aq "skeldat: board sound: self test passed" "$c1" ||
	fail "the board sound's self test ($c1)"
roll=$(grep -a "skeldat: board speed" "$c1" |
	sed 's/.*the roll \([0-9]*\)\.\.\([0-9]*\) ms.*/\1 \2/' |
	awk 'NR == 1 { lo = $1; hi = $2 } $1 < lo { lo = $1 } $2 > hi { hi = $2 }
		END { print NR, lo, hi }')
read -r roll_n roll_lo roll_hi <<< "$roll"
[ "${roll_n:-0}" -ge 10 ] && [ "${roll_lo:-0}" -ge 30 ] && [ "${roll_hi:-999}" -le 41 ] &&
	! grep -aq "board sound: .* underruns" "$c1" ||
	fail "the roll's stream: $roll_n reports, $roll_lo to $roll_hi ms ahead ($c1)"
echo "the roll: $roll_lo to $roll_hi ms ahead over $roll_n reports"
grep -aq "skeldat: client1 rides a board" "$t/board2.log" ||
	fail "client2 did not see client1 on a board ($t/board2.log)"
# 25. Free-running ([SERVER_FREE_RUN]): a 128 world, no player, at the
# real constants with --free-run. A game day (1200 s) after the world is
# in passes in well under its time, and its expansions are the day's (4
# sections, one each 150 s: 32). The same world in real time for 60 s
# takes about 60 s of game time (a bones line every 10). A client is
# turned away, and with --lan-announce the server does not start.
free()
{
	BUILDAT_SKELDAT_WORLD=free BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="1 0 0" \
		start_server "$t/srv28_$1.log" "STATUS Listening" 300 auto \
		"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
		-D "$t/srv28" -C "$t/srv.cache" -l 3 "${@:2}" || fail "the server ($t/srv28_$1.log)"
	CHECK_PIDS+=($SERVER_PID)
}
free fast --free-run
s="$t/srv28_fast.log"
printf '%s\n' "wait_log 20000 Disconnected from server" quit > "$t/free.cmds"
timeout 40 "$b" -C "$t/c_free" -D "$t/u_free" -w 800x500 -l 3 -o sound_mute=1 \
	-s "127.0.0.1:$SERVER_PORT" -c @"$t/free.cmds" > "$t/free.log" 2>&1
grep -aq "Disconnected from server: This server is free-running" "$t/free.log" ||
	fail "a client was not turned away by the free-running server ($t/free.log)"
# The day after the world is in: 120 bones lines (each 10 s), timed
wait_for_log "$s" "skeldat: the world is in" 120 || fail "the world not in ($s)"
for _ in $(seq 120); do
	[ $(awk '/the world is in/ { on = 1 } on && /skeldat: bones:/ { n++ } END { print n + 0 }' "$s") -gt 120 ] && break
	sleep 1
done
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
day=$(awk '/the world is in/ { on = 1 } on && /skeldat: bones:/ { n++; if(n == 1 || n == 121) print $3, $9 }' "$s")
set -- $day
[ $# = 4 ] || fail "no day free-running in 120 s: $day ($s)"
secs=$(echo "$1 $3" | awk '{ split($1, a, ":"); split($2, b, ":"); print (b[1] - a[1]) * 3600 + (b[2] - a[2]) * 60 + b[3] - a[3] }')
echo "free-running: a day in $secs s, $(($4 - $2)) expansions; $(grep -a "free-run: " "$s" | tail -1 | sed 's/.*free-run: //')"
awk -v s="$secs" -v e=$(($4 - $2)) 'BEGIN { exit !(s < 120 && e >= 30 && e <= 34) }' ||
	fail "the free-running day: $secs s, $(($4 - $2)) expansions ($s)"
free real
sleep 60
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
lines=$(awk '/the world is in/ { on = 1 } on && /skeldat: bones:/ { n++ } END { print n + 0 }' "$t/srv28_real.log")
[ $lines -ge 3 ] && [ $lines -le 7 ] || fail "in real time, $lines bones lines in a minute ($t/srv28_real.log)"
! timeout 60 "$here/Build/bin/buildat_server" -m "$here/apps/skeldat" -D "$t/srv28" \
	-C "$t/srv.cache" -l 3 --free-run --lan-announce check > "$t/srv28_lan.log" 2>&1 &&
	grep -aq "free-run is for a headless check" "$t/srv28_lan.log" ||
	fail "--free-run with --lan-announce started ($t/srv28_lan.log)"
# 26. A deep hole ([SKELDAT_SURFACE_END]): at midnight, a shaft 10 deep
# dug 3 from the launcher's client (invulnerable) and a skeleton 1 off
# its edge. Within a minute the skeleton drops a skull into it, which
# falls to the shaft's bottom and is a skull voxel there.
log29="$t/srv29.log"
shaft=$(for d in $(seq 10 -1 1); do printf 'marker 3 0 air -%d; ' $d; done)
{ echo "$placed"; toggle; echo "delay 90000"; echo quit; } > "$t/hole.cmds"
BUILDAT_SKELDAT_WORLD=hole BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="2 -1 0" \
	BUILDAT_SKELDAT_TIME=0 BUILDAT_SKELDAT_SPAWN="0 0" BUILDAT_SKELDAT_SKELETONS=0 \
	BUILDAT_SKELDAT_TEST="${shaft}skeleton 1 0 marked" \
	start_server "$log29" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
	-D "$t/srv29" -C "$t/srv.cache" -l 3 -u launcher=1 || fail "the server ($log29)"
CHECK_PIDS+=($SERVER_PID)
client hole "$t/hole.cmds"
wait_for_log "$log29" "a dropped skull is a voxel" 300
kill $CLIENT $SERVER_PID 2>/dev/null; wait $CLIENT $SERVER_PID 2>/dev/null
bottom=$(grep -a "test: air at" "$log29" | head -1 | sed 's/.*air at \([-0-9]*\),\([-0-9]*\),\([-0-9]*\).*/\1 \2 \3/')
set -- $bottom
grep -aq "a skeleton drops a skull into the hole at $1," "$log29" &&
	grep -aq "a dropped skull is a voxel at $1,$2,$3" "$log29" ||
	fail "no skull dropped down the shaft at ${bottom:-none} to its bottom ($log29)"
# 27. The bones' speed ([SKELDAT_BONE_SPEED]). A 128 world made at 5x,
# free-running a game day after it is in: 1x's expansions (32), the
# rule run 5 times in each. Then in real time at 5x: the launcher's
# client (an admin) sends "speed 1", which is in the audit log and in
# its chat. Started again with no admin, the world is at 1x, a player's
# "speed 10" does nothing, and in 70 s nothing says it falls behind. A
# 10x world starved (0.3 expansions a second of 4 due) says in the chat
# that it can't keep up.
speed_server() # <run> <world> [args]: a 128 world
{
	local n=$1 world=$2
	shift 2
	BUILDAT_SKELDAT_WORLD=$world BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="1 0 0" \
		start_server "$t/srv30_$n.log" "STATUS Listening" 300 auto \
		"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
		-D "$t/srv30" -C "$t/srv.cache" -l 3 "$@" || fail "the server ($t/srv30_$n.log)"
	CHECK_PIDS+=($SERVER_PID)
}
BUILDAT_SKELDAT_SPEED=5 speed_server free speed5 --free-run
s="$t/srv30_free.log"
wait_for_log "$s" "skeldat: the world is in" 120 || fail "the world not in ($s)"
for _ in $(seq 120); do
	[ $(awk '/the world is in/ { on = 1 } on && /skeldat: bones:/ { n++ } END { print n + 0 }' "$s") -gt 120 ] && break
	sleep 1
done
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
day=$(awk '/the world is in/ { on = 1 } on && /skeldat: bones:/ { n++; if(n == 1 || n == 121) print $9, $21 }' "$s")
set -- $day
[ $# = 4 ] && grep -aq "the bones at 5x" "$s" && [ $(($4 - $2)) = $((5 * ($3 - $1))) ] &&
	[ $(($3 - $1)) -ge 30 ] && [ $(($3 - $1)) -le 34 ] ||
	fail "a day at 5x: expansions and rule runs $day ($s)"
echo "the bones at 5x: a day's $(($3 - $1)) expansions, $(($4 - $2)) rule runs"
printf '%s\n' "$placed" "delay 2000" "event skeldat_admin speed 1" \
	"wait_log 10000 chat: *** The bones now grow at 1x" "delay 1000" quit > "$t/speed1.cmds"
BUILDAT_SKELDAT_SPEED=5 speed_server 1 speedw -u launcher=1
client speed1 "$t/speed1.cmds"
wait $CLIENT || fail "the admin's speed drive ($t/speed1.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
grep -aq "the bones at 5x" "$t/srv30_1.log" && grep -aq "client1 sets : bone speed 1x" "$t/srv30_1.log" ||
	fail "the admin's speed 1 not set and audited ($t/srv30_1.log)"
printf '%s\n' "$placed" "delay 2000" "event skeldat_admin speed 10" "delay 70000" quit > "$t/speed2.cmds"
speed_server 2 speedw
client speed2 "$t/speed2.cmds"
wait $CLIENT || fail "the player's speed drive ($t/speed2.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
grep -aq "the bones at 1x (the lowest 1x)" "$t/srv30_2.log" && ! grep -aq "bone speed 10x" "$t/srv30_2.log" &&
	! grep -aq "can't keep up" "$t/srv30_2.log" ||
	fail "the speed not kept, a player's speed taken, or a 1x world behind ($t/srv30_2.log)"
printf '%s\n' "$placed" "wait_log 90000 chat: *** The server can't keep up with 10x bones" \
	"delay 500" quit > "$t/speed3.cmds"
BUILDAT_SKELDAT_SPEED=10 BUILDAT_SKELDAT_EXPAND=1 BUILDAT_SKELDAT_BUDGET=0.01 speed_server 3 behind
client speed3 "$t/speed3.cmds"
wait $CLIENT || fail "no can't-keep-up line in the chat ($t/speed3.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
echo "behind: $(grep -a "can't keep up" "$t/srv30_3.log" | head -1 | sed 's/.*skeldat: //')"
# 28. The opening dialog ([SKELDAT_INTRO]): a new player in a new 128
# world at 1x gets it, with the days measured for a 128 world (28,
# less the minutes gone); joining again it does not come, and
# the pause menu's How to play... shows it. The world's starter items
# ([SKELDAT_STARTER_ITEMS]): 4 sticks and 4 bones resting within 6 of
# the spawn, and none dropped again when the world is loaded
intro_server()
{
	BUILDAT_SKELDAT_INTRO=1 BUILDAT_SKELDAT_STARTER=1 BUILDAT_SKELDAT_WORLD=intro BUILDAT_SKELDAT_SEED=2 \
		BUILDAT_SKELDAT_SIZE="1 0 0" \
		start_server "$t/srv31_$1.log" "STATUS Listening" 300 auto \
		"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
		-D "$t/srv31" -C "$t/srv.cache" -l 3 || fail "the server ($t/srv31_$1.log)"
	CHECK_PIDS+=($SERVER_PID)
}
printf '%s\n' "$placed" "wait_log 30000 pause: how to play shown" "delay 500" \
	"screenshot $t/intro.png" "keypress Escape" "wait_log 5000 pause: the menu closed" \
	"delay 500" quit > "$t/intro1.cmds"
intro_server 1
client intro1 "$t/intro1.cmds"
wait $CLIENT || fail "no opening dialog for a new player ($t/intro1.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
days=$(grep -a "skeldat : pause: how to play shown" "$t/intro1.log" | head -1 | sed 's/.*shown, \([0-9]*\) days/\1/')
[ "$days" = 27 ] || [ "$days" = 28 ] || fail "the days at a 128 world's start: $days ($t/intro1.log)"
starter=$(grep -a "skeldat: spawn at\|skeldat: a drop of skeldat:\(stick\|bone\) at\|skeldat: the drop of skeldat:\(stick\|bone\) rests at" \
	"$t/srv31_1.log" | sed 's/.*skeldat: //' | awk '
	/^spawn at/ { sx = $3; sz = $5 }
	/^a drop/ { n++; split($6, p, ","); x[n] = p[1]; z[n] = p[3] }
	/rests at/ { r++ }
	END { for (i = 1; i <= n; i++) { d = x[i] - sx; e = z[i] - sz
			if (d < 0) d = -d; if (e < 0) e = -e
			if (d > far) far = d; if (e > far) far = e }
		print n + 0, r + 0, far + 0 }')
read -r s_n s_rest s_far <<< "$starter"
[ "$s_n" = 8 ] && [ "$s_rest" = 8 ] && awk -v f="$s_far" 'BEGIN { exit !(f <= 6) }' ||
	fail "the starter items: $s_n dropped, $s_rest resting, the farthest $s_far off ($t/srv31_1.log)"
printf '%s\n' "$placed" "delay 5000" "keypress Escape" "wait_log 5000 pause: the menu shown" \
	"delay 500" 'click Button "How to play..."' "wait_log 5000 pause: how to play shown" \
	"delay 500" quit > "$t/intro2.cmds"
intro_server 2
client intro2 "$t/intro2.cmds"
wait $CLIENT || fail "no How to play from the pause menu ($t/intro2.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
[ $(grep -ac "skeldat : pause: how to play shown" "$t/intro2.log") = 1 ] ||
	fail "the dialog came again on the second join ($t/intro2.log)"
grep -aq "skeldat: a drop of skeldat:stick" "$t/srv31_2.log" &&
	fail "the starter items dropped again on a loaded world ($t/srv31_2.log)"
echo "the opening dialog: $days days at a new 128 world's start; the starter items within $s_far"
# 29. High scores ([SKELDAT_HIGH_SCORES]), three 128 worlds of seed 2 at
# 1x on one server tree, each ended at once (the surface filled), aged by
# BUILDAT_SKELDAT_WORLD_T: "w1" 30 days with 12 players' times given
# (the ten most kept and the 11th, in over half the time; the 12th not),
# its Players field the same; "w2" 10 days, second in the set, the set
# now named w2; "w2_rerun" 5 days, third, the name kept. A client in it:
# the end text's place, High scores... with the one set, and the set's
# three scores. Then the launcher's world menu: the set as a preset, and
# a world made from it is of seed 2, 128 wide, 1x.
hs() # <n> [server args], the environment the caller's
{
	local n=$1
	shift
	BUILDAT_SKELDAT_SEED=2 start_server "$t/srv32_$n.log" "STATUS Listening" \
		300 auto "$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
		-D "$t/srv32" -C "$t/srv.cache" -l 3 "$@" || fail "the server ($t/srv32_$n.log)"
	CHECK_PIDS+=($SERVER_PID)
}
hs_w() # <n> <world> <age>: a 128 world ended at once
{
	BUILDAT_SKELDAT_WORLD=$2 BUILDAT_SKELDAT_SIZE="1 -1 0" BUILDAT_SKELDAT_FILL=surface \
		BUILDAT_SKELDAT_WORLD_T=$3 hs $1
}
hs_end()
{
	wait_for_log "$t/srv32_$1.log" "skeldat: the score .* is [0-9]*\. of" 60 ||
		fail "no score recorded ($t/srv32_$1.log)"
	grep -a "skeldat: the score" "$t/srv32_$1.log" | sed 's/.*skeldat: //'
}
played="p01 30000; p02 29000; p03 28000; p04 27000; p05 26000; p06 25000; p07 24000; p08 23000; p09 22000; p10 21000; p11 20000; p12 1000"
BUILDAT_SKELDAT_PLAYED="$played" hs_w 1 w1 36000
s1=$(hs_end 1)
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
echo "$s1" | grep -q 'is 1\. of 1 in set/2/128/1 ("w1")' &&
	echo "$s1" | grep -q "players: p01 8.3 h, .*p10 5.8 h, p11 5.6 h$" ||
	fail "w1's score, or its players: $s1 ($t/srv32_1.log)"
hs_w 2 w2 12000
s2=$(hs_end 2)
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
echo "$s2" | grep -q 'is 2\. of 2 in set/2/128/1 ("w2"), best 30\.0' ||
	fail "w2 not second, or the set not named after it: $s2 ($t/srv32_2.log)"
printf '%s\n' "$placed" "delay 1500" "keypress Escape" "wait_log 5000 pause: the menu shown" \
	"delay 500" 'click Button "High scores..."' "wait_log 5000 pause: high scores shown" \
	"delay 500" 'click Button "w2:*"' "wait_log 5000 pause: scores of" \
	"delay 500" "screenshot $t/scores.png" quit > "$t/hs.cmds"
hs_w 3 w2_rerun 6000
s3=$(hs_end 3)
echo "$s3" | grep -q 'is 3\. of 3 in set/2/128/1 ("w2"), best 30\.0' ||
	fail "the re-run's score, or the name it left: $s3 ($t/srv32_3.log)"
client hs "$t/hs.cmds"
wait $CLIENT || fail "the high scores drive ($t/hs.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
grep -aq "Best for these parameters: 30.0 days; this one is number 3" "$t/hs.log" &&
	grep -aq "pause: high scores shown, 1 sets" "$t/hs.log" &&
	grep -aq "pause: scores of set/2/128/1 shown, 3 scores" "$t/hs.log" ||
	fail "the end's place, or the high scores pages ($t/hs.log)"
printf '%s\n' "wait_log 120000 world_menu: 1 presets" 'click Button "New world..."' \
	"wait_log 5000 world_menu: the name screen shown" "delay 300" "text fromset" \
	'click DropDownList "▼"' "delay 500" "keypress Down" "keypress Return" \
	"wait_log 5000 world_menu: preset 1 picked" "delay 500" 'click Button "Create"' \
	"wait_log 180000 skeldat: placed at" quit > "$t/hs_menu.cmds"
hs 4 -u launcher=1
client hs_menu "$t/hs_menu.cmds"
wait $CLIENT || fail "the world menu's preset drive ($t/hs_menu.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
grep -aq 'the world "fromset" starts, seed 2,.* 128 x 64 x 128' "$t/srv32_4.log" &&
	grep -aq "the bones at 1x" "$t/srv32_4.log" ||
	fail "a world from the preset not of its seed, size and speed ($t/srv32_4.log)"
echo "high scores: $s3"
# 30. The re-run ([SKELDAT_RERUN]): "w" (seed 2, 128 wide, ended at once,
# the surface filled) re-run from the pause menu's Play again: the client
# told the world is made again (a client with a launcher rejoins by it;
# these are started with -s and are only disconnected), the module
# reloaded and "w_rerun" made with w's seed, size and speed, w kept; a
# client joining is placed in it; its own Play again deletes and makes
# w_rerun again, no w_rerun_rerun.
log33="$t/srv33.log"
BUILDAT_SKELDAT_WORLD=w BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="1 -1 0" \
	BUILDAT_SKELDAT_FILL=surface start_server "$log33" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
	-D "$t/srv33" -C "$t/srv.cache" -l 3 || fail "the server ($log33)"
CHECK_PIDS+=($SERVER_PID)
again='keypress Escape
wait_log 5000 pause: the menu shown
delay 500
click Button "Play again"
wait_log 10000 Disconnected from server: The world is being made again'
printf '%s\n' "$placed" "delay 1500" "$again" quit > "$t/rr1.cmds"
client rr1 "$t/rr1.cmds"
wait $CLIENT
wait_for_log "$log33" 'the world "w_rerun" starts' 120 ||
	fail "no re-run world ($log33, $t/rr1.log)"
grep -aq "Disconnected from server: The world is being made again as w_rerun" "$t/rr1.log" ||
	fail "the client not told of the re-run ($t/rr1.log)"
printf '%s\n' "$placed" "delay 1500" "$again" quit > "$t/rr2.cmds"
client rr2 "$t/rr2.cmds"
wait $CLIENT
wait_for_log "$log33" "re-run: deleted w_rerun" 120 ||
	fail "the second re-run did not delete w_rerun ($log33, $t/rr2.log)"
wait_for_log "$log33" "the world is in" 120
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
grep -aq "client1 starts a re-run as w_rerun" "$log33" &&
	grep -aq "re-run: w_rerun, seed [0-9]*, 128 wide, 1x" "$log33" &&
	[ $(grep -ac 'the world "w_rerun" starts, seed 2,.* 128 x 128 x 128' "$log33") = 2 ] ||
	fail "the re-run's name, seed or size ($log33)"
grep -aq "skeldat: placed at" "$t/rr2.log" || fail "no client placed in w_rerun ($t/rr2.log)"
[ -d "$t/srv33/apps/skeldat/saves/w" ] && [ -d "$t/srv33/apps/skeldat/saves/w_rerun" ] &&
	[ ! -e "$t/srv33/apps/skeldat/saves/w_rerun_rerun" ] ||
	fail "the saves after two re-runs: $(ls "$t/srv33/apps/skeldat/saves")"
echo "re-run: w to w_rerun, w_rerun again: $(ls "$t/srv33/apps/skeldat/saves" | tr '\n' ' ')"
# 31. Touch controls ([SKELDAT_TOUCH]), BUILDAT_TOUCH=1 at 800x500 in
# the crafting world of 12: the stick pushed full and then half way for
# 2 s each (the second about half as far); a finger dragged 50 pixels
# right turns the view (48 degrees at the default 0.2 and this UI scale
# of 1.25), dragged down it looks at the ground; a tap places the held
# dirt (slot 1), a finger held still digs; hotbar slot 2 (UI 640 x 400,
# skeldat's scale 1) tapped, the bow drawn by a held finger and
# shot by its lift; the Inventory button opens it, two taps craft and
# move the sticks to main:10, a finger on main:11 slid onto main:10 and
# a second finger's tap there picks up half, a tap on main:11 puts it
# down. simplified: a tap on a mob, the board's brake by the stick and
# the pause menu's buttons by tap are not driven: the first is the
# place's own branch, the others are the keys' and the UI's.
log34="$t/srv34.log"
BUILDAT_SKELDAT_WORLD=touch BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="2 -1 0" \
	BUILDAT_SKELDAT_TIME=0.5 BUILDAT_SKELDAT_SPAWN="0 0" \
	BUILDAT_SKELDAT_TEST="craft 1 skeldat:wood 3; craft 4 skeldat:wood 3; give skeldat:dirt 10 1; give skeldat:bow 1 1; give skeldat:arrow 10 1" \
	start_server "$log34" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
	-D "$t/srv34" -C "$t/srv.cache" -l 3 || fail "the server ($log34)"
CHECK_PIDS+=($SERVER_PID)
{
	echo "$placed"; echo "delay 2000"
	for to in 250 309; do
		echo "finger_down 1 100 350"; echo "finger_move 1 100 $to"
		echo "delay 2000"; echo "finger_up 1"; echo "delay 1000"
	done
	echo "finger_down 2 600 250"
	for x in 610 620 630 640 650; do echo "finger_move 2 $x 250"; echo "delay 60"; done
	echo "finger_up 2"; echo "delay 500"; echo "finger_down 2 600 200"
	for y in 210 220 230 240 250; do echo "finger_move 2 600 $y"; echo "delay 60"; done
	echo "finger_up 2"; echo "delay 500"
	echo "tap 600 250"; echo "delay 1000"
	echo "finger_down 3 600 250"; echo "delay 4000"; echo "finger_up 3"
	echo "delay 500"; echo "tap 325 485"; echo "delay 500"
	echo "finger_down 3 600 150"; echo "delay 1500"; echo "finger_up 3"
	echo "delay 1000"; echo "tap 548 94"
	echo "wait_log 5000 inventory: inventory opened"; echo "delay 500"
	# The window's slots at skeldat's scale 1: the craft result, main:10
	# and main:11 (12's are at its scale 2, without touch's UI scale)
	echo "tap 468 199"; echo "delay 700"; echo "tap 310 253"; echo "delay 700"
	echo "finger_down 1 333 253"; echo "delay 200"; echo "finger_move 1 310 253"
	echo "delay 200"; echo "finger_down 2 400 420"; echo "delay 100"
	echo "finger_up 2"; echo "delay 200"; echo "finger_up 1"; echo "delay 500"
	echo "tap 333 253"; echo "delay 700"; echo "keypress Escape"; echo "delay 500"
	echo quit
} > "$t/touch.cmds"
BUILDAT_TOUCH=1 client touch "$t/touch.cmds"
wait $CLIENT || fail "the touch drive ($t/touch.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
strokes=$(grep -a "skeldat: the stick pushed" "$t/touch.log" | sed 's/.*pushed \([0-9.]*\) moved \([0-9.]*\)/\1 \2/' | tr '\n' ' ')
turned=$(grep -a "skeldat: touch turned" "$t/touch.log" | head -1 | sed 's/.*turned \([-0-9.]*\) .*/\1/')
set -- $strokes
awk -v p1="${1:-0}" -v m1="${2:-0}" -v p2="${3:-0}" -v m2="${4:-0}" 'BEGIN {
	exit !(p1 > 0.95 && m1 > 4 && p2 > 0.4 && p2 < 0.6 && m2 / m1 > 0.3 &&
		m2 / m1 < 0.7) }' ||
	fail "the stick's strokes: $strokes ($t/touch.log)"
awk -v y="${turned:-0}" 'BEGIN { exit !(y > 35 && y < 70) }' ||
	fail "a drag did not turn the view: ${turned:-none} ($t/touch.log)"
grep -aq "client1 places skeldat:dirt" "$log34" && grep -aq "dig: done at" "$t/touch.log" &&
	grep -aq "touch: hotbar slot 2" "$t/touch.log" &&
	grep -aq "skeldat: the bow drawn" "$t/touch.log" &&
	grep -aq "client1 shoots an arrow at" "$log34" ||
	fail "the tap's place, the held finger's dig, or the bow ($log34, $t/touch.log)"
grep -aq "inventory: move 4 skeldat:stick craftresult:1 -> main:10" "$t/touch.log" &&
	grep -aq "inventory: move 2 skeldat:stick main:10 -> main:11" "$t/touch.log" ||
	fail "the inventory by finger ($t/touch.log)"
echo "touch: strokes (push, moved) $strokes, a 50 pixel drag turned $turned degrees"
echo "a night: $(echo $night)"
echo "lanterns: $lantern"
echo "skeletons: clean: $clean; flooded, after the player: $(echo "$last" | sed 's/.*skeldat: //'); the world with 2000 added: $light"
echo "a new world populated: $pop"
echo "far skeletons: $far"
echo "a respawn far away: the chunks within 2 drawn $respawn"
echo "run 1: $(grep -ac "pulled back" "$t/srv1.log") pull backs; run 2: $mobs mobs back"
echo "PASS: skeldat's rules, the movement check, the chat's report and mute, the admin's menu and map, the bones zone, the world's end, the skeletons' count, sleep and wake, a marker skull, a night's walk and bone blocks, lanterns lit, luring and taken, a marker dug and placed, the dig's crack, the world sizes, crafting more, invulnerability, items on the ground, a far respawn's world, a new world's skeletons, the far skeletons, the world's edge, a skeleton's body after its light form, no sun beside a bone block, death in water and a pond kept out of, ways built of bone, the bow, the skateboard and its roll, free-running, a skull down a shaft, the bones' speed, the opening dialog and the starter items, the high scores, the re-run, the touch controls"
# vim: set noet ts=4 sw=4:
