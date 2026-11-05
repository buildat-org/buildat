#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~20 s (2026-11-05)
# covers: builtin/kit/client_lua/signals.lua builtin/kit/client_lua/editor.lua builtin/kit/client_lua/ui.lua builtin/kit/client_lua/input.lua
# [KIT_SIGNALS_VIEW] The editor's Signals view on Workbench. kitboss (the
# admin, 1024x700), a kit/flag with links to three kit/ui_bars and from a
# kit/timer:
#   1. F5 from 3D: the three columns side by side under the bar, no panel, no
#      other window; the 3D camera where it was afterwards;
#   2. a link added from the table (output, target, input by its dropdowns),
#      unlinked by its chip, hidden and shown by its toggle: the server's
#      edits; the toggle's in the save;
#   3. a target's name selects it, its "Comes from" there;
#   4. the filter narrows the list, by type and by name; a view key while
#      typing in it;
#   5. a rename: the server's edit, undone by Ctrl+Z, again; in the save, and
#      read in the table by another client after the server's restart;
#   6. the viewport's camera on the selected entity, the walk camera's on one
#      with no position; a ui_bar selected: the HUD laid out in its rectangle,
#      that bar marked; game_rules selected: no HUD;
#   7. Escape back to the view before; Walk has its panels and HUD back;
#   8. a 1800x1000 window, and a touch client at 600x400: one column at a time.
# Screenshots kept with KEEP_TMP=1: $t/signals.png, $t/added.png, $t/hud.png,
# $t/game_wide.png, $t/wide.png, $t/narrow_*.png; look at them.
#   util/kit_signals_view_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_signals_view; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1

client() # <name> <window> [client's options]: its commands in $t/<name>.cmds
{
	local name=$1 win=$2
	shift 2
	sed -i "s|@T@|$t|g" "$t/$name.cmds"
	run_client 60 "$t/$name.log" timeout 180 bin/buildat -C "$t/client_cache" \
		-D "$t/cu_$name" -s localhost:$SERVER_PORT -w "$win" -l 3 "$@" \
		-c @"$t/$name.cmds" || fail "client $name failed ($t/$name.log, $t/srv.log)"
}
serve() # <log>
{
	start_server "$1" "Listening at" 300 auto \
		bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
		--sim-rate "$CHECK_RATE" || fail "the server did not come up ($1)"
	CHECK_PIDS+=($SERVER_PID)
}
stop_server()
{
	kill -INT "$SERVER_PID" 2>/dev/null
	wait "$SERVER_PID" 2>/dev/null
}
edit() # <op json>: an edit and its answer
{
	printf 'event kit_edit %s\nwait_log 10000 kit editor: state:\n' "$1"
}
state() # the answer to the edit just asked for by a click
{
	echo "wait_log 10000 kit editor: state:"
}
id=2
place() # <type>: the next id
{
	id=$((id + 1))
	edit "{\"op\": \"place\", \"type\": \"$1\", \"pos\": [$id, 1, 6]}"
}
link() # <from> <output> <to> <input>
{
	edit "{\"op\": \"link\", \"id\": $1, \"comp\": 0, \"output\": \"$2\", \"to\": $3, \"input\": \"$4\"}"
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
wait_log_any 10000 kit editor: edit mode on
frames 5
EOF
	place kit/flag; FLAG=$id
	place kit/ui_bar; BAR1=$id
	place kit/ui_bar; BAR2=$id
	place kit/ui_bar; BAR3=$id
	place kit/timer; TIMER=$id
	place kit/game_rules; RULES=$id
	link $FLAG left $BAR1 value
	link $FLAG taken $BAR1 show
	link $FLAG home $BAR1 hide
	link $FLAG taken $BAR2 hide
	link $FLAG home $BAR2 hide
	link $FLAG placed $BAR2 show
	link $TIMER done $FLAG home
	cat <<EOF
event kit_select $FLAG
frames 3
event kit_cam3d 40 30 40 0 0 0
frames 5
event kit_cam_where before
frames 3
keypress F5
frames 8
event kit_ui_where signals
event kit_tabs signals
frames 3
screenshot @T@/signals.png
EOF
	# 2. Added from the table: a third bar's value from "progress"
	cat <<EOF
click Button "add link"
frames 3
screenshot @T@/form.png
click DropDownList "▼" 450 200
frames 3
click Text "progress*"
frames 3
click DropDownList "▼" 450 230
frames 3
screenshot @T@/form_target.png
click Text "$BAR3 ui_bar"
frames 3
click DropDownList "▼" 450 264
frames 3
click Text "value*"
frames 3
screenshot @T@/form_input.png
click Button "Link"
EOF
	state
	cat <<EOF
frames 3
screenshot @T@/added.png
click Button "Done"
frames 3
click Button "unlink $FLAG.taken $BAR2.hide"
EOF
	state
	cat <<EOF
frames 3
click Button "visible $FLAG.left $BAR1.value"
EOF
	state
	cat <<EOF
frames 3
click Button "visible $FLAG.home $BAR1.hide"
EOF
	state
	cat <<EOF
frames 3
click Button "visible $FLAG.home $BAR1.hide"
EOF
	state
	# 3. A target's name selects it
	cat <<EOF
frames 3
click Button "goto $BAR1"
frames 5
screenshot @T@/target.png
click Button "goto $FLAG"
frames 5
EOF
	# 5. The name, undone, again
	cat <<EOF
click LineEdit "signals name"
frames 2
text Home flag
frames 2
click Button "Rename"
EOF
	state
	cat <<EOF
frames 3
screenshot @T@/renamed.png
keydown ctrl
keypress Z
keyup ctrl
EOF
	state
	cat <<EOF
frames 3
click LineEdit "signals name"
frames 2
text Home flag
frames 2
click Button "Rename"
EOF
	state
	# 4. The filter
	cat <<EOF
frames 3
click LineEdit "signals filter"
frames 2
text ui_bar
frames 3
screenshot @T@/filtered.png
keypress Backspace
keypress Backspace
keypress Backspace
keypress Backspace
keypress Backspace
keypress Backspace
frames 2
text home F
frames 3
keypress Backspace
keypress Backspace
keypress Backspace
keypress Backspace
keypress Backspace
keypress Backspace
frames 3
EOF
	# A view key with the focus in the filter, and back
	cat <<EOF
keypress F2
frames 5
keypress F5
frames 5
EOF
	# 6. The viewport; its HUD
	cat <<EOF
event kit_select $RULES
frames 5
screenshot @T@/nohud.png
event kit_select $BAR1
frames 5
screenshot @T@/hud.png
event kit_ui_where hud
event kit_select $RULES
frames 5
screenshot @T@/game_wide.png
event kit_select $FLAG
frames 5
event kit_cam_where after
frames 3
EOF
	# 7. Back to the view before; Walk
	cat <<EOF
keypress Escape
frames 5
event kit_tabs out
frames 2
screenshot @T@/out.png
keypress F3
frames 5
screenshot @T@/walk.png
keypress F5
frames 5
sync 3000
quit
EOF
} > "$t/kitboss.cmds"
serve "$t/srv.log"
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code client kitboss 1024x700 -u 1
s=$t/srv.log b=$t/kitboss.log
want() # <log> <text>...
{
	local log=$1 w
	shift
	for w in "$@"; do
		grep -aqF -- "$w" "$log" || fail "no \"$w\" in $log"
	done
}
wantp() # <log> <perl regex>
{
	grep -aqP -- "$2" "$1" || fail "no /$2/ in $1"
}
kit() # <log>: Kit's own lines, not the drive's
{
	grep -a " I kit " "$1"
}
# 1. Three columns side by side, under the bar, inside the window
kit "$b" > "$t/kit.txt"
python3 -I - "$t/kit.txt" <<'PY' || fail "the columns ($t/kit.txt)"
import re, sys
lines = [l for l in open(sys.argv[1], errors="replace") if "signals: columns in 1024x700" in l]
assert lines, "no columns line"
m = re.search(r"under (\d+): (.*)$", lines[-1])
top, cols = int(m[1]), {}
for c in m[2].split(", "):
    n, x, y, w, h = c.split()
    cols[n] = (int(x), int(y), int(w), int(h))
assert set(cols) == {"sg_list", "sg_links", "inspector", "sg_view"}, cols
l, c, i, v = (cols[k] for k in ("sg_list", "sg_links", "inspector", "sg_view"))
assert l[0] + l[2] <= c[0] and c[0] + c[2] <= i[0], cols
assert i[1] + i[3] <= v[1] and i[0] == v[0], cols
assert v[0] + v[2] <= 1024 and v[1] + v[3] <= 700 and l[1] + l[3] <= 700, cols
assert min(l[1], c[1], i[1]) >= top > 10, (top, cols)
PY
wantp "$b" "the windows at bar \d+ \d+ \d+ \d+, inspector \d+ \d+ \d+ \d+, sg_list \d+ \d+ \d+ \d+, sg_links \d+ \d+ \d+ \d+, sg_view \d+ \d+ \d+ \d+ \(signals\)"
wantp "$b" "the view Signals|the view signals, the tabs"
want "$b" "kit editor: the view is Signals"
before=$(grep -a "the 3D camera at .*(before)" "$b" | sed 's/.*camera at //; s/ (.*//')
after=$(grep -a "the 3D camera at .*(after)" "$b" | sed 's/.*camera at //; s/ (.*//')
[ -n "$before" ] && [ "$before" = "$after" ] || fail "the 3D camera moved: $before, $after"
echo "ok: F5: three columns under the bar in 1024x700, no other panel; the 3D camera kept"
# 2.
want "$b" "signals: linked $FLAG.progress -> $BAR3.value" "signals: unlinked $FLAG.taken -> $BAR2.hide" \
	"signals: $FLAG.left -> $BAR1.value shown in play" "signals: $FLAG.home -> $BAR1.hide shown in play" \
	"signals: $FLAG.home -> $BAR1.hide hidden in play"
want "$s" "linked $FLAG.progress -> $BAR3.value" "unlinked $FLAG.taken -> $BAR2.hide" \
	"showed $FLAG.left -> $BAR1.value in play" "hid $FLAG.home -> $BAR1.hide in play"
echo "ok: a link added, unlinked and hidden from the table"
# 3.
seq=$(kit "$b" | grep -a "kit editor: selected " | sed 's/.*selected //; s/ (.*//' | tr '\n' ' ')
case $seq in
*"$BAR1 $FLAG "*) ;;
*) fail "the target's name did not select: $seq ($b)" ;;
esac
want "$b" "signals: $BAR1 $BAR1 ui_bar: 0 out, "
echo "ok: a target's name selects it, its links both ways there"
# 4.
wantp "$b" "signals: list \"ui_bar\" \(3\): .*$BAR1, .*$BAR2, .*$BAR3"
wantp "$b" "signals: list \"home F\" \(1\): .*$FLAG\$"
echo "ok: the filter, by type and by name"
seq=$(kit "$b" | grep -a "kit editor: the view is " | sed 's/.*view is //' | tr '\n' ' ')
case $seq in
*"3D Signals 3D Signals 3D Walk Signals "*) ;;
*) fail "the views: $seq ($b)" ;;
esac
echo "ok: a view key from the filter; Escape back to the view before"
# 5.
want "$s" "renamed $FLAG to Home flag"
want "$b" "signals: $FLAG $FLAG Home flag: "
# Undone in between: the placed name's line after the first rename
kit "$b" | grep -a "signals: $FLAG $FLAG " | sed 's/.*signals: //; s/:.*//' | uniq > "$t/names.txt"
awk 'index($0, "Home flag") { h = 1 } h && !index($0, "Home flag") { u = 1 } u && index($0, "Home flag") { a = 1 } END { exit !a }' "$t/names.txt" ||
	fail "the rename not undone and done again ($t/names.txt)"
echo "ok: a rename, undone, again"
# 6.
want "$b" "signals: the viewport shows entity $FLAG" "signals: the viewport shows entity $BAR1" \
	"signals: the viewport shows what the walk camera shows" \
	"signals: the HUD in the viewport on" "signals: the HUD in the viewport off"
kit "$b" > "$t/kit.txt"
python3 -I - "$t/kit.txt" "$BAR1" <<'PY' || fail "the HUD in the viewport ($t/kit.txt)"
import re, sys
bar = sys.argv[2]
lines = open(sys.argv[1], errors="replace").read().split("\n")
ui = re.compile(r"kit: ui %s bar at (\d+),(\d+) (\d+)x(\d+) in (\d+)x(\d+) .* (shown|hidden)" % bar)
on = [i for i, l in enumerate(lines) if ", marked" in l and ui.search(l)][-1]
cols = [l for l in lines[:on] if "signals: columns in 1024x700" in l][-1]
x, y, w, h = map(int, re.search(r"sg_view (\d+) (\d+) (\d+) (\d+)", cols).groups())
# Selected: shown and marked, inside the viewport's rectangle
m = ui.search(lines[on])
assert m[7] == "shown", m[0]
bx, by, bw, bh, aw, ah = map(int, m.groups()[:6])
assert aw < w and ah < h and aw > 100 and ah > 50, (aw, ah, w, h)
assert x <= bx and bx + bw <= x + w and y <= by and by + bh <= y + h, (m[0], x, y, w, h)
# Then game_rules selected: hidden, not marked
after = [l for l in lines[on + 1:] if ui.search(l) and ", marked" not in l]
assert after and ui.search(after[0])[7] == "hidden", after[:1]
PY
echo "ok: the viewport's camera; a HUD element selected lays the HUD out in its rectangle, marked"
# 7. The Walk view's panels back
wantp "$b" "kit: ui $BAR1 bar at .* in 1024x700 .* shown"
for p in signals form added target renamed filtered nohud hud game_wide out walk; do
	[ -s "$t/$p.png" ] || fail "no screenshot $t/$p.png"
done
# 5. The name after a restart; 8. A wide window, a narrow touch one
stop_server
python3 -I - "$t/user/apps/workbench/saves/world/save.sqlite" "$FLAG" "$BAR1" <<'PY' || fail "the save"
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
a = json.loads(db.execute("SELECT value FROM store WHERE store = 'kit' AND key = 'authored'").fetchone()[0])
e = next(e for e in a["entities"] if e["id"] == int(sys.argv[2]))
assert e["name"] == "Home flag", e["name"]
ls = {(l["output"], l["to"], l["input"]): l.get("visible") for l in e["components"][0]["links"]}
assert ls[("left", int(sys.argv[3]), "value")] is True, ls
assert not ls[("home", int(sys.argv[3]), "hide")], ls
PY
cat > "$t/kitwide.cmds" <<EOF
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log_any 10000 kit editor: edit mode on
frames 5
event kit_select $FLAG
frames 3
keypress F5
frames 8
screenshot @T@/wide.png
sync 3000
quit
EOF
cat > "$t/kitnarrow.cmds" <<EOF
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log_any 10000 kit editor: edit mode on
frames 5
event kit_select $FLAG
frames 3
keypress F5
frames 8
screenshot @T@/narrow_links.png
click Button "Entities"
frames 5
screenshot @T@/narrow_list.png
click Button "Inspector"
frames 5
screenshot @T@/narrow_inspector.png
sync 3000
quit
EOF
serve "$t/srv2.log"
BUILDAT_JOIN_NAME=kitboss client kitwide 1800x1000 -u 1
BUILDAT_JOIN_NAME=kitboss BUILDAT_TOUCH=1 client kitnarrow 600x400 -u 1
stop_server
want "$t/kitwide.log" "signals: $FLAG $FLAG Home flag: " "signals: columns in 1800x1000 "
wantp "$t/kitwide.log" "signals: the HUD in the viewport on"
wantp "$t/kitnarrow.log" "signals: columns in 600x400 under \d+: sg_links \d+ \d+ 588 \d+"
wantp "$t/kitnarrow.log" "signals: columns in 600x400 under \d+: sg_list \d+ \d+ 588 \d+"
wantp "$t/kitnarrow.log" "signals: columns in 600x400 under \d+: inspector \d+ \d+ 588 \d+$"
echo "ok: the name after a restart, read by another client; a wide window; one column at a time on a narrow touch one"
if grep -aE "kit: ui: |kit: ui handles: |attempt to|stack traceback" "$b" "$t/kitwide.log" "$t/kitnarrow.log" | grep -av " I kit editor" | head -5 | grep -a .; then
	fail "a Lua error in the logs"
fi
echo "PASS: the Signals view: three columns, links added, unlinked and hidden, names followed, a rename kept, the filter, the viewport and its HUD; screenshots $t/signals.png $t/added.png $t/hud.png $t/wide.png $t/narrow_links.png"
