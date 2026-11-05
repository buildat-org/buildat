#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~30 s, more with a cold module cache (2026-11-05)
# covers: builtin/kit/client_lua/editor.lua builtin/kit/client_lua/ui.lua builtin/kit/client_lua/signals.lua builtin/kit/kit.cpp builtin/kit/types/*.lua
# [KIT_PARAM_CATEGORIES] The inspector's categories on Workbench. kitboss (the
# admin, 1024x700), a kit/flag, a kit/timer, a kit/ui_bar, a kit/game_rules and
# a type of the check's own with a wrong cat:
#   1. every cat in builtin/kit/types is one of the five; the wrong ones warned
#      of on the server, the type loaded, its parameters under Behaviour;
#   2. chips on kit/flag, none on kit/timer; a chip filters and is kept moving to
#      another entity, All on a type without it, back on the next that has it;
#   3. a field edited in one category and one in another survive the switches
#      and Apply sends both (the save);
#   4. a click on Kit's own hotbar and health bar in Walk: narrowed to hotbar_*,
#      health_*; All back to the chips; a click on a ui_bar: the HUD chip;
#   5. the HUD view: the panel beside the selected element, a value set in it
#      applied, its own click no background click, following the element as it
#      is dragged, closed by a click on the background, opened by a click on
#      the element, a double click leaves the view;
#   6. the flag's inspector, two links on it, not over the window in 3D;
#   7. the Signals view's column has the chips;
#   8. a 1800x1000 window; a touch client at 600x400: a tap opens and closes the
#      panel, its title's tap is its own, two taps leave.
# Screenshots kept with KEEP_TMP=1: $t/flag.png, $t/look.png, $t/narrow.png,
# $t/hud_panel.png, $t/hud_health.png, $t/hud_bar.png, $t/signals.png,
# $t/wide*.png, $t/touch*.png; look at them.
#   util/kit_param_categories_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
# 1. One line: the five, nothing else
bad=$(grep -ohE '\bcat = "[^"]*"' "$here"/builtin/kit/types/*.lua | grep -vE '"(behaviour|hud|look|physics|advanced)"$' | sort -u)
[ -z "$bad" ] || fail "a cat that is none of the five: $bad"
echo "ok: every cat in builtin/kit/types is one of the five"
check_tmp kit_param_categories; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1
# (in its app directory: the sandboxed server reads nothing else of the run's)
export BUILDAT_WORKBENCH_TYPES="$t/user/apps/workbench/check_types"
mkdir -p "$BUILDAT_WORKBENCH_TYPES"
cat > "$BUILDAT_WORKBENCH_TYPES/catprobe.lua" <<'EOF'
-- The check's type: a wrong cat, a cat of the wrong type, a right one
return {
	params = {
		a = {cat = "nonsense", type = "number", default = 1},
		b = {cat = 5, type = "number", default = 1},
		c = {cat = "physics", type = "number", default = 1},
		d = {type = "number", default = 1}, e = {type = "number", default = 1},
		f = {type = "number", default = 1}, g = {type = "number", default = 1},
		h = {type = "number", default = 1},
	},
}
EOF
client() # <name> <window> [client's options]: its commands in $t/<name>.cmds
{
	local name=$1 win=$2
	shift 2
	sed -i "s|@T@|$t|g" "$t/$name.cmds"
	run_client 60 "$t/$name.log" timeout 180 bin/buildat -C "$t/client_cache" \
		-D "$t/cu_$name" -s localhost:$SERVER_PORT -w "$win" -l 3 "$@" \
		-c @"$t/$name.cmds" || fail "client $name failed ($t/$name.log, $t/srv.log)"
}
edit() # <op json>: an edit and its answer
{
	printf 'event kit_edit %s\nwait_log 10000 kit editor: state:\n' "$1"
}
id=2
place() # <type>: the next id
{
	id=$((id + 1))
	edit "{\"op\": \"place\", \"type\": \"$1\", \"pos\": [$id, 1, 6]}"
}
set_param() # <id> <param> <json>
{
	edit "{\"op\": \"set\", \"id\": $1, \"comp\": 0, \"param\": \"$2\", \"value\": $3}"
}
at() # <x> <y>: the pointer there, a click
{
	printf 'mouse_pos %d %d\nframes 2\nmouse_click left\nframes 5\n' "$1" "$2"
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
	place kit/timer; TIMER=$id
	place kit/ui_bar; BAR=$id
	place kit/game_rules; RULES=$id
	place workbench/catprobe; PROBE=$id
	place kit/ui_text; TEXT=$id
	set_param $BAR anchor '"top"'
	set_param $BAR x 0
	set_param $BAR y 30
	edit "{\"op\": \"link\", \"id\": $FLAG, \"comp\": 0, \"output\": \"progress\", \"to\": $BAR, \"input\": \"value\"}"
	edit "{\"op\": \"link\", \"id\": $FLAG, \"comp\": 0, \"output\": \"holder_team\", \"to\": $TEXT, \"input\": \"value\"}"
	# 2. and 6. In 3D, the chips, a chip kept
	cat <<EOF
keypress F2
frames 5
event kit_select $FLAG
frames 5
event kit_ui_where flag
frames 3
screenshot @T@/flag.png
event kit_select $TIMER
frames 5
event kit_select $PROBE
frames 5
event kit_select $FLAG
frames 5
click Button "Look"
frames 5
screenshot @T@/look.png
event kit_select $RULES
frames 5
event kit_select $TIMER
frames 5
event kit_select $FLAG
frames 5
EOF
	# 3. Edited in Look and in Advanced, seen again, applied from Advanced
	cat <<'EOF'
click LineEdit "#f0f0f0"
frames 2
keypress Backspace
frames 2
text 1
frames 3
click Button "Advanced"
frames 5
click LineEdit "0.1"
frames 2
keypress Backspace
frames 2
text 2
frames 3
click Button "Look"
frames 5
screenshot @T@/pending.png
click LineEdit "#f0f0f1"
frames 2
click Button "Advanced"
frames 5
click LineEdit "0.2"
frames 2
click Button "Apply"
wait_log 10000 kit editor: state:
frames 5
EOF
	# 4. In Walk, over the kept Look: Kit's own, a ui_bar's click
	cat <<EOF
click Button "Look"
frames 5
keypress F3
frames 5
event kit_select $TIMER
frames 5
EOF
	# (between the palette and the inspector)
	at 455 665
	cat <<'EOF'
frames 3
screenshot @T@/narrow.png
click Button "All" 800 300
frames 5
click Button "HUD"
frames 5
click Button "All" 800 300
frames 5
EOF
	at 460 219
	cat <<'EOF'
screenshot @T@/walk_bar.png
EOF
	at 455 619
	# 5. The HUD view
	cat <<'EOF'
frames 3
screenshot @T@/walk_health.png
keypress F4
frames 5
screenshot @T@/hud_health.png
EOF
	at 512 665
	cat <<'EOF'
frames 3
screenshot @T@/hud_panel.png
click Text "Hotbar" 400 480
frames 5
click LineEdit "2.8"
frames 2
keypress Backspace
keypress Backspace
keypress Backspace
frames 2
text 4
frames 3
click Button "Apply"
wait_log 10000 kit editor: state:
frames 8
screenshot @T@/hud_applied.png
EOF
	printf 'mouse_pos 512 658\nframes 2\nmouse_down left\nframes 2\nmouse_pos 512 560\nframes 2\nmouse_pos 512 480\nframes 2\nmouse_up left\nwait_log 10000 kit: ui own:hotbar dragged to\nwait_log 10000 kit editor: state:\nframes 8\n'
	cat <<'EOF'
screenshot @T@/hud_dragged.png
EOF
	at 100 300
	cat <<'EOF'
screenshot @T@/hud_closed.png
EOF
	at 512 478
	cat <<'EOF'
frames 3
screenshot @T@/hud_reopened.png
mouse_pos 100 300
frames 2
mouse_click left
mouse_click left
frames 5
EOF
	# 4. The bar's panel from the view; 7. the Signals view
	cat <<EOF
screenshot @T@/hud_out.png
event kit_tabs out
keypress F4
frames 5
EOF
	at 512 215
	cat <<EOF
frames 3
screenshot @T@/hud_bar.png
keypress Escape
frames 5
event kit_select $FLAG
frames 5
keypress F5
frames 8
click Button "Look"
frames 5
screenshot @T@/signals.png
keypress Escape
frames 5
sync 3000
quit
EOF
} > "$t/kitboss.cmds"
start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
	--sim-rate "$CHECK_RATE" || fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
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
grep -a " I kit " "$b" > "$t/kit.txt"
# 1. The wrong cats
grep -aq "catprobe: parameter a: cat \"nonsense\" is none of" "$s" || fail "no warning on the wrong cat ($s)"
grep -aq "catprobe: parameter b: cat 5 is none of" "$s" || fail "no warning on the cat of a wrong type ($s)"
want "$b" "parameters $PROBE/1 workbench/catprobe: chips All Behaviour Physics, showing all, 8 of 8"
echo "ok: a wrong cat warned of, the type loaded, under Behaviour"
python3 -I - "$t/kit.txt" "$FLAG" "$TIMER" "$RULES" "$BAR" <<'PY' || fail "the chips ($t/kit.txt)"
import re, sys
flag, timer, rules, bar = sys.argv[2:6]
lines = open(sys.argv[1], errors="replace").read().split("\n")
par = [l.split("kit editor: parameters ")[1] for l in lines if "kit editor: parameters " in l]
def of(i):
	return [l for l in par if l.startswith(i + "/1 ")]
# 2. The chips and their filter
assert of(flag)[0].split(", ")[0].endswith("chips All Behaviour HUD Look Advanced"), of(flag)[0]
assert ", showing all, 41 of 41:" in of(flag)[0], of(flag)[0]
assert any("no chips, 5 of 5" in l for l in of(timer)), of(timer)
look = next(l for l in of(flag) if "showing look" in l)
assert look.endswith(": color lift marker_color marker_label marker_lift marker_style own_look"), look
# Kept: Look on the flag, All on the rules (no Look there), Look on the flag
order = [l for l in par if ("showing look" in l and l.startswith(flag)) or l.startswith(rules)]
assert " kit/game_rules: chips All Behaviour HUD, showing all, 42 of 42" in order[1], order[:3]
assert "showing look" in order[2], order[:3]
# 4. The bar's click over the kept Look; the own ones; All; HUD
assert any("chips All Behaviour HUD, showing hud" in l for l in of(bar)), of(bar)
hb = [l for l in of(rules) if "chips [hotbar]" in l]
assert hb and "showing hotbar_*, 3 of 42: hotbar_anchor hotbar_x hotbar_y" in hb[0], hb
hl = [l for l in of(rules) if "chips [health]" in l]
assert hl and re.search(r"showing health_\*, 15 of 42: health_anchor", hl[0]), hl
i = par.index(hb[0])
assert "chips All Behaviour HUD, showing all, 42 of 42" in par[i + 1], par[i + 1]
assert "showing hud" in par[i + 2], par[i + 2]
# The panel: beside, not over, inside; following the drag
panels = [re.search(r"the HUD panel at (\S+) (\w+) (-?\d+) (-?\d+) (\d+) (\d+), the element (-?\d+) (-?\d+) (\d+) (\d+)", l) for l in lines]
panels = [m for m in panels if m]
assert any(m[1] == "own:hotbar" for m in panels) and any(m[1] == "own:health" for m in panels), panels
for m in panels:
	x, y, w, h, ex, ey, ew, eh = map(int, m.groups()[2:])
	assert x >= 0 and y >= 0 and x + w <= 1024 and y + h <= 700, m[0]
	assert x + w <= ex or ex + ew <= x or y + h <= ey or ey + eh <= y, "over the element: " + m[0]
ys = {int(m[8]) for m in panels if m[1] == "own:hotbar"}
assert len(ys) >= 3 and min(ys) <= 485, ("did not follow the applied value and the drag", ys)
ph = [l.split("parameters: ")[1] for l in lines if "the HUD panel's parameters: " in l]
assert "hotbar_anchor hotbar_x hotbar_y" in ph, ph
assert any(p.startswith("anchor background blink_below border color") and "source" not in p for p in ph), ph
# The order of the clicks on the background
ev = [l for l in lines if re.search(r"the HUD panel closed|a double click out|the view is |own:hotbar dragged|selected Kit's own", l)]
ev = [re.sub(r".*kit(: ui:? | editor: )", "", l) for l in ev]
s = "; ".join(ev)
want = ("own:hotbar dragged to 0, ", "the HUD panel closed; selected Kit's own hotbar; the HUD panel closed; "
	"a double click out of the HUD view; the view is Walk")
assert want[1] in s, s
assert s.index(want[0]) < s.index(want[1]), s
# The panel's own click, its field and Apply closed nothing and dragged nothing
assert s.count("own:hotbar dragged") == 1, s
d = s.index(want[0])
assert "closed" not in s[s.rindex("the view is HUD", 0, d):d], s
print("the panel at", panels[0][0])
PY
echo "ok: chips on the flag, none on the timer; a chip kept; narrowing; the panel beside the element and following it"
# 2., 6.
wid=$(grep -aoP "inspector \K-?\d+ \d+ \d+ \d+(?=.*\(flag\))" "$b" | head -1)
pal=$(grep -aoP "palette \K-?\d+ \d+ \d+ \d+(?=.*\(flag\))" "$b" | head -1)
read -r ix _ iw _ <<<"$wid"
read -r px _ pw _ <<<"$pal"
[ -n "${iw:-}" ] && [ -n "${pw:-}" ] || fail "no windows' line ($b)"
# (It was 1048 wide before the Link row wrapped; a long link's row sets it now)
[ "$ix" -ge $((px + pw)) ] && [ $((ix + iw)) -le 1024 ] ||
	fail "the flag's inspector over the window: $wid, the palette $pal"
echo "ok: the flag's inspector $wid, the palette $pal at 1024x700"
# 5. Apply and the view left; the panel's own click closed nothing
grep -aq "own:hotbar own at .*" "$b" || fail "no hotbar line ($b)"
want "$t/kit.txt" "kit editor: signals: columns in 1024x700"
want "$b" "chips All Behaviour HUD Look Advanced, showing look"
for p in flag look pending walk_bar narrow walk_health hud_health hud_panel hud_applied hud_dragged hud_closed hud_reopened hud_out hud_bar signals; do
	[ -s "$t/$p.png" ] || fail "no screenshot $t/$p.png"
done
# 8. A wide window; a touch client
cat > "$t/kitwide.cmds" <<EOF
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log_any 10000 kit editor: edit mode on
frames 5
keypress F2
frames 5
event kit_select $FLAG
frames 5
event kit_ui_where wide
frames 3
screenshot @T@/wide_flag.png
event kit_select $BAR
frames 5
keypress F4
frames 8
event kit_ui_where widepanel
frames 3
screenshot @T@/wide_panel.png
sync 3000
quit
EOF
cat > "$t/kittouch.cmds" <<EOF
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log_any 10000 kit editor: edit mode on
frames 5
event kit_select $BAR
frames 5
keypress F4
frames 8
screenshot @T@/touch_panel.png
tap Text "◆ $BAR *"
frames 5
event kit_tabs title
tap 60 300
frames 5
screenshot @T@/touch_closed.png
tap 300 125
frames 8
screenshot @T@/touch_reopened.png
tap 60 300
tap 60 300
frames 5
event kit_tabs out
sync 3000
quit
EOF
BUILDAT_JOIN_NAME=kitboss client kitwide 1800x1000 -u 1
BUILDAT_JOIN_NAME=kitboss BUILDAT_TOUCH=1 client kittouch 600x400 -u 1
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
grep -a "the windows at .*hud_panel .*(widepanel)" "$t/kitwide.log" >/dev/null || fail "no panel in the wide window ($t/kitwide.log)"
grep -a " I kit " "$t/kittouch.log" | grep -a "the HUD panel closed\|the HUD panel at\|double click\|the view is \|the tabs" |
	sed 's/.*kit editor: //' > "$t/touch.txt"
python3 -I - "$t/touch.txt" <<'PY' || fail "the touch client's panel ($t/touch.txt)"
import sys
s = [l.strip() for l in open(sys.argv[1], errors="replace")]
t = next(i for i, l in enumerate(s) if "(title)" in l)
assert any("the HUD panel at" in l for l in s[:t]), s
assert not any("closed" in l for l in s[:t]), s
c = next(i for i, l in enumerate(s) if "closed" in l)
assert any("the HUD panel at" in l for l in s[c + 1:]), s
assert any("a double click out" in l for l in s[c + 1:]), s
PY
echo "ok: a wide window; a touch client: a tap opens and closes the panel, two leave the view"
# 3. and 5. In the save: the fields of two categories, the panel's value
python3 -I - "$t/user/apps/workbench/saves/world/save.sqlite" "$FLAG" "$RULES" <<'PY' || fail "the save"
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
a = json.loads(db.execute("SELECT value FROM store WHERE store = 'kit' AND key = 'authored'").fetchone()[0])
def params(i):
	return next(e for e in a["entities"] if e["id"] == int(i))["components"][0]["params"]
f = params(sys.argv[2])
assert f["color"] == "#f0f0f1" and f["poll"] == 0.2, f
r = params(sys.argv[3])
assert r["hotbar_y"] != 2.8, r
# (kept out: a chip is the editor's; a cat is no saved value)
assert "cat" not in f and "cat" not in r
PY
echo "ok: fields edited in two categories applied; the panel's value in the save"
if grep -aE " W kit +: kit: ui|attempt to|stack traceback" "$b" "$t/kitwide.log" "$t/kittouch.log" | head -5 | grep -a .; then
	fail "a Lua error in the logs"
fi
echo "PASS: categories: chips filter and are kept, pending fields survive, Kit's own HUD narrows, the HUD view's panel, the flag's inspector fits; screenshots $t/flag.png $t/look.png $t/narrow.png $t/hud_panel.png $t/signals.png $t/wide_flag.png $t/touch_panel.png"
