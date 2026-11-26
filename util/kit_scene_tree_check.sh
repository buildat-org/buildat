#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~4 min (2026-11-16)
# covers: builtin/kit/kit.cpp builtin/kit/client_lua/editor.lua builtin/kit/client_lua/editor_input.lua builtin/kit/client_lua/shell.lua builtin/kit/client_lua/signals.lua builtin/kit/types/controls.lua builtin/kit/types/game_rules.lua builtin/kit/types/ui_scene_list.lua apps/workbench/main/main.cpp util/web_drive.js
# [KIT_SCENE_TREE] Scenes under scenes. kitboss, the admin of two Workbench
# servers one after the other, on a headless weston's Xwayland of the
# check's own:
#   1. A (a project New would make: its ground row "heightmap", so a scene
#      with no kit/terrain has no ground): on the root kit/controls (camera
#      top_down) and kit/environment; "world" a heightmap. A group "racing"
#      (its World a copy) with its own kit/controls (chase, kit/click_to_move)
#      and kit/game_rules; a track "t1" under it, a heightmap stroke in it;
#      "arena" on the root. The builder moved between them gets each one's
#      controls: racing's in t1, the root's in arena.
#   2. t1 and arena listed: Running, racing's kit/ui_scene_list lists t1
#      alone, world's (no scene under it) every listed one.
#   3. racing's removal refused (t1 under it); a draft (a session's copy of
#      t1) has racing's controls in t1.
#   4. racing exported: t1 in the package, its World's stroke, racing's
#      parent the root, the root's kit/environment carried ("Rules from
#      above") with its link by name to racing's list, kit/controls not
#      (racing has its own).
#   5. racing's kit/controls edited while the builder is in t1: the camera
#      and the movement change under their body.
#   6. "menu", a new scene: the scene entity alone, World none: no ground,
#      no section, no heightmap sent, movement none; Running, the player
#      there out of the tools is held, the same place a second later, kept
#      in menu, never falling out of the world. [KIT_SCENES_REMOVE_TIP] The
#      Scenes window in menu: the Remove of menu, racing and world dimmed,
#      each clicked: nothing sent, the pointer resting there its tip (the
#      builder's own, scenes under it, the first); t1's and arena's none.
#      Its buttons in columns (each kind at one x).
#   7. B (another user dir): a scene "hub"; racing.scene.zip added under it
#      (Scenes..., Add here...): racing under hub, t1 under racing, racing's
#      controls in t1, the Scenes window indented so, its buttons in columns.
#   8. The web client (headless Chrome; skipped without web/ or Chrome) in
#      B: the Scenes window the same; t1's Move..., the root: t1 on the
#      root. B's save after: the tree and the carried environment (B's
#      root has none), its link by name kept.
# Screenshots, kept with KEEP_TMP=1: $t/a_tree.png (A's scene list open),
# $t/a_menu.png (menu, played), $t/a_scenes.png (A's Scenes window),
# $t/b_scenes.png (B's after the add), $t/web/web_scenes.png,
# $t/web/web_move.png, $t/web/web_moved.png
#   util/kit_scene_tree_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
for c in weston unzip; do
	command -v $c > /dev/null || skip "no $c"
done
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_scene_tree; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1
check_build
sock=buildat-tree-$$
weston --backend=headless --xwayland --socket=$sock --width=1100 \
	--height=800 > "$t/weston.log" 2>&1 &
CHECK_PIDS+=($!)
for i in $(seq 50); do
	d=$(grep -ao "xserver listening on display :[0-9]*" "$t/weston.log" | grep -o ":[0-9]*$")
	[ -n "$d" ] && break
	sleep 0.2
done
[ -n "$d" ] || fail "weston's Xwayland ($t/weston.log)"
CLIENT=
mark() { wc -c < "$1"; }
await() # <log> <offset> <seconds> <regex>
{
	local i
	for i in $(seq $(($3 * 5))); do
		tail -c +$(($2 + 1)) "$1" | grep -qaE "$4" && return 0
		[ -z "$CLIENT" ] || kill -0 $CLIENT 2>/dev/null || fail "the client is gone ($CL)"
		sleep 0.2
	done
	fail "no \"$4\" in $1 in $3 s ($SL, $CL)"
}
cmd() { printf '%s\n' "$@" >&3; }
step() # <seconds> <regex in the client's log> <command>...
{
	local s=$1 re=$2 m
	shift 2
	m=$(mark "$CL")
	cmd "$@"
	await "$CL" "$m" "$s" "$re"
}
edit() # <regex in the server's log> <kit:edit JSON>
{
	local m
	m=$(mark "$SL")
	cmd "event kit_edit $2"
	await "$SL" "$m" 10 "$1"
}
refused() # <regex of the refusal> <kit:edit JSON>
{
	local m
	m=$(mark "$SL")
	cmd "event kit_edit $2"
	await "$SL" "$m" 10 "An edit \([a-z_]+\) by peer [0-9]+ refused|An edit by kitboss"
	tail -c +$((m + 1)) "$SL" | grep -qaE "refused: $1" ||
		fail "not refused so: $(tail -c +$((m + 1)) "$SL" | grep -a "An edit" | head -2) ($SL)"
}
ID= # placed's
placed() # <type> <name> [extra JSON fields]: ID the new entity's
{
	local m
	m=$(mark "$SL")
	cmd "event kit_edit {\"op\": \"place\", \"type\": \"$1\", \"pos\": [2, 9, 2]${3:+, $3}}"
	await "$SL" "$m" 10 "An edit by kitboss: placed $1 [0-9]+|An edit \(place\) by peer [0-9]+ refused"
	ID=$(tail -c +$((m + 1)) "$SL" | grep -aoP "An edit by kitboss: placed \S+ \K[0-9]+" | head -1)
	[ -n "$ID" ] || fail "no id of the placed $1 ($SL)"
	edit "An edit by kitboss: renamed $ID to $2" "{\"op\": \"rename\", \"id\": $ID, \"name\": \"$2\"}"
}
arrived() # <offset in the client's log> <scene> <regex of the controls the client has there>
{
	# (the controls come before the body's put; none are sent where they
	# are the same as where it was)
	# (the body's put after that line: a scene left on the way, as Play's
	# round start through world, has a put and controls of its own before)
	local o
	await "$CL" "$1" 20 "kit editor: in the scene $2 "
	o=$(tail -c +$(($1 + 1)) "$CL" | grep -abm1 -E "kit editor: in the scene $2 " | cut -d: -f1)
	await "$CL" "$(($1 + o))" 20 "player physics enabled"
	grep -a "kit: controls: camera " "$CL" | tail -1 | grep -qaE "kit: controls: $3" ||
		fail "in $2 not \"$3\": $(grep -a "kit: controls: camera " "$CL" | tail -1) ($CL)"
}
to_scene() # <scene> <regex of the controls the client has there>
{
	local m
	m=$(mark "$CL")
	cmd "event kit_edit {\"op\": \"scene\", \"name\": \"$1\"}"
	arrived "$m" "$1" "$2"
}
web=""
if command -v "${CHROME:-google-chrome}" > /dev/null && [ -f "$here/web/buildat.wasm" ]; then
	web="-W $here/web"
fi
server() # <name>: a Workbench server in $t/<name>, its log $SL
{
	SL=$t/$1.log
	start_server "$SL" "Listening at" 300 auto \
		bin/buildat_server -m ../apps/workbench -D "$t/$1" -l 3 $web \
		--sim-rate "$CHECK_RATE" || fail "the server did not come up ($SL)"
	SRV=$SERVER_PID
	CHECK_PIDS+=($SRV)
	wait_for_log "$SL" "setup code [A-Z0-9]+" 30
	code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$SL" | head -1)
	[ -n "$code" ] || fail "no setup code ($SL)"
}
client() # <name>: kitboss in $t/cu_<name>, the admin by the setup code, its commands from a fifo; the tools on, Stopped
{
	exec 3>&-
	mkfifo "$t/$1.cmd"
	sleep 900 > "$t/$1.cmd" &
	CHECK_PIDS+=($!)
	CL=$t/$1_client.log
	DISPLAY=$d WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11 BUILDAT_JOIN_NAME=kitboss \
		BUILDAT_JOIN_CODE=$code timeout 600 bin/buildat -C "$t/client_cache" \
		-D "$t/cu_$1" -s localhost:$SERVER_PORT -w 1024x700 -l 3 -o sound_mute=1 \
		-c - < "$t/$1.cmd" > "$CL" 2>&1 &
	CLIENT=$!
	CHECK_PIDS+=($CLIENT)
	exec 3> "$t/$1.cmd"
	await "$CL" 0 120 "Joined as kitboss"
	cmd "wait_log_any 30000 server window: the page ntfy" "frames 3" 'click Button "Don'"'"'t add"'
	await "$CL" 0 60 "player physics enabled"
	await "$CL" 0 30 "kit editor: edit rights: yes"
	step 20 "kit editor: edit mode on" "frames 3" "keypress F6"
	await "$CL" 0 20 "kit editor: the server is (Running|Ended)"
	if grep -a "kit editor: the server is" "$CL" | tail -1 | grep -q Running; then
		step 10 "kit editor: the server is Ended" 'event kit_edit {"op": "stop"}'
	fi
}
bye() # the client and its server gone
{
	cmd "quit"
	exec 3>&-
	wait $CLIENT
	CLIENT=
	kill -INT $SRV 2>/dev/null
	wait $SRV 2>/dev/null
}
scenes_window() # <the scenes it shows, ">" a level under>: the scene list's Scenes...
{
	# (the bar's second list, the first the view's)
	cmd "frames 3" 'click DropDownList "▼" 1024 0' "delay 300" "frames 3"
	step 10 "kit editor: the Scenes window: " 'click Text "Scenes..."'
	grep -a "kit editor: the Scenes window: " "$CL" | tail -1 | grep -qF "window: $1" ||
		fail "the Scenes window not \"$1\": $(grep -a "kit editor: the Scenes window: " "$CL" | tail -1) ($CL)"
	cmd "frames 3"
}
# The Scenes window's buttons in columns: in the rows (each with a Move...),
# each kind at one x whatever the name's length and indent
scenes_columns() # <a name for the dump>
{
	step 10 "kit editor: touch targets \\($1\\)" "frames 3" "event kit_touch_targets $1"
	python3 -I - "$CL" "$1" <<'PY' || fail "the Scenes window's columns ragged ($CL)"
import re, sys
l = [x for x in open(sys.argv[1], errors="replace") if "touch targets (%s)" % sys.argv[2] in x][-1]
bs = [(t, int(x), int(y)) for t, x, y in re.findall(r'Button "([^"]*)" (-?\d+) (-?\d+) \d+ \d+', l)]
rows = {y for t, x, y in bs if t == "Move..."}
xs = {}
for t, x, y in bs:
    if y in rows and t in ("List", "Unlist", "Move...", "Add here...", "Remove"):
        xs.setdefault("List" if t == "Unlist" else t, set()).add(x)
assert len(rows) >= 2 and len(xs) >= 3 and all(len(v) == 1 for v in xs.values()), (len(rows), xs)
print("ok: the Scenes window's %d rows, its buttons in columns at x %s" % (len(rows),
    ", ".join("%s %d" % (k, min(v)) for k, v in sorted(xs.items(), key=lambda kv: min(kv[1])))))
PY
}

# A: its save made first, as New makes one (Workbench's "ground" row): a
# scene without kit/terrain has no ground
python3 -I - "$t/a/apps/workbench/saves/world" <<'PY' || fail "A's save"
import os, sqlite3, sys
os.makedirs(sys.argv[1])
c = sqlite3.connect(sys.argv[1] + "/save.sqlite")
c.execute("CREATE TABLE IF NOT EXISTS store (store TEXT NOT NULL, key TEXT NOT NULL, value BLOB, PRIMARY KEY(store, key))")
c.execute("PRAGMA user_version = 2")
c.execute("INSERT INTO store VALUES ('workbench', 'ground', 'heightmap')")
c.commit()
PY

# 1. The tree, each scene's controls
server a
client a
m=$(mark "$CL")
placed kit/terrain World
await "$CL" "$m" 30 "heightmap: terrain built"
m=$(mark "$CL")
placed kit/controls Controls '"params": {"camera": "top_down"}'
await "$CL" "$m" 20 "kit: controls: camera top_down, pointer \S+, movement kit/walker"
placed kit/environment Sky
SKY=$ID
step 20 "kit editor: in the scene racing " \
	'event kit_edit {"op": "new_scene", "name": "racing", "copy": true}'
m=$(mark "$CL")
placed kit/controls "Racing controls" '"on": "scene", "params": {"camera": "chase", "movement": "kit/click_to_move"}'
RC=$ID
await "$CL" "$m" 20 "kit: controls: camera chase, pointer \S+, movement kit/click_to_move"
placed kit/game_rules "Racing rules" '"on": "scene", "params": {"peaceful": true}'
placed kit/ui_scene_list "Racing list"
RL=$ID
# (a link by name, carried with the Sky in the export)
edit "An edit by kitboss: linked $SKY\.dawn -> \"Racing list\" in the player's scene\.show" \
	"{\"op\": \"link\", \"id\": $SKY, \"comp\": 0, \"output\": \"dawn\", \"to_name\": \"Racing list\", \"input\": \"show\"}"
m=$(mark "$CL")
ms=$(mark "$SL")
cmd 'event kit_edit {"op": "new_scene", "name": "t1", "copy": true, "parent": "racing"}'
await "$SL" "$ms" 20 "An edit by kitboss: made the scene t1 under racing, its World racing's copied"
arrived "$m" t1 "camera chase, pointer \S+, movement kit/click_to_move"
step 10 "kit editor: terrain: " \
	'event kit_edit {"op": "terrain", "tool": "raise", "x": 4, "y": 0, "z": 4, "size": 2, "strength": 5, "stroke": 1}'
placed kit/scene_info "T1 info"
m=$(mark "$CL")
ms=$(mark "$SL")
cmd 'event kit_edit {"op": "new_scene", "name": "arena", "copy": true}'
await "$SL" "$ms" 20 "An edit by kitboss: made the scene arena, its World t1's copied"
arrived "$m" arena "camera top_down, pointer \S+, movement kit/walker"
placed kit/scene_info "Arena info"
to_scene t1 "camera chase, pointer \S+, movement kit/click_to_move"
to_scene world "camera top_down, pointer \S+, movement kit/walker"
placed kit/ui_scene_list "World list"
WL=$ID
echo "ok: racing's controls in racing and t1 under it, the root's in arena and world"

# 2. The lists, Running
m=$(mark "$SL")
step 10 "kit editor: the server is Running" 'event kit_edit {"op": "play"}'
await "$SL" "$m" 10 "kit/ui_scene_list $RL: scenes: "
await "$SL" "$m" 10 "kit/ui_scene_list $WL: scenes: "
grep -aqE "kit/ui_scene_list $RL: scenes: t1=t1/$" "$SL" ||
	fail "racing's list: $(grep -a "ui_scene_list $RL: scenes" "$SL") ($SL)"
grep -aqE "kit/ui_scene_list $WL: scenes: t1=t1/, arena=arena/$" "$SL" ||
	fail "world's list: $(grep -a "ui_scene_list $WL: scenes" "$SL") ($SL)"
step 10 "kit editor: the server is Ended" 'event kit_edit {"op": "stop"}'
echo "ok: racing's list t1 alone, world's every listed scene"

# 3. Refused removal; a session's copy of t1
refused "the scene racing has scenes under it \(t1\)" '{"op": "remove_scene", "name": "racing"}'
to_scene t1 "camera chase, pointer \S+, movement kit/click_to_move"
m=$(mark "$CL")
ms=$(mark "$SL")
cmd 'event kit_edit {"op": "draft"}'
await "$SL" "$ms" 20 "kitboss's tools on in session [0-9]+"
# (a session's own controls sent anew)
await "$CL" "$m" 20 "kit: controls: camera chase, pointer \S+, movement kit/click_to_move"
tail -c +$((ms + 1)) "$SL" | grep -qaE "t1~[0-9]+" ||
	fail "the draft not in t1's copy ($SL)"
ms=$(mark "$SL")
cmd 'event kit_edit {"op": "leave_draft"}'
await "$SL" "$ms" 30 "Peer [0-9]+ from session [0-9]+ to session 0 \(scene t1\)"
echo "ok: racing not removed with t1 under it; a draft's t1 has racing's controls"

# 4. racing exported
ms=$(mark "$SL")
step 20 "kit editor: Exported to .*racing\.scene\.zip" 'event kit_edit {"op": "export_scene", "scene": "racing"}'
z=$t/cu_a/exports/racing.scene.zip
[ -s "$z" ] || fail "no $z ($CL)"
mkdir "$t/a_zip"
unzip -q "$z" -d "$t/a_zip" || fail "the export does not unzip ($z)"
python3 -I - "$t/a_zip" <<'PY' || fail "A's export ($z)"
import json, sys, zlib
x = sys.argv[1]
c = json.load(open(x + "/composition.json"))
es = {e["id"]: e for e in c["entities"]}
sc = {e["name"]: e for e in es.values() if e.get("kind") == "scene"}
assert sorted(sc) == ["racing", "t1"], sorted(sc)
assert sc["racing"].get("parent", 1) == 1 and sc["t1"]["parent"] == sc["racing"]["id"], sc
under = [e for e in es.values() if e.get("parent") == sc["racing"]["id"] and "pos" not in e]
types = sorted(cm["type"] for e in under for cm in e.get("components", []))
assert "kit/controls" in types and "kit/game_rules" in types, types
up = [e for e in under if e.get("name") == "Rules from above"]
assert len(up) == 1 and [cm["type"] for cm in up[0]["components"]] == ["kit/environment"], up
assert up[0]["components"][0]["links"] == [{"output": "dawn", "to_name": "Racing list", "input": "show"}], up
f = json.loads(zlib.decompress(open(x + "/edits.bin", "rb").read()))
assert f["scenes"]["t1"]["hm"], sorted(f["scenes"])
print("A's export: racing and t1 under it, its rules from above %s, t1's stroke" %
    [cm["type"] for cm in up[0]["components"]])
PY
mkdir -p "$t/cu_b/exports"
cp "$z" "$t/cu_b/exports/"
echo "ok: racing exported with t1, the root's environment carried"

# 5. racing's controls edited under the builder in t1
m=$(mark "$CL")
edit "An edit by kitboss: set $RC's kit/controls camera" \
	"{\"op\": \"set\", \"id\": $RC, \"comp\": 0, \"param\": \"camera\", \"value\": \"first_person\"}"
await "$CL" "$m" 20 "kit: controls: camera first_person, pointer \S+, movement kit/click_to_move"
m=$(mark "$CL")
edit "An edit by kitboss: set $RC's kit/controls movement" \
	"{\"op\": \"set\", \"id\": $RC, \"comp\": 0, \"param\": \"movement\", \"value\": \"kit/walker\"}"
await "$CL" "$m" 20 "kit: controls: camera first_person, pointer \S+, movement kit/walker"
echo "ok: racing's edit reached the builder in t1"

# 6. An empty scene
ms=$(mark "$SL")
m=$(mark "$CL")
cmd 'event kit_edit {"op": "new_scene", "name": "menu"}'
await "$SL" "$ms" 20 "An edit by kitboss: made the scene menu"
tail -c +$((ms + 1)) "$SL" | grep -a "An edit by kitboss: made the scene menu" | grep -qv "copied" ||
	fail "menu made with something ($SL)"
arrived "$m" menu "camera top_down, pointer \S+, movement none"
tail -c +$((ms + 1)) "$SL" | grep -qaE "World: empty [0-9]+x[0-9]+, .*no ground" ||
	fail "menu's World not empty ($SL)"
tail -c +$((ms + 1)) "$SL" | grep -qaF "World: the save holds 0 sections (0 edited)" ||
	fail "menu's World holds sections ($SL)"
! tail -c +$((ms + 1)) "$SL" | grep -qa "heightmap: the map sent" ||
	fail "a heightmap sent in menu ($SL)"
# Out of the tools there, Running (Ended, F6 would play from the start)
step 10 "kit editor: the server is Running" 'event kit_edit {"op": "play"}'
to_scene menu "camera top_down, pointer \S+, movement none"
ms=$(mark "$SL")
step 20 "kit editor: edit mode off" "frames 3" "keypress F6"
await "$SL" "$ms" 10 "kitboss left edit mode"
cmd "frames 30"
step 10 "kit: body at " "event kit_body"
b1=$(grep -aoP "kit: body at \K\S+" "$CL" | tail -1)
cmd "delay 1000" "frames 30"
step 10 "kit: body at " "event kit_body"
b2=$(grep -aoP "kit: body at \K\S+" "$CL" | tail -1)
[ "$b1" = "$b2" ] || fail "the body moved in menu: $b1 then $b2 ($CL)"
! tail -c +$((ms + 1)) "$SL" | grep -qa "fell out of the world" ||
	fail "fell out of the world in menu ($SL)"
! tail -c +$((ms + 1)) "$SL" | grep -a "kitboss joined " | grep -qv "joined menu " ||
	fail "the player not kept in menu ($SL)"
cmd "frames 5" "screenshot $t/a_menu.png"
step 20 "kit editor: edit mode on" "frames 3" "keypress F6"
step 10 "kit editor: the server is Ended" 'event kit_edit {"op": "stop"}'
echo "ok: menu empty (no ground, 0 sections, no heightmap sent), its player held at $b1"
cmd "frames 3" 'click DropDownList "▼" 1024 0' "delay 300" "frames 5" "screenshot $t/a_tree.png" 'click Text "Scene: menu"' "frames 3"
scenes_window "world, racing, >t1, arena, menu"
cmd "frames 5" "screenshot $t/a_scenes.png"
scenes_columns a_scenes
# [KIT_SCENES_REMOVE_TIP] The dimmed Remove: a click nothing, the pointer
# resting there its tip (from the last row up: a tip is drawn under its
# button)
m=$(mark "$CL")
ms=$(mark "$SL")
step 10 "kit editor: the tip of remove menu at .*: The scene you're editing: switch to another first" \
	'click Button "remove menu"'
step 10 "kit editor: the tip of remove racing at .*: Has scenes under it" \
	'click Button "remove racing"'
step 10 "kit editor: the tip of remove world at .*: The first scene is always kept" \
	'click Button "remove world"'
cmd "frames 10"
! tail -c +$((m + 1)) "$CL" | grep -qa "kit editor: remove the scene" ||
	fail "a dimmed Remove sent a removal ($CL)"
! tail -c +$((ms + 1)) "$SL" | grep -qa "remove_scene" ||
	fail "a dimmed Remove's edit came ($SL)"
grep -aqE "kit editor: the tip of remove (t1|arena)" "$CL" &&
	fail "a Remove that works has a tip ($CL)"
echo "ok: the dimmed Remove of menu (the builder's), racing (t1 under it), world (the first): its tip, its click nothing"
bye

# 7. B: racing added under hub
server b
client b
step 20 "kit editor: in the scene hub " 'event kit_edit {"op": "new_scene", "name": "hub"}'
scenes_window "world, hub"
m=$(mark "$SL")
step 10 "The file picker at .*/exports" 'click Button "Add here..." 1024 700'
step 60 "kit editor: Added the scene racing " "frames 3" 'click Button "racing.scene.zip"'
await "$SL" "$m" 10 "kitboss adds the scene racing \(and 1 under it\) under hub "
to_scene t1 "camera chase, pointer \S+, movement kit/click_to_move"
scenes_window "world, hub, >racing, >>t1"
cmd "frames 5" "screenshot $t/b_scenes.png"
scenes_columns b_scenes
cmd 'click Button "Close"' "frames 3"
cmd "quit"
exec 3>&-
wait $CLIENT
CLIENT=
# 8. The web page's Scenes window (headless Chrome; skipped without web/
# or Chrome)
if [ -n "$web" ]; then
	cat > "$t/web.json" <<'J'
[["nav", "${URL}"], ["waitlog", "accounts: the login page shown", 120], ["wait", 1000],
 ["selall"], ["frames", 2], ["type", "kitboss"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["type", "checkpass12"], ["frames", 2], ["key", "Enter"], ["waitlog", "Joined as kitboss", 30],
 ["waitlog_any", "pause: the menu shown", 30], ["frames", 3],
 ["click", "Button", "Edit"], ["waitlog_any", "kit editor: edit mode on", 20], ["frames", 10],
 ["click", "DropDownList", "▼", 1024, 0], ["wait", 300], ["frames", 3],
 ["click", "Text", "Scenes..."],
 ["waitlog", "kit editor: the Scenes window: world, hub, >racing, >>t1", 10], ["frames", 5],
 ["shot", "${OUT}/web_scenes.png"],
 ["click", "Button", "Move...", 522, 395], ["waitlog", "kit editor: the dialog Move t1", 10], ["frames", 3],
 ["shot", "${OUT}/web_move.png"],
 ["click", "Button", "The root (top level)"], ["waitlog", "kit editor: the scene t1 under the root", 10],
 ["waitlog", "kit editor: state: ", 10], ["frames", 3],
 ["click", "DropDownList", "▼", 1024, 0], ["wait", 300], ["frames", 3],
 ["click", "Text", "Scenes..."],
 ["waitlog", "kit editor: the Scenes window: world, hub, >racing, t1", 10], ["frames", 5],
 ["shot", "${OUT}/web_moved.png"]
]
J
	m=$(mark "$SL")
	WEB_DRIVE_VIEWPORT=1024x700@1 WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/" \
		"$here/util/web_drive.sh" chrome workbench "$t/web.json" "$t/web" > "$t/web.txt" 2>&1 ||
		fail "the web page: $(tail -2 "$t/web.txt") ($t/web/page.log, $SL)"
	await "$SL" "$m" 10 "An edit by kitboss: put the scene t1 under the root"
	echo "ok: the web page's Scenes window: hub > racing > t1; t1 moved to the root by its Move..."
	t1_up=root
else
	echo "(no web part: no web/buildat.wasm or Chrome)"
	t1_up=racing
fi
kill -INT $SRV 2>/dev/null
wait $SRV 2>/dev/null
python3 -I - "$t/b/apps/workbench/saves/world/save.sqlite" "$t1_up" <<'PY' || fail "B's save"
import json, sqlite3, sys
c = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True)
rows = dict(((s, k), v) for s, k, v in c.execute("SELECT store, key, value FROM store"))
es = {e["id"]: e for e in json.loads(rows[("kit", "authored")])["entities"]}
sc = {e["name"]: e for e in es.values() if e.get("kind") == "scene"}
assert {"world", "hub", "racing", "t1"} <= set(sc), sorted(sc)
assert sc["racing"]["parent"] == sc["hub"]["id"], sc
t1_up = sc[sys.argv[2]]["id"] if sys.argv[2] != "root" else 1
assert sc["t1"].get("parent", 1) == t1_up, (sc["t1"], sys.argv[2])
up = [e for e in es.values() if e.get("name") == "Rules from above"]
assert len(up) == 1 and up[0]["parent"] == sc["racing"]["id"], up
assert [cm["type"] for cm in up[0]["components"]] == ["kit/environment"], up
assert up[0]["components"][0]["links"] == [{"output": "dawn", "to_name": "Racing list", "input": "show"}], up
assert any(k[1].startswith("hm_edit:t1/") for k in rows)
print("B's save: hub > racing, t1 under %s, racing's rules from above with their link by name, t1's stroke" % sys.argv[2])
PY
echo "PASS: a scene tree: a group's controls and movement in it and the track under it, the root's in a sibling, each sent as the builder moved and as the group's changed; the group's list its tracks alone; its removal refused; a draft's track the group's; exported with its track and the root's environment, added under another game's scene; an empty scene with no ground holding its player. Screenshots in $t"
