#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min, ~2 min with web (2026-11-07)
# covers: builtin/kit/kit.cpp builtin/kit/api.h builtin/kit/types/goal.lua builtin/kit/types/quest.prefab.json builtin/kit/client_lua/ui.lua builtin/kit/client_lua/editor.lua builtin/kit/client_lua/editor_input.lua apps/workbench/**
# [KIT_GOALS] (kit_plan stage 7b) kit/goal: a quest of goals with a branch,
# composed on a fresh Workbench save by the editor's ops and played through.
# The chain (bands across the way the body walks, +z from the spawn):
#   6 line (reach, autostart, validate_reachable 10) -done-> 7 button (use 11)
#     and -done-> 8 side (reach, far off: the arm "final" cancels) and -done-> 15
#     shared (to everyone, a signal)
#   7 -done-> 9 bots only -done-> 13 middle (reach) -done-> 10 final (reach)
#   10 -done-> 8's cancel, -done-> 12
#   14 pressed (to everyone, use 11, autostart)
# 1. The editor's warnings (screenshots inspector_*.png, map_final.png,
#    publish_list.png): before the links, every goal not activated, and a use
#    goal with no object; then with 9 -> 13 and 13 -> 12's links missing: 12
#    "nothing activates it" in its inspector; 6's "no chain of links reaches 10",
#    last reached 9, first cut off 13; the final goal in gold on the plan. A
#    draft's Publish lists them, Cancel, Publish anyway. Links made: none left.
#    The prefab kit/quest placed: its first goal says the links lead to its last.
# 2. kitboss plays (hud_*.png): 6's line and marker alone with 14's (the others'
#    hidden). The button used too early: 14 done for all, 7 stays waiting. Walked
#    into 6's band: 6 hidden, 7, 8 and 15 up. Walked on into the band of 13, not
#    active: nothing. The button used: 7 done, 9 passes with no line, 13 active
#    with him in it: done at once; 10 up. Walked into it: 10 done, 8 cancelled, the
#    chain's end.
# 3. kitbob joins late (late_*.png): his own 6 up, 7 and 10 not (kitboss's), 14
#    done before he came, 15 up as it stands. Walked into 6's band: his 7 up.
# 4. kitboss again, in a game session (session_*.png): his 6 done here, up there
#    as the session's copy starts afresh; walked in, done, his 7 up; back in the
#    default, as he left it.
# Screenshots kept with KEEP_TMP=1: $t/*.png
#   util/kit_goals_check.sh
#   util/kit_goals_check.sh web    the same, every client in headless Chrome on
#      web/'s wasm: the sequences turned into a page's steps
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
export BUILDAT_WORKBENCH_PROJECT=world
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
check_tmp "kit_goals${WEB:+_web}"; t=$CHECK_TMP
cd "$here/Build"
start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 4 \
	${WEB:+-W "$here/web"} --sim-rate "$CHECK_RATE" ||
	fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
PAGE_STUB="(function(){ var held = null, refuse = false;
 Object.defineProperty(document, 'pointerLockElement', {configurable: true, get: function(){ return held; }});
 function set(e){ held = e; document.dispatchEvent(new Event('pointerlockchange')); }
 document.addEventListener('keydown', function(e){ if(e.key === 'Escape') refuse = true; }, true);
 document.addEventListener('mousedown', function(){ refuse = false; }, true);
 HTMLCanvasElement.prototype.requestPointerLock = function(){
  if(refuse || !window.lockOk){ document.dispatchEvent(new Event('pointerlockerror')); return Promise.reject(new Error('refused')); }
  if(held !== this) set(this); return Promise.resolve(); };
 document.exitPointerLock = function(){ if(held) set(null); };
 return 'stub'; })()"
# A sequence as a page's steps (kit_free_prefab_check.sh's)
cat > "$t/to_web.py" <<'PY'
import json, math, re, shlex, sys
PAUSE = [["waitlog_any", "pause: the menu shown", 10], ["eval", "window.lockOk = true, 'lock'"],
	["click", 100, 680], ["waitlog", "pause: the menu closed", 10], ["wait", 500]]
out, held, at = json.load(open(sys.argv[2])), None, [512, 350]
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
		if "player physics enabled" in text:
			out += PAUSE
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
	elif cmd == "mouse_pos":
		at = list(map(int, rest.split()))
		out.append(["mouse", *at])
	elif cmd == "mouse_wheel":
		out.append(["wheel", *at, 100 if int(rest) < 0 else -100])
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
web_client() # <name> <player> <login steps>
{
	local log=$t/$1.log
	printf '[["nav", "${URL}?scale=0.648148"], ["eval", %s], %s ["frames", 2]]' \
		"$(printf %s "$PAGE_STUB" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
		"$3" > "$t/$1.head.json"
	python3 "$t/to_web.py" "$t/$1.cmds" "$t/$1.head.json" > "$t/$1.json" ||
		fail "the steps of $1"
	WEB_DRIVE_VIEWPORT=1024x700@1 WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/" \
		"$here/util/web_drive.sh" chrome workbench "$t/$1.json" "$t/drive_$1" \
		> "$t/drive_$1.txt" 2>&1
	local st=$?
	cp "$t/drive_$1/page.log" "$log" 2>/dev/null
	[ $st = 0 ] || fail "the page's $1 ($(tail -2 "$t/drive_$1.txt"), $log, $t/srv.log)"
}
LOGIN_AGAIN=' ["waitlog", "accounts: the login page shown", 120], ["wait", 1000],
 ["selall"], ["frames", 2], ["type", "kitboss"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["type", "checkpass12"], ["frames", 2], ["key", "Enter"], ["waitlog", "Joined as kitboss", 30],'
client() # <name>: its commands in $t/<name>.cmds; BUILDAT_JOIN_* its login
{
	run_client 60 "$t/$1.log" timeout 240 bin/buildat -C "$t/client_cache" \
		-D "$t/cu_$BUILDAT_JOIN_NAME" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
		-c @"$t/$1.cmds" ||
		fail "client $1 failed ($t/$1.log, $t/srv.log)"
}
export BUILDAT_JOIN_PASSWORD=checkpass12
ed() { printf 'event kit_edit %s\nwait_log 10000 kit editor: state:\n' "$1"; }
place() { ed "{\"op\": \"place\", \"type\": \"$1\", \"pos\": [$2]}"; }
set_() { ed "{\"op\": \"set\", \"id\": $1, \"comp\": 0, \"param\": \"$2\", \"value\": $3}"; }
link() { ed "{\"op\": \"link\", \"id\": $1, \"comp\": 0, \"output\": \"$2\", \"to\": $3, \"input\": \"$4\"}"; }
goal() # <x, y, z> <text> <label>: the next id's
{
	place kit/goal "$1"
	id=$((id + 1))
	set_ $id text "\"$2\""
	set_ $id marker_label "\"$3\""
}
inspect() # <id> <shot>
{
	printf 'event kit_select %s\nwait_log 5000 kit editor: the inspector\nframes 5\nscreenshot %s\n' "$1" "$t/$2.png"
}
# A walk +z, as a player does: held, let go (a band is three cells deep)
walk() { printf 'keydown W\ndelay %s\nkeyup W\nframes 5\n' "$1"; }
# Its line up or down on this client's screen; its marker
up() { printf 'wait_log_any 8000 kit: ui %s text at\n' "$1"; }
into_play()
{
	cat <<'EOF'
wait_log_any 10000 kit: controls: camera first_person
frames 10
look_dir 0 0 1
frames 10
EOF
}
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log 10000 kit editor: state: 1 entities, 0 to undo
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by kitboss)
EOF
	place kit/world '0, 1, 0'; id=3
	set_ 3 surface '"voxels"'
	set_ 3 generator '"flat"'
	set_ 3 decorations false
	set_ 3 biome '"grassland"'
	# (not kit:regenerated: a change regenerating nothing over one under way loses
	# that answer, kit.cpp's world_regenerating = again > 0)
	echo "wait_log_any 30000 chunk node"
	place kit/walker '0, 1, 0'; id=4
	place kit/controls '0, 1, 0'; id=5
	goal '-8, 1, 3' 'Reach the first line' Line
	set_ $id size '[17, 3, 3]'
	set_ $id autostart true
	goal '2, 1, 1' 'Press the button' Button
	set_ $id kind '"use"'
	goal '14, 1, 1' 'Or go to the far side' Side
	goal '-14, 1, -6' 'Written for bots alone' Bot
	set_ $id audience '"bots"'
	goal '-8, 1, 14' 'Reach the end' End
	set_ $id size '[17, 3, 3]'
	place kit/button '2, 1, 5'; id=11
	set_ 11 hold 0.2
	goal '-4, 1, -6' 'Nothing activates this' Orphan
	goal '-8, 1, 8' 'Reach the middle' Middle
	set_ $id size '[17, 3, 5]'
	goal '4, 1, -4' 'Someone presses it' Shared
	set_ $id kind '"use"'
	set_ $id target 11
	set_ $id to '"everyone"'
	set_ $id autostart true
	goal '6, 1, -4' 'All of us wait for a signal' Waiting
	set_ $id kind '"signal"'
	# ([KIT_GUIDE_BOTS] what a bot would use for it, else a warning)
	set_ $id via 11
	set_ $id to '"everyone"'
	set_ $id marker false
	# A game session: into the arena beside the spawn by the teleporter
	place kit/arena '4, 1, 0'; id=16
	set_ 16 size '[3, 3, 2]'
	set_ 16 players 1
	set_ 16 countdown 0
	set_ 16 duration 0
	set_ 16 results 0
	place kit/teleporter '8, 1, -4'; id=17
	set_ 17 to '[5, 1, 1]'
	# 1. The warnings: a use goal with no object, one nothing activates
	inspect 7 inspector_use
	set_ 7 target 11
	link 6 done 7 activate
	link 6 done 8 activate
	link 6 done 15 activate
	link 7 done 9 activate
	link 13 done 10 activate
	link 10 done 8 cancel
	set_ 6 validate_reachable 10
	inspect 12 inspector_unreachable
	inspect 6 inspector_broken
	cat <<EOF
keypress F1
wait_log 5000 kit editor: the view is 2D
frames 10
mouse_pos 400 350
mouse_wheel -1
frames 3
mouse_wheel -1
frames 3
mouse_wheel -1
frames 10
screenshot $t/map_final.png
keypress F2
wait_log 5000 kit editor: the view is 3D
frames 5
EOF
	# A draft's Publish lists them, and goes only when answered (its tools
	# come in the edit state after the session's: edit mode off, then on)
	cat <<EOF
event kit_edit {"op": "draft"}
wait_log 30000 kit editor: edit mode on
wait_log_any 1000 kit editor: in session 1 draft
frames 5
click Button "Publish"
wait_log 5000 kit editor: publish this draft:
frames 5
screenshot $t/publish_list.png
click Button "Cancel"
wait_log 5000 kit editor: publish cancelled
frames 3
click Button "Publish"
wait_log 5000 kit editor: publish this draft:
frames 5
click Button "Publish anyway"
wait_log 5000 kit editor: published with goal warnings
sync 3000
click Button "Leave draft"
wait_log 30000 kit editor: edit mode on
wait_log_any 1000 kit editor: in session 0 default
frames 5
EOF
	link 9 done 13 activate
	link 10 done 12 activate
	echo "wait_log_any 5000 kit editor: goal warnings: 0"
	inspect 6 inspector_ok
	# The prefab: its first goal's check, then gone again
	ed '{"op": "place", "prefab": "kit/quest", "pos": [-20, 1, 20]}'
	echo "sync 2000"
	inspect 19 inspector_quest
	ed '{"op": "undo"}'
	# 2. Played
	cat <<EOF
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running (by kitboss)
keypress F6
wait_log 10000 kit editor: edit mode off
EOF
	into_play
	cat <<EOF
wait_log_any 8000 kit: marker 6 "Line" on screen
wait_log_any 8000 kit: marker 14 "Shared"
frames 5
screenshot $t/hud_first.png
event kit_use 11
wait_log_any 8000 Someone presses it
sync 3000
EOF
	walk 1000
	cat <<EOF
wait_log_any 8000 kit: marker 7 "Button" on screen
wait_log_any 8000 kit: marker 8 "Side" at the edge
frames 10
screenshot $t/hud_branch.png
EOF
	walk 400
	cat <<EOF
sync 3000
frames 5
screenshot $t/hud_in_middle.png
event kit_use 11
wait_log_any 8000 kit: marker 10 "End" on screen
frames 10
screenshot $t/hud_end.png
EOF
	walk 1200
	cat <<EOF
wait_log_any 8000 kit: marker 10 "End" hidden
wait_log_any 8000 kit: marker 8 "Side" hidden
frames 10
screenshot $t/hud_done.png
quit
EOF
} > "$t/boss.cmds"
# 3. A late joiner
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
EOF
	into_play
	cat <<EOF
wait_log_any 8000 kit: marker 6 "Line" on screen
wait_log_any 8000 All of us wait for a signal
frames 5
screenshot $t/late_join.png
EOF
	walk 1000
	cat <<EOF
wait_log_any 8000 kit: marker 7 "Button" on screen
frames 10
screenshot $t/late_on.png
quit
EOF
} > "$t/bob.cmds"
# 4. A session
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
EOF
	into_play
	cat <<EOF
wait_log_any 8000 kit: marker 6 "Line" hidden
keypress F6
wait_log 10000 kit editor: state:
event kit_edit {"op": "try", "id": 17, "comp": 0, "input": "teleport"}
wait_log 30000 kit editor: in session 2 game
frames 10
look_dir 0 0 1
wait_log_any 8000 shown: "Reach the first line"
wait_log 20000 chunk node
frames 10
screenshot $t/session_first.png
EOF
	# (the session's sections may be on their way: a cell not there holds him)
	walk 800
	walk 800
	cat <<EOF
wait_log_any 8000 kit: marker 7 "Button"
frames 10
screenshot $t/session_on.png
keypress F6
wait_log 10000 kit editor: state:
event kit_edit {"op": "try", "id": 16, "comp": 0, "input": "end"}
wait_log 30000 kit editor: in session 0 default
wait_log_any 8000 kit: marker 6 "Line" hidden
frames 10
screenshot $t/session_back.png
quit
EOF
} > "$t/session.cmds"
# The admin's account and open registration: natively, as a page has no
# BUILDAT_JOIN_ADMIN
cat > "$t/admin.cmds" <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
wait_log_any 60000 player physics enabled
sync 3000
quit
EOF
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client admin
if [ -n "$WEB" ]; then
	web_client boss kitboss "$LOGIN_AGAIN"
	web_client bob kitbob "$(web_login_steps kitbob)"
	web_client session kitboss "$LOGIN_AGAIN"
else
	BUILDAT_JOIN_NAME=kitboss client boss
	BUILDAT_JOIN_NAME=kitbob BUILDAT_JOIN_CREATE=1 client bob
	BUILDAT_JOIN_NAME=kitboss client session
fi
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
python3 - "$t" <<'PY' || fail "the logs say otherwise ($t)"
import re, sys
t = sys.argv[1]
def lines(n):
	return open(f"{t}/{n}.log", errors="replace").read().split("\n")
def after(log, start, want, label=""):
	# The first line from start with want; its index + 1
	for i in range(start, len(log)):
		if want in log[i]:
			return i + 1
	sys.exit(f"{label}: no \"{want}\" after line {start}")
def ui(log, id_, shown, start=0):
	return next((i + 1 for i in range(start, len(log))
		if re.search(rf"kit: ui {id_} text at .* {shown}: ", log[i])), None)
boss, bob, ses = lines("boss"), lines("bob"), lines("session")
# 1. The warnings, in the order they came
text = "\n".join(boss)
for want in ("a use goal with no object to use",
		"nothing activates it: no link to its activate, autostart off",
		"no chain of links reaches ◆ 10 goal: last reached ◆ 9 goal, first cut off ◆ 13 goal",
		"kit editor: at publish: ",
		"publish cancelled", "published with goal warnings",
		"goal warnings: 0"):
	if want not in text:
		sys.exit(f"boss: no \"{want}\"")
if not any("at publish: ◆ 12 goal: nothing activates" in l for l in boss):
	sys.exit("boss: the goal nothing activates not listed at publish")
if not any("at publish: ◆ 6 goal: no chain of links" in l for l in boss):
	sys.exit("boss: the broken chain not listed at publish")
srv = open(f"{t}/srv.log", errors="replace").read()
if "publishes draft" not in srv:
	sys.exit("server: the draft not published")
# 2. Each goal only when linked
play = after(boss, after(boss, 0, "the server is Running"), "edit mode off")
for id_, shown in ((6, "shown"), (14, "shown")):
	if not ui(boss, id_, shown, play):
		sys.exit(f"boss: {id_} not {shown} after Play")
first = ui(boss, 6, "shown", play)
for id_ in (7, 8, 9, 10, 12, 13, 15):
	s = ui(boss, id_, "shown", play)
	if s and s < first:
		sys.exit(f"boss: {id_} shown before 6")
done6 = ui(boss, 6, "hidden", first)
if not done6:
	sys.exit("boss: 6's line never hidden")
for id_ in (7, 8, 15):
	s = ui(boss, id_, "shown", play)
	if not s or s < done6 - 40:
		sys.exit(f"boss: {id_}'s line: {s}, 6 hidden at {done6}")
if ui(boss, 9, "shown", play):
	sys.exit("boss: the bots' goal shown")
for id_ in (7, 8, 10):
	s = ui(boss, id_, "shown", play)
	if not ui(boss, id_, "hidden", s):
		sys.exit(f"boss: {id_}'s line never hidden")
for g, what in ((6, "done for kitboss"), (7, "done for kitboss"), (9, "done for kitboss"),
		(13, "done for kitboss"), (10, "done for kitboss"), (8, "cancelled for"),
		(14, "done for everyone"), (12, "active for kitboss")):
	if not re.search(rf"kit/goal {g}: {what}", srv):
		sys.exit(f"server: entity {g} not \"{what}\"")
# The button used early: 7 not done by it
a, b = srv.find("Entity 11 used by kitboss"), srv.find("Entity 6: kitboss enters")
if a < 0 or b < 0 or a > b:
	sys.exit("server: the early use not before 6's band")
m = re.search(r"kit/goal 7: done for kitboss", srv)
if m.start() < b:
	sys.exit("server: 7 done by the early use")
# 13 done with him already in it: entered before it was active
e13 = srv.find("Entity 13: kitboss enters")
a13 = re.search(r"kit/goal 13: active for kitboss", srv)
if e13 < 0 or not a13 or e13 > a13.start():
	sys.exit("server: 13 was not active only after he stood in it")
# 3. The late joiner: his own, 14 done before he came, 15 as it stands
for id_, shown in ((6, "shown"), (15, "shown"), (14, "hidden"), (7, "hidden"), (10, "hidden")):
	if not ui(bob, id_, shown):
		sys.exit(f"bob: {id_} not {shown}")
if ui(bob, 14, "shown"):
	sys.exit("bob: 14 shown though done")
if not ui(bob, 7, "shown"):
	sys.exit("bob: his own 7 not up")
if ui(bob, 10, "shown"):
	sys.exit("bob: 10 up")
# 4. A session: afresh
hid = ui(ses, 6, "hidden")
if not hid:
	sys.exit("session: 6 not hidden in the default")
ins = after(ses, 0, "in session 2 game")
if not ui(ses, 6, "shown", ins - 1):
	sys.exit("session: 6 not up in the session's copy")
if not ui(ses, 7, "shown", ins - 1):
	sys.exit("session: his 7 not up there")
back = after(ses, ins, "in session 0 default")
if ui(ses, 6, "shown", back):
	sys.exit("session: 6 up again back in the default")
placed = after(boss, 0, '"prefab": "kit/quest"')
for l in boss[placed:]:
	m = re.search(r"kit editor: goal warnings: (\d+)$", l)
	if m and m[1] != "0":
		sys.exit(f"boss: the prefab kit/quest warned: {l}")
print("the chain played as linked")
PY
[ $? = 0 ] || exit 1
echo "PASS: the goals: a chain with a branch, warnings, a late joiner, a session${WEB:+ (web)}"
# vim: set noet ts=4 sw=4:
