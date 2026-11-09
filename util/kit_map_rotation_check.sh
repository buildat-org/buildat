#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~3.5 min (2026-11-07)
# covers: builtin/kit/kit.cpp builtin/kit/api.h builtin/kit/box/box.c builtin/kit/types/arena.lua builtin/kit/client_lua/editor.lua apps/workbench/**
# [KIT_MAP_ROTATION] (kit_plan stage 7b) One composition, a lobby and three
# maps as scenes of it, composed on a fresh Workbench save with the editor's
# ops (kitboss, the admin) and played by kitboss and kitbob. The maps:
#   alpha: grassland, huts, teams Red and Blue
#   beta:  desert, teams Gold and Teal
#   gamma: snow, teams Jade and Aqua, a button into the arena's next_map
# Each has its own text ("Map <name>") and a kit/timer of its own length into
# its first team's score, that team's win_score reached linked to the
# arena's "win": a round's winner says whose timer ran, and a map not picked
# running sends the arena a team not in the round, which it logs.
# The arena's maps begin by its inspector's "Add to maps" dropdown (add_to_maps.png).
# The arena (kit/arena, in the lobby's zone round the spawn: back from a
# round both queue again) has maps "alpha, beta, gamma, nowhere". Played:
#   1. map_pick round_robin: alpha, beta, gamma, alpha
#   2. map_pick random (Stop, set, Play): six rounds, each on what the lobby
#      said was next, more than one map among them
#   3. map_pick signal: alpha, alpha again; the lobby's prev button: gamma
#      (the use of its button there leaves the round on gamma); next twice:
#      beta
# For each round: the session on the map, both players into that map's copy
# and its teams, its team the winner, the players
# back in the lobby; the client's text its map's. Screenshots (look at them):
# alpha.png, beta.png, gamma.png, lobby.png.
#   KIT_MAP_WEB=1: the second player (webbie) on the web client, in Chrome
#   (util/build_web.sh first); its screenshots web_alpha.png and so on.
#   util/kit_map_rotation_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
web=${KIT_MAP_WEB:-} second=kitbob web_args=
if [ -n "$web" ]; then
	command -v "${CHROME:-google-chrome}" > /dev/null || skip "no Chrome"
	[ -f "$here/web/buildat.wasm" ] || skip "no web client (util/build_web.sh)"
	second=webbie web_args="-W $here/web"
fi
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_map_rotation; t=$CHECK_TMP
cd "$here/Build"

start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 4 --sim-rate 1 $web_args ||
	fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
client() # <name>: its commands in $t/<name>.cmds; BUILDAT_JOIN_* its login
{
	run_client 120 "$t/$1.log" timeout 600 bin/buildat -C "$t/client_cache" \
		-D "$t/cu_$1" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
		-c @"$t/$1.cmds" ||
		fail "client $1 failed ($t/$1.log, $t/srv.log)"
}
export BUILDAT_JOIN_PASSWORD=checkpass12
ed() { printf 'event kit_edit %s\nwait_log 10000 kit editor: state:\n' "$1"; }
id=2
place() # <type> <x, y, z> [parent]: the next id
{
	id=$((id + 1))
	ed "{\"op\": \"place\", \"type\": \"$1\", \"pos\": [$2]${3:+, \"parent\": $3}}"
}
set_() # <id> <param> <value>
{
	ed "{\"op\": \"set\", \"id\": $1, \"comp\": 0, \"param\": \"$2\", \"value\": $3}"
}
link() # <from> <output> <to> <input>
{
	ed "{\"op\": \"link\", \"id\": $1, \"comp\": 0, \"output\": \"$2\", \"to\": $3, \"input\": \"$4\"}"
}
world() # <width> <biome>: the scene's World, flat
{
	place kit/terrain '0, 1, 0'
	set_ $id surface '"voxels"'
	set_ $id generator '"flat"'
	set_ $id biome "\"$2\""
	set_ $id decorations false
	set_ $id border '"wall"'
	set_ $id width "$1"
	set_ $id depth "$1"
}
team() # <x, y, z> <name> <color>
{
	place kit/team "$1"
	set_ $id name "\"$2\""
	set_ $id color "\"$3\""
}
map_scene() # <name> <biome> <seconds> <team 1> <color> <team 2> <color>
{
	id=$((id + 1))
	printf 'event kit_edit {"op": "new_scene", "name": "%s"}\nwait_log 30000 kit editor: in the scene %s of\n' "$1" "$1"
	world 32 "$2"
	team '5, 1, 0' "$4" "$5"; local first=$id
	set_ $id win_score 1
	link $id reached $ARENA win
	team '-5, 1, 0' "$6" "$7"
	eval "TEAMS_$1='$4 $6'"
	place kit/timer '0, 1, 8'
	set_ $id interval "$3"
	set_ $id repeats 1
	set_ $id autostart true
	link $id done $first add
	place kit/ui_text '0, 1, 9'
	set_ $id text "\"Map $1\""
	set_ $id anchor '"top_left"'
	set_ $id size 5
}
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log 10000 kit editor: state: 1 entities, 0 to undo
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by kitboss)
EOF
	world 32 grassland
	place kit/spawner '0, 1, 0'
	set_ $id players true
	place kit/arena '-2, 1, -2'; ARENA=$id
	set_ $id size '[5, 3, 5]'
	set_ $id players 2
	# Long enough for a button or a Stop between a round's end and the next
	set_ $id countdown 3
	set_ $id duration 60
	set_ $id results 2
	set_ $id after_round 0
	set_ $id hud_style '"plain"'
	place kit/button '3, 1, 1'; NEXT=$id
	set_ $id hold 0.2
	link $id pressed $ARENA next_map
	place kit/button '3, 1, -1'; PREV=$id
	set_ $id hold 0.2
	link $id pressed $ARENA prev_map
	# What tells kitbob it is over
	place kit/button '-3, 1, 0'; DONE=$id
	team '-6, 1, 4' Done '#808080'
	link $DONE pressed $id add
	map_scene alpha grassland 4 Red '#d03030' Blue '#3050e0'
	map_scene beta desert 5 Gold '#e0c020' Teal '#20c0c0'
	map_scene gamma snow 6 Jade '#20a040' Aqua '#40a0e0'
	place kit/button '5, 1, 2'; IN_ROUND=$id
	link $id pressed $ARENA next_map
	# Last (a prefab of voxels alone may take no id)
	cat <<'EOF'
event kit_edit {"op": "scene", "name": "alpha"}
wait_log 30000 kit editor: in the scene alpha of
event kit_edit {"op": "place", "prefab": "kit/hut", "pos": [12, 1, 5]}
sync 2000
event kit_edit {"op": "scene", "name": "world"}
wait_log 30000 kit editor: in the scene world of
EOF
	# The inspector's dropdown adds a scene to the list; the rest by the op.
	# Apply sits below the 700-high window's inspector: scrolled to, as a
	# person would
	cat <<EOF
event kit_select $ARENA
wait_log 5000 kit editor: the inspector
frames 5
click Button "Behaviour"
frames 5
click DropDownList "▼" 925 645
delay 500
frames 3
screenshot $t/add_to_maps.png
click Text "alpha"
wait_log 5000 maps = alpha
mouse_pos 800 400
mouse_wheel -1
frames 1
mouse_wheel -1
frames 1
mouse_wheel -1
frames 1
mouse_wheel -1
frames 1
mouse_wheel -1
frames 3
click Button "Apply"
wait_log 10000 kit editor: state:
EOF
	set_ $ARENA maps '"alpha, beta, gamma, nowhere"'
	cat <<'EOF'
event kit_select
frames 3
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running (by kitboss)
keypress F6
wait_log 10000 kit editor: edit mode off
EOF
	# round <map>: the next round played, kitboss looking at it
	round()
	{
		printf 'wait_log 60000 kit editor: in session %d game\n' "$1"
		[ -z "${2:-}" ] || cat <<EOF
wait_log_any 30000 Map $2
sync 3000
idle 10000
look_dir 1 -0.25 0.4
delay 2000
frames 10
screenshot $t/$2.png
EOF
		[ -z "${3:-}" ] || printf 'event kit_use %s\nsync 3000\n' "$3"
		printf 'wait_log 60000 kit editor: in session 0 default\n'
	}
	# 1. Round-robin
	echo 'wait_log_any 60000 Next map: alpha'
	round 1 alpha
	echo 'wait_log_any 30000 Next map: beta'
	cat <<EOF
frames 10
screenshot $t/lobby.png
EOF
	round 2 beta
	round 3 gamma
	round 4
	# 2. Random: Stop, the mode, Play
	stop_set_play()
	{
		cat <<'EOF'
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by kitboss)
keypress F6
wait_log 10000 kit editor: edit mode on
EOF
		set_ $ARENA map_pick "\"$1\""
		cat <<'EOF'
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running (by kitboss)
keypress F6
wait_log 10000 kit editor: edit mode off
EOF
	}
	stop_set_play random
	for s in 5 6 7 8 9 10; do
		round $s
	done
	# 3. Signals
	stop_set_play signal
	round 11
	round 12
	cat <<EOF
event kit_use $PREV
wait_log 3000 Next map: gamma
EOF
	round 13 "" "$IN_ROUND"
	cat <<EOF
event kit_use $NEXT
wait_log 3000 Next map: alpha
delay 300
event kit_use $NEXT
wait_log 3000 Next map: beta
EOF
	round 14
	cat <<EOF
event kit_use $DONE
sync 3000
quit
EOF
} > "$t/boss.cmds"
cat > "$t/bob.cmds" <<EOF
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
wait_log 500000 shows "Done: 1"
quit
EOF
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client boss &
boss=$!
wait_for_log "$t/srv.log" "kitboss entered; 1 of 2 inside" 240 ||
	fail "kitboss did not get into the arena's zone ($t/srv.log)"
if [ -n "$web" ]; then
	steps=$(web_login_steps webbie) || fail "$steps"
	{
		printf '[\n ["nav", "${URL}"],\n%s\n' "$steps"
		echo ' ["waitlog", "player physics enabled", 120],'
		for m in alpha beta gamma; do
			printf ' ["waitlog", "shown: .Map %s", 120], ["wait", 2000], ["frames", 5],\n' $m
			printf ' ["shot", "${OUT}/web_%s.png"],\n' $m
		done
		printf ' ["waitlog", "shows .Done: 1", 500], ["sync", 3000]\n]\n'
	} > "$t/web.json"
	(WEB_DRIVE_VIEWPORT=1024x700@1 WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/" \
		"$here/util/web_drive.sh" chrome workbench "$t/web.json" "$t/drive" \
		> "$t/drive.txt" 2>&1) &
else
	BUILDAT_JOIN_NAME=kitbob BUILDAT_JOIN_CREATE=1 client bob &
fi
bob=$!
wait $boss || fail "the admin's client ($t/boss.log)"
wait $bob || fail "the second player's client ($t/bob.log, $t/drive.txt, $t/drive)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
s=$t/srv.log
second_log=$t/bob.log
[ -z "$web" ] || second_log=$t/drive/page.log
grep -aq "refused" "$t/boss.log" && grep -a "refused" "$t/boss.log" | head -5
ALPHA="$TEAMS_alpha" BETA="$TEAMS_beta" GAMMA="$TEAMS_gamma" \
ARENA=$ARENA SECOND=$second \
python3 - "$s" "$t/boss.log" "$second_log" <<'PY' || fail "the rounds ($s, $t/boss.log, $t/bob.log)"
import os, re, sys
log = open(sys.argv[1], errors="replace").read()
teams = {"alpha": os.environ["ALPHA"].split(), "beta": os.environ["BETA"].split(),
	"gamma": os.environ["GAMMA"].split()}
A = "kit/arena %s: " % os.environ["ARENA"]
def part(n):
	return log.split("Session %d (a game)" % n)[1].split("Session %d ended" % n)[0]
def map_of(n):
	m = re.findall(r"Session %d on the map (\w+)" % n, log)
	assert len(m) == 1, ("session", n, m)
	return m[0]
played = {}
for n in range(1, 15):
	m = played[n] = map_of(n)
	p = part(n)
	for who in ("kitboss", os.environ["SECOND"]):
		assert "workbench: %s to scene %s~%d" % (who, m, n) in p, (n, who, m)
		joined = re.findall(r"kit/team \d+: %s joins team (\w+)" % who, p)
		assert len(joined) == 1 and joined[0] in teams[m], (n, who, m, joined)
	assert "joins team" in p
	# Its team the winner. (A timer's log says nothing: the default round's
	# copies log alike)
	assert A + "round over: %s wins!" % teams[m][0] in p, (n, m)
	end = log.split("Session %d (a game)" % n)[1].split("Session %d (a game)" % (n + 1))[0]
	for who in ("kitboss", os.environ["SECOND"]):
		assert "workbench: %s to scene world" % who in end, (n, who, "back")
# A map not picked running: its timer's team into "win", none of the round's
assert "win: no team or player in" not in log, "a map not picked ran"
print("  rounds:", " ".join(played[n] for n in sorted(played)))
assert [played[n] for n in (1, 2, 3, 4)] == ["alpha", "beta", "gamma", "alpha"], played
print("ok: round_robin: alpha, beta, gamma, alpha")
# Random: each on what the lobby had as next
rnd = [played[n] for n in range(5, 11)]
assert len(set(rnd)) > 1, rnd
for n in range(5, 11):
	before = log.split("Session %d (a game)" % n)[0]
	nx = re.findall(re.escape(A) + r"next map: (\w+)", before)[-1]
	assert nx == played[n], (n, nx, played[n])
print("ok: random:", " ".join(rnd))
assert [played[n] for n in (11, 12, 13, 14)] == ["alpha", "alpha", "gamma", "beta"], played
assert "next_map in a round: its map stays" in part(13)
print("ok: signal: alpha twice, prev wraps to gamma (a press in its round changes nothing), next twice to beta")
assert A + "maps: no scene nowhere" in log
print("ok: a name no scene has is left out, logged")
# What the clients were shown, in order
for f in sys.argv[2:]:
	c = open(f, errors="replace").read()
	shown = re.findall(r'shown: "Map (\w+)"', c)
	want = []
	for n in sorted(played):
		if not want or want[-1] != played[n]:
			want.append(played[n])
	got = []
	for x in shown:
		if not got or got[-1] != x:
			got.append(x)
	assert got == want, (f, got, want)
print("ok: both clients shown each round's map's text, no other's")
PY
for m in alpha beta gamma lobby; do
	[ -s "$t/$m.png" ] || fail "no screenshot $m ($t)"
done
[ -z "$web" ] || cp "$t"/drive/web_*.png "$t"/ || fail "no web screenshots ($t/drive)"
python3 - "$t" "" ${web:+web_} <<'PY' || fail "the ground's colours ($t)"
import sys
from PIL import Image
# The lower half's average: alpha's grass green, beta's sand and gamma's snow
def avg(n):
	im = Image.open("%s/%s.png" % (sys.argv[1], n)).convert("RGB")
	w, h = im.size
	r = im.crop((w // 4, h * 3 // 4, w * 3 // 4, h * 7 // 8)).resize((1, 1), Image.BOX).getpixel((0, 0))
	print("  " + n, r)
	return r
for pre in sys.argv[2:]:
	a, b, g = avg(pre + "alpha"), avg(pre + "beta"), avg(pre + "gamma")
	assert a[1] > a[0] and a[1] > a[2], "alpha is not green"
	assert b[0] > b[2] + 20, "beta is not sand"
	assert min(g) > max(a), "gamma is not snow"
PY
echo "ok: each map's ground in its screenshot ($t)"
if [ -n "${KIT_MAP_KEEP:-}" ]; then
	mkdir -p "$KIT_MAP_KEEP" && cp "$t"/*.png "$KIT_MAP_KEEP"/
fi
echo "PASS: map rotation through scenes: one composition's maps picked round-robin, at random and by signals; each round's players in its map, on its teams, its content alone running"
# vim: set noet ts=4 sw=4:
