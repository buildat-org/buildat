#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~30 s, more with a cold module cache (2026-11-05)
# covers: builtin/kit/client_lua/editor.lua builtin/kit/client_lua/editor_input.lua builtin/kit/client_lua/ui.lua builtin/kit/client_lua/signals.lua builtin/kit/kit.cpp builtin/kit/types/*.lua
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
#   5. the HUD view ([KIT_LOBBY] the tool panel at the right, the frame
#      left of it): the selected element's parameters in it, a value set in
#      it applied, its own click no background click, the element dragged, a
#      click on the background letting it go, one on the element taking it
#      again, the views dropdown leaving the view;
#   6. the flag's inspector, two links on it, not over the window in 3D;
#   7. the Signals view's column has the chips;
#   8. a 1800x1000 window; a touch client at 600x400 (-u 1: the desktop's
#      tool panel): a tap lets the element go and takes it again, its
#      title's tap is its own, typing in a field, the views dropdown leaves;
#   9. a chip holding an edit not applied marked; the last chip back in a new
#      session; a warning's height given back; narrowing on the kill feed and
#      the hint; a drag started on the panel moves nothing; the
#      panel's Place kit/game_rules with no rules placed.
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
click Button "Look*"
frames 5
screenshot @T@/pending.png
click LineEdit "#f0f0f1"
frames 2
click Button "Advanced*"
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
	# ([KIT_LOBBY] the frame the room left of the 390 wide tool panel, 634x700:
	# its middle at x 317, the HUD's units 634/700 of Walk's)
	at 317 665
	cat <<'EOF'
frames 3
screenshot @T@/hud_panel.png
click Text "Hotbar" 860 60
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
	printf 'mouse_pos 317 658\nframes 2\nmouse_down left\nframes 2\nmouse_pos 317 560\nframes 2\nmouse_pos 317 480\nframes 2\nmouse_up left\nwait_log 10000 kit: ui own:hotbar dragged to\nwait_log 10000 kit editor: state:\nframes 8\n'
	cat <<'EOF'
screenshot @T@/hud_dragged.png
EOF
	at 100 300
	cat <<'EOF'
screenshot @T@/hud_closed.png
EOF
	at 317 478
	cat <<'EOF'
frames 3
screenshot @T@/hud_reopened.png
click DropDownList "hud views"
wait_log 10000 hud views open
frames 3
click Text "hud views: Walk (F3)"
wait_log 10000 kit editor: the view is Walk
frames 5
EOF
	# 4. The bar's panel from the view; 7. the Signals view
	cat <<EOF
screenshot @T@/hud_out.png
event kit_tabs out
keypress F4
frames 5
EOF
	at 317 198
	cat <<EOF
frames 3
screenshot @T@/hud_bar.png
keypress Escape
frames 5
event kit_select $FLAG
frames 5
keypress F5
frames 8
click Button "Inspector"
frames 5
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
assert any("no chips, 4 of 4" in l for l in of(timer)), of(timer)
look = next(l for l in of(flag) if "showing look" in l)
assert look.endswith(": color lift marker_color marker_label marker_lift marker_style own_look"), look
# Kept: Look on the flag, All on the rules (no Look there), Look on the flag
order = [l for l in par if ("showing look" in l and l.startswith(flag)) or l.startswith(rules)]
assert " kit/game_rules: chips All Behaviour HUD, showing all, 43 of 43" in order[1], order[:3]
assert "showing look" in order[2], order[:3]
# 4. The bar's click over the kept Look; the own ones; All; HUD
assert any("chips All Behaviour HUD, showing hud" in l for l in of(bar)), of(bar)
hb = [l for l in of(rules) if "chips [hotbar]" in l]
assert hb and "showing hotbar_*, 3 of 43: hotbar_anchor hotbar_x hotbar_y" in hb[0], hb
hl = [l for l in of(rules) if "chips [health]" in l]
assert hl and re.search(r"showing health_\*, 16 of 43: health_anchor", hl[0]), hl
i = par.index(hb[0])
assert "chips All Behaviour HUD, showing all, 43 of 43" in par[i + 1], par[i + 1]
assert "showing hud" in par[i + 2], par[i + 2]
# [KIT_LOBBY] The tool panel at the right, the frame the room left of it;
# its parameters the selected element's (Kit's own too)
assert any(l.endswith("the HUD tool panel 390x700, the frame 0 0 634 700") for l in lines), \
	[l for l in lines if "the HUD tool panel" in l]
# (Kit's own rows fit it: the frame never moved)
assert all("390x700" in l for l in lines if "the HUD tool panel" in l), \
	[l for l in lines if "the HUD tool panel" in l]
shows = [l.split("the HUD panel shows ")[1] for l in lines if "the HUD panel shows " in l]
assert "own:hotbar" in shows and "own:health" in shows, shows
ph = [l.split("parameters: ")[1] for l in lines if "the HUD panel's parameters: " in l]
assert "hotbar_anchor hotbar_x hotbar_y" in ph, ph
assert any(p.startswith("anchor appear background blink_below border color") and "source" not in p for p in ph), ph
# The order of the clicks: on nothing in the frame the selection let go, on
# the element taken again; out by the views dropdown
ev = [l for l in lines if re.search(r"the HUD panel shows|the HUD panel closed|the view is |own:hotbar dragged|selected Kit's own", l)]
ev = [re.sub(r".*kit(: ui:? | editor: )", "", l) for l in ev]
s = "; ".join(ev)
want = ("own:hotbar dragged to 0, ", "the HUD panel shows nothing; selected Kit's own hotbar; "
	"the HUD panel shows own:hotbar; the view is Walk")
assert want[1] in s, s
assert s.index(want[0]) < s.index(want[1]), s
# The panel's own click, its field and Apply let go of nothing and dragged nothing
assert s.count("own:hotbar dragged") == 1, s
d = s.index(want[0])
assert "shows nothing" not in s[s.rindex("the view is HUD", 0, d):d], s
PY
echo "ok: chips on the flag, none on the timer; a chip kept; narrowing; the HUD view's tool panel and its frame"
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
tap LineEdit "#000000a0"
frames 3
keypress Backspace
frames 2
text 1
frames 5
screenshot @T@/touch_typed.png
tap Text "◆ $BAR *"
frames 5
event kit_tabs title
tap 60 200
frames 5
screenshot @T@/touch_closed.png
tap 150 93
frames 8
screenshot @T@/touch_reopened.png
tap DropDownList "hud views"
wait_log 10000 hud views open
frames 3
tap Text "hud views: Walk (F3)"
wait_log 10000 kit editor: the view is Walk
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
grep -a " I kit " "$t/kittouch.log" | grep -a "the HUD panel shows\|the HUD tool panel\|the view is \|the tabs" |
	sed 's/.*kit editor: //' > "$t/touch.txt"
python3 -I - "$t/touch.txt" "$BAR" <<'PY' || fail "the touch client's panel ($t/touch.txt)"
import sys
s = [l.strip() for l in open(sys.argv[1], errors="replace")]
bar = "the HUD panel shows " + sys.argv[2]
# ([KIT_LOBBY] -u 1: the desktop's tool panel, at 600x400 half the room for
# its touch-sized rows)
assert "the HUD tool panel 300x400, the frame 0 0 300 400" in s, s
t = next(i for i, l in enumerate(s) if "(title)" in l)
assert bar in s[:t], s
assert not any("shows nothing" in l for l in s[:t]), s
c = next(i for i, l in enumerate(s) if "shows nothing" in l)
assert bar in s[c + 1:], s
assert any("the view is Walk" in l for l in s[c + 1:]), s
PY
echo "ok: a wide window; a touch client: a tap lets the element go, one on it takes it again, the views dropdown leaves"
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
grep -aqF "chips All Behaviour HUD Look * Advanced *" "$b" ||
	fail "no chip marked with a pending edit ($b)"
[ "$(grep -ac "kit editor: $BAR/1 background = " "$t/kittouch.log")" -ge 2 ] ||
	fail "typing in the panel on touch ($t/kittouch.log)"
# 9.
cat > "$t/kitrest.cmds" <<EOF
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log_any 10000 kit editor: edit mode on
frames 5
keypress F2
frames 5
event kit_select $TIMER
frames 5
event kit_tabs warn0
click LineEdit "2"
frames 2
keypress Backspace
frames 2
text x
frames 5
event kit_tabs warn1
screenshot @T@/warned.png
keypress Backspace
frames 2
text 2
frames 5
event kit_tabs warn2
screenshot @T@/warning_gone.png
event kit_select $FLAG
frames 5
click Button "Look"
frames 5
delay 1200
event kit_select $TIMER
frames 5
keypress F3
frames 5
EOF
{
	at 940 50
	at 512 595
	cat <<EOF
event kit_edit {"op": "delete", "id": $RULES}
wait_log 10000 kit editor: state:
frames 3
keypress F4
frames 5
EOF
	at 317 627
	cat <<'EOF'
frames 3
event kit_tabs drag0
click Text "Health bar" 860 60
frames 2
mouse_down left
frames 2
mouse_pos 100 300
frames 2
mouse_pos 90 310
frames 2
mouse_up left
frames 5
event kit_tabs drag1
screenshot @T@/panel_drag.png
EOF
	# (the kill feed at the frame's top right)
	at 560 45
	cat <<'EOF'
frames 3
screenshot @T@/no_rules.png
click Button "Place kit/game_rules"
wait_log 10000 the HUD panel's parameters: feed_
frames 3
screenshot @T@/rules_placed.png
sync 3000
quit
EOF
} >> "$t/kitrest.cmds"
cat > "$t/kitmem.cmds" <<EOF
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
wait_log_any 10000 kit editor: edit mode on
frames 5
event kit_select $FLAG
frames 5
sync 3000
quit
EOF
start_server "$t/srv2.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
	--sim-rate "$CHECK_RATE" || fail "the server did not come back ($t/srv2.log)"
CHECK_PIDS+=($SERVER_PID)
BUILDAT_JOIN_NAME=kitboss client kitrest 1024x700 -u 1
# (the same user directory: the chip kept on this machine)
mv "$t/kitrest.log" "$t/kitrest1.log"
cp "$t/kitmem.cmds" "$t/kitrest.cmds"
BUILDAT_JOIN_NAME=kitboss client kitrest 1024x700 -u 1
mv "$t/kitrest.log" "$t/kitmem.log"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
grep -aq "parameters $FLAG/1 kit/flag: chips All Behaviour HUD Look Advanced, showing hud" "$t/kitmem.log" ||
	fail "the chip not remembered ($t/kitmem.log)"
python3 -I - "$t/kitrest1.log" <<'PY' || fail "the warning, the narrowing, the drag or the Place ($t/kitrest1.log)"
import re, sys
lines = open(sys.argv[1], errors="replace").read().split("\n")
def at(mark):
	return next(i for i, l in enumerate(lines) if "(" + mark + ")" in l)
# The warning grew it, and its height came back
tall = [(i, int(m[1])) for i, m in ((i, re.search(r"the inspector (\d+) of \d+ tall", l))
	for i, l in enumerate(lines)) if m]
grown = [h for i, h in tall if at("warn0") < i < at("warn1")]
back = [h for i, h in tall if at("warn1") < i < at("warn2")]
before = [h for i, h in tall if i < at("warn0")][-1]
assert grown and grown[-1] > before, (before, grown)
assert back and back[-1] == before, (before, grown, back)
print("the inspector", before, "with the warning", grown[-1], "after it", back[-1])
# Narrowed on each of Kit's own
# (not the item line: skipped while Kit draws its hotbar, as on Workbench)
for own in ("feed", "hint"):
	assert any("kit: ui: selected Kit's own " + own in l for l in lines), own
	m = [l for l in lines if "chips [" + own + "]" in l]
	assert m and "showing " + own + "_*" in m[0], (own, m)
# The drag on the panel: the element stays, the panel stays open, no click through
d = "\n".join(lines[at("drag0"):at("drag1")])
assert "dragged" not in d and "the HUD panel shows nothing" not in d and "selected" not in d, d
PY
echo "ok: a warning's height given back; the chip remembered and marked; narrowing on the feed and hint; a drag on the panel; its Place"
# [KIT_LAST_ROW_CLIP] Each body with no scroll bar shown to its foot
python3 -I - "$t"/kit*.log <<'PY' || fail "a body cut by its view"
import re, sys
n = 0
for f in sys.argv[1:]:
	for w, a, b in re.findall(r"the (inspector|HUD panel)'s body ends at (\d+), shown to (\d+)",
			open(f, errors="replace").read()):
		n += 1
		assert int(a) <= int(b), (f, w, a, b)
assert n >= 3, n
print("ok: %d bodies shown to their foot" % n)
PY
if grep -aE " W kit +: kit: ui|attempt to|stack traceback" "$b" "$t/kitwide.log" "$t/kittouch.log" | head -5 | grep -a .; then
	fail "a Lua error in the logs"
fi
echo "PASS: categories: chips filter and are kept, pending fields survive, Kit's own HUD narrows, the HUD view's panel, the flag's inspector fits; screenshots $t/flag.png $t/look.png $t/narrow.png $t/hud_panel.png $t/signals.png $t/wide_flag.png $t/touch_panel.png"
