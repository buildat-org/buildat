#!/bin/bash
# tier: full
# cost: ~24 min (2026-10-19)
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
# has a higher target, and a player among 200 light skeletons makes some
# active, dormant again when it leaves, none lost. 2000 light
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
#   SECTIONS="12 33" apps/skeldat/check.sh   # those alone
#   SECTIONS=list apps/skeldat/check.sh      # the sections
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
check_tmp skeldat; t=$CHECK_TMP
b="$here/Build/bin/buildat"
m="$here/apps/skeldat/main"

# [SKELDAT_CHECK_SECTIONS] Each section is its lines from its "# N." to the
# next header, run by eval. SECTIONS="12 33" runs those after the shared
# setup, and what they stand on (2 runs in 1's save, 39 in 32's), each
# under an "== section N" line; unset, all in the file's order and then
# the summary. 0 is the rules' own tests.
sec() # <header>: its lines, to the next header
{
	awk -v h="# $1" 'index($0, h) == 1 { on = 1; print; next }
		/^# ([0-9]+\. |The shared setup|The summary)/ { on = 0 } on' "$0"
}
all=$(awk '/^# [0-9]+\. / { print $2 + 0 }' "$0")
if [ "${SECTIONS:-}" = list ]; then
	awk '/^# [0-9]+\. / { print substr($0, 3) }' "$0"
	exit 0
fi
want=" $(echo ${SECTIONS:-$all}) "
for n in $want; do
	echo "$all" | grep -qx "$n" || fail "no section $n (SECTIONS=list names them)"
done
case $want in *" 2 "*) want="${want}1 ";; esac
case $want in *" 39 "*) want="${want}32 ";; esac
for n in $all; do
	case $want in *" $n "*) ;; *) continue ;; esac
	if [ $n != 0 ] && [ -z "${shared:-}" ]; then
		shared=1
		eval "$(sec "The shared setup")"
	fi
	echo "== section $n"
	eval "$(sec "$n. ")"
done
if [ -n "${SECTIONS:-}" ]; then
	echo "PASS: skeldat's sections$want"
	exit 0
fi
eval "$(sec "The summary")"
exit

# 0. The rules' own tests
cc="g++ -std=c++11 -Wno-pragma-once-outside-header -I$here/src"
$cc -DSKELDAT_GAME_TEST -x c++ "$m/game.h" -o "$t/game" && "$t/game" ||
	fail "game.h's self test"
# [SKELDAT_SKULL_ICON] Every item's picture a PNG in client_data with a
# pixel not fully transparent (8-bit, not interlaced, as client_data's are)
# (filtered rows: the first alpha not 0 is predicted from zeros, so its
# byte is not 0 either); and [SKELDAT_BOARD_TOGGLE]'s two HUD pictures,
# 16x16
{ "$t/game" images; echo "board_icon main/board_icon.png"
	echo "board_cross main/board_cross.png"; } | python3 -I -c '
import struct, sys, zlib
bad = []
for line in sys.stdin:
    name, image = line.split()
    try:
        d = open(sys.argv[1] + "/client_data/" + image.split("/", 1)[1], "rb").read()
    except OSError:
        bad.append(name + ": no " + image); continue
    w, h, depth, ctype = struct.unpack(">IIBB", d[16:26])
    if name.startswith("board_") and (w, h) != (16, 16):
        bad.append(name + ": " + image + " is %dx%d" % (w, h))
    idat, i = b"", 8
    while i < len(d):
        n, kind = struct.unpack(">I4s", d[i:i + 8])
        if kind == b"IDAT": idat += d[i + 8:i + 8 + n]
        i += 12 + n
    raw = zlib.decompress(idat)
    if ctype == 6 and depth == 8:
        row = 1 + 4 * w
        if not any(raw[y * row + 1 + 4 * x + 3] for y in range(h) for x in range(w)):
            bad.append(name + ": " + image + " is empty")
if bad: sys.exit("\n".join(bad))
' "$m" || fail "an item's picture missing or empty"
$cc -DSKELDAT_BONES_TEST -x c++ "$m/bones.h" -o "$t/bones" && "$t/bones" ||
	fail "bones.h's self test"
$cc -DSKELDAT_HAZARDS_TEST -x c++ "$m/hazards.h" -o "$t/hazards" && "$t/hazards" ||
	fail "hazards.h's self test"
$cc -O2 -DSKELDAT_MAPGEN_TEST -x c++ "$m/mapgen.h" -o "$t/mapgen" && "$t/mapgen" ||
	fail "mapgen.h's self test"
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

# The shared setup: what the sections after 0 use
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
	timeout 480 "$b" -C "$t/c_$1" -D "$t/u_$1" -w "${CLIENT_SIZE:-800x500}" -l 3 \
		-o sound_mute=1 -s "127.0.0.1:$SERVER_PORT" -c @"$2" \
		> "$t/$1.log" 2>&1 &
	CLIENT=$!
	CHECK_PIDS+=($CLIENT)
}
placed='wait_log 300000 skeldat: placed at'
# The worlds a drive walks, shoots or builds in are flat
# (BUILDAT_SKELDAT_TERRAIN=flat, [SKELDAT_OWN_MAPGEN]: one height, no tree
# within 24 of the spawn, no cave open at the ground), so their spots
# stay as the generator changes; the rest are of the generated forms
# (rivers but where named), which the survey, the end, the high scores
# and the forms' own section (47) look at
# The opening dialog holds a new player's keys: off but in its own run (28)
export BUILDAT_SKELDAT_INTRO=0 BUILDAT_SKELDAT_STARTER=0
# The scripted clients in as "client<peer>" with no login ([SKELDAT_LOGIN];
# the login of every public join is builtin/world_menu/check.sh's)
export BUILDAT_SKELDAT_GUEST_JOIN=1

# The water from the feet to over the head, 4 markers stacked, walled in by
# stone (water flows, [SKELDAT_OWN_MAPGEN]), the walls first, 5 markers
# stacked a column: 13's, 14's, 15's and 42's
water=""
for d in "1 0" "-1 0" "0 1" "0 -1"; do
	for y in 0 1 2 3 4; do water="$water marker $d skeldat:stone 0;"; done
done
water="$water$(for y in 0 1 2 3; do echo " marker 0 0 skeldat:water_source 0;"; done)"

# 1. Two players. client1's pause menu, after its chat page, closed by a
# click off it ([SKELDAT_PAUSE_CLOSE]), a click on its margin first
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
mouse_pos 338 250
delay 100
mouse_click left
delay 1000
mouse_pos 10 10
delay 100
mouse_click left
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
event skeldat_modes fly fast
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
# [SKELDAT_PAUSE_CLOSE] A click on the pause menu's own margin leaves it
# open; one off it (at 10,10) is Continue (the walk after it is the
# world's keys again)
awk '/command: mouse_pos 10 10/ { off = 1 } /pause: a click off the menu/ { n++; if(!off) bad = 1 }
	off && /pause: the menu closed/ { closed = 1 }
	END { exit !(n == 1 && !bad && closed) }' "$t/a1.log" ||
	fail "the pause menu not closed by a click off it alone ($t/a1.log)"
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
# [FOV_SETTING]: the camera's baseline, 72 unset
grep -aq "skeldat: field of view 72 at start" "$t/a1.log" || fail "the field of view at start ($t/a1.log)"
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
delay 5000
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
look 118 -89
keypress 2
delay 500
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
# A stone pick for client1 (alone, the first in): the zone's ground can
# be a bone pile, which a hand does not dig
BUILDAT_SKELDAT_TEST="populate; give skeldat:stone_pick 1 1" server "$t/srv2.log" -u launcher=1
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
# Spawned there, or one of the populated world's made active by the player
# ([SKELDAT_START_SKELETONS]: the zone's own count can leave no room)
grep -aE "a skeleton \([0-9]*\) spawns at .*, danger (0\.[5-9]|1)|skeletons, [1-9][0-9]* full" "$s" |
	grep -q . || fail "no skeleton spawned or active in the zone ($s)"
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
	BUILDAT_SKELDAT_WORLD=mark BUILDAT_SKELDAT_TERRAIN=flat BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="2 -1 0" \
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
# (the dying is in the morning), a player among them a while: some made
# active and dormant again, none lost
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
grep -aE "skeldat: [0-9]+ skeletons, [0-9]+ full, [1-9][0-9]* activated" "$log6" | grep -q . ||
	fail "no skeleton made active by the player ($log6)"
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
BUILDAT_SKELDAT_WORLD=take BUILDAT_SKELDAT_TERRAIN=flat BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="2 -1 0" \
	BUILDAT_SKELDAT_TIME=0.5 BUILDAT_SKELDAT_SPAWN="0 0" \
	BUILDAT_SKELDAT_LANTERNS="4 0 2" BUILDAT_SKELDAT_TEST="skeleton 4 1 marked; marker 0 1" \
	start_server "$log13" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
	-D "$t/srv13" -C "$t/srv.cache" -l 3 || fail "the server ($log13)"
CHECK_PIDS+=($SERVER_PID)
printf '%s\n' "$placed" "delay 1500" "look 0 -60" "delay 500" "mouse_down left" \
	"delay 600" "mouse_up left" "delay 800" "look 0 -60" "delay 500" \
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
BUILDAT_SKELDAT_WORLD=dig BUILDAT_SKELDAT_TERRAIN=flat BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="2 -1 0" \
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
BUILDAT_SKELDAT_WORLD=craft BUILDAT_SKELDAT_TERRAIN=flat BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="2 -1 0" \
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
# the server started again, in the shared setup's water
for n in 1 2; do
	BUILDAT_SKELDAT_WORLD=inv BUILDAT_SKELDAT_TERRAIN=flat BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="2 -1 0" \
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
# them all up, one pickup sound a tick ([SKELDAT_BOW_SOUNDS]). Before the
# respawn, Escape opens the pause menu over the death screen and
# Continue goes back to it ([SKELDAT_DEATH_PAUSE]), then the same by its
# Pause menu button ([SKELDAT_DEATH_MENU_BUTTON]).
log17="$t/srv17.log"
printf '%s\n' "$placed" "delay 2000" "look 0 -89" "mouse_down left" \
	"delay 2500" "mouse_up left" "delay 1000" "look 0 0" "keypress Q" \
	"delay 1500" "look 0 -40" "delay 500" "screenshot $t/drops.png" \
	"wait_log 60000 pause: the death screen shown" "delay 25000" quit \
	> "$t/drops1.cmds"
printf '%s\n' "wait_log 300000 pause: the death screen shown" "delay 1000" \
	"keypress Escape" "wait_log 5000 pause: the menu shown" "delay 500" \
	"screenshot $t/death_pause.png" 'click Button "Continue"' \
	"wait_log 5000 pause: back to the death screen" "delay 500" \
	'click Button "Pause menu"' "wait_log 5000 pause: the menu shown" \
	"delay 500" 'click Button "Continue"' \
	"wait_log 5000 pause: back to the death screen" "delay 500" \
	'click Button "Respawn"' "delay 3000" quit > "$t/drops2.cmds"
for n in 1 2; do
	BUILDAT_SKELDAT_WORLD=drops BUILDAT_SKELDAT_TERRAIN=flat BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="2 -1 0" \
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
# [SKELDAT_DEATH_PAUSE] Escape on the death screen: the menu over it, the
# single player's pause; Continue back to it, and Respawn then
grep -aq "client1 paused the world (the pause menu)" "$t/srv17_2.log" &&
	grep -aq "client1 resumed the world (the pause menu)" "$t/srv17_2.log" ||
	fail "the pause menu over the death screen did not pause ($t/srv17_2.log, $t/drops.log)"
# [SKELDAT_DEATH_MENU_BUTTON] its Pause menu button the same, no respawn
[ "$(grep -ac "client1 paused the world (the pause menu)" "$t/srv17_2.log")" = 2 ] &&
	[ "$(grep -ac "skeldat *: pause: back to the death screen" "$t/drops.log")" = 2 ] ||
	fail "the death screen's Pause menu button ($t/srv17_2.log, $t/drops.log)"
grep -aq "skeldat: 18 drops on the ground" "$t/srv17_2.log" &&
	[ $(grep -acE "client1 picks up 9[89] skeldat:stone" "$t/srv17_2.log") = 18 ] ||
	fail "the drops not kept over the restart, or not picked up ($t/srv17_2.log)"
# [SKELDAT_BOW_SOUNDS] A pickup's sound, once a tick however many stacks
# (the picker's own, [SKELDAT_SOUNDS_HEARD])
picks=$(grep -ac "skeldat: sound_own pickup" "$t/drops.log")
[ "$picks" -ge 1 ] && [ "$picks" -lt 18 ] ||
	fail "18 stacks picked up with $picks pickup sounds ($t/drops.log)"
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
# row 52 voxels ahead (past ACTIVE_WITHIN), their steps slowed to 30 s: the client
# draws as many as the server sends; started again at midnight (by day
# the active ones burn) with the player placed 7 from them, they are made
# active, have
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
	fail "the near skeletons not made active out of the far list ($t/srv20_2.log)"
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
# body put back on its light form over two reports. [SKELDAT_SKELETON_DRAW]
# Each shot 0.8 s after its draw: on the server "draws at" then "shoots
# at", on the client "sound bow_draw at" then "sound bow at", and the
# pose's "a skeleton draws". simplified: the draw let go is not driven (a
# player cannot walk from 9 out past 16 in its 0.8 s)
log22="$t/srv22.log"
BUILDAT_SKELDAT_WORLD=body BUILDAT_SKELDAT_TERRAIN=flat BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="2 -1 0" \
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
python3 -I - "$log22" "$t/body.log" <<'PY' || fail "the skeleton's draw ($log22, $t/body.log)"
import sys, re
def ts(l):
    m = re.search(r" (\d\d):(\d\d):(\d\d)\.(\d\d\d) ", l)
    return int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3)) + int(m.group(4)) / 1000
# A draw, then the shot that follows it: on the server by the skeleton's
# key, on the client by the place (it stands while it draws)
def gaps(path, a, b, key):
    lines = open(path, errors="replace").read().split("\n")
    out, t = [], {}
    for l in lines:
        if a in l:
            t[key(l)] = ts(l)
        elif b in l and key(l) in t:
            out.append(ts(l) - t.pop(key(l)))
    return out
def at(l):
    m = re.search(r" at ([-0-9.]+),[-0-9.]+,([-0-9.]+)", l)
    return (round(float(m.group(1))), round(float(m.group(2))))
srv = gaps(sys.argv[1], "draws at client1", "a skeleton shoots at client1",
        lambda l: "")
cli = gaps(sys.argv[2], "skeldat: sound bow_draw at", "skeldat: sound bow at", at)
assert srv and all(0.7 <= g <= 1.0 for g in srv), "the server's draws to shots %s" % srv
assert cli and all(0.6 <= g <= 1.1 for g in cli), "the client's sounds %s" % cli
assert "skeldat: a skeleton draws" in open(sys.argv[2], errors="replace").read(), "no pose"
print("draws: %d shots %.2f-%.2f s after their draws" % (len(srv), min(srv), max(srv)))
PY
# 20. No sun in the bones ([SKELDAT_SUN_IN_BONES]): at noon on clean
# ground two skeletons: one 6 from a player, at a bow's distance where
# it stands, beside a bone block, which does not burn; one 20 off with no
# bones round it, which does as it walks in. Both marked, as the marker
# skull a skeleton puts in the next column on seeing a player would keep
# the sun off it too
log23="$t/srv23.log"
BUILDAT_SKELDAT_WORLD=sun BUILDAT_SKELDAT_TERRAIN=flat BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="2 -1 0" \
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
# (the water still: BUILDAT_SKELDAT_STILL_WATER, the liquid step off)
log24="$t/srv24.log"
pond=$(for x in -4 -3 -2 -1 0 1 2 3 4; do printf 'marker %d 10 skeldat:water_source; ' $x; done)
# The pool 3 x 3 round the skeleton: its light form steps off a single
# voxel of water before the body is made active in it
pool=$(for x in -1 0 1; do for z in -7 -6 -5; do printf 'marker %d %d skeldat:water_source; ' $x $z; done; done)
BUILDAT_SKELDAT_WORLD=water BUILDAT_SKELDAT_TERRAIN=flat BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="2 -1 0" \
	BUILDAT_SKELDAT_TIME=0 BUILDAT_SKELDAT_SPAWN="0 0" BUILDAT_SKELDAT_DAY=2400 BUILDAT_SKELDAT_STILL_WATER=1 \
	BUILDAT_SKELDAT_TEST="${pond}${pool}skeleton 0 12 marked; skeleton 0 -6 marked" \
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
# builds nothing (at x 10, the own terrain's trees clear of it)
log25="$t/srv25.log"
ways=$(for z in $(seq -7 7); do for x in 3 4 5 6 7 8; do
	printf 'marker %d %d skeldat:water_source -1; ' $x $z; done; done
for z in -1 0 1; do for x in -9 -8 -7; do printf 'marker %d %d skeldat:stone 4; ' $x $z; done; done
for x in 7 8 9 10 11 12 13; do for y in 0 1 2; do printf 'marker %d -14 skeldat:stone %d; ' $x $y; done; done)
BUILDAT_SKELDAT_WORLD=ways BUILDAT_SKELDAT_TERRAIN=flat BUILDAT_SKELDAT_STILL_WATER=1 BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="2 -1 0" \
	BUILDAT_SKELDAT_TIME=0.8 BUILDAT_SKELDAT_SPAWN="0 0" BUILDAT_SKELDAT_DAY=600 \
	BUILDAT_SKELDAT_LIGHT_STEP=0.2 \
	BUILDAT_SKELDAT_TEST="${ways}lantern -8 0 3; skeleton 1 0 marked seed 11 0 4; skeleton -4 1 marked seed 11 0 4; skeleton -3 0 marked lure; skeleton 10 -11 marked seed 10 -17 1; place 100 0" \
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
# it picks it up. Frames of the hand at rest, half and full drawn. The
# draws', shots' and landings' sounds ([SKELDAT_BOW_SOUNDS]).
log26="$t/srv26.log"
shot()
{
	printf '%s\n' "mouse_down left" "delay $1" ${2:+"screenshot $2"} \
		"mouse_up left" "delay 1500"
}
{ echo "$placed"; toggle; echo "look 0 -5"; echo "delay 1000"
	echo "screenshot $t/bow_rest.png"
	shot 1200 "$t/bow_full.png"; shot 450 "$t/bow_half.png"; shot 10
	shot 1200; shot 1200
	echo "look 0 -60"; shot 2500
	echo "look 90 0"; shot 1200; shot 1200; shot 1200; shot 1200; shot 1200
	echo "delay 66000"; echo quit; } > "$t/bow1.cmds"
printf '%s\n' "$placed" "delay 3000" quit > "$t/bow2.cmds"
for n in 1 2; do
	BUILDAT_SKELDAT_WORLD=bow BUILDAT_SKELDAT_TERRAIN=flat BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="2 -1 0" \
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
# [SKELDAT_BOW_SOUNDS] Each draw squeaks on the drawer's own (the server
# sends it to the others only; the skeleton's draws placed,
# [SKELDAT_SKELETON_DRAW]); each shot chops: the player's on its own
# client at the release, not from the server ([SKELDAT_BOW_SOUND_TUNE]),
# the skeleton's from the server; an arrow sticking lands. The sounds'
# self-check: the arrow's 4x louder, the draw's mids halved, the release
# the user's blip ([SKELDAT_BOW_RELEASE_PICK]) hashed
b1="$t/bow1.log"
skel=$(grep -ac "a skeleton shoots at client1" "$s1")
[ "$(grep -ac "skeldat: sound bow_draw (own)" "$b1")" = "$draws" ] &&
	[ "$(grep -ac "skeldat: sound bow_draw at" "$b1")" = "$(grep -ac "skeleton ([0-9]*) draws at" "$s1")" ] &&
	[ "$(grep -ac "skeldat: sound bow (own)" "$b1")" = "$#" ] &&
	[ "$(grep -ac "skeldat: sound bow at" "$b1")" = "$skel" ] && [ "$skel" -ge 1 ] &&
	grep -aq "skeldat: sound arrow_land at" "$b1" &&
	grep -aq "skeldat: 184 sounds made" "$b1" &&
	grep -aq "skeldat: sounds: self-check passed, bow [0-9a-f]\{8\} " "$b1" ||
	fail "the bow's sounds: $draws draws, $# shots and $skel of the skeleton's, 23 sounds of 8 made ($b1)"
echo "the bow's sounds: $draws draws, $# shots and $skel of the skeleton's; $(grep -a "sounds: self-check" "$b1" | head -1 | sed 's/.*skeldat: //')"
[ -n "$kept" ] && grep -aq "client1 picks up an arrow at ${kept% *}.0,[-0-9.]*,${kept#* }.0" "$t/srv26_2.log" ||
	fail "no stuck-arrow voxel, or not picked up after the restart: ${kept:-none} ($t/srv26_2.log)"
# 24. The board ([SKELDAT_SKATEBOARD]) on a course of stone (TEST
# course, main.cpp): walked onto its slope of 12, client1 is on the board
# by itself, gets the drop's speed and keeps it on the flat, flies off a
# ramp of 2 and lands, lying flat (Shift held from the boarding on) goes
# through a wall's hole one high, and a wall of 3 stops it; walked off the side down
# 8 onto a flat, S stops it within the brake's reach. The camera looks
# back over the first ride, which goes on straight ([SKELDAT_BOARD_KEYS];
# W held over it, so Camera steer leaves it, [SKELDAT_CAMERA_STEER]). The server pulls
# back none of it, and pulls back a board the drive forces to 35 on the
# flat. No steps on the board, steps again walking off it ([SKELDAT_BOARD_NO_STEPS]).
# client2 sees client1 on a board and lying flat, then walks into
# a ring of water 2 round the spawn and splashes ([SKELDAT_BOARD_WATER]),
# and sees client1 walk when its ride ends ([SKELDAT_BOARD_HIDE]).
log27="$t/srv27.log"
ring=$(for x in -2 -1 0 1 2; do for z in -2 -1 0 1 2; do
	[ ${x#-} = 2 ] || [ ${z#-} = 2 ] && printf 'marker %d %d skeldat:water_source; ' $x $z
done; done)
cat > "$t/board1.cmds" <<EOF
$placed
wait_log 60000 skeldat: placed at (-40.0,
delay 1500
look 90 0
delay 1000
keydown W
wait_log 5000 skeldat: on the board
look 270 0
keydown Left Shift
wait_log 20000 skeldat: walking
keyup Left Shift
keyup W
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
keydown A
delay 1000
keyup A
delay 500
event skeldat_board 35
delay 3000
quit
EOF
printf '%s\n' "$placed" "wait_log 60000 skeldat: client1 lies flat" \
	"delay 500" "keydown W" "wait_log 5000 skeldat: a splash at" "keyup W" \
	"wait_log_any 30000 skeldat: client1 walks" "delay 500" quit > "$t/board2.cmds"
BUILDAT_SKELDAT_WORLD=board BUILDAT_SKELDAT_TERRAIN=flat BUILDAT_SKELDAT_STILL_WATER=1 BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="2 -1 2" \
	BUILDAT_SKELDAT_TIME=0.5 BUILDAT_SKELDAT_SPAWN="0 0" BUILDAT_SKELDAT_SKELETONS=0 \
	BUILDAT_SKELDAT_TEST="${ring}course -40 -20" \
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
# [SKELDAT_BOARD_NO_STEPS] steps between "on the board" and "walking at": none;
# after the brake's stop, the walk to the side steps
steps=$(awk '/skeldat: on the board/ { on = 1 } /skeldat: walking at/ { on = 0; w++ }
	/skeldat: step / { if (on) b++; else if (w == 2) a++ }
	END { print b + 0, a + 0 }' "$c1")
[ "${steps% *}" = 0 ] && [ "${steps#* }" -ge 1 ] ||
	fail "steps on the board ${steps% *}, after it ${steps#* } ($c1)"
cheat=$(grep -a "the board forced to" "$c1" | head -1 | awk '{print $3}')
first_pull=$(grep -a "pulled back" "$log27" | head -1 | awk '{print $3}')
[ -n "$cheat" ] && [ -n "$first_pull" ] && [[ ! "$first_pull" < "$cheat" ]] &&
	grep -aq "pulled back .*: too far (on the board)" "$log27" ||
	fail "an honest board pulled back, or the forced one not: first at $first_pull, the cheat at $cheat ($log27)"
# [SKELDAT_BOARD_SOUND] The roll's self test, and its stream at the
# device's buffer and 20 ms to a chunk over it ahead after each feed over
# the ride ([SKELDAT_BOARD_SOUND_FAULT]: the figure the client logs, or
# the last the queue was raised to, the frames here run to 50 ms), the
# underruns said at most once (the raises end them)
grep -aq "skeldat: board sound: self test passed" "$c1" ||
	fail "the board sound's self test ($c1)"
roll=$(grep -a "skeldat: board speed" "$c1" |
	sed 's/.*the roll \([0-9]*\)\.\.\([0-9]*\) ms.*/\1 \2/' |
	awk 'NR == 1 { lo = $1; hi = $2 } $1 < lo { lo = $1 } $2 > hi { hi = $2 }
		END { print NR, lo, hi }')
read -r roll_n roll_lo roll_hi <<< "$roll"
kept=$(grep -a "board sound: the device's buffer" "$c1" | head -1 |
	sed 's/.*the roll kept \([0-9]*\) ms ahead.*/\1/')
echo "the roll's device: $(grep -a "board sound: the device's buffer" "$c1" | head -1 | sed 's/.*board sound: //')"
raised=$(grep -a "board sound: the queue raised to" "$c1" | tail -1 |
	sed 's/.*raised to \([0-9]*\) ms.*/\1/')
echo "the roll's queue raised $(grep -ac "board sound: the queue raised" "$c1") times, to ${raised:-none}"
[ "${roll_n:-0}" -ge 10 ] && [ -n "$kept" ] && [ "${roll_lo:-0}" -ge "$kept" ] &&
	[ "${roll_hi:-999}" -le $((${raised:-$kept} + 11)) ] &&
	[ "$(grep -ac "board sound: .* underruns in" "$c1")" -le 1 ] ||
	fail "the roll's stream: $roll_n reports, $roll_lo to $roll_hi ms ahead ($c1)"
echo "the roll: $roll_lo to $roll_hi ms ahead over $roll_n reports"
# [SKELDAT_BOARD_CLAP] A clack for each flight logged (those of 0.3 s and
# more; one of 0.15 clacks too), none at a jump: no sound is made for one
flights=$(grep -ac "skeldat: the board flew" "$c1")
clacks=$(grep -ac "skeldat: the board's clack at" "$c1")
[ "$flights" -ge 1 ] && [ "$clacks" -ge "$flights" ] ||
	fail "the landings' clacks: $clacks for $flights flights ($c1)"
echo "the board: $clacks clacks, $flights flights logged"
# [SKELDAT_SPLASH_TAKES] its onset from the walk's speed into it;
# [SKELDAT_SPLASH_F] its noise by the speed, under 1 at a walk's
grep -aq "skeldat: a splash at [0-9.]*, gain 0\.[0-9]*, onset [0-9.]* s, noise 0\.[0-9]*$" "$t/board2.log" ||
	fail "client2's splash ($t/board2.log)"
grep -aq "skeldat: client1 rides a board" "$t/board2.log" ||
	fail "client2 did not see client1 on a board ($t/board2.log)"
# [SKELDAT_BOARD_HIDE] the board hidden when the ride ends, its box too:
# the own and the other's
grep -aq "skeldat: the board hidden: false false" "$t/board1.log" ||
	fail "client1's board not hidden after the ride ($t/board1.log)"
grep -aq "skeldat: client1 walks" "$t/board2.log" ||
	fail "client2 did not see client1's board go ($t/board2.log)"
# 25. Free-running ([SERVER_FREE_RUN]): a 128 world, no player, at the
# real constants with --free-run. A game day (1200 s) after the world is
# in passes in well under its time, and its expansions are the day's (4
# sections, one each 150 s: 32). The same world in real time for 60 s
# takes about 60 s of game time (a bones line every 10). A client is
# turned away, and with --lan-announce the server does not start.
free()
{
	BUILDAT_SKELDAT_WORLD=free BUILDAT_SKELDAT_TERRAIN=flat BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="1 0 0" \
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
BUILDAT_SKELDAT_WORLD=hole BUILDAT_SKELDAT_TERRAIN=flat BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="2 -1 0" \
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
	wait_for_log "$t/srv32_$1.log" "skeldat: the score .* is [0-9]*\. of" 120 ||
		fail "no score recorded ($t/srv32_$1.log)"
	grep -a "skeldat: the score" "$t/srv32_$1.log" | sed 's/.*skeldat: //'
}
played="p01 30000; p02 29000; p03 28000; p04 27000; p05 26000; p06 25000; p07 24000; p08 23000; p09 22000; p10 21000; p11 20000; p12 1000"
BUILDAT_SKELDAT_PLAYED="$played" hs_w 1 w1 36000
s1=$(hs_end 1)
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
echo "$s1" | grep -q 'is 1\. of 1 in set/2/128/1/rivers ("w1")' &&
	echo "$s1" | grep -q "players: p01 8.3 h, .*p10 5.8 h, p11 5.6 h$" ||
	fail "w1's score, or its players: $s1 ($t/srv32_1.log)"
hs_w 2 w2 12000
s2=$(hs_end 2)
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
echo "$s2" | grep -q 'is 2\. of 2 in set/2/128/1/rivers ("w2"), best 30\.[01]' ||
	fail "w2 not second, or the set not named after it: $s2 ($t/srv32_2.log)"
printf '%s\n' "$placed" "delay 1500" "keypress Escape" "wait_log 5000 pause: the menu shown" \
	"delay 500" 'click Button "High scores..."' "wait_log 5000 pause: high scores shown" \
	"delay 500" 'click Button "w2:*"' "wait_log 5000 pause: scores of" \
	"delay 500" "screenshot $t/scores.png" quit > "$t/hs.cmds"
hs_w 3 w2_rerun 6000
s3=$(hs_end 3)
echo "$s3" | grep -q 'is 3\. of 3 in set/2/128/1/rivers ("w2"), best 30\.[01]' ||
	fail "the re-run's score, or the name it left: $s3 ($t/srv32_3.log)"
client hs "$t/hs.cmds"
wait $CLIENT || fail "the high scores drive ($t/hs.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
grep -aq "Best for these parameters: 30.0 days; this one is number 3" "$t/hs.log" &&
	grep -aq "pause: high scores shown, 1 sets" "$t/hs.log" &&
	grep -aq "pause: scores of set/2/128/1/rivers shown, 3 scores" "$t/hs.log" ||
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
# client joining is placed in it; its own Play again moves w_rerun to the
# trash and makes it again, no w_rerun_rerun.
log33="$t/srv33.log"
BUILDAT_SKELDAT_WORLD=w BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="1 -1 0" \
	BUILDAT_SKELDAT_FILL=surface start_server "$log33" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
	-D "$t/srv33" -C "$t/srv.cache" -l 3 || fail "the server ($log33)"
CHECK_PIDS+=($SERVER_PID)
again='wait_log_any 120000 skeldat: The bones cover the whole surface
delay 500
keypress Escape
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
wait_for_log "$log33" "re-run: w_rerun to the trash" 120 ||
	fail "the second re-run did not move w_rerun to the trash ($log33, $t/rr2.log)"
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
# down; main:10 picked again, a tap in the window's margin lets it go
# and leaves the window open ([SKELDAT_INV_DESELECT]); picked again, the
# drop key drops one, a tap outside the other, Q with none picked
# nothing ([SKELDAT_INV_DROP]); a tap outside the window closes it ([SKELDAT_INV_TAP_OUT], the slots' taps did not). More's Skateboard ([SKELDAT_TOUCH_BOARD]) tapped twice turns
# the board off and on. simplified: a tap on a mob, the board's brake
# by the stick and the pause menu's buttons by tap are not driven: the
# first is the place's own branch, the others are the keys' and the UI's.
log34="$t/srv34.log"
BUILDAT_SKELDAT_WORLD=touch BUILDAT_SKELDAT_TERRAIN=flat BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="2 -1 0" \
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
	echo "tap 333 253"; echo "delay 700"
	# [SKELDAT_INV_DESELECT] main:10 picked, let go by a tap in the
	# window's margin, which leaves it open
	echo "tap 310 253"; echo "delay 500"; echo "tap 300 175"
	echo "wait_log 3000 inventory: let go"; echo "delay 500"
	# [SKELDAT_INV_DROP] main:10's two picked: the drop key drops one, a
	# tap outside the other, the window open; the key with none picked
	# drops nothing
	echo "tap 310 253"; echo "delay 500"; echo "keypress Q"
	echo "wait_log 3000 inventory: drop 1"; echo "delay 500"; echo "tap 400 30"
	echo "wait_log 3000 inventory: drop 1"; echo "delay 500"; echo "keypress Q"
	echo "delay 500"
	# [SKELDAT_INV_TAP_OUT] closed by a tap outside it
	echo "tap 400 30"; echo "wait_log 3000 inventory: closed"; echo "delay 500"
	# More, then its sixth entry (Drop, Fly, Fast, Noclip, HUD, Skateboard)
	# twice: at this UI scale of 1.25 five fit, the sixth heads a second
	# column to the left
	echo "tap 739 94"; echo "delay 500"; echo "tap 601 182"; echo "delay 500"
	echo "tap 601 182"; echo "delay 500"
	echo quit
} > "$t/touch.cmds"
BUILDAT_TOUCH=1 client touch "$t/touch.cmds"
wait $CLIENT || fail "the touch drive ($t/touch.log)"
# [SKELDAT_HUD_PORTRAIT] Upright, 400 x 900: the HUD's scale is 2 (the
# windows' 1), the hotbar 364 wide from x 18, and a tap on slot 9 (x 360)
# selects it
printf '%s\n' "$placed" "delay 1500" "tap 360 876" "delay 500" \
	"screenshot $t/portrait.png" quit > "$t/portrait.cmds"
CLIENT_SIZE=400x900 BUILDAT_TOUCH=1 client portrait "$t/portrait.cmds"
wait $CLIENT || fail "the upright drive ($t/portrait.log)"
grep -aq "touch: hotbar slot 9" "$t/portrait.log" ||
	fail "slot 9 of the upright hotbar not tapped ($t/portrait.log, $t/portrait.png)"
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
[ "$(grep -ac "skeldat *: inventory: closed" "$t/touch.log")" = 1 ] &&
	[ "$(grep -ac "skeldat *: inventory: let go" "$t/touch.log")" = 1 ] &&
	[ "$(grep -ac "skeldat *: inventory: move" "$t/touch.log")" = 2 ] &&
	[ "$(grep -acE "client1 drops skeldat:stick( 1)? from me main:10" "$log34")" = 2 ] &&
	[ "$(grep -ac "a drop of " "$log34")" = 2 ] &&
	grep -aq "inventory: move 4 skeldat:stick craftresult:1 -> main:10" "$t/touch.log" &&
	grep -aq "inventory: move 2 skeldat:stick main:10 -> main:11" "$t/touch.log" ||
	fail "the inventory by finger ($t/touch.log)"
board=$(grep -a "touch: Skateboard\|skeldat: the skateboard " "$t/touch.log" |
	sed 's/.*\(touch: Skateboard\|skateboard o[nf]*\)$/\1/' | tr '\n' '|')
[ "$board" = "touch: Skateboard|skateboard off|touch: Skateboard|skateboard on|" ] ||
	fail "More's Skateboard: $board ($t/touch.log)"
echo "touch: strokes (push, moved) $strokes, a 50 pixel drag turned $turned degrees"
# 32. The picker's worlds and pause ([SKELDAT_WORLD_ADMIN]): 128 worlds of
# seed 2 on a launcher's server (-u launcher=1: a client on 127.0.0.1 is
# its own, world_menu's picker). "w2" made first; then in "w1" client1's
# pause menu pauses the world by itself and its close resumes it; Pause
# world holds the day and the world's age over 10 s (W held, its moves
# refused); Resume world; the menu open again pauses, and a second
# client's join resumes it. Worlds... lists w1 running, and w2's Play
# switches: client1 sent off, w2 starts. A client in w2 closes it from
# the same menu: no world runs; the next client gets the menu and plays
# w1 again, at the day it was closed with. Then on a server with no
# launcher a player's pause and Worlds... are refused.
# simplified: the steps that stand while paused are one return in
# on_tick; the day and m_world_t stand for them. A non-picker's wait
# after a close is world_menu's ([WORLD_MENU_ADMIN]'s check)
log35="$t/srv35.log"
wa_server() # <log> <world> [args]
{
	local log=$1 world=$2
	shift 2
	BUILDAT_SKELDAT_WORLD=$world BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="1 -1 0" \
		start_server "$log" "STATUS Listening" 300 auto \
		"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
		-D "$t/srv35" -C "$t/srv.cache" -l 3 "$@" || fail "the server ($log)"
	CHECK_PIDS+=($SERVER_PID)
}
wa_server "$t/srv35a.log" w2 -u launcher=1
wait_for_log "$t/srv35a.log" "the world is in" 120 || fail "w2 not made ($t/srv35a.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
wa_server "$log35" w1 -u launcher=1
cat > "$t/wa1.cmds" <<EOF
$placed
delay 1500
keypress Escape
wait_log 5000 skeldat: paused by client1 (the pause menu)
delay 500
keypress Escape
wait_log 5000 skeldat: running
delay 500
keypress Escape
wait_log 5000 pause: the menu shown
delay 500
click Button "Pause world"
wait_log 5000 skeldat: paused by client1
keydown W
delay 10000
keyup W
keypress Escape
wait_log 5000 pause: the menu shown
delay 500
click Button "Resume world"
wait_log 5000 skeldat: running
delay 500
keypress Escape
wait_log 5000 skeldat: paused by client1 (the pause menu)
wait_log 120000 skeldat: running
delay 500
keypress Escape
delay 500
keypress Escape
wait_log 5000 pause: the menu shown
delay 500
click Button "Worlds..."
wait_log 10000 world_menu: the list shown, 2 worlds
delay 500
click Button "w2"
wait_log 5000 world_menu: the list shown
delay 500
expect_error Disconnected from server: The server switches
click Button "Play"
wait_log 30000 Disconnected from server: The server switches to the world w2
quit
EOF
client wa1 "$t/wa1.cmds"; a=$CLIENT
for _ in $(seq 600); do
	# The third: the first two are the menu's before the picker's pause
	[ "$(grep -ac "paused the world (the pause menu)" "$log35")" -ge 3 ] && break
	kill -0 $a 2>/dev/null || break
	sleep 0.2
done
printf '%s\n' "$placed" "delay 1000" quit > "$t/wa2.cmds"
client wa2 "$t/wa2.cmds"; b2=$CLIENT
# A client the server sends off exits with an error: the drive's end
# is what says it went through
drove(){ ! grep -aq "Command sequence failed" "$1" && grep -aq "command: quit" "$1"; }
wait $a; drove "$t/wa1.log" || fail "the pause and the switch ($t/wa1.log)"
wait $b2 || fail "the second client ($t/wa2.log)"
wait_for_log "$log35" 'the world "w2" starts' 120 || fail "no switch to w2 ($log35)"
cat > "$t/wa3.cmds" <<EOF
$placed
delay 1500
keypress Escape
wait_log 5000 pause: the menu shown
delay 500
click Button "Worlds..."
wait_log 10000 world_menu: the list shown, 2 worlds
delay 500
expect_error Disconnected from server: The world w2 was closed
click Button "Close world"
wait_log 30000 Disconnected from server: The world w2 was closed
quit
EOF
client wa3 "$t/wa3.cmds"
wait $CLIENT; drove "$t/wa3.log" || fail "the close ($t/wa3.log)"
wait_for_log "$log35" "no world runs: the world menu" 60 || fail "w2 not closed ($log35)"
cat > "$t/wa4.cmds" <<EOF
wait_log 60000 world_menu: the list shown, 2 worlds
delay 1000
click Button "w1"
wait_log 5000 world_menu: the list shown
delay 500
click Button "Play"
$placed
delay 1000
quit
EOF
client wa4 "$t/wa4.cmds"
wait $CLIENT || fail "w1 played again ($t/wa4.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
paused=$(grep -a "client1 paused the world, day" "$log35" | sed 's/.*, day //')
resumed=$(grep -a "client1 resumed the world, day" "$log35" | sed 's/.*, day //')
[ -n "$paused" ] && [ "$paused" = "$resumed" ] ||
	fail "the world went on while paused: day $paused, then $resumed ($log35)"
grep -aq "client1's luanti:where refused: paused" "$log35" ||
	fail "client1's moves not refused while paused ($log35)"
grep -aq "client2 resumed the world (the pause menu)" "$log35" ||
	fail "a second client did not end the pause menu's pause ($log35)"
grep -aq "client1 switches the world to w2" "$log35" &&
	grep -aq "world_menu: close \"w2\"" "$log35" ||
	fail "the switch or the close ($log35)"
closed=$(grep -a 'the world "w1" closed for a reload, day' "$log35" | sed 's/.*, day //')
again=$(grep -a 'the world "w1" starts' "$log35" | sed -n 2p | sed 's/.*, day //')
[ -n "$closed" ] && [ "$closed" = "$again" ] ||
	fail "w1 did not come back at its day: closed at $closed, started at $again ($log35)"
log36="$t/srv36.log"
BUILDAT_SKELDAT_WORLD=w BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="1 -1 0" \
	start_server "$log36" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
	-D "$t/srv36" -C "$t/srv.cache" -l 3 || fail "the server ($log36)"
CHECK_PIDS+=($SERVER_PID)
printf '%s\n' "$placed" "delay 1000" "event skeldat_send pause on" \
	"event skeldat_send worlds" "event skeldat_send skip on" "delay 1000" quit \
	> "$t/wa5.cmds"
client wa5 "$t/wa5.cmds"
wait $CLIENT || fail "the player's requests ($t/wa5.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
grep -aq "client1's pause on refused: not the picker" "$log36" &&
	grep -aq "client1's Worlds... refused: not the picker" "$log36" &&
	grep -aq "client1's skip refused: not the picker" "$log36" &&
	! grep -aq "paused the world" "$log36" ||
	fail "a player's pause or Worlds... not refused ($log36)"
echo "worlds and pause: day $paused over 10 s paused, w1 closed at $closed and back at $again"
# 33. Skipping time ([SKELDAT_SKIP_TIME]): a 128 world of seed 2 at noon
# on a launcher's server, client1 the picker. Skip to sunset from the
# pause menu: it ends at day 0.75 or just past, the skeletons' sunset
# pick logged once, the expansions those due for the game time skipped
# (within 5%), no hit points lost; the wall time logged. Then a skip to
# sunrise stopped from the menu stands between the two. (A player's skip
# refused: 32's server with no launcher.) [SKELDAT_SKIP_DAWN] The skip
# to sunrise again, whole: it ends at 05:00 (day 0.2083), the sunrise's
# pick not in it; the menu's skip then is to sunset.
log37="$t/srv37.log"
BUILDAT_SKELDAT_WORLD=w BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="1 0 0" \
	BUILDAT_SKELDAT_TIME=0.5 start_server "$log37" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
	-D "$t/srv37" -C "$t/srv.cache" -l 3 -u launcher=1 || fail "the server ($log37)"
CHECK_PIDS+=($SERVER_PID)
cat > "$t/skip.cmds" <<EOF
$placed
delay 2000
keypress Escape
wait_log 5000 pause: the menu shown
delay 500
click Button "Skip to sunset"
wait_log 5000 skeldat: skipping to sunset
wait_log 60000 skeldat: running
delay 1000
keypress Escape
wait_log 5000 pause: the menu shown
delay 500
click Button "Skip to sunrise"
wait_log 5000 skeldat: skipping to sunrise
delay 1000
keypress Escape
wait_log 5000 pause: the menu shown
delay 300
click Button "Stop skipping"
wait_log 5000 skeldat: running
delay 1000
keypress Escape
wait_log 5000 pause: the menu shown
delay 500
click Button "Skip to sunrise"
wait_log 5000 skeldat: skipping to sunrise
wait_log 120000 skeldat: running
delay 1000
keypress Escape
wait_log 5000 pause: the menu shown
delay 500
click Button "Skip to sunset"
wait_log 5000 skeldat: skipping to sunset
delay 500
keypress Escape
wait_log 5000 pause: the menu shown
delay 300
click Button "Stop skipping"
wait_log 5000 skeldat: running
delay 1000
quit
EOF
client skip "$t/skip.cmds"
wait $CLIENT || fail "the skips ($t/skip.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
done_line=$(grep -a "the skip to sunset done" "$log37" | sed 's/.*done: //')
stopped=$(grep -a "the skip to sunrise stopped by client1" "$log37" | sed 's/.*client1: //')
echo "skip: to sunset $done_line; to sunrise $stopped"
echo "$done_line" | awk '{ d = $10 + 0; e = $11 + 0; due = substr($13, 2) + 0
	exit !(d >= 0.75 && d < 0.751 && (e - due) ^ 2 <= (due * 0.05 > 1 ? due * 0.05 : 1) ^ 2) }' ||
	fail "the skip to sunset: $done_line ($log37)"
[ "$(awk '/skips to sunset/ { on = 1 } /the skip to sunset done/ { on = 0 } on && /skeldat: sunset: / { n++ } END { print n + 0 }' "$log37")" = 1 ] ||
	fail "the sunset's pick not logged once in the skip ($log37)"
# Unharmed in the skips; after the second (at night) the skeletons may hit
[ "$(awk '/ skips to / { on = 1 } /the skip to / { on = 0 } on && /client1 .* hp left/ { n++ } END { print n + 0 }' "$log37")" = 0 ] ||
	fail "client1 hurt in a skip ($log37)"
echo "$stopped" | awk '{ d = $10 + 0; exit !(d > 0.751 || d < 0.249) }' ||
	fail "the stopped skip did not stand between: $stopped ($log37)"
dawn=$(grep -a "the skip to sunrise done" "$log37" | sed 's/.*done: //')
echo "$dawn" | awk '{ d = $10 + 0; exit !(d >= 0.2083 && d < 0.2085) }' ||
	fail "the skip to dawn: ${dawn:-none} ($log37)"
[ "$(awk '/skips to dawn \(05:00\)/ { on = 1 } /the skip to sunrise done/ { on = 0 } on && /skeldat: sunrise: / { n++ } END { print n + 0 }' "$log37")" = 0 ] &&
	[ "$(grep -ac "client1 skips to sunset" "$log37")" = 2 ] ||
	fail "the sunrise's pick in the skip to dawn, or no skip to sunset after it ($log37)"
echo "skip: to dawn $dawn"
# 34. The stars round the moon's axis ([STARS_AXIS]): at 23:31 in a
# 128 world, the camera fixed on the moon high in the south, two
# screenshots 5 s (30 game minutes, DAY 240) apart: the stars near the
# moon matched between them keep their angle from it -- the median change
# under half a degree over five or more (the old turn about Z: 1.4)
log38="$t/srv38.log"
BUILDAT_SKELDAT_WORLD=sky BUILDAT_SKELDAT_TERRAIN=flat BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="1 -1 0" \
	BUILDAT_SKELDAT_TIME=0.98 BUILDAT_SKELDAT_DAY=240 BUILDAT_SKELDAT_SPAWN="0 0" \
	start_server "$log38" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
	-D "$t/srv38" -C "$t/srv.cache" -l 3 || fail "the server ($log38)"
CHECK_PIDS+=($SERVER_PID)
printf '%s\n' "$placed" "delay 3000" "look_dir 0 0.92 0.39" "delay 8000" \
	"screenshot $t/sky_a.png" "delay 5000" "screenshot $t/sky_b.png" quit \
	> "$t/sky.cmds"
client sky "$t/sky.cmds"
wait $CLIENT || fail "the night sky's drive ($t/sky.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
stars=$(python3 -I - "$t/sky_a.png" "$t/sky_b.png" <<'PY'
import sys, math, struct, zlib
def png(path):
    d = open(path, 'rb').read()
    w, h = struct.unpack('>II', d[16:24]); bd, ct = d[24], d[25]
    assert bd == 8 and ct in (2, 6)
    n = 3 if ct == 2 else 4
    idat = b''; i = 8
    while i < len(d):
        l = struct.unpack('>I', d[i:i+4])[0]; t = d[i+4:i+8]
        if t == b'IDAT': idat += d[i+8:i+8+l]
        i += 12 + l
    raw = zlib.decompress(idat); stride = w * n
    out = []; prev = bytearray(stride); p = 0
    for y in range(h):
        f = raw[p]; line = bytearray(raw[p+1:p+1+stride]); p += 1 + stride
        for x in range(stride):
            a = line[x-n] if x >= n else 0; b = prev[x]; c = prev[x-n] if x >= n else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                pp = a + b - c; pa, pb, pc = abs(pp-a), abs(pp-b), abs(pp-c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        out.append([sum(line[x*n:x*n+3]) for x in range(w)]); prev = line
    return w, h, out
def find(path):
    w, h, img = png(path)
    H = h - 70
    # the crosshair out
    for y in range(h // 2 - 9, h // 2 + 10):
        for x in range(w // 2 - 9, w // 2 + 10):
            img[y][x] = 0
    top = max(max(r) for r in img[:H])
    core = [(x, y) for y in range(H) for x in range(w) if img[y][x] >= 0.8 * top]
    mc = (sum(p[0] for p in core) / len(core), sum(p[1] for p in core) / len(core))
    r2 = max((p[0]-mc[0])**2 + (p[1]-mc[1])**2 for p in core)
    stars = []
    for y in range(4, H - 4):
        row = img[y]
        for x in range(4, w - 4):
            v = row[x]
            if v < 20 or (x-mc[0])**2 + (y-mc[1])**2 < r2 * 4:
                continue
            if any(img[y+dy][x+dx] > v or (img[y+dy][x+dx] == v and (dy, dx) < (0, 0))
                    for dy in (-1, 0, 1) for dx in (-1, 0, 1) if dx or dy):
                continue
            low = min(img[y+dy][x+dx] for dy in (-4, 0, 4) for dx in (-4, 0, 4))
            if v - low >= 15:
                stars.append((x, y))
    return w, h, mc, stars, len(core)
fov = float(sys.argv[3]) if len(sys.argv) > 3 else 72
def ray(w, h, p):
    f = (h / 2) / math.tan(math.radians(fov) / 2)
    v = (p[0] - w / 2, -(p[1] - h / 2), f)
    l = math.sqrt(sum(c * c for c in v)); return [c / l for c in v]
def ang(a, b):
    return math.degrees(math.acos(max(-1, min(1, sum(x * y for x, y in zip(a, b))))))
wa, ha, ma, sa, na = find(sys.argv[1])
wb, hb, mb, sb, nb = find(sys.argv[2])
print("moon at %.1f,%.1f (%d px) and %.1f,%.1f (%d px); %d and %d stars" % (ma + (na,) + mb + (nb, len(sa), len(sb))))
ra, rb = ray(wa, ha, ma), ray(wb, hb, mb)
print("the moon moved %.2f degrees" % ang(ra, rb))
diffs = []
near = sorted(sa, key=lambda s: ang(ray(wa, ha, s), ra))[:12]
for s in near:
    guess = (s[0] - ma[0] + mb[0], s[1] - ma[1] + mb[1])
    t = min(sb, key=lambda q: (q[0]-guess[0])**2 + (q[1]-guess[1])**2)
    if (t[0]-guess[0])**2 + (t[1]-guess[1])**2 > 15**2: continue
    # one star in b for one in a: the nearest a star to it is this one
    back = min(sa, key=lambda q: (q[0]-t[0]+mb[0]-ma[0])**2 + (q[1]-t[1]+mb[1]-ma[1])**2)
    if back != s: continue
    a1, a2 = ang(ray(wa, ha, s), ra), ang(ray(wb, hb, t), rb)
    diffs.append(a2 - a1)
    print("star %.0f,%.0f -> %.0f,%.0f: %.2f -> %.2f degrees from the moon" % (s + t + (a1, a2)))
ad = sorted(abs(d) for d in diffs)
med = ad[len(ad) // 2] if ad else 99
print("matched %d, the median change %.2f degrees" % (len(ad), med))
sys.exit(0 if len(ad) >= 5 and med < 0.5 else 1)
PY
) || fail "the stars moved against the moon: $(echo "$stars" | tail -1) ($t/sky_a.png, $t/sky_b.png)"
echo "stars: $(echo "$stars" | tail -1)"
# 35. The bow on the move ([SKELDAT_BOW_AIM]): on 24's course, a bow and
# arrows, the ride down the slope looking to the side: five short draws
# at different moments of the 0.1 s where, then one lying flat. Each
# arrow starts on the crosshair's line: from the eye the client released
# at, within 0.3; the server's copy, its where applied at the release,
# under 1.5 off (before: 1.4 to 6.1, up to 0.3 s old); flat, 0.5 and a
# little over the feet. Then standing, the eye said 5
# off (BUILDAT_SKELDAT_EYE_SHIFT): refused, the copy's used
log39="$t/srv39.log"
aim_server() # <log> [the eye's shift]
{
	local log=$1
	BUILDAT_SKELDAT_EYE_SHIFT=${2:-0} BUILDAT_SKELDAT_WORLD=aim BUILDAT_SKELDAT_TERRAIN=flat BUILDAT_SKELDAT_SEED=2 \
		BUILDAT_SKELDAT_SIZE="2 -1 2" BUILDAT_SKELDAT_TIME=0.5 \
		BUILDAT_SKELDAT_SPAWN="0 0" BUILDAT_SKELDAT_SKELETONS=0 \
		BUILDAT_SKELDAT_TEST="give skeldat:bow 1 1; give skeldat:arrow 20 1; course -40 -20" \
		start_server "$log" "STATUS Listening" 300 auto \
		"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
		-D "${log%.log}" -C "$t/srv.cache" -l 3 || fail "the server ($log)"
	CHECK_PIDS+=($SERVER_PID)
}
quick() { printf '%s\n' "mouse_down left" "delay 300" "mouse_up left" "delay $1"; }
{ echo "$placed"; echo "wait_log 60000 skeldat: placed at (-40.0,"
	echo "delay 1500"; echo "look 90 0"; echo "delay 1000"; echo "keydown W"
	# W held over the ride: with it Camera steer leaves the board on its
	# way while the look turns ([SKELDAT_CAMERA_STEER])
	echo "wait_log 5000 skeldat: on the board"
	echo "delay 600"; echo "look 0 0"
	quick 130; quick 160; quick 110; quick 190; quick 150
	echo "keydown Left Shift"; echo "delay 700"; quick 200
	echo "keyup Left Shift"; echo "keyup W"; echo "delay 1500"; echo quit; } > "$t/aim1.cmds"
aim_server "$log39"
client aim1 "$t/aim1.cmds"
wait $CLIENT || fail "the ride's drive ($t/aim1.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
aim=$(python3 -I - "$t/aim1.log" "$log39" <<'PY'
import re, sys
rel = [tuple(map(float, m.groups())) for m in (re.search(
    r"the bow released at [0-9.]+ from ([-0-9.]+),([-0-9.]+),([-0-9.]+)", l)
    for l in open(sys.argv[1], errors="replace")) if m]
shots = [tuple(map(float, m.groups())) for m in (re.search(
    r"client1 shoots an arrow at [0-9.]+ \(drawn [0-9.]+\) from ([-0-9.]+),"
    r"([-0-9.]+),([-0-9.]+) \(the copy's ([0-9.]+) off; the feet at ([-0-9.]+)\)",
    l) for l in open(sys.argv[2], errors="replace")) if m]
assert len(rel) == 6 and len(shots) == 6, "%d releases, %d shots" % (len(rel), len(shots))
gaps = [sum((a - b) ** 2 for a, b in zip(r, s[:3])) ** 0.5 for r, s in zip(rel, shots)]
assert max(gaps) < 0.3, "the arrows from %s off the eyes" % gaps
# The copy too, its where applied at the release (luanti's session
# applies them every 0.2 s): no more than the wire's wait behind
assert max(s[3] for s in shots) < 1.5, "the copy's off: %s" % [s[3] for s in shots]
flat = shots[5][1] - shots[5][4]
assert 0.45 < flat < 0.8, "lying flat, the eye %.2f over the feet" % flat
print("the eyes within %.3f; the copy's off %s; flat %.2f over the feet" % (
    max(gaps), " ".join("%.2f" % s[3] for s in shots), flat))
PY
) || fail "the bow on the move: $aim ($t/aim1.log, $log39)"
echo "the bow on the move: $aim"
printf '%s\n' "$placed" "wait_log 60000 skeldat: placed at (-40.0," "delay 1500" \
	"mouse_down left" "delay 500" "mouse_up left" "delay 3000" quit > "$t/aim2.cmds"
aim_server "$t/srv39b.log" 5
client aim2 "$t/aim2.cmds"
wait $CLIENT || fail "the shifted eye's drive ($t/aim2.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
grep -aq "client1's eye at the release refused (5\.0[0-9] off" "$t/srv39b.log" &&
	grep -aq "client1 shoots an arrow at .* (the copy's 0.00 off" "$t/srv39b.log" ||
	fail "an eye 5 off was not refused ($t/srv39b.log)"
# 36. The skateboard turned off ([SKELDAT_BOARD_TOGGLE]): F logs it off,
# the game's storage keeps "1", and the client started again reads it
log40="$t/srv40.log"
BUILDAT_SKELDAT_WORLD=w BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="1 -1 0" \
	start_server "$log40" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
	-D "$t/srv40" -C "$t/srv.cache" -l 3 || fail "the server ($log40)"
CHECK_PIDS+=($SERVER_PID)
printf '%s\n' "$placed" "delay 1000" "keypress F" \
	"wait_log 5000 skeldat: the skateboard off" "delay 500" \
	"screenshot $t/board_off.png" quit > "$t/toggle1.cmds"
client toggle "$t/toggle1.cmds"
wait $CLIENT || fail "the toggle's drive ($t/toggle.log)"
cp "$t/toggle.log" "$t/toggle1.log"
kept_file=$(find "$t/u_toggle" -name board_off | head -1)
[ -n "$kept_file" ] && [ "$(cat "$kept_file")" = 1 ] ||
	fail "the board's off not kept in the game's storage ($t/u_toggle)"
printf '%s\n' "$placed" "delay 500" quit > "$t/toggle2.cmds"
client toggle "$t/toggle2.cmds"
wait $CLIENT || fail "the toggle's second drive ($t/toggle.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
grep -aq "skeldat: the skateboard off (kept)" "$t/toggle.log" ||
	fail "the client started again did not read the board's off ($t/toggle.log)"
echo "the skateboard: off by F, kept in $(basename "$(dirname "$kept_file")")/board_off"
# 37. Bridges on the long walk ([SKELDAT_BRIDGES_SEEN]), as 22 at night:
# a skeleton whose goal section (x < 0) is past a river 8 wide in its
# own (level: markers follow the ground's top; 94 long, z -30..63, so a
# skeleton's detours do not take it round an end), the walk's
# waypoint past it, builds a line at one height over the water; one on a
# stone tower 8 high at x 18..23 (8 markers stacked a column; no tree
# near), its goal section off
# the -x side, builds down the
# face, top first. Their "finds a way to" are the walk's waypoints
log41="$t/srv41.log"
seen=$(echo 'level 3 -30 8 94 skeldat:water_source -1; '
for z in $(seq -45 -40); do for x in $(seq 18 23); do for y in $(seq 0 7); do
	printf 'marker %d %d skeldat:stone 0; ' $x $z; done; done; done)
BUILDAT_SKELDAT_WORLD=seen BUILDAT_SKELDAT_TERRAIN=flat BUILDAT_SKELDAT_STILL_WATER=1 BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="2 -1 0" \
	BUILDAT_SKELDAT_TIME=0.8 BUILDAT_SKELDAT_SPAWN="0 0" BUILDAT_SKELDAT_DAY=600 \
	BUILDAT_SKELDAT_LIGHT_STEP=0.2 \
	BUILDAT_SKELDAT_TEST="${seen}skeleton 16 0 marked goal -40 30; skeleton 20 -42 marked goal -40 -42; place 100 0" \
	start_server "$log41" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
	-D "$t/srv41" -C "$t/srv.cache" -l 3 || fail "the server ($log41)"
CHECK_PIDS+=($SERVER_PID)
printf '%s\n' "$placed" "delay 60000" quit > "$t/seen.cmds"
client seen "$t/seen.cmds"
wait $CLIENT || fail "the bridges' drive ($t/seen.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
set -- $(grep -a "test: a skeleton (" "$log41" | sed 's/.*(\([0-9]*\)).*/\1/')
river=$(grep -a "skeleton ($1) builds" "$log41" | sed 's/.* at //')
cliff=$(grep -a "skeleton ($2) builds" "$log41" | sed 's/.* at //')
echo "bridges: the river $(echo $river); the cliff $(echo $cliff)"
grep -a "skeleton ($1) finds a way to\|skeleton ($2) finds a way to" "$log41" | head -4
# the river: 6 or more at one height, over x 3..10 (one off the bank
# allowed for where it starts; the first and the last may climb to a
# higher bank's, the own terrain's banks uneven)
[ "$(echo "$river" | awk -F, '$1 >= 2 && $1 <= 11 {print $2}' | sort | uniq -c |
	sort -rn | awk 'NR == 1 {print $1}')" -ge 6 ] 2>/dev/null ||
	fail "no line over the river ($log41)"
# to the far bank: the last column's (x 3) built
echo "$river" | grep -q "^3," || fail "the bridge short of the far bank ($log41)"
# the cliff: 3 or more, and the heights never going up
[ "$(echo "$cliff" | grep -c .)" -ge 3 ] &&
	echo "$cliff" | cut -d, -f2 | awk 'NR > 1 && $1 > p {exit 1} {p = $1}' ||
	fail "no blocks down the cliff, top first ($log41)"
# 38. Loot on the ground ([SKELDAT_LOOT_GROUND]) at noon: a drop 2.5 off
# is picked up where the player stands, one 3.5 off is not; a boar at 1
# hp 4 ahead (a voxel up: aimed level) killed by a hit leaves its meat
# there, not taken until the player walks to it; a stone dropped by Q is
# not taken back until the player has walked 3 off it and back
log42="$t/srv42.log"
BUILDAT_SKELDAT_WORLD=loot BUILDAT_SKELDAT_TERRAIN=flat BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="2 -1 0" \
	BUILDAT_SKELDAT_TIME=0.5 BUILDAT_SKELDAT_SPAWN="0 0" BUILDAT_SKELDAT_SKELETONS=0 \
	BUILDAT_SKELDAT_TEST="give skeldat:stone 5 1; drop 2.5 0 skeldat:dirt 1; drop -3.5 0 skeldat:cobble 1; boar 0 4 hp 1" \
	start_server "$log42" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
	-D "$t/srv42" -C "$t/srv.cache" -l 3 || fail "the server ($log42)"
CHECK_PIDS+=($SERVER_PID)
printf '%s\n' "$placed" "look 0 -13" "delay 1000" "screenshot $t/loot_boar.png" "mouse_down left" "delay 100" \
	"mouse_up left" "delay 2000" "keypress Q" "delay 2000" "keydown S" \
	"delay 800" "keyup S" "keydown W" "delay 3000" "keyup W" "delay 1000" \
	quit > "$t/loot.cmds"
client loot "$t/loot.cmds"
wait $CLIENT || fail "the loot's drive ($t/loot.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
grep -a "dies at\|picks up\|a drop of" "$log42" | sed 's/.*skeldat: //'
python3 -I - "$log42" <<'PY' || fail "the loot on the ground ($log42)"
import sys, re
lines = open(sys.argv[1], errors="replace").read().split("\n")
def ts(l):
    m = re.search(r" (\d\d):(\d\d):(\d\d)\.(\d\d\d) ", l)
    return int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3)) + int(m.group(4)) / 1000
def at(s):
    return [ts(l) for l in lines if s in l]
assert at("client1 picks up 1 skeldat:dirt"), "the drop 2.5 off not picked up"
assert not at("picks up 1 skeldat:cobble"), "the drop 3.5 off picked up"
died = [ts(l) for l in lines if re.search(r"the boar \(\d+\) dies at .*, drops on the ground \[skeldat:meat_raw", l)]
assert died, "the boar's meat not dropped on the ground"
meat = [ts(l) for l in lines if re.search(r"client1 picks up \d skeldat:meat_raw", l)]
assert meat and meat[0] - died[0] > 3, "the meat taken %s after the kill" % (meat and "%.1f s" % (meat[0] - died[0]))
q = at("a drop of skeldat:stone at")
stone = at("client1 picks up 1 skeldat:stone")
assert q and stone and stone[0] - q[0] > 2.5, "the Q drop taken back %s" % (stone and q and "%.1f s after" % (stone[0] - q[0]))
print("ok: the meat taken %.1f s after the kill, the stone %.1f s after Q" % (meat[0] - died[0], stone[0] - q[0]))
PY
# 39. A dedicated server starts the world that ran at its exit
# ([SKELDAT_RESUME_WORLD]): 32's directory, w1 running when it was
# stopped. A start with no launcher and no BUILDAT_SKELDAT_WORLD runs w1
# again; a launcher's start is the menu, where w1 is played and closed;
# the next start with no launcher is the menu. 32's second directory ran
# "w": with that save deleted the start says so and is the menu, and the
# one after says nothing, the name gone.
rw_server() # <log> <dir> [args]: no world named, no launch; 32's size
{
	local log=$1 dir=$2
	shift 2
	BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="1 -1 0" start_server "$log" "STATUS Listening" 300 auto \
		"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
		-D "$dir" -C "$t/srv.cache" -l 3 "$@" || fail "the server ($log)"
	CHECK_PIDS+=($SERVER_PID)
}
rw_server "$t/srv43a.log" "$t/srv35"
wait_for_log "$t/srv43a.log" "the world is in" 120 &&
	grep -aq "skeldat: resumed the world w1" "$t/srv43a.log" ||
	fail "w1 not resumed ($t/srv43a.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
rw_server "$t/srv43b.log" "$t/srv35" -u launcher=1
cat > "$t/rw1.cmds" <<EOF
wait_log 60000 world_menu: the list shown, 2 worlds
delay 1000
click Button "w1"
wait_log 5000 world_menu: the list shown
delay 500
click Button "Play"
$placed
delay 1500
keypress Escape
wait_log 5000 pause: the menu shown
delay 500
click Button "Worlds..."
wait_log 10000 world_menu: the list shown, 2 worlds
delay 500
expect_error Disconnected from server: The world w1 was closed
click Button "Close world"
wait_log 30000 Disconnected from server: The world w1 was closed
quit
EOF
client rw1 "$t/rw1.cmds"
wait $CLIENT; drove "$t/rw1.log" || fail "w1's close ($t/rw1.log)"
wait_for_log "$t/srv43b.log" "no world runs: the world menu" 60 ||
	fail "w1 not closed ($t/srv43b.log)"
! grep -aq "skeldat: resumed the world" "$t/srv43b.log" ||
	fail "a launcher's start resumed a world ($t/srv43b.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
rw_server "$t/srv43c.log" "$t/srv35"
sleep 5
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
! grep -aq "skeldat: resumed the world\|the world is in" "$t/srv43c.log" ||
	fail "a world started after a close ($t/srv43c.log)"
rm -r "$t/srv36/apps/skeldat/saves/w"
rw_server "$t/srv43d.log" "$t/srv36"
sleep 3
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
rw_server "$t/srv43e.log" "$t/srv36"
sleep 3
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
grep -aq "skeldat: the world w that ran at exit is gone: the menu" "$t/srv43d.log" &&
	! grep -aq "ran at exit\|skeldat: resumed" "$t/srv43e.log" ||
	fail "a deleted world's name ($t/srv43d.log, $t/srv43e.log)"
echo "the world at exit: w1 resumed, the menu after its close, a deleted one's name dropped"
# 40. The sounds heard ([SKELDAT_SOUNDS_HEARD]): two clients at noon,
# one with a bow; its arrow shot into the ground at its feet sticks and
# is picked up. The shooter's client hears the landing "near 16" and its
# pickup as its own; the other the landing and the pickup placed, neither
# near nor own. The sounds' self check hashes the pickup, the user's take
# as made, and logs its level ([SKELDAT_PICKUP_TAKE]), and the step on
# grass, and the other steps on grass ([SKELDAT_STEP_GRASS]); the cave
# music's dark air search passes its self test of the plan's made-up caves
# ([SKELDAT_CAVE_MUSIC_DARK]), and its limit its timeline of a minute of 6
# s and a day of 20 ([SKELDAT_CAVE_MUSIC_LIMIT]); the camera has the
# sound listener the placed sounds need ([SKELDAT_LISTENER]).
log44="$t/srv44.log"
BUILDAT_SKELDAT_WORLD=sounds BUILDAT_SKELDAT_TERRAIN=flat BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="1 -1 0" \
	BUILDAT_SKELDAT_TIME=0.5 BUILDAT_SKELDAT_SPAWN="0 0" BUILDAT_SKELDAT_SKELETONS=0 \
	BUILDAT_SKELDAT_TEST="give skeldat:bow 1 1; give skeldat:arrow 3 1" \
	start_server "$log44" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
	-D "$t/srv44" -C "$t/srv.cache" -l 3 || fail "the server ($log44)"
CHECK_PIDS+=($SERVER_PID)
{ echo "$placed"; echo "delay 8000"; echo "look 0 -60"; echo "delay 500"
	echo "mouse_down left"; echo "delay 2500"; echo "mouse_up left"
	echo "delay 4000"; echo quit; } > "$t/snd1.cmds"
# The other steps back, out of the arrow's reach; after the pickup, a walk
# to the side on the grass
printf '%s\n' "$placed" "keydown S" "delay 800" "keyup S" "delay 14700" \
	"keydown D" "delay 800" "keyup D" "delay 1500" quit > "$t/snd2.cmds"
client snd1 "$t/snd1.cmds"
p1=$CLIENT
# The first to join has the bow (the test's give)
wait_for_log "$t/snd1.log" "skeldat: placed at" 300 || fail "the shooter not placed ($t/snd1.log)"
client snd2 "$t/snd2.cmds"
wait $p1 || fail "the shooter's drive ($t/snd1.log)"
wait $CLIENT || fail "the other's drive ($t/snd2.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
grep -aq "picks up an arrow" "$log44" &&
	grep -aq "skeldat: sound arrow_land at .* near 16" "$t/snd1.log" &&
	grep -aq "skeldat: sound_own pickup" "$t/snd1.log" &&
	! grep -aq "skeldat: sound pickup at" "$t/snd1.log" &&
	grep -aq "skeldat: sound arrow_land at" "$t/snd2.log" &&
	! grep -aq "near 16\|sound_own" "$t/snd2.log" &&
	grep -aq "skeldat: sound pickup at" "$t/snd2.log" ||
	fail "the shooter's own and the other's placed sounds ($log44, $t/snd1.log, $t/snd2.log)"
grep -aqE "self-check passed, bow [0-9a-f]{8} \([0-9]+ samples\), pickup [0-9a-f]{8} \([0-9]+ samples\), step_grass [0-9a-f]{8} " "$t/snd1.log" &&
	grep -aq "skeldat: step skeldat:grass" "$t/snd2.log" &&
	grep -aq "levels: pickup peak " "$t/snd1.log" &&
	grep -aq "skeldat: the sound listener on the camera" "$t/snd1.log" &&
	grep -aq "skeldat: cave dark: self test passed" "$t/snd1.log" &&
	grep -aq "skeldat: music limit: self test passed" "$t/snd1.log" ||
	fail "no pickup or step_grass hash, level line, sound listener, step on grass or cave dark self test ($t/snd1.log, $t/snd2.log)"
echo "sounds heard: $(grep -a "levels: " "$t/snd1.log" | head -1 | sed 's/.*levels: //; s/, the draw.*//')"
# 41. The world's making over its map ([SKELDAT_MAKING_MAP]): a new 512
# world of seed 2. client1 joined before the making waits in the stripes
# (world_menu's wait) over the map: its first packet 8 x 8 footprints,
# footprints mapped as they come in, a screenshot a few seconds in, off
# once the world is in, and then placed. client2, joined half way, gets
# what was mapped before it in one go and ends with the same footprints.
# simplified: the screenshots are for the eye, not compared
log45="$t/srv45.log"
BUILDAT_SKELDAT_WORLD=making BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="4 -1 0" \
	start_server "$log45" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
	-D "$t/srv45" -C "$t/srv.cache" -l 3 || fail "the server ($log45)"
CHECK_PIDS+=($SERVER_PID)
printf '%s\n' "wait_log 120000 making_map: first packet" "delay 3000" \
	"screenshot $t/making1.png" "$placed" \
	"delay 500" quit > "$t/mk1.cmds"
printf '%s\n' "wait_log 120000 making_map: first packet" "delay 1000" \
	"screenshot $t/making2.png" "$placed" \
	"delay 500" quit > "$t/mk2.cmds"
client mk1 "$t/mk1.cmds"
p1=$CLIENT
wait_for_log "$log45" "sections loaded" 300 || fail "the making did not start ($log45)"
client mk2 "$t/mk2.cmds"
wait $p1 || fail "the first client's wait ($t/mk1.log)"
wait $CLIENT || fail "the second client's wait ($t/mk2.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
m1=$(grep -ac "making_map: footprint .* mapped" "$t/mk1.log")
m2=$(grep -ac "making_map: footprint .* mapped" "$t/mk2.log")
# "off" is logged right before "placed at": checked after, as a wait for
# it could start after the placing
grep -aq "making_map: first packet, 8 x 8 footprints" "$t/mk1.log" &&
	grep -aq "making_map: off" "$t/mk1.log" &&
	grep -aq "making_map: off" "$t/mk2.log" &&
	grep -aq "world_menu: the wait shown" "$t/mk1.log" &&
	[ "$m1" -ge 1 ] && [ "$m1" = "$m2" ] ||
	fail "the making's map: client1 $m1 footprints mapped, client2 $m2 ($t/mk1.log, $t/mk2.log)"
echo "the making's map: $m1 footprints mapped on each, $(grep -a "the world is in" "$log45" | sed 's/.*skeldat: //')"
# 42. Back dead ([SKELDAT_DEAD_REJOIN]): a public server with its world
# running (no guest join); bob, the admin by the setup code, drowns at
# the spawn, quits on the death screen and joins again on the same
# server: the death screen again, and Respawn places bob with full hp.
# Before it, the pause menu over the death screen ([SKELDAT_DEATH_PAUSE])
# has "My account (bob)...", accounts' page, whose Back comes back to
# the menu ([SKELDAT_PAUSE_ACCOUNT]).
log46="$t/srv46.log"
BUILDAT_SKELDAT_GUEST_JOIN= BUILDAT_SKELDAT_WORLD=dead BUILDAT_SKELDAT_TERRAIN=flat BUILDAT_SKELDAT_SEED=2 \
	BUILDAT_SKELDAT_SIZE="2 -1 0" BUILDAT_SKELDAT_TIME=0.5 \
	BUILDAT_SKELDAT_SPAWN="0 0" BUILDAT_SKELDAT_SKELETONS=0 \
	BUILDAT_SKELDAT_TEST="$water" \
	start_server "$log46" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
	-D "$t/srv46" -C "$t/srv.cache" -l 3 || fail "the server ($log46)"
CHECK_PIDS+=($SERVER_PID)
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$log46" | head -1)
[ -n "$code" ] || fail "no setup code ($log46)"
printf '%s\n' "wait_log_any 60000 accounts: ntfy asked" \
	"wait_log_any 5000 server window: the page ntfy" "delay 300" \
	"click Button \"Don't add\"" \
	"wait_log_any 120000 pause: the death screen shown" "delay 2000" \
	quit > "$t/dead1.cmds"
printf '%s\n' "wait_log_any 120000 pause: the death screen shown" \
	"delay 1000" "screenshot $t/dead_back.png" "keypress Escape" \
	"wait_log 5000 pause: the menu shown" "delay 500" \
	'click Button "My account (bob)..."' "wait_log 5000 server window: the page" \
	"delay 500" "screenshot $t/my_account.png" 'click Button "Back"' \
	"wait_log 5000 pause: the menu shown" "delay 500" \
	'click Button "Continue"' "wait_log 5000 pause: back to the death screen" \
	"delay 500" 'click Button "Respawn"' \
	"wait_log 30000 skeldat: placed at" "delay 1000" quit > "$t/dead2.cmds"
for n in 1 2; do
	BUILDAT_JOIN_NAME=bob BUILDAT_JOIN_PASSWORD=secret123 \
		BUILDAT_JOIN_CREATE=$([ $n = 1 ] && echo 1) \
		BUILDAT_JOIN_CODE=$([ $n = 1 ] && echo "$code") \
		client dead$n "$t/dead$n.cmds"
	wait $CLIENT || fail "the dead rejoin's drive $n ($t/dead$n.log)"
done
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
grep -aq "skeldat: bob dies at" "$log46" &&
	grep -aq "skeldat: hp 20 " "$t/dead2.log" ||
	fail "bob not back from the dead: $(grep -a "pause: the death\|skeldat: hp\|placed at" "$t/dead2.log" | sed 's/.*: skeldat: \|.*: pause: //' | tr '\n' ';') ($t/dead2.log, $log46)"
echo "back dead: the death screen on the rejoin, Respawn placed bob"
# 43. A headshot ([SKELDAT_HEADSHOT]): section 23's skeleton 6 ahead at
# midnight, the launcher's client invulnerable; one full draw aimed 12
# degrees up, at its head (1.5 to 2 over its feet), kills it. A body's
# hit leaves it alive: section 23's first shot.
log47="$t/srv47.log"
BUILDAT_SKELDAT_WORLD=headshot BUILDAT_SKELDAT_TERRAIN=flat BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="2 -1 0" \
	BUILDAT_SKELDAT_TIME=0 BUILDAT_SKELDAT_SPAWN="0 0" BUILDAT_SKELDAT_DAY=2400 \
	BUILDAT_SKELDAT_TEST="give skeldat:bow 1 1; give skeldat:arrow 1 1; skeleton 0 6 marked" \
	start_server "$log47" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
	-D "$t/srv47" -C "$t/srv.cache" -l 3 -u launcher=1 || fail "the server ($log47)"
CHECK_PIDS+=($SERVER_PID)
{ echo "$placed"; toggle; echo "look 0 3"; echo "delay 1000"
	shot 1200; echo "delay 1000"; echo quit; } > "$t/head.cmds"
client head "$t/head.cmds"
wait $CLIENT || fail "the headshot's drive ($t/head.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
[ "$(grep -ac "client1 shoots an arrow" "$log47")" = 1 ] &&
	grep -aq "skeldat: client1's headshot kills the skeleton (1)" "$log47" &&
	grep -aq "the skeleton (1) dies" "$log47" ||
	fail "one arrow at the head did not kill: $(grep -a "client1 shoots\|hits the\|headshot" "$log47" | sed 's/.*skeldat: //' | tr '\n' ';') ($log47)"
echo "a headshot: one arrow killed the skeleton"
# 44. Boars kept to the grass ([SKELDAT_BOAR_GRASS]), a game day of 20 s:
# a boar on a stone (the ground's top 6 east made stone) dies off the
# grass with no drops, one on the grass 6 west lives the day; 200 boar
# spawn searches round the player find spots, and those under a cover
# (leaves pass sky light 15) are refused.
log48="$t/srv48.log"
BUILDAT_SKELDAT_WORLD=boars BUILDAT_SKELDAT_TERRAIN=flat BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="1 -1 0" \
	BUILDAT_SKELDAT_TIME=0.5 BUILDAT_SKELDAT_SPAWN="0 0" BUILDAT_SKELDAT_DAY=20 \
	BUILDAT_SKELDAT_SKELETONS=0 \
	BUILDAT_SKELDAT_TEST="marker 6 0 skeldat:stone -1; boar 6 0; boar -6 0; boar_spots 200" \
	start_server "$log48" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
	-D "$t/srv48" -C "$t/srv.cache" -l 3 || fail "the server ($log48)"
CHECK_PIDS+=($SERVER_PID)
printf '%s\n' "$placed" "delay 28000" quit > "$t/boars.cmds"
client boars "$t/boars.cmds"
wait $CLIENT || fail "the boars' drive ($t/boars.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
stone=$(grep -a "test: a boar (" "$log48" | head -1 | sed 's/.*boar (\([0-9]*\)).*/\1/')
grass=$(grep -a "test: a boar (" "$log48" | sed -n 2p | sed 's/.*boar (\([0-9]*\)).*/\1/')
spots=$(grep -a "boar spawn searches" "$log48" | sed 's/.*searches, //')
[ -n "$stone" ] && grep -aq "the boar ($stone) dies off the grass" "$log48" &&
	[ -n "$grass" ] && ! grep -aq "the boar ($grass) dies" "$log48" &&
	! grep -aq "a drop of" "$log48" ||
	fail "the boar on stone ($stone) not dead off the grass, the one on grass ($grass) dead, or drops ($log48)"
[ "$(echo "$spots" | awk '{ print ($1 > 0) }')" = 1 ] ||
	fail "no boar spawn spot: $spots ($log48)"
echo "boars: the one on stone died off the grass; spawn searches $spots"
# 45. Cave skeletons ([SKELDAT_CAVE_SKELETON]) at midnight, the launcher's
# client invulnerable: one 8 behind draws and shoots at the player (level
# with it on the spawn's hill: one 8 ahead stands under the hill's brow,
# with no clear shot, [SKELDAT_CLEAR_SHOT]); a bone
# skeleton and a cave skeleton 10 apart, 30 off the player, fight until
# one is dead. 200 cave skeleton spawn searches round the player find
# spots under a cover. The server again on the saved world: the cave
# skeleton left loads and shoots again.
# simplified: no bone placed is the code's (a cave skeleton has no path
# to the bones), not counted
log49="$t/srv49.log"
for n in 1 2; do
	BUILDAT_SKELDAT_WORLD=cave BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="1 -1 0" \
		BUILDAT_SKELDAT_TIME=0 BUILDAT_SKELDAT_SPAWN="0 0" BUILDAT_SKELDAT_DAY=2400 \
		BUILDAT_SKELDAT_TEST="$([ $n = 1 ] && echo "cave_skeleton 0 -8; skeleton 0 30 marked; cave_skeleton 10 30; cave_spots 200" || echo "place 0 0")" \
		start_server "$t/srv49_$n.log" "STATUS Listening" 300 auto \
		"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
		-D "$t/srv49" -C "$t/srv.cache" -l 3 -u launcher=1 ||
		fail "the server ($t/srv49_$n.log)"
	CHECK_PIDS+=($SERVER_PID)
	{ echo "$placed"; toggle; echo "delay $([ $n = 1 ] && echo 60000 || echo 10000)"
		echo quit; } > "$t/cave$n.cmds"
	client cave$n "$t/cave$n.cmds"
	wait $CLIENT || fail "the cave skeletons' drive $n ($t/cave$n.log)"
	kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
	cat "$t/srv49_$n.log" >> "$log49"
done
c1="$t/srv49_1.log"
shooter=$(grep -a "test: a cave_skeleton (" "$c1" | head -1 | sed 's/.*(\([0-9]*\)).*/\1/')
grep -aq "a cave_skeleton ($shooter) draws at client1" "$c1" &&
	grep -aq "a cave_skeleton shoots at client1" "$c1" ||
	fail "the cave skeleton did not draw and shoot at the player ($c1)"
grep -aq "a skeleton ([0-9]*) draws at the cave_skeleton" "$c1" &&
	grep -aq "a cave_skeleton ([0-9]*) draws at the skeleton" "$c1" &&
	grep -aqE "an arrow from a (cave_)?skeleton hits the (cave_)?skeleton" "$c1" &&
	grep -aqE "the (cave_)?skeleton \([0-9]*\) dies" "$c1" ||
	fail "the bone and the cave skeleton did not fight to a death: $(grep -a "draws at the\|arrow from a\|dies" "$c1" | sed 's/.*skeldat: //' | tr '\n' ';') ($c1)"
spots=$(grep -a "cave_skeleton spawn searches" "$c1" | sed 's/.*searches, //')
[ "$(echo "$spots" | awk '{ print ($1 > 0) }')" = 1 ] ||
	fail "no cave skeleton spawn spot: $spots ($c1)"
grep -aq "a cave_skeleton ($shooter) draws at client1" "$t/srv49_2.log" ||
	fail "the saved cave skeleton not loaded or not shooting ($t/srv49_2.log)"
echo "cave skeletons: the fight: $(grep -aE "the (cave_)?skeleton \([0-9]*\) dies" "$c1" | head -1 | sed 's/.*skeldat: //; s/ at .*//'); spawn searches $spots"
# 46. The hazards ([SKELDAT_MINING_HAZARDS]) at noon: a 2x4x2 box of
# full water 10 off the player; the water spreads and its volume (128
# eighths) stays in every report, less what evaporates. The player with a stack in a lava
# pool burns 4 a second and dies, the stack burnt, not dropped, the hurt
# sound heard; a boar in a box of poison gas breathes it. The server
# again on the saved world reads the active set back and steps it.
log50="$t/srv50.log"
for n in 1 2; do
	BUILDAT_SKELDAT_WORLD=hazards BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="1 -1 0" BUILDAT_SKELDAT_TERRAIN=plains \
		BUILDAT_SKELDAT_TIME=0.5 BUILDAT_SKELDAT_SPAWN="0 0" BUILDAT_SKELDAT_SKELETONS=0 \
		BUILDAT_SKELDAT_TEST="$([ $n = 1 ] && echo "give skeldat:stone 5; pocket lava -2 -2 5 3 5; pocket poison -9 -1 3 3 3; boar -8 0; pocket water 10 0 2 4 2" || echo "place 0 0")" \
		start_server "$t/srv50_$n.log" "STATUS Listening" 300 auto \
		"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
		-D "$t/srv50" -C "$t/srv.cache" -l 3 ||
		fail "the server ($t/srv50_$n.log)"
	CHECK_PIDS+=($SERVER_PID)
	printf '%s\n' "$placed" "delay $([ $n = 1 ] && echo 22000 || echo 12000)" quit > "$t/hazards$n.cmds"
	client hazards$n "$t/hazards$n.cmds"
	wait $CLIENT || fail "the hazards' drive $n ($t/hazards$n.log)"
	kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
	cat "$t/srv50_$n.log" >> "$log50"
done
h1="$t/srv50_1.log"
volumes=$(grep -a "skeldat: hazards: .* water volume" "$h1" | sed 's/.*water volume //' | tr '\n' ' ')
first=$(grep -a "skeldat: hazards: .* water volume" "$h1" | head -1 | sed 's/.*skeldat: //')
# Kept but for what evaporates under the open sky ([SKELDAT_OWN_MAPGEN]):
# never more, and not 8 less
echo "$volumes" | awk '{ for(i = 1; i <= NF; i++) if($i > 128 || $i < 120 ||
		(i > 1 && $i > $(i - 1))) exit 1; exit !(NF >= 2) }' &&
	echo "$first" | awk '{ exit !($4 > 0) }' ||
	fail "the water's volume not kept at 128 less what evaporates ($volumes), or nothing stepped: $first ($h1)"
back=$(grep -a "skeldat: hazards: [0-9]* active read back" "$t/srv50_2.log" | sed 's/.*hazards: \([0-9]*\).*/\1/')
[ "${back:-0}" -gt 0 ] &&
	grep -a "skeldat: hazards: .* stepped" "$t/srv50_2.log" | sed 's/.*skeldat: //' |
		awk '$4 > 0 { s = 1 } END { exit !s }' ||
	fail "the active set not read back (${back:-none}) or not stepped ($t/srv50_2.log)"
grep -a "client1 burns in lava" "$h1" | head -1 | grep -q "16 hp left" &&
	grep -aq "client1 dies at .*, burning 1 of 1 stacks" "$h1" &&
	! grep -aq "a drop of skeldat:stone" "$h1" &&
	grep -aq "skeldat: the boar ([0-9]*) breathes poison gas" "$h1" &&
	grep -aq "skeldat: sound player_hurt (own)" "$t/hazards1.log" ||
	fail "the lava's 4 a second, the stacks burnt, the boar's gas or the hurt sound ($h1, $t/hazards1.log)"
echo "$first; ${back} active read back"
# 47. The own map generator's forms ([SKELDAT_OWN_MAPGEN]): a 128 world
# of each, the server alone for 2 minutes, its water reported every 10 s
# (BUILDAT_SKELDAT_WATER_REPORT): made and settled; on rivers the
# volume within 8% of the first report's (the springs of low pressure,
# [SKELDAT_LOW_BANKS]: 8234 -> 7999 in 2 minutes measured, 2026-10-19;
# before, pushing the river over its banks, +20% in 10); on sea the level drain holds the line (within 3%); plains
# and lake have no spring, their volume never more. Rivers: riffles made
# ([SKELDAT_RIVER_RIFFLES]), the pools' tops logged. On sea the edge's
# drains are the voxel over the line alone ([SKELDAT_LOW_BANKS]), drawn as
# nothing, and the client's backdrop water at the voxels' surface (the
# line's top face less the mesher's eighth of sag). A lava spring on the
# ground adds lava; one walled in by stone adds none.
# simplified: 2 minutes where the plan has 10, the margins to match
forms=""
for form in rivers sea plains lake; do
	BUILDAT_SKELDAT_WORLD=$form BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="1 -1 0" \
		BUILDAT_SKELDAT_TERRAIN=$form BUILDAT_SKELDAT_SKELETONS=0 BUILDAT_SKELDAT_WATER_REPORT=1 \
		start_server "$t/srv51_$form.log" "STATUS Listening" 300 auto \
		"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
		-D "$t/srv51" -C "$t/srv.cache" -l 3 || fail "the server ($t/srv51_$form.log)"
	CHECK_PIDS+=($SERVER_PID)
	wait_for_log "$t/srv51_$form.log" "the world is in" 120 ||
		fail "the $form world not made ($t/srv51_$form.log)"
	if [ $form = sea ]; then
		printf '%s\n' "$placed" "delay 2000" quit > "$t/sea.cmds"
		client sea "$t/sea.cmds"
		wait $CLIENT || fail "the sea's drive ($t/sea.log)"
	fi
	sleep 120
	kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
	f="$t/srv51_$form.log"
	grep -aq "skeldat: the heightmap ($form) made" "$f" &&
		grep -aq "skeldat: water: .* after the settling" "$f" ||
		fail "the $form world not made and settled ($f)"
	vols=$(grep -a "skeldat: water: [0-9]* voxels, [0-9]* volume;" "$f" | sed 's/.*voxels, \([0-9]*\) volume.*/\1/' | tr '\n' ' ')
	case $form in
	rivers) margin=0.08 rise=1;;
	sea) margin=0.03 rise=1;;
	*) margin=0.05 rise=0;;
	esac
	echo "$vols" | awk -v m=$margin -v r=$rise '{ if(NF < 8) exit 1
		for(i = 2; i <= NF; i++){ d = ($i - $1) / $1; if(d > m || d < -m) exit 1
			if(!r && $i > $(i - 1)) exit 1 } }' ||
		fail "the $form water not kept: $vols ($f)"
	forms="$forms $form $(echo $vols | awk '{ printf "%d->%d", $1, $NF }');"
	# [SKELDAT_RIVER_RIFFLES] Riffles in the channels; the pools' tops at
	# the last report against the intended, read and not held to a figure
	if [ $form = rivers ]; then
		grep -aq "skeldat: the heightmap (rivers) made .*, [1-9][0-9]* riffles" "$f" ||
			fail "no riffles in the rivers ($f)"
		echo "rivers: $(grep -ao "[0-9]* riffles" "$f" | head -1); the pools: $(grep -a "skeldat: water: \|skeldat: river .* pool" "$f" |
			awk '/water:/ { s = ""; next } { sub(/.*skeldat: /, ""); s = s $0 "; " } END { print s }')"
	fi
	if [ $form = sea ]; then
		grep -aq "skeldat: water: .* lava voxels; [1-9][0-9]* edge drains, 0 off the line" "$f" ||
			fail "the sea's edge drains not on the line's voxel over it ($f)"
		grep -a "skeldat: the backdrop beyond the edge" "$t/sea.log" |
			sed 's/.*the water at \([-0-9.]*\), drawn at \([-0-9.]*\).*/\1 \2/' |
			awk '{ exit !(NF == 2 && $2 == $1 + 0.375) }' ||
			fail "the sea's backdrop water not at the voxels' surface ($t/sea.log)"
	fi
done
for n in 1 2; do
	# The spring 4 ahead, on flat; walled: stone
	# 2 high on its 4 sides and 1 on it
	walls=""
	[ $n = 2 ] && walls="$(for d in "1 4" "-1 4" "0 3" "0 5"; do echo "marker $d skeldat:stone 0; marker $d skeldat:stone 0;"; done) marker 0 4 skeldat:stone 0"
	BUILDAT_SKELDAT_WORLD=lava$n BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="1 -1 0" \
		BUILDAT_SKELDAT_TERRAIN=flat BUILDAT_SKELDAT_SKELETONS=0 BUILDAT_SKELDAT_WATER_REPORT=1 \
		BUILDAT_SKELDAT_TIME=0.5 BUILDAT_SKELDAT_SPAWN="0 0" \
		BUILDAT_SKELDAT_TEST="marker 0 4 skeldat:lava_spring 0; $walls" \
		start_server "$t/srv51_lava$n.log" "STATUS Listening" 300 auto \
		"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
		-D "$t/srv51_lava$n" -C "$t/srv.cache" -l 3 || fail "the server ($t/srv51_lava$n.log)"
	CHECK_PIDS+=($SERVER_PID)
	printf '%s\n' "$placed" "delay 60000" quit > "$t/lava$n.cmds"
	client lava$n "$t/lava$n.cmds"
	wait $CLIENT || fail "the lava spring's drive $n ($t/lava$n.log)"
	kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
done
# [SKELDAT_COASTS] Onto an island: the sea at 128 (seed 2), spawned on an
# island at 0 -4 (a spawn over water is at the world's top), walked 4 s
# south into the sea, then W and Space held north: the player in the water
# (2 over the line at most), then 3 over it within 12 s (its shore no
# cliff).
printf '%s\n' "$placed" "delay 1500" "look 180 0" "keydown W" "delay 4000" \
	"keyup W" "delay 1000" "event skeldat_where" "look 0 0" "keydown W" \
	"keydown Space" > "$t/coast.cmds"
for i in $(seq 24); do printf '%s\n' "delay 500" "event skeldat_where" >> "$t/coast.cmds"; done
printf '%s\n' "keyup Space" "keyup W" quit >> "$t/coast.cmds"
BUILDAT_SKELDAT_WORLD=coast BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="1 -1 0" \
	BUILDAT_SKELDAT_TERRAIN=sea BUILDAT_SKELDAT_SKELETONS=0 BUILDAT_SKELDAT_SPAWN="0 -4" \
	start_server "$t/srv51_coast.log" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
	-D "$t/srv51_coast" -C "$t/srv.cache" -l 3 || fail "the server ($t/srv51_coast.log)"
CHECK_PIDS+=($SERVER_PID)
client coast "$t/coast.cmds"
wait $CLIENT || fail "the coast's drive ($t/coast.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
ys=$(grep -a "skeldat: where (" "$t/coast.log" | sed 's/.*where ([-0-9.]*, \([-0-9.]*\),.*/\1/' | tr '\n' ' ')
coast=$(echo $ys | awk '{ m = $2; for(i = 2; i <= NF; i++) if($i > m) m = $i; print $1 " -> " m }')
echo $ys | awk '{ exit !(NF >= 20 && $1 <= 2) }' &&
	echo $ys | awk '{ for(i = 2; i <= NF; i++) if($i >= 4) exit 0; exit 1 }' ||
	fail "the island not climbed from the sea: $ys ($t/coast.log)"
lava() { grep -a "skeldat: water: .* lava voxels" "$t/srv51_lava$1.log" | sed 's/.*; \([0-9]*\) lava voxels.*/\1/' | tr '\n' ' '; }
l1=$(lava 1) l2=$(lava 2)
echo "$l1" | awk '{ exit !(NF >= 4 && $NF > $2 + 4) }' &&
	echo "$l2" | awk '{ for(i = 3; i <= NF; i++) if($i != $2) exit 1; exit !(NF >= 4) }' ||
	fail "the lava spring: on the ground $l1, walled in $l2 ($t/srv51_lava1.log, $t/srv51_lava2.log)"
# 48. A clear shot ([SKELDAT_CLEAR_SHOT]): a player at midnight in a box
# of stone 3 high round it and over it, the box open at +x (1 0), a
# skeleton 4 x and -5 z off, its straight shot through the wall. No shot
# while blocked; "has no clear shot ... to (...)", then a shot within 15 s
# of it. The box sealed and 30 skeletons round it: no shot, each one's
# "no spot" tries 3 s apart at least; the light step's time logged.
box() {
	for d in "1 1" "0 1" "-1 1" "-1 0" "-1 -1" "0 -1" "1 -1" ${1:+"$1"}; do
		printf 'marker %s skeldat:stone 0; marker %s skeldat:stone 0; marker %s skeldat:stone 0; ' "$d" "$d" "$d"
	done
	for dx in -1 0 1; do for dz in -1 0 1; do printf 'marker %d %d skeldat:stone 3; ' $dx $dz; done; done
}
ring=$(for i in $(seq 0 29); do awk -v i=$i 'BEGIN { a = i * 6.2832 / 30; r = 5 + i % 4
	printf "skeleton %d %d; ", r * sin(a), r * cos(a) }'; done)
for run in open sealed; do
	if [ $run = open ]; then test="$(box "")skeleton 4 -5"; else test="$(box "1 0")$ring"; fi
	BUILDAT_SKELDAT_WORLD=shot_$run BUILDAT_SKELDAT_TERRAIN=flat BUILDAT_SKELDAT_SEED=2 \
		BUILDAT_SKELDAT_SIZE="2 -1 0" BUILDAT_SKELDAT_TIME=0 BUILDAT_SKELDAT_SPAWN="0 0" \
		BUILDAT_SKELDAT_DAY=2400 BUILDAT_SKELDAT_SKELETONS=0 BUILDAT_SKELDAT_TEST="$test" \
		start_server "$t/srv52_$run.log" "STATUS Listening" 300 auto \
		"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
		-D "$t/srv52_$run" -C "$t/srv.cache" -l 3 || fail "the server ($t/srv52_$run.log)"
	CHECK_PIDS+=($SERVER_PID)
	printf '%s\n' "$placed" "delay 25000" quit > "$t/shot_$run.cmds"
	client shot_$run "$t/shot_$run.cmds"
	wait $CLIENT || fail "the clear shot's drive ($t/shot_$run.log)"
	kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
done
python3 -I - "$t/srv52_open.log" "$t/srv52_sealed.log" <<'PY' || fail "the clear shot ($t/srv52_open.log, $t/srv52_sealed.log)"
import sys, re
def ts(l):
    m = re.search(r" (\d\d):(\d\d):(\d\d)\.(\d\d\d) ", l)
    return int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3)) + int(m.group(4)) / 1000
o = open(sys.argv[1], errors="replace").read().split("\n")
to = [ts(l) for l in o if re.search(r"has no clear shot at client1, to \(", l)]
shots = [ts(l) for l in o if "a skeleton shoots at client1" in l]
assert to, "no try with a spot"
assert shots and shots[0] > to[0] and shots[0] - to[0] < 15, (to[:3], shots[:3])
s = open(sys.argv[2], errors="replace").read().split("\n")
assert not any("shoots at client1" in l for l in s), "a shot out of the sealed box"
tries = {}
for l in s:
    m = re.search(r"a skeleton \((\d+)\) has no clear shot at client1, no spot", l)
    if m:
        tries.setdefault(m.group(1), []).append(ts(l))
assert len(tries) >= 10, tries
gap = min(b - a for v in tries.values() for a, b in zip(v, v[1:]))
assert gap >= 2.9, gap
print("open: the shot %.1f s after the try; sealed: %d skeletons trying, %d tries, the least gap %.1f s" %
      (shots[0] - to[0], len(tries), sum(len(v) for v in tries.values()), gap))
PY
# 49. Out of the sun ([SKELDAT_SUN_SHELTER]): at 0.17 of a 600 s day
# (the dawn's search from 0.19, 11 s on, when the rooms' light is in;
# sunrise at 0.23, 36 s on), flat ground. Two rooms of stone, 3 x 3 inside,
# walls 3 high, a door 2 high, a roof, whose back rows the sky lights 11
# at most; every skeleton 20 or more from the player, so none fights. A
# skeleton 12 from the first room's door: "finds shelter", and no burn
# after sunrise; one 25 off in the open: "finds no shelter", and it
# burns; one in the second room's back row: none of its steps out of it
# by day (the report's steps kept out of the sun), no burn; a cave
# skeleton in the open: no shelter line. A skeleton in lava (walled in)
# burns in lava 4 hp a second (two burns a second apart at least: a test
# marker over a voxel not loaded yet floats, and the lava can run out), no
# "is in water"; one in water dies at once. The fixtures clear of seed
# 2's trees (tree_at; (29,3) and (-23,-22) the nearest), whose sections
# can be made after a marker went up and put a crown through a room. The
# sheltering one far enough that its walk before the search (12 s) brings
# it into no shade (8 from the door it was once found never exposed).
# room <x> <z> <door side x|z>: the inside x-1..x+1, z-1..z+1, its door on
# the -x or -z wall's middle
room() {
	local x=$1 z=$2 dx dz
	for dz in -2 -1 0 1 2; do for dx in -2 -1 0 1 2; do
		[ ${dx#-} -lt 2 ] && [ ${dz#-} -lt 2 ] && continue
		if { [ $3 = x ] && [ $dx = -2 ] && [ $dz = 0 ]; } ||
				{ [ $3 = z ] && [ $dz = -2 ] && [ $dx = 0 ]; }; then
			printf 'marker %d %d skeldat:stone 2; ' $((x + dx)) $((z + dz))
		else
			for k in 1 2 3; do printf 'marker %d %d skeldat:stone 0; ' $((x + dx)) $((z + dz)); done
		fi
	done; done
	for dz in -2 -1 0 1 2; do for dx in -2 -1 0 1 2; do
		if [ ${dx#-} -lt 2 ] && [ ${dz#-} -lt 2 ]; then
			printf 'marker %d %d skeldat:stone 3; ' $((x + dx)) $((z + dz))
		else
			printf 'marker %d %d skeldat:stone 0; ' $((x + dx)) $((z + dz))
		fi
	done; done
}
# The lava 3 x 3 in a stone ring 2 high, which keeps it in and the
# skeleton in it
lava=$(for dz in -2 -1 0 1 2; do for dx in -2 -1 0 1 2; do
	if [ ${dx#-} -lt 2 ] && [ ${dz#-} -lt 2 ]; then continue; fi
	printf 'marker %d %d skeldat:stone 0; marker %d %d skeldat:stone 0; ' \
		$((-12 + dx)) $((-20 + dz)) $((-12 + dx)) $((-20 + dz)); done; done
	for d in "-1 -1" "0 -1" "1 -1" "-1 0" "0 0" "1 0" "-1 1" "0 1" "1 1"; do
	set -- $d; printf 'marker %d %d skeldat:lava; ' $((-12 + $1)) $((-20 + $2)); done)
test="$(room 30 -6 x)$(room 0 30 z)${lava}marker 20 -20 skeldat:water_source; "
test="${test}skeleton 16 -14; skeleton -25 0; skeleton 0 31; cave_skeleton 0 -25; skeleton -12 -20; skeleton 20 -20"
log53="$t/srv53.log"
BUILDAT_SKELDAT_WORLD=sun BUILDAT_SKELDAT_TERRAIN=flat BUILDAT_SKELDAT_SEED=2 \
	BUILDAT_SKELDAT_SIZE="2 -1 0" BUILDAT_SKELDAT_TIME=0.17 BUILDAT_SKELDAT_SPAWN="0 0" \
	BUILDAT_SKELDAT_DAY=600 BUILDAT_SKELDAT_SKELETONS=0 BUILDAT_SKELDAT_TEST="$test" \
	start_server "$log53" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
	-D "$t/srv53" -C "$t/srv.cache" -l 3 || fail "the server ($log53)"
CHECK_PIDS+=($SERVER_PID)
printf '%s\n' "$placed" "delay 100000" quit > "$t/sun.cmds"
client sun "$t/sun.cmds"
wait $CLIENT || fail "the sun's drive ($t/sun.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
sun=$(python3 -I - "$log53" <<'PY'
import sys, re
lines = open(sys.argv[1], errors="replace").read().split("\n")
keys = {}
for l in lines:
    m = re.search(r"skeldat: test: a (skeleton|cave_skeleton) \((\d+)\) at ([-0-9.]+),[-0-9.]+,([-0-9.]+)", l)
    if m:
        keys[(round(float(m.group(3))), round(float(m.group(4))))] = m.group(2)
def has(pat, k):
    return any(re.search(pat % k, l) for l in lines)
def count(pat, k):
    return sum(1 for l in lines if re.search(pat % k, l))
shel, none, inside, cave, lava, water = (keys.get(p) for p in
        [(16, -14), (-25, 0), (0, 31), (0, -25), (-12, -20), (20, -20)])
assert all([shel, none, inside, cave, lava, water]), keys
assert has(r"a skeleton \(%s\) finds shelter at", shel), "no shelter found"
assert not has(r"the skeleton \(%s\) burns$", shel), "the sheltered one burnt"
assert has(r"a skeleton \(%s\) finds no shelter", none), "no 'no shelter'"
assert has(r"the skeleton \(%s\) burns$", none), "the one in the open did not burn"
assert not has(r"the skeleton \(%s\) burns$", inside), "the one inside burnt"
assert not has(r"skeleton \(%s\) finds", cave), "a cave skeleton looked for shelter"
kept = sum(int(m.group(1)) for l in lines for m in [re.search(r"(\d+) steps kept out of the sun", l)] if m)
assert kept > 0, "no step kept out of the sun"
def ts(l):
    m = re.search(r" (\d\d):(\d\d):(\d\d)\.(\d\d\d) ", l)
    return int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3)) + int(m.group(4)) / 1000
lt = [ts(l) for l in lines if re.search(r"the skeleton \(%s\) burns in lava" % lava, l)]
n = len(lt)
gaps = [b - a for a, b in zip(lt, lt[1:])]
assert n >= 2 and all(0.8 < g < 1.4 for g in gaps), ("lava", lt)
assert not has(r"the skeleton \(%s\) is in water", lava), "the one in lava drowned"
assert has(r"the skeleton \(%s\) is in water", water), "the one in water"
print("shelter found by %s, %d steps kept out, lava burnt %d times" % (shel, kept, n))
PY
) || fail "out of the sun: $sun ($log53)"
# 50. A placed voxel pushes its water aside ([SKELDAT_DISPLACE]): a 2x4x2
# pocket of full water 10 off the player (128 eighths, watched as in 46),
# 10 stone put into its water by the test's markers (set_node, the hook a
# player's place goes through too): "8 of water displaced" 10 times, and
# the watched volume 120 to 128 in every report (only evaporation takes,
# an eighth at a time; lost, it would be 48).
# simplified: the markers, not a player's aimed places
stones=$(for c in "10 0 3" "11 0 3" "10 1 2" "11 1 2"; do set -- $c
	for d in $(seq 1 $3); do printf 'marker %d %d skeldat:stone -%d; ' $1 $2 $d; done; done)
log54="$t/srv54.log"
BUILDAT_SKELDAT_WORLD=displace BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="1 -1 0" \
	BUILDAT_SKELDAT_TERRAIN=plains BUILDAT_SKELDAT_TIME=0.5 BUILDAT_SKELDAT_SPAWN="0 0" \
	BUILDAT_SKELDAT_SKELETONS=0 BUILDAT_SKELDAT_TEST="pocket water 10 0 2 4 2; $stones" \
	start_server "$log54" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
	-D "$t/srv54" -C "$t/srv.cache" -l 3 || fail "the server ($log54)"
CHECK_PIDS+=($SERVER_PID)
printf '%s\n' "$placed" "delay 22000" quit > "$t/displace.cmds"
client displace "$t/displace.cmds"
wait $CLIENT || fail "the displacing drive ($t/displace.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
pushed=$(grep -ac "skeldat: hazards: 8 of water displaced from" "$log54")
dvol=$(grep -a "skeldat: hazards: .* water volume" "$log54" | sed 's/.*water volume //' | tr '\n' ' ')
[ "$pushed" = 10 ] && ! grep -aq "of water lost at" "$log54" &&
	echo "$dvol" | awk '{ for(i = 1; i <= NF; i++) if($i > 128 || $i < 120) exit 1; exit !(NF >= 2) }' ||
	fail "the water pushed aside: $pushed displaced, volumes $dvol ($log54)"
# 51. Water puts out a torch ([SKELDAT_WATER_TORCH]): flat ground, a
# torch 2 off the player beside a 2x2x2 pocket of water (sunk a voxel,
# its top layer flowing out): "water puts out a torch", a torch dropped
# there, and in the next report that voxel's lamp light 0. The player
# stands in a 1x2x1 pocket (the lower voxel walled by the ground, so it
# stays water) with 2 torches in hand, looking straight down: the torch
# into the water refused, none placed.
log55="$t/srv55.log"
BUILDAT_SKELDAT_WORLD=torch BUILDAT_SKELDAT_TERRAIN=flat BUILDAT_SKELDAT_SEED=2 \
	BUILDAT_SKELDAT_SIZE="1 -1 0" BUILDAT_SKELDAT_TIME=0.5 BUILDAT_SKELDAT_SPAWN="0 0" \
	BUILDAT_SKELDAT_SKELETONS=0 \
	BUILDAT_SKELDAT_TEST="give skeldat:torch 2 1; marker 3 0 skeldat:torch; pocket water 4 0 2 2 2; pocket water 0 0 1 2 1" \
	start_server "$log55" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
	-D "$t/srv55" -C "$t/srv.cache" -l 3 || fail "the server ($log55)"
CHECK_PIDS+=($SERVER_PID)
printf '%s\n' "$placed" "delay 2000" "look 0 -89" "delay 500" "mouse_down right" \
	"delay 100" "mouse_up right" "delay 21000" quit > "$t/torch.cmds"
client torch "$t/torch.cmds"
wait $CLIENT || fail "the torch's drive ($t/torch.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
out=$(grep -a "water puts out a torch at" "$log55" | head -1 | sed 's/.*at (\(.*\))/\1/')
[ -n "$out" ] && grep -aq "a drop of skeldat:torch" "$log55" &&
	grep -aq "the torch put out at ($out): lamp light 0" "$log55" ||
	fail "the torch not put out, dropped, or its light left: ${out:-none} ($log55)"
grep -aq "client1's torch into skeldat:water_source at .* refused" "$log55" &&
	! grep -aq "client1 places skeldat:torch" "$log55" ||
	fail "a torch placed into water ($log55)"
# 52. A wooden board ([SKELDAT_BOARD_WOOD]): flat ground at noon and at
# midnight, the board forced on at a walk's speed (event skeldat_board 1),
# a boar beside it, the look straight down: "the board's material
# main/wood.png" logged, a shot of each ($t/board_wood_<time>.png), the
# board lit as the boar is.
for time in 0.5 0; do
	BUILDAT_SKELDAT_WORLD=wood_$time BUILDAT_SKELDAT_TERRAIN=flat BUILDAT_SKELDAT_SEED=2 \
		BUILDAT_SKELDAT_SIZE="1 -1 0" BUILDAT_SKELDAT_TIME=$time BUILDAT_SKELDAT_SPAWN="0 0" \
		BUILDAT_SKELDAT_SKELETONS=0 BUILDAT_SKELDAT_TEST="boar 1 1" \
		start_server "$t/srv56_$time.log" "STATUS Listening" 300 auto \
		"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
		-D "$t/srv56_$time" -C "$t/srv.cache" -l 3 || fail "the server ($t/srv56_$time.log)"
	CHECK_PIDS+=($SERVER_PID)
	printf '%s\n' "$placed" "delay 3000" "event skeldat_board 1" "look 0 -70" \
		"delay 1500" "screenshot $t/board_wood_$time.png" quit > "$t/wood_$time.cmds"
	client wood_$time "$t/wood_$time.cmds"
	wait $CLIENT || fail "the wooden board's drive ($t/wood_$time.log)"
	kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
	grep -aq "skeldat: the board's material main/wood.png" "$t/wood_$time.log" &&
		grep -aq "skeldat: on the board" "$t/wood_$time.log" ||
		fail "no wooden board ($t/wood_$time.log)"
done
# 53. Apple trees, leaf decay and saplings ([SKELDAT_APPLE_TREES]): flat
# ground, a 60 s day from 0.6 (midnights 24 s and 84 s on), fixtures set
# by the player's feet ("set dx dy dz node"):
# - decay: a log column of 4 at +10 (out of reach of the apple's log at
#   2, 2), five leaves, an apple and an apple
#   branch round its top, then the logs set to air: the 7 go a voxel a
#   second ("leaf decay: N queued, M gone"), an apple dropped; a control:
#   leaves beside a log at -6 (a log over them set and taken away, so they
#   are queued) stay;
# - an apple at the eye 2 ahead, a log 2 from it: the player digs it, an
#   apple in hand and an apple branch left, an apple again at the first
#   midnight;
# - on the row 6 behind: a sapling (grows at the first midnight, a tree at
#   the second), an apple sapling (likewise, its tree 3 to 6 apples), a
#   sapling on stone (gone at the first midnight, no drop) and one under a
#   roof 3 over it (sky light 14: waits both nights).
# Generated apple trees are the mapgen self-test's (one in 4, 3 to 6 each).
# The decay's step time under 5 ms a second (1.1 to 1.8 measured: a centre's
# 9x9x9 read voxel by voxel).
log57="$t/srv57.log"
tr53="set 10 0 0 skeldat:tree; set 10 1 0 skeldat:tree; set 10 2 0 skeldat:tree; set 10 3 0 skeldat:tree"
tr53="$tr53; set 9 3 0 skeldat:leaves; set 11 3 0 skeldat:leaves; set 10 3 1 skeldat:leaves"
tr53="$tr53; set 10 3 -1 skeldat:leaves; set 10 4 0 skeldat:leaves; set 9 3 1 skeldat:apple_fruit"
tr53="$tr53; set 11 3 1 skeldat:apple_branch"
tr53="$tr53; set 10 0 0 air; set 10 1 0 air; set 10 2 0 air; set 10 3 0 air"
tr53="$tr53; set -6 0 0 skeldat:tree; set -6 1 0 skeldat:tree; set -5 1 0 skeldat:leaves"
tr53="$tr53; set -6 2 0 skeldat:tree; set -6 2 0 air"
tr53="$tr53; set 2 0 2 skeldat:tree; set 0 1 2 skeldat:apple_fruit"
tr53="$tr53; set 0 0 -6 skeldat:sapling; set 6 0 -6 skeldat:apple_sapling"
tr53="$tr53; set -6 -1 -6 skeldat:stone; set -6 0 -6 skeldat:sapling"
tr53="$tr53; set 3 0 -6 skeldat:sapling; set 3 3 -6 skeldat:stone"
BUILDAT_SKELDAT_WORLD=trees BUILDAT_SKELDAT_TERRAIN=flat BUILDAT_SKELDAT_SEED=2 \
	BUILDAT_SKELDAT_SIZE="1 -1 0" BUILDAT_SKELDAT_TIME=0.6 BUILDAT_SKELDAT_DAY=60 \
	BUILDAT_SKELDAT_SPAWN="0 0" BUILDAT_SKELDAT_SKELETONS=0 BUILDAT_SKELDAT_TEST="$tr53" \
	start_server "$log57" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
	-D "$t/srv57" -C "$t/srv.cache" -l 3 || fail "the server ($log57)"
CHECK_PIDS+=($SERVER_PID)
printf '%s\n' "$placed" "delay 2000" "look 0 0" "delay 500" "mouse_down left" \
	"delay 1500" "mouse_up left" "delay 85000" quit > "$t/trees.cmds"
client trees "$t/trees.cmds"
wait $CLIENT || fail "the trees' drive ($t/trees.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
python3 -I - "$log57" <<'PY' || fail "apple trees, decay or saplings ($log57)"
import sys, re
log = open(sys.argv[1], errors="replace").read()
gone = sum(int(m) for m in re.findall(r"leaf decay: \d+ queued, (\d+) gone", log))
assert gone == 7, ("gone", gone)
ms = [float(m) for m in re.findall(r"leaf decay: .*?([\d.]+) ms a second", log)]
assert ms and max(ms) < 5, ms
assert "a drop of skeldat:apple at" in log, "no apple dropped by decay"
assert re.search(r"client1 digs skeldat:apple_fruit at", log), "the apple not dug"
nights = re.findall(r"(\d+) saplings grew at midnight \((\d+) trees\); (\d+) apples again, "
        r"(\d+) off soil gone, (\d+) waiting", log)
assert len(nights) >= 2, nights
assert nights[0] == ("2", "0", "1", "1", "1"), nights[0]
assert nights[1] == ("2", "2", "0", "0", "1"), nights[1]
a = re.findall(r"an apple tree grew at \S+, (\d+) apples", log)
assert len(a) == 1 and 3 <= int(a[0]) <= 6, a
assert len(re.findall(r" a tree grew at ", log)) == 1
print("decay %d gone, %.3f ms a second at most; nights %s; the apple tree's %s apples"
        % (gone, max(ms), nights[:2], a[0]))
PY
# 54. Boats ([SKELDAT_BOATS]): flat ground at 256, a 60 s day from 0.2, a
# pond 71 x 71 from 10 ahead of the spawn and an island of bone blocks
# 3 x 3 at its middle (0, 45; the bones under its feet keep the sun off,
# and every shore is past SEED_RANGE and the waypoint's reach, so it
# neither seeds nor bridges), a bone skeleton on it. Two sunrises: a
# green skull placed; the sunset after: it takes to a boat, the client
# draws the boat. The server stopped and started again: the boat read
# back with its aim. The next sunset: a new aim; then it lands on a shore
# at night, 12 or more from where it boarded, a bone skeleton again; no
# burn and no drowning on the way (on flat land it burns by day after).
log58="$t/srv58.log"
# The island first and the pond round it: a voxel set into the water
# pushes its volume aside ([SKELDAT_DISPLACE]), here over the island
bt54="level -1 44 3 3 skeldat:bone_block -1; level -35 10 71 34 skeldat:water_source -1"
bt54="$bt54; level -35 47 71 34 skeldat:water_source -1; level -35 44 34 3 skeldat:water_source -1"
bt54="$bt54; level 2 44 34 3 skeldat:water_source -1; skeleton 0 45"
boats() { # log, client name, delay ms[, the test's fixtures]
	BUILDAT_SKELDAT_WORLD=${W54:-boats} BUILDAT_SKELDAT_TERRAIN=flat BUILDAT_SKELDAT_SEED=2 \
		BUILDAT_SKELDAT_SIZE="2 -1 0" BUILDAT_SKELDAT_TIME=${T54:-0.2} \
		BUILDAT_SKELDAT_DAY=${D54:-60} \
		BUILDAT_SKELDAT_SPAWN="0 0" BUILDAT_SKELDAT_SKELETONS=0 BUILDAT_SKELDAT_TEST="${4-}" \
		start_server "$1" "STATUS Listening" 300 auto \
		"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
		-D "$t/srv58" -C "$t/srv.cache" -l 3 || fail "the server ($1)"
	CHECK_PIDS+=($SERVER_PID)
	printf '%s\n' "$placed" "delay $3" quit > "$t/$2.cmds"
	client $2 "$t/$2.cmds"
	wait $CLIENT || fail "the boats' drive $2 ($t/$2.log)"
	kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
}
boats "$log58" boats1 160000 "$bt54"
# [SKELDAT_SKULL_CALL] A strip of bones 3 x 21 into the pond, a green skull
# at its far end and a skeleton 14 short of it; a 600 s day from 0.6617: the
# call an hour before sunset 28 s in, about 7 s after the fixtures, the
# boarding at sunset 53 s in. The skeleton is in the sun and wanders the
# strip meanwhile, so the call's distance varies: a way to the skull's
# water is searched unless it is within BOAT_NEAR already
bt54c="level -1 44 3 21 skeldat:bone_block -1; level -35 10 71 34 skeldat:water_source -1"
bt54c="$bt54c; level -35 65 71 16 skeldat:water_source -1; level -35 44 34 21 skeldat:water_source -1"
bt54c="$bt54c; level 2 44 34 21 skeldat:water_source -1; marker 0 64 skeldat:green_skull"
bt54c="$bt54c; skeleton 0 50"
W54=skullcall T54=0.6617 D54=600 boats "$t/srv58_call.log" boats_call 75000 "$bt54c"
call=$(python3 -I - "$t/srv58_call.log" <<'PY'
import sys, re
a = open(sys.argv[1], errors="replace").read()
k = re.search(r"skeldat: test: a skeleton \((\d+)\) at", a).group(1)
c = re.search(r"a green skull at \S+ calls a skeleton \(%s\), (\d+) away" % k, a)
assert c, "no call"
# The way is searched as the skull calls, before the call's line
w = re.search(r"a skeleton \(%s\) finds a way to -?\d+,\d+,6[34]:" % k, a)
assert w or int(c.group(1)) <= 4, ("no way to the call from", c.group(1))
b = re.search(r"a skeleton \(%s\) takes to a boat" % k, a)
assert b and b.start() > c.start(), "the called skeleton took no boat"
print("called from %s, boarded" % c.group(1))
PY
) || fail "the skull's call ($t/srv58_call.log)"
grep -aq "skeldat: a skeleton ([0-9]*) takes to a boat" "$log58" ||
	fail "no skeleton took to a boat ($log58)"
grep -aq "skeldat: a skeleton on a boat" "$t/boats1.log" ||
	fail "the client drew no boat ($t/boats1.log)"
# [SKELDAT_BOAT_STAND] Standing on it as it moves, not walking
grep -aq "skeldat: a skeleton stands on its moving boat ([0-9]*), its limbs at 0 degrees" "$t/boats1.log" ||
	fail "the skeleton on the moving boat not standing ($t/boats1.log)"
boats "$t/srv58_2.log" boats2 170000
boat=$(python3 -I - "$log58" "$t/srv58_2.log" <<'PY'
import sys, re
a = open(sys.argv[1], errors="replace").read()
b = open(sys.argv[2], errors="replace").read()
k = re.search(r"skeldat: test: a skeleton \((\d+)\) at", a).group(1)
assert re.search(r"a skeleton \(%s\) places a green skull at" % k, a), "no green skull"
m = re.search(r"a skeleton \(%s\) takes to a boat at (-?\d+),(-?\d+), aim ([-\d.]+)" % k, a)
assert m, "the island's skeleton took no boat"
r = re.search(r"a skeleton \(%s\) on a boat at -?\d+,-?\d+, aim ([-\d.]+)" % k, b)
assert r and r.group(1) == m.group(3), ("the boat not read back", m.group(3), r and r.group(1))
assert re.search(r"a skeleton \(%s\) on a boat aims" % k, b), "no new aim at the sunset"
l = re.search(r"a skeleton \(%s\) lands at \((-?\d+) (-?\d+)\)" % k, b)
assert l, "no landing"
lx, lz = int(l.group(1)), int(l.group(2))
assert (lx - 0) ** 2 + (lz - 45) ** 2 >= 144, ("landed near home", lx, lz)
for log in (a, b[:l.start()]):
    assert not re.search(r"the skeleton \(%s\) (burns|is in water)" % k, log), "burnt or drowned"
# [SKELDAT_BOAT_LAND_SKULL] A skull by the landing, and no burning after
sk = re.search(r"a skeleton \(%s\) lands at .*, a skull at (-?\d+),-?\d+,(-?\d+)" % k, b)
assert sk and abs(int(sk.group(1)) - lx) <= 1 and abs(int(sk.group(2)) - lz) <= 1, ("no skull by the landing", sk and sk.groups())
assert not re.search(r"the skeleton \(%s\) burns" % k, b[l.end():]), "it burnt by its skull"
print("a boat from %s,%s, aim %s; landed at %d %d, a skull at %s,%s" % (m.group(1), m.group(2), m.group(3), lx, lz, sk.group(1), sk.group(2)))
PY
) || fail "boats ($log58, $t/srv58_2.log)"
# [SKELDAT_BOAT_FAULTS] Boats by their age, at night: a pond from 10 ahead
# with ground islands in its row 41 -- a boned shore (3) and a bone-block
# one (15) beside a boat a day old (A, -10) and one 3 days old (B, 0), a
# bone-block one beside a boat 5 days old (C, 10) -- each boat 11.4 from
# where it boarded and its shores 12 and more, which a boat once waited
# beside forever. A lands on neither, B on the boned one, C on the bone
# block. D, a boat 12 from the player, places no marker skull on seeing it.
W=skeldat:water_source
bt54a="level -30 10 61 31 $W -1; level -30 42 61 29 $W -1; level -30 41 20 1 $W -1"
bt54a="$bt54a; level -8 41 8 1 $W -1; level 2 41 8 1 $W -1; level 11 41 20 1 $W -1"
bt54a="$bt54a; bones -10 41 3; bones -9 41 15; bones 0 41 3; bones 1 41 15; bones 10 41 15"
bt54a="$bt54a; skeleton -10 40 boat 1 -10 28.6; skeleton 0 40 boat 3 0 28.6"
bt54a="$bt54a; skeleton 10 40 boat 5 10 28.6; skeleton 0 12 boat 0.5 0 9"
W54=boatage T54=0.85 D54=600 boats "$t/srv58_age.log" boats_age 30000 "$bt54a"
# [SKELDAT_BOAT_LAND_SKULL] Its skull keeps the sun off: B's boat alone,
# a 600 s day from 0.15, so it lands before the dawn (0.19, 23 s in) on
# a bare shore, a skull beside it; into the day (0.30), it does not burn
bt54s="level -30 10 61 31 $W -1; level -30 42 61 29 $W -1; level -30 41 20 1 $W -1"
bt54s="$bt54s; level -8 41 8 1 $W -1; level 2 41 28 1 $W -1; bones 0 41 3"
bt54s="$bt54s; skeleton 0 40 boat 3 0 28.6"
W54=boatskull T54=0.15 D54=600 boats "$t/srv58_skull.log" boats_skull 90000 "$bt54s"
skull=$(python3 -I - "$t/srv58_skull.log" <<'PY'
import sys, re
a = open(sys.argv[1], errors="replace").read()
k = re.search(r"skeldat: test: a skeleton \((\d+)\) at", a).group(1)
l = re.search(r"a skeleton \(%s\) lands at \((-?\d+) (-?\d+)\).*, a skull at (-?\d+),(-?\d+),(-?\d+)" % k, a)
assert l, "no landing with a skull"
assert not re.search(r"the skeleton \(%s\) (burns|is in water)" % k, a[l.end():]), "it burnt or drowned by its skull"
print("landed at %s %s, a skull at %s,%s,%s, no burning into the day" % l.groups())
PY
) || fail "the landing's skull ($t/srv58_skull.log)"
age=$(python3 -I - "$t/srv58_age.log" <<'PY'
import sys, re
a = open(sys.argv[1], errors="replace").read()
ks = re.findall(r"skeldat: test: a skeleton \((\d+)\) at", a)
assert len(ks) == 4, ks
def landed(k):
    m = re.search(r"a skeleton \(%s\) lands at \((-?\d+) (-?\d+)\)" % k, a)
    return m and (int(m.group(1)), int(m.group(2)))
A, B, C = landed(ks[0]), landed(ks[1]), landed(ks[2])
assert A not in ((-10, 41), (-9, 41)), ("a day-old boat landed on bones", A)
assert B == (0, 41), ("a 3-day boat not on the boned shore", B)
assert C == (10, 41), ("a 5-day boat not on the bone block", C)
assert not re.search(r"a skeleton \(%s\) places a marker skull" % ks[3], a), "a boat placed a marker"
print("1 day: %s; 3 days: %s; 5 days: %s; no marker from a boat" % (A or "on the water", B, C))
PY
) || fail "boats by their age ($t/srv58_age.log)"
# 55. Water holds no bones ([SKELDAT_BONES_UNDERWATER]): flat ground at
# noon with the bones at full at x >= 0 (FILL=half), a pond 16 x 16 and 8
# deep dug into them (its water put over voxels that had bones, its bed
# stone at full), a section's expansion every 0.3 s at 10x: bones grown
# into the water off the bed; the world started again with its map
# (BUILDAT_SKELDAT_SURVEY): every column of the pond is water with no
# bones, so no pile on the surface and no bones carried up. Then a lake
# world with bones on its surface alone (FILL=surface, the lake's bed
# bare), a section's expansion every 0.3 s: it ends, the bed not waited
# for. (A shore the water drained off gets its bones through the ground
# now, not the water: at the default pace that took longer than 90 s.)
lb="level 4 -8 16 16 skeldat:stone -9"
for dy in -8 -7 -6 -5 -4 -3 -2 -1; do lb="$lb; level 4 -8 16 16 skeldat:water_source $dy"; done
lake55() { # log; the caller's env with it
	local log=$1
	BUILDAT_SKELDAT_WORLD=lakebed BUILDAT_SKELDAT_TERRAIN=flat BUILDAT_SKELDAT_SEED=2 \
		BUILDAT_SKELDAT_SIZE="1 -1 0" BUILDAT_SKELDAT_TIME=0.5 BUILDAT_SKELDAT_DAY=600 \
		BUILDAT_SKELDAT_SPAWN="0 0" BUILDAT_SKELDAT_SKELETONS=0 BUILDAT_SKELDAT_SPEED=10 \
		BUILDAT_SKELDAT_EXPAND=0.3 \
		start_server "$log" "STATUS Listening" 300 auto \
		"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
		-D "$t/srv59" -C "$t/srv.cache" -l 3 || fail "the server ($log)"
	CHECK_PIDS+=($SERVER_PID)
}
BUILDAT_SKELDAT_FILL=half BUILDAT_SKELDAT_TEST="$lb" lake55 "$t/srv55.log"
printf '%s\n' "$placed" "delay 40000" quit > "$t/lakebed.cmds"
client lakebed "$t/lakebed.cmds"
wait $CLIENT || fail "the lake bed's drive ($t/lakebed.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
wet=$(grep -a "skeldat: bones: " "$t/srv55.log" | tail -1 | sed 's/.*; \([0-9]*\) grown into a liquid.*/\1/')
[ "${wet:-0}" -ge 5 ] || fail "bones grown into the pond off its bed: ${wet:-none} ($t/srv55.log)"
BUILDAT_SKELDAT_SURVEY=1 lake55 "$t/srv55_map.log"
wait_for_log "$t/srv55_map.log" "skeldat: the map written to" 120 || fail "the lake bed's map ($t/srv55_map.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
pond=$(python3 -I - "$t/srv55.log" "$(grep -a "skeldat: the map written to" "$t/srv55_map.log" | sed 's/.*written to //')" <<'PY'
import sys, re
from PIL import Image
a = open(sys.argv[1], errors="replace").read()
m = re.findall(r"skeldat: test: skeldat:water_source at y -?\d+ over (-?\d+),(-?\d+) (\d+)x(\d+)", a)
assert m, "no pond"
x0, z0, w, d = map(int, m[-1])
im = Image.open(sys.argv[2]).convert("RGB")
W = im.size[0]; h = W // 2
bad = [(x, z, im.getpixel((x + h, W - 1 - (z + h))))
	for z in range(z0, z0 + d) for x in range(x0, x0 + w)
	if im.getpixel((x + h, W - 1 - (z + h))) != (40, 80, 200)]
assert not bad, "the pond's columns not clean water: %d, %s" % (len(bad), bad[:4])
print("%dx%d at %d,%d all clean water" % (w, d, x0, z0))
PY
) || fail "the lake bed's map ($t/srv55_map.log)"
BUILDAT_SKELDAT_WORLD=lakeend BUILDAT_SKELDAT_TERRAIN=lake BUILDAT_SKELDAT_SEED=2 \
	BUILDAT_SKELDAT_SIZE="1 -1 0" BUILDAT_SKELDAT_FILL=surface BUILDAT_SKELDAT_SPEED=2 \
	BUILDAT_SKELDAT_SKELETONS=0 BUILDAT_SKELDAT_WATER_REPORT=1 BUILDAT_SKELDAT_EXPAND=0.3 \
	start_server "$t/srv55_end.log" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
	-D "$t/srv59" -C "$t/srv.cache" -l 3 || fail "the server ($t/srv55_end.log)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$t/srv55_end.log" "every column's top has bones: the world ends after" 90 ||
	fail "the lake world with a bare bed did not end ($t/srv55_end.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
grep -aq "skeldat: water: [1-9][0-9]* voxels" "$t/srv55_end.log" || fail "the lake world had no water ($t/srv55_end.log)"
# 56. Boars in water ([SKELDAT_BOAR_SWIM]), flat ground, still water. A
# 120 s day from 0.62: a pond 13 x 13 a voxel deep with a middle 5 x 5 four
# deep; boar W on its shallow rim floats, is never over the deep middle,
# and is out of the water within a quarter day (30 s, and the swim);
# boar D in the middle swims for shallower water; boar N in a pit of
# water walled 3 high, from before sunset (15.6 s in), is gone at sunrise
# (75.6 s), no drop. Then at 0.3 of a long day: a boar over a pond 4
# deep and one in a pool a voxel deep, the client gone 3 s after: no
# player within SLEEP, the deep one is gone, the shallow one kept.
sw="level 4 -6 13 13 skeldat:water_source -1; level 8 -2 5 5 skeldat:stone -5"
for dy in -4 -3 -2 -1; do sw="$sw; level 8 -2 5 5 skeldat:water_source $dy"; done
sw="$sw; level -2 10 5 5 skeldat:stone 2; level -1 11 3 3 skeldat:water_source -1"
sw="$sw; boar 6 4; boar 10 0; boar 0 12"
swim56() { # log, client name, delay ms, fixtures
	BUILDAT_SKELDAT_WORLD=$2 BUILDAT_SKELDAT_TERRAIN=flat BUILDAT_SKELDAT_SEED=2 \
		BUILDAT_SKELDAT_SIZE="1 -1 0" BUILDAT_SKELDAT_TIME=${T56:-0.62} \
		BUILDAT_SKELDAT_DAY=${D56:-120} BUILDAT_SKELDAT_STILL_WATER=1 \
		BUILDAT_SKELDAT_SPAWN="0 0" BUILDAT_SKELDAT_SKELETONS=0 BUILDAT_SKELDAT_TEST="$4" \
		start_server "$1" "STATUS Listening" 300 auto \
		"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
		-D "$t/srv60" -C "$t/srv.cache" -l 3 || fail "the server ($1)"
	CHECK_PIDS+=($SERVER_PID)
	printf '%s\n' "$placed" "delay $3" quit > "$t/$2.cmds"
	client $2 "$t/$2.cmds"
	wait $CLIENT || fail "the boars' drive $2 ($t/$2.log)"
}
swim56 "$t/srv60.log" swim 85000 "$sw"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
swim=$(python3 -I - "$t/srv60.log" <<'PY'
import sys, re
a = open(sys.argv[1], errors="replace").read()
W, D, N = re.findall(r"skeldat: test: a boar \((\d+)\) at", a)
f = re.search(r"the boar \(%s\) floats, its feet at ([-0-9.]+), the water's top at (-?\d+)" % W, a)
assert f, "W did not float"
assert 0.6 < int(f.group(2)) + 0.5 - float(f.group(1)) < 0.9, ("W not at the top", f.groups())
assert not re.search(r"the boar \(%s\) is over deep water" % W, a), "W went over the deep middle"
o = re.search(r"the boar \(%s\) is out of the water after (\d+) s" % W, a)
assert o and int(o.group(1)) <= 50, ("W not out within a quarter day and the swim", o and o.group(1))
assert re.search(r"the boar \(%s\) swims for shallower water" % D, a), "D did not swim for shallower water"
assert re.search(r"the boar \(%s\) spent the night in water" % N, a), "N not gone at sunrise"
assert not re.search(r"the boar \(%s\) is out of the water" % N, a), "N got out of the pit"
assert "a drop of" not in a, "a drop"
print("W floated (feet %s, top %s), out after %s s; D swam for shallower water; N gone at sunrise" %
	(f.group(1), f.group(2), o.group(1)))
PY
) || fail "boars in water ($t/srv60.log)"
deep="level 6 -5 11 11 skeldat:stone -5"
for dy in -4 -3 -2 -1; do deep="$deep; level 6 -5 11 11 skeldat:water_source $dy"; done
deep="$deep; level -12 -2 5 5 skeldat:water_source -1; boar 11 0; boar -10 0"
T56=0.3 D56=2400 swim56 "$t/srv60_deep.log" swim_deep 3000 "$deep"
wait_for_log "$t/srv60_deep.log" "left in deep water" 20 ||
	fail "the boar over deep water not gone with no player near ($t/srv60_deep.log)"
sleep 2
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
left=$(python3 -I - "$t/srv60_deep.log" <<'PY'
import sys, re
a = open(sys.argv[1], errors="replace").read()
E, S = re.findall(r"skeldat: test: a boar \((\d+)\) at", a)
assert re.search(r"the boar \(%s\) left in deep water" % E, a), "E kept"
assert not re.search(r"the boar \(%s\) left in deep water" % S, a), "S gone from shallow water"
print("the deep one gone, the shallow one kept")
PY
) || fail "boars left in water ($t/srv60_deep.log)"
# 57. Boars asleep ([SKELDAT_BOAR_SLEEP]): flat ground, a 240 s day from
# 0.68 (sunset 17 s in, the shade's hour to 27 s, up an hour before
# sunrise, 127 s): a tree 8 ahead (a log 4 high, leaves 5 x 5 at its top
# and 3 x 3 over), a boar 7 east of it. It goes to the shade under the
# leaves and lies down there (sky light 4 to 14), the client draws it
# lying; the server stopped 50 s in and started again: still lying, the
# client draws it so, and it gets up at the hour before sunrise.
tree="boar 7 8"
for y in 0 1 2 3; do tree="$tree; set 0 $y 8 skeldat:tree"; done
for x in -2 -1 0 1 2; do for z in 6 7 8 9 10; do
	[ $x = 0 ] && [ $z = 8 ] || tree="$tree; set $x 3 $z skeldat:leaves"; done; done
for x in -1 0 1; do for z in 7 8 9; do tree="$tree; set $x 4 $z skeldat:leaves"; done; done
sleep57() { # log, client name, delay ms[, fixtures]; T57 the time, for a new world
	[ -n "${T57:-}" ] && export BUILDAT_SKELDAT_TIME=$T57
	BUILDAT_SKELDAT_WORLD=boarsleep BUILDAT_SKELDAT_TERRAIN=flat BUILDAT_SKELDAT_SEED=2 \
		BUILDAT_SKELDAT_SIZE="1 -1 0" BUILDAT_SKELDAT_DAY=240 \
		BUILDAT_SKELDAT_SPAWN="0 0" BUILDAT_SKELDAT_SKELETONS=0 BUILDAT_SKELDAT_TEST="${4-}" \
		start_server "$1" "STATUS Listening" 300 auto \
		"$here/Build/bin/buildat_server" -m "$here/apps/skeldat" \
		-D "$t/srv61" -C "$t/srv.cache" -l 3 -u launcher=1 || fail "the server ($1)"
	unset BUILDAT_SKELDAT_TIME
	CHECK_PIDS+=($SERVER_PID)
	printf '%s\n' "$placed" "event skeldat_admin invulnerable client1 on" "delay $3" quit \
		> "$t/$2.cmds"
	client $2 "$t/$2.cmds"
	wait $CLIENT || fail "the boar's drive $2 ($t/$2.log)"
	kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
}
T57=0.68 sleep57 "$t/srv61.log" sleep1 50000 "$tree"
# A test item keeps the night's spawning off, as in the first run; the
# player invulnerable (the launcher's, an admin) to the night's skeletons
sleep57 "$t/srv61_2.log" sleep2 85000 "give skeldat:stone 1 1"
asleep=$(python3 -I - "$t/srv61.log" "$t/srv61_2.log" "$t/sleep1.log" "$t/sleep2.log" <<'PY'
import sys, re
a, b, c1, c2 = (open(f, errors="replace").read() for f in sys.argv[1:])
k = re.search(r"skeldat: test: a boar \((\d+)\) at", a).group(1)
s = re.search(r"the boar \(%s\) goes to the shade at (-?\d+),(-?\d+)" % k, a)
assert s, "no shade found"
l = re.search(r"the boar \(%s\) lies down at ([-0-9.]+),[-0-9.]+,([-0-9.]+), its sky light (\d+)" % k, a)
assert l, "it did not lie down"
x, z, sky = float(l.group(1)), float(l.group(2)), int(l.group(3))
t = re.search(r"test: set skeldat:tree at (-?\d+),-?\d+,(-?\d+)", a)
tx, tz = int(t.group(1)), int(t.group(2))
assert abs(int(s.group(1)) - tx) <= 2 and abs(int(s.group(2)) - tz) <= 2, ("the shade not under the leaves", s.groups(), tx, tz)
assert abs(x - tx) <= 2.5 and abs(z - tz) <= 2.5, ("not lying under the leaves", x, z)
assert 3 < sky < 15, ("not in medium shade", sky)
assert "skeldat: a boar lies down" in c1, "the client did not draw it lying"
assert not re.search(r"the boar \(%s\) goes to the shade" % k, b), "it looked for shade again after the restart"
assert "skeldat: a boar lies down" in c2, "not lying after the restart"
g = re.search(r"the boar \(%s\) gets up\n" % k, b)
assert g, "it did not get up"
assert "skeldat: a boar gets up" in c2, "the client did not draw it getting up"
print("shade at %s,%s, lying at %.1f,%.1f with sky light %d; lying after the restart, up before sunrise" %
	(s.group(1), s.group(2), x, z, sky))
PY
) || fail "the boar's sleep ($t/srv61.log, $t/srv61_2.log)"
# The summary of a full run
shotlight=$(grep -a "skeletons, [0-9]* full" "$t/srv52_sealed.log" | tail -1 | sed 's/.*skeldat: //')
echo "a clear shot, sealed with 30: $shotlight"
echo "out of the sun: $sun"
echo "displaced: $pushed stones into water, the volume $dvol"
echo "a torch put out at $out"
echo "boats: $boat; a skull's call: $call; by age: $age; the landing's skull: $skull"
echo "under water: $wet grown into the pond, its map $pond; a lake world with a bare bed ended"
echo "boars in water: $swim; $left"
echo "boars asleep: $asleep"
echo "an island climbed to $coast"
echo "forms:$forms lava spring: open $(echo $l1 | awk '{ print $2 "->" $NF }'), walled $(echo $l2 | awk '{ print $2 "->" $NF }')"
echo "a night: $(echo $night)"
echo "lanterns: $lantern"
echo "skeletons: clean: $clean; flooded, after the player: $(echo "$last" | sed 's/.*skeldat: //'); the world with 2000 added: $light"
echo "a new world populated: $pop"
echo "far skeletons: $far"
echo "a respawn far away: the chunks within 2 drawn $respawn"
echo "run 1: $(grep -ac "pulled back" "$t/srv1.log") pull backs; run 2: $mobs mobs back"
echo "PASS: skeldat's rules, the movement check, the chat's report and mute, the admin's menu and map, the bones zone, the world's end, the skeletons' count, sleep and wake, a marker skull, a night's walk and bone blocks, lanterns lit, luring and taken, a marker dug and placed, the dig's crack, the world sizes, crafting more, invulnerability, items on the ground, a far respawn's world, a new world's skeletons, the far skeletons, the world's edge, a skeleton's body after its light form, no sun beside a bone block, death in water and a pond kept out of, ways built of bone, the bow, the skateboard and its roll, free-running, a skull down a shaft, the bones' speed, the opening dialog and the starter items, the high scores, the re-run, the touch controls, the picker's worlds and pause, skipping time, bridges on the long walk, loot on the ground, the world at exit started again, the sounds heard, the making over its map, the hazards' water and gas, a clear shot, shelter from the sun and lava's burn, water pushed aside by a placed voxel, torches put out by water, a wooden board, boats, bones off a lake's bed and none in its water, boars swimming and asleep in the shade"
# vim: set noet ts=4 sw=4:
