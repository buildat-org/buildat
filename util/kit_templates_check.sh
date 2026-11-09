#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~3 min, ~5 min with web (2026-11-07)
# covers: apps/workbench/** builtin/world_menu/** builtin/kit/kit.cpp builtin/kit/types/player_state.lua builtin/kit/types/walker.lua builtin/kit/types/spawn_rule.lua builtin/kit/types/arena.lua builtin/kit/types/team.lua builtin/kit/types/goal.lua builtin/kit/types/sign.lua builtin/kit/types/button.lua builtin/kit/types/flag.lua builtin/kit/types/symmetry.lua src/impl/aitta.cpp client/core/aitta/init.lua util/pack_templates.sh util/kit_ctf_warp.lua
# [KIT_TEMPLATES] (kit_plan stage 7b, Workbench templates) Each template through
# New, opened in edit mode and played to its end by real clients. A check's
# default Aitta is a closed port, so all this but part 3 is the offline case.
# 0. Their files: the voxels named are Kit's, the licence file there.
# 1. Puzzle room, a fresh user: New lists Empty, then ours (p_new*.png). Created:
#    Stopped, in edit mode, the admin on the spawner; no goal warnings in the
#    inspector or at a draft's Publish (p_edit*.png). Played: the button, the
#    gate open on its timer; the levers in the wrong set keep the exit shut, the
#    right one opens it; out of it, solved (p_play*.png).
# 2. Arena, likewise (a_edit*.png), then two rounds by kitbob and kitboss, into
#    the lobby's queue by the pad: its maps in turn; a team's own beacon refused;
#    three presses of the other's, a win; back in the lobby (a_*.png).
# 2b. Capture the flag, likewise (c_*.png), shortened by edit ops: kitboss
#    takes the flag and places it in Red's zone, a point wins.
# 2c. Survival ([KIT_SURVIVAL_TEMPLATE]): opened (v_edit.png), its clock set
#    to just before dusk, played; kitbob digs two cells into his inventory
#    and places one back, a creature of the night's spawn rule chases and bites him; he
#    leaves and rejoins where he was (v_*.png). [KIT_SURVIVAL_TUNING] Before,
#    kitboss falls 14 m and is hurt; Stop and Play leave him where he is.
# 3. Packed by util/pack_templates.sh with a key made here, the licence file in
#    the archive and no .wasm, published to a local Aitta, `buildat aitta
#    install`ed: New lists it after ours, and it opens in edit mode (i_*.png).
# Screenshots kept with KEEP_TMP=1: $t/*.png
#   util/kit_templates_check.sh
#   util/kit_templates_check.sh web   parts 1 and 2's players in headless Chrome
#      on web/'s wasm: the sequences turned into a page's steps
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
WEB=
if [ "${1:-}" = web ]; then
	WEB=1
	command -v "${CHROME:-google-chrome}" > /dev/null || skip "no Chrome"
	[ -f "$here/web/buildat.wasm" ] || skip "no web client (util/build_web.sh)"
fi
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp "kit_templates${WEB:+_web}"; t=$CHECK_TMP
export BUILDAT_JOIN_PASSWORD=checkpass12

# 0. The files; the entities' ids by scene and name for the drives: P_ the room's,
# A_ the arena's
python3 -I - "$here" > "$t/ids.sh" <<'PY' || fail "the templates' files"
import json, re, sys
here = sys.argv[1]
known = set(json.load(open(here + "/builtin/kit/materials.json"))["voxels"])
for name, pre in (("puzzle_room", "P"), ("arena", "A"), ("ctf", "C"), ("airships", "S"),
		("survival", "V")):
	d = "%s/apps/workbench/templates/%s" % (here, name)
	m = json.load(open(d + "/meta.json"))
	assert m["kind"] == "template" and m["name"] == name and m["title"], name
	assert open(d + "/LICENSE").read().strip(), name
	comp = json.load(open(d + "/composition.json"))
	rows = comp["entities"]
	print("%s_next_id=%d" % (pre, max([comp.get("next_id", 2)] + [r["id"] + 1 for r in rows])))
	by = {r["id"]: r for r in rows}
	def scene(r):
		while r.get("kind") != "scene" and r.get("parent") in by:
			r = by[r["parent"]]
		# (one on the app root: "", so V__game_rules_...)
		return r.get("name", "") if r.get("kind") == "scene" else ""
	for r in rows:
		for c in r.get("components", []):
			v = c.get("params", {}).get("voxel", "")
			assert not v or v in known, (name, r["name"], v)
			v = c.get("params", {}).get("material", "")
			assert "/" not in v or v in known, (name, r["name"], v)
		key = re.sub(r"\W+", "_", scene(r) + "_" + r["name"])
		print("%s_%s=%d" % (pre, key, r["id"]))
PY
. "$t/ids.sh"
echo "ok: the templates' files"

cd "$here/Build"
b="$here/Build/bin/buildat"
# The lock always granted: the tools open with no lock asked, and Play's comes
# from the "Play mode" click
PAGE_STUB="(function(){ var held = null;
 Object.defineProperty(document, 'pointerLockElement', {configurable: true, get: function(){ return held; }});
 function set(e){ held = e; document.dispatchEvent(new Event('pointerlockchange')); }
 HTMLCanvasElement.prototype.requestPointerLock = function(){ if(held !== this) set(this); return Promise.resolve(); };
 document.exitPointerLock = function(){ if(held) set(null); };
 return 'stub'; })()"
# A sequence as a page's steps (kit_goals_check.sh's)
cat > "$t/to_web.py" <<'PY'
import json, math, re, shlex, sys
out, held = json.load(open(sys.argv[2])), None
for line in open(sys.argv[1]):
	line = line.strip()
	if not line:
		continue
	cmd, _, rest = line.partition(" ")
	if cmd == "event":
		out.append(["event", rest])
	elif cmd in ("wait_log", "wait_log_any"):
		ms, _, text = rest.partition(" ")
		out.append(["waitlog" if cmd == "wait_log" else "waitlog_any", re.escape(text), int(ms) / 1000])
	elif cmd in ("frames", "sync"):
		out.append([cmd, int(rest)])
	elif cmd == "delay":
		out.append(["holdkey", held, int(rest)] if held else ["wait", int(rest)])
	elif cmd == "keypress":
		out.append(["key", rest.lower() if len(rest) == 1 else rest])
	elif cmd == "keydown":
		held = rest.lower()
	elif cmd == "keyup":
		held = None
	elif cmd == "screenshot":
		out.append(["shot", rest])
	elif cmd == "click":
		a = shlex.split(rest)
		out.append(["click", *a[:2], *map(int, a[2:])])
	elif cmd == "look_dir":
		x, y, z = map(float, rest.split())
		out.append(["event", "kit_face %.3f %.3f" % (math.degrees(math.atan2(x, z)),
			-math.degrees(math.atan2(y, math.hypot(x, z))))])
	elif cmd == "quit":
		out.append(["sync", 3000])
	else:
		sys.exit("no page's step for: " + line)
json.dump(out, sys.stdout)
PY
# (no --sim-rate: the room's gate is a race against its 5 s, on the wall's clock)
server() # <name>: a fresh user dir <name>, its log <name>.log; web/ served in web mode
{
	SRV=$t/$1.log
	start_server "$SRV" "Listening at" 300 auto \
		bin/buildat_server -m ../apps/workbench -D "$t/$1" -l 4 \
		${WEB:+-W "$here/web"} ||
		fail "the server did not come up ($SRV)"
	CHECK_PIDS+=($SERVER_PID)
}
server_end() { kill -INT "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; }
native() # <name>: commands in $t/<name>.cmds; BUILDAT_JOIN_* its login
{
	run_client 60 "$t/$1.log" timeout 240 bin/buildat -C "$t/client_cache_$BUILDAT_JOIN_NAME" \
		-D "$t/cu_$BUILDAT_JOIN_NAME" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
		-c @"$t/$1.cmds" || fail "client $1 ($t/$1.log, $SRV)"
}
page() # <name> <login steps>
{
	printf '[["nav", "${URL}?scale=0.648148"], ["eval", %s], %s ["frames", 2]]' \
		"$(printf %s "$PAGE_STUB" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
		"$2" > "$t/$1.head.json"
	python3 "$t/to_web.py" "$t/$1.cmds" "$t/$1.head.json" > "$t/$1.json" ||
		fail "the steps of $1"
	WEB_DRIVE_VIEWPORT=1024x700@1 WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/" \
		"$here/util/web_drive.sh" chrome workbench "$t/$1.json" "$t/drive_$1" \
		> "$t/drive_$1.txt" 2>&1
	local st=$?
	cp "$t/drive_$1/page.log" "$t/$1.log" 2>/dev/null
	[ $st = 0 ] || fail "the page's $1 ($(tail -2 "$t/drive_$1.txt"), $t/$1.log, $SRV)"
}
boss() # <name>: the sequence as kitboss, whose account admin() made
{
	if [ -n "$WEB" ]; then
		page "$1" ' ["waitlog", "accounts: the login page shown", 120], ["wait", 1000],
 ["selall"], ["frames", 2], ["type", "kitboss"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["type", "checkpass12"], ["frames", 2], ["key", "Enter"], ["waitlog", "Joined as kitboss", 30],'
	else
		BUILDAT_JOIN_NAME=kitboss native "$1"
	fi
}
bob() # <name>
{
	if [ -n "$WEB" ]; then
		page "$1" "$(web_login_steps kitbob)"
	else
		BUILDAT_JOIN_NAME=kitbob BUILDAT_JOIN_CREATE=1 native "$1"
	fi
}
# The admin's account and open registration, natively (a page has no
# BUILDAT_JOIN_ADMIN), on a fresh server
admin()
{
	cat > "$t/admin.cmds" <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
wait_log_any 30000 world_menu: the list shown
sync 3000
quit
EOF
	wait_for_log "$SRV" "setup code [A-Z0-9]+" 30
	local code
	code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$SRV" | head -1)
	[ -n "$code" ] || fail "no setup code ($SRV)"
	BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
		BUILDAT_JOIN_ADMIN="setting open_registration on" native admin
}
# New, the template by its label, Create; up to the tools open
new_project() # <label> <shot prefix>
{
	cat <<EOF
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 world_menu: the list shown
frames 3
click Button "New project..."
wait_log 5000 world_menu: the name screen shown
frames 3
screenshot $t/$2_new.png
click DropDownList "▼"
delay 300
frames 3
screenshot $t/$2_new_open.png
click Text "$1"
wait_log 5000 world_menu: template picked
frames 3
screenshot $t/$2_new_picked.png
click Button "Create"
wait_log_any 60000 player physics enabled
wait_log_any 20000 kit editor: edit rights: yes
wait_log_any 20000 kit editor: edit mode on
delay 1500
sync 3000
frames 10
EOF
}
# What the builder sees; the goals' warnings in the inspector and at Publish
# (a draft's tools come in the edit state after the session's: edit mode
# off, then on)
edit_look() # <prefix> <a goal's id>
{
	cat <<EOF
screenshot $t/$1_edit_walk.png
keypress F2
wait_log 5000 kit editor: the view is
frames 10
screenshot $t/$1_edit_3d.png
keypress F1
wait_log 5000 kit editor: the view is
frames 10
screenshot $t/$1_edit_plan.png
keypress F3
wait_log 5000 kit editor: the view is
frames 5
event kit_select $2
wait_log 5000 kit editor: the inspector
wait_log_any 5000 kit editor: goal warnings: 0
frames 5
screenshot $t/$1_edit_inspector.png
event kit_edit {"op": "draft"}
wait_log 30000 kit editor: edit mode on
wait_log_any 1000 kit editor: in session 1 draft
frames 5
click Button "Publish"
wait_log 5000 kit editor: publish this draft: 0 goal warnings
sync 3000
click Button "Leave draft"
wait_log 30000 kit editor: edit mode on
wait_log_any 1000 kit editor: in session 0 default
frames 5
EOF
}
to_play()
{
	cat <<'EOF'
click Button "Play mode"
wait_log_any 10000 kit editor: the server is Running (by kitboss)
wait_log_any 10000 kit: controls: camera first_person
frames 10
look_dir 0 0 1
frames 5
EOF
}
# A walk +z: held, let go, as a page's held key is a length of time
walk() { printf 'keydown W\ndelay %s\nkeyup W\nframes 3\n' "$1"; }
use() { printf 'event kit_use %s\nsync 3000\n' "$1"; }
shot() { printf 'frames 10\nscreenshot %s\n' "$t/$1.png"; }
# A text on this client's screen in play: "shown, edit mode" is the tools' copy
up() { printf 'wait_log_any 15000 shown: "%s\n' "$1"; }

# 1. The puzzle room
server room
admin
{
	new_project "Puzzle room" p
	edit_look p "$P_world_goal_the_button"
	to_play
	up "Press the red button"
	shot p_play_start
	use "$P_world_button"
	up "The gate is open"
	shot p_play_gate
	# Through the gate before its 5 s are up, into the levers' reach
	walk 2200
	up "Find which two levers"
	shot p_play_levers
	# All three on: B holds the door shut. B off: open
	use "$P_world_lever_A"
	use "$P_world_lever_B"
	use "$P_world_lever_C"
	echo "look_dir 1 0 0"
	shot p_play_wrong
	echo "look_dir 0 0 1"
	use "$P_world_lever_B"
	up "Leave through the door"
	shot p_play_open
	walk 2200
	up "Solved!"
	shot p_play_solved
	echo "look_dir 0 0 -1"
	shot p_play_back
	echo quit
} > "$t/p.cmds"
boss p
server_end
python3 -I - "$t" "$P_world_lever_B" "$P_world_exit_door" <<'PY' || fail "the puzzle room's logs ($t)"
import re, sys
t, lever_b, door = sys.argv[1:]
srv = open(t + "/room.log", errors="replace").read()
cl = open(t + "/p.log", errors="replace").read()
for want in ("the project from the template puzzle_room", "A template: Stopped, in edit mode",
		"kitboss opens the template in edit mode"):
	assert want in srv, want
m = re.search(r"world_menu: template choices: (.*)", cl)
assert m and m[1].startswith("Empty, ") and "Arena" in m[1] and "Puzzle room" in m[1], m and m[1]
assert not re.search(r"goal warnings: [1-9]", cl), "goal warnings"
# The door opened by B going off, not before: B used twice, then it
uses = [m.start() for m in re.finditer("Entity %s used by kitboss" % lever_b, srv)]
opened = srv.find("kit/door %s: opened" % door)
assert len(uses) == 2 and uses[1] < opened, (uses, opened)
# Five: [KIT_GUIDE_BOTS]' bots-only "Flip lever A" passes on as done for a player
assert len(re.findall(r"kit/goal \d+: done for kitboss", srv)) == 5, "the goals' ends"
PY
echo "ok: the puzzle room opens in edit mode and is solved through to its exit"

# 2. The arena: kitbob to the pad first, kitboss when his countdown shows. The
# round takes kitboss first: Red at z -16, kitbob Blue at z 16 (asserted below)
round_runner() # <map> <own beacon> <beacon to press>
{
	cat <<EOF
wait_log 60000 left | Red 0 : Blue 0
sync 3000
look_dir 0 0 -1
EOF
	shot "a_$1_start"
	# His own beacon, near his spawn: refused
	use "$2"
	# Over the field, its 35 cells; a stand or a player holds him there. (A map's
	# first seconds may hold him: no line says when, physics may be on before
	# this runs. So long enough for both, the base's goal says he got there)
	for _ in 1 2 3 4 5 6 7; do walk 1800; done
	up "Press the red beacon"
	shot "a_$1_there"
	use "$3"
	echo "delay 2200"
	use "$3"
	echo "delay 2200"
	use "$3"
	echo "wait_log 20000 Blue wins!"
	shot "a_$1_won"
	echo "wait_log 30000 Last round: Blue won"
}
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
wait_log_any 120000 Next map: meadow
frames 10
look_dir 0 0 1
frames 5
EOF
	walk 1800
	echo "wait_log_any 8000 Starting in"
	round_runner meadow "$A_meadow_blue_beacon" "$A_meadow_red_beacon"
	cat <<'EOF'
wait_log_any 8000 Next map: dunes
frames 5
look_dir 0 0 1
EOF
	shot a_lobby_again
	walk 1800
	echo "wait_log 30000 Starting in"
	round_runner dunes "$A_dunes_blue_beacon" "$A_dunes_red_beacon"
	echo quit
} > "$t/a_bob.cmds"
{
	new_project Arena a
	edit_look a "$A_world_the_arena"
	to_play
	echo "wait_log_any 8000 Next map: meadow"
	shot a_lobby
	# kitbob on the pad; then he too
	echo "wait_log 120000 Starting in"
	walk 1800
	echo "wait_log 60000 left | Red 0 : Blue 0"
	echo "delay 1500"
	shot a_red_meadow
	echo "wait_log 60000 Blue wins!"
	shot a_red_lost
	echo "wait_log 30000 Last round: Blue won"
	echo "look_dir 0 0 1"
	walk 1800
	echo "wait_log 60000 left | Red 0 : Blue 0"
	echo "delay 1500"
	shot a_red_dunes
	echo "wait_log 60000 Blue wins!"
	shot a_red_lost2
	echo quit
} > "$t/a_boss.cmds"
server fight
admin
boss a_boss &
boss_pid=$!
wait_for_log "$SRV" "kitboss opens the template in edit mode" 180 ||
	fail "the arena did not open ($SRV)"
bob a_bob
wait "$boss_pid" || exit 1
server_end
python3 -I - "$t" <<'PY' || fail "the arena's logs ($t)"
import re, sys
t = sys.argv[1]
srv = open(t + "/fight.log", errors="replace").read()
bob = open(t + "/a_bob.log", errors="replace").read()
boss = open(t + "/a_boss.log", errors="replace").read()
assert "the project from the template arena" in srv
assert not re.search(r"goal warnings: [1-9]", boss), "goal warnings"
assert "kit editor: edit mode on" not in bob, "kitbob has the tools"
over = re.findall(r"round over: (.*?) --", srv)
assert len(over) == 2 and all(o.startswith("Blue wins! ") for o in over), over
assert srv.count("kitbob joins team Blue") == 2 and srv.count("kitboss joins team Red") == 2
assert srv.count("refused: ") >= 2 and "A use of entity" in srv, "his own beacon"
for m in ("a round for 2 players on meadow", "a round for 2 players on dunes"):
	assert m in srv, m
PY
echo "ok: the arena plays two rounds on its two maps, by a win on score"

# 2b. Capture the flag ([KIT_CTF_TEMPLATE]), likewise (c_edit*.png), then a
# round by kitbob and kitboss into the lobby's queue by the pad, started
# when both are ready ([KIT_READY_UP]: kitboss by the key, kitbob by the
# button). Shorter for
# the check by edit ops, Stopped: prep 3 s, a point every 3 s, one wins; and
# kitboss's warps (kit_ctf_check's type) to the flag and to Red's zone. He
# takes the flag, places it there: a point, Red wins
ed() { printf 'event kit_edit %s\nwait_log 10000 kit editor: state:\n' "$1"; }
set_() { ed "{\"op\": \"set\", \"id\": $1, \"comp\": 0, \"param\": \"$2\", \"value\": $3}"; }
{
	new_project "Capture the flag" c
	edit_look c "$C_world_the_arena"
	set_ "$C_map_prep_timer" repeats 3
	set_ "$C_map_the_flag" score_interval 3
	set_ "$C_world_the_arena" countdown 3
	set_ "$C_world_the_arena" score_to_win 1
	cat <<'EOF'
event kit_edit {"op": "scene", "name": "map"}
wait_log 30000 kit editor: in the scene map of world, map
event kit_edit {"op": "place", "type": "workbench/warp", "pos": [4, 1, 6]}
wait_log 10000 kit editor: state:
EOF
	w=$C_next_id
	set_ $w who '"kitboss"'
	set_ $w p1 '[0, 1, 0]'
	set_ $w p2 '[30, 1, 4]'
	cat <<'EOF'
event kit_edit {"op": "scene", "name": "world"}
wait_log 30000 kit editor: in the scene world of world, map
EOF
	to_play
	up "Stand on the golden pad and press Ready"
	shot c_lobby
	echo "wait_log_any 120000 Waiting for players: 1 of 2"
	walk 1800
	printf 'wait_log_any 30000 Ready: 0 of 2\nkeypress K\n'
	echo "wait_log_any 60000 The flag is out in 2 s"
	shot c_prep
	echo "wait_log_any 30000 The flag is out in 0 s"
	cat <<'EOF'
delay 500
keypress Y
wait_log 10000 shown: "Flag carried by Red
look_dir 1 0.3 0
EOF
	shot c_carry
	cat <<'EOF'
keypress U
delay 800
event kit_click_at 0 1 0 right
wait_log 30000 Red wins!
EOF
	shot c_won
	echo quit
} > "$t/c_boss.cmds"
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
wait_log_any 60000 shown: "Stand on the golden pad
frames 10
look_dir 0 0 1
frames 5
EOF
	walk 1800
	cat <<'EOF'
wait_log_any 60000 Ready: 1 of 2
keypress K
wait_log_any 60000 The flag is out in 0 s
wait_log_any 30000 shown: "Flag carried by Red
wait_log 30000 Red wins!
EOF
	shot c_bob_lost
	echo quit
} > "$t/c_bob.cmds"
mkdir -p "$t/ctf/apps/workbench/check_types"
cp "$here/util/kit_ctf_warp.lua" "$t/ctf/apps/workbench/check_types/warp.lua"
BUILDAT_WORKBENCH_TYPES=$t/ctf/apps/workbench/check_types server ctf
admin
boss c_boss &
boss_pid=$!
wait_for_log "$SRV" "kitboss opens the template in edit mode" 180 ||
	fail "capture the flag did not open ($SRV)"
wait_for_log "$SRV" "Play by kitboss" 180 ||
	fail "capture the flag did not start ($SRV)"
bob c_bob
wait "$boss_pid" || exit 1
server_end
python3 -I - "$t" "$C_map_the_flag" <<'PY' || fail "capture the flag's logs ($t)"
import re, sys
t, flag = sys.argv[1:]
srv = open(t + "/ctf.log", errors="replace").read()
boss = open(t + "/c_boss.log", errors="replace").read()
assert "the project from the template ctf" in srv
assert not re.search(r"goal warnings: [1-9]", boss), "goal warnings"
assert not re.search(r"edit refused|kit:edit_refused|kit editor: refused", boss + srv), "an edit refused"
assert "kitboss joins team Red" in srv and "kitbob joins team Blue" in srv
F = "kit/flag %s: " % flag
i = srv.index(F + "enabled")
j = srv.index(F + "taken by kitboss from home (Red)", i)
k = srv.index(F + "placed by kitboss", j)
s = srv.index(F + "scores 1 for Red", k)
assert srv.index("Red wins!", s)
assert "countdown over: a round for 2 players" in srv
for m in ("kitboss is ready", "kitbob is ready", "2 of 2 ready"):
	assert m in srv, m
# Nothing single across the seam: no parity warning at Play
assert "entities outside it in the other slices" not in srv, "a parity warning"
for hint in ("Take the flag at the middle", "The flag is out in "):
	assert 'shown: "' + hint in boss, hint
PY
echo "ok: capture the flag plays a round to a capture"

# 2c. Survival: the clock set to 17.98 (dusk a second into Play at its 20
# minute day), Played, kitboss gone. kitbob at the World's spawn (0.5, 189,
# 0.5; valleys seed 1) digs the grass and the dirt under it at (1, 188, 2),
# (1, 187, 2) (a hand's 1 s each: asked again), places the grass back; the
# night's spawn rule (enabled at dusk; here every 3 s, 4-8 m out) makes
# creatures by him and kitboss, one spots him and bites. He leaves and comes back
# where he left
dig2() # <x, y, z>: a dig asked twice (it waits)
{
	printf 'event workbench_build {"p": [%s], "voxel": "air"}\nsync 2000\ndelay 1000\n' "$1"
	printf 'event workbench_build {"p": [%s], "voxel": "air"}\nsync 2000\n' "$1"
}
{
	new_project Survival v
	shot v_edit
	to_play
	# [KIT_SURVIVAL_TUNING] a fall from 14 m over the plateau hurts; Stop
	# and Play leave him where he fell (keep_position). The clock set
	# between (it goes on over Stop and Play, from where it was set)
	ed '{"op": "mode", "on": true}'
	cat <<'EOF'
event kit_edit {"op": "walk_here", "pos": [4.5, 203, 4.5]}
wait_log 10000 the server put the player at (4.5, 203
event kit_edit {"op": "mode", "on": false}
wait_log 20000 your health
sync 2000
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is
EOF
	ed '{"op": "mode", "on": true}'
	ed "{\"op\": \"set\", \"id\": $V__game_rules_the_day_and_the_night, \"comp\": 1, \"param\": \"time\", \"value\": 17.98}"
	ed "{\"op\": \"set\", \"id\": $V_world_creatures_come_at_night, \"comp\": 0, \"param\": \"every\", \"value\": 3}"
	ed "{\"op\": \"set\", \"id\": $V_world_creatures_come_at_night, \"comp\": 0, \"param\": \"radius\", \"value\": 8}"
	cat <<'EOF'
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running
sync 2000
quit
EOF
} > "$t/v_boss.cmds"
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
wait_log_any 20000 kit: slots: 1:kit/pickaxe x1, 2:kit/sword x1
EOF
	dig2 "1, 188, 2"
	echo "wait_log_any 5000 3:kit/grass x1"
	dig2 "1, 187, 2"
	cat <<'EOF'
wait_log_any 5000 4:kit/dirt x1
event kit_slot 3
wait_log 5000 held 3 kit/grass
sync 2000
event workbench_build {"p": [1, 187, 2], "voxel": "kit/grass"}
wait_log 5000 kit: slots: 1:kit/pickaxe x1, 2:kit/sword x1, 4:kit/dirt x1
EOF
	echo "wait_log_any 60000 health 18/20"
	shot v_bitten
	walk 600
	echo quit
} > "$t/v_bob.cmds"
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
sync 3000
EOF
	shot v_back
	echo quit
} > "$t/v_back.cmds"
server surv
admin
boss v_boss
bob v_bob
if [ -n "$WEB" ]; then
	page v_back ' ["waitlog", "accounts: the login page shown", 120], ["wait", 1000],
 ["selall"], ["frames", 2], ["type", "kitbob"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["type", "checkpass12"], ["frames", 2], ["key", "Enter"], ["waitlog", "Joined as kitbob", 30],'
else
	BUILDAT_JOIN_NAME=kitbob native v_back
fi
server_end
python3 -I - "$t" "$V_world_creatures_come_at_night" <<'PY' || fail "survival's logs ($t)"
import re, sys
t, spawner = sys.argv[1:]
srv = open(t + "/surv.log", errors="replace").read()
back = open(t + "/v_back.log", errors="replace").read()
for want in ("the project from the template survival", "kitboss opens the template in edit mode",
		"workbench: kitbob dug (1,188,2): written", "workbench: kitbob dug (1,187,2): written",
		"kitbob placed kit/grass at (1,187,2): one taken from slot 3",
		"kit/spawn_rule %s: made" % spawner, "hurts kitbob: 2 bite"):
	assert want in srv, want
assert re.search(r"kit/environment \d+: dusk", srv), "no dusk"
# [KIT_SURVIVAL_TUNING] the fall's damage; Stop and Play put him nowhere
fell = re.search(r"kitboss fell ([\d.]+) m: (\d+) damage", srv)
assert fell and int(fell[2]) >= 5, "no fall damage"
assert "kitboss put at" not in srv[fell.end():], "kitboss put somewhere at Play"
assert re.search(r"kit/attack \d+: chases \d+", srv), "no chase"
kept = re.findall(r"kitbob kept at \(([^)]*)\)", srv)
assert kept, "kitbob not kept"
assert "kitbob back where they were at (%s) in world" % kept[0] in srv, kept
x = kept[0].split(", ")[0]
assert "the server put the player at (%s, " % x in back, (x, "not put back")
PY
echo "ok: survival: dug and placed from the inventory, chased at dusk, back where he left"

[ -n "$WEB" ] && { echo "PASS: the templates: made, opened and played (web)"; exit 0; }

# 3. Packed, published, installed, listed
start_server "$t/aitta.log" "setup code" 120 auto \
	bin/buildat_server -m ../apps/aitta -D "$t/aitta" -l 3 ||
	fail "Aitta did not start ($t/aitta.log)"
CHECK_PIDS+=($SERVER_PID)
aitta_pid=$SERVER_PID; P=$SERVER_PORT
acode=$(grep -ao "setup code [A-Z0-9]*" "$t/aitta.log" | cut -d' ' -f3)
"$b" aitta keygen "$t/key" > "$t/pub" 2>/dev/null || fail "keygen"
printf 'wait_log_any 20000 ai: {"id":1,\nquit\n' > "$t/bind.cmds"
BUILDAT_AITTA_CREATE=1 BUILDAT_AITTA_NAME=admin BUILDAT_AITTA_PASSWORD=checkpass \
	BUILDAT_AITTA_CODE=$acode \
	BUILDAT_AITTA_REQS="{\"cmd\":\"bind\",\"author\":\"buildat\",\"key\":\"$(cat "$t/pub")\"}" \
	timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl" -w 800x600 -l 3 \
	-s 127.0.0.1:$P -c @"$t/bind.cmds" > "$t/bind.log" 2>&1 ||
	fail "the bind's client ($t/bind.log)"
grep -aq 'ai: {"id":1,"ok":true' "$t/bind.log" || fail "the bind ($t/bind.log)"
# (a key inside the tree is refused)
if "$here/util/pack_templates.sh" "$here/util/check_lib.sh" "$t/refused" 2>/dev/null; then
	fail "pack_templates.sh took a key inside the repo"
fi
"$here/util/pack_templates.sh" "$t/key" "$t/out" puzzle_room arena ctf > "$t/zips.txt" 2> "$t/pack.err" ||
	fail "pack_templates.sh ($t/pack.err)"
for name in puzzle_room arena ctf; do
	zip=$(grep -a "$name" "$t/zips.txt" | head -1)
	[ -f "$zip" ] || fail "no archive of $name ($t/zips.txt)"
	python3 -I - "$zip" <<'PY' || fail "$name's archive"
import sys, zipfile
names = zipfile.ZipFile(sys.argv[1]).namelist()
assert any(n.split("/")[-1].startswith("LICENSE") for n in names), names
assert not any(n.endswith(".wasm") for n in names), names
assert any(n.endswith("composition.json") for n in names), names
PY
	"$b" aitta publish "$zip" 127.0.0.1:$P > "$t/publish.txt" 2>&1 ||
		fail "the publish of $name ($t/publish.txt)"
	grep -q "listed: buildat/$name" "$t/publish.txt" || fail "$name not listed ($t/publish.txt)"
done
# (one with no licence file, or with a type not Kit's, is not packed)
mkdir "$t/bad"
cp "$here/apps/workbench/templates/arena/meta.json" "$here/apps/workbench/templates/arena/composition.json" "$t/bad/"
if "$b" aitta pack "$t/bad" "$t/key" "$t/refused" > /dev/null 2>&1; then
	fail "a template with no licence file packed"
fi
cp "$here/apps/workbench/templates/arena/LICENSE" "$t/bad/"
sed -i 's|"kit/sign"|"alice/sign"|' "$t/bad/composition.json"
if "$b" aitta pack "$t/bad" "$t/key" "$t/refused" > /dev/null 2>&1; then
	fail "a template with a type not Kit's packed"
fi
echo "ok: packed with the licence and no .wasm, published"
"$b" aitta install "127.0.0.1:$P" buildat/puzzle_room "$t/inst" > "$t/install.txt" 2>&1 ||
	fail "the install ($t/install.txt)"
kill -INT "$aitta_pid" 2>/dev/null; wait "$aitta_pid" 2>/dev/null
{
	new_project "Puzzle room (buildat, installed)" i
	cat <<EOF
frames 10
screenshot $t/i_edit.png
quit
EOF
} > "$t/i.cmds"
server inst
admin
BUILDAT_JOIN_NAME=kitboss native i
server_end
python3 -I - "$t" <<'PY' || fail "the installed one's logs ($t)"
import re, sys
t = sys.argv[1]
cl = open(t + "/i.log", errors="replace").read()
srv = open(t + "/inst.log", errors="replace").read()
m = re.search(r"world_menu: template choices: (.*)", cl)
assert m, "no choices"
got = m[1].strip()
assert got.startswith("Empty, ") and got.endswith(", Puzzle room (buildat, installed)"), got
assert {"Airships", "Arena", "Capture the flag", "Puzzle room", "Ship", "Survival"} <= set(got[7:].split(", ")[:-1]), got
assert "A template: Stopped, in edit mode" in srv
assert "kitboss opens the template in edit mode" in srv
PY
echo "PASS: the templates: listed, opened, played, packed, installed and listed"
# vim: set noet ts=4 sw=4:
