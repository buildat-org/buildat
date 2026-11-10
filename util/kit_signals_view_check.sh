#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2.5 min (2026-11-06)
# covers: builtin/kit/client_lua/signals.lua builtin/kit/client_lua/editor.lua builtin/kit/client_lua/editor_input.lua builtin/kit/client_lua/ui.lua builtin/kit/client_lua/input.lua builtin/kit/types/*.lua builtin/kit/kit.cpp
# [KIT_SIGNALS_VIEW] The editor's Signals view on Workbench. kitboss (the
# admin, 1024x700), a kit/flag with links to three kit/ui_bars and from a
# kit/timer:
#   0. [KIT_NO_WORLD_TYPES] The ui_bars, the timer and the logic placed at a
#      position have none: in the list's Scene group, a kit/starting_kit under
#      the flag too, a Prefab's in the save with none;
#   1. F5 from 3D: the list and the links side by side under the bar, the
#      Inspector button the list and the inspector over its viewport, no
#      panel, no other window; the 3D camera where it was afterwards;
#   2. a link added from the table (output, target, input by its dropdowns),
#      unlinked by its menu, hidden and shown by its checkbox: the server's
#      edits; the toggle's in the save;
#   3. a target's name selects it, its Inputs there;
#   4. the filter narrows the list, by type and by name; a view key while
#      typing in it; the list's symbols marked for what has a link either way;
#   5. a rename: the server's edit, undone by Ctrl+Z, again; in the save, and
#      read in the table by another client after the server's restart;
#   6. the viewport's camera on the selected entity, the walk camera's on one
#      with no position (a ui_bar: the HUD laid out in its rectangle, that bar
#      marked; game_rules: no HUD);
#   7. Escape back to the view before; Walk has its panels and HUD back;
#   8. a 1800x1000 window: all three columns; a touch client at 600x400: one
#      column at a time;
#   9. a real window made small and large again: the UI's fit back at x1.
#  10. [KIT_PALETTE_MENU] Add from palette, from 3D: the popup in the window;
#      closed by Escape, a press outside and its button, the view kept; a type
#      with no position placed at once, none, and selected in the list; a
#      positioned one back in 3D, armed, placed by the click there; small windows:
#      600x400 (touch: selected scrolled into view) and 800x500 at UI scale 2;
#  11. [KIT_PALETTE_MENU] A type with no position in the palette: its menu, Cancel,
#      Escape, another's button, a press on the view place nothing; Favourite; Place
#      at once and selected; a drag still places, a positioned one still arms.
#  12. [KIT_SIGNALS_PARENT_BUTTONS] Switch parent and Un-parent in its inspector:
#      armed, a click in the list picks; a refusal (itself, none with a position)
#      stays armed with its status over the list; past an edit, the filter and
#      another view; the row indented under the new one; Escape and the button
#      cancel, the view kept; narrow touch: armed, the list's column is up.
#      [KIT_SIGNALS_PARENT_LEFTOVERS] A name in the links table picks while armed;
#      the status's cancel says Escape, on touch the Inspector's button.
#  13. [KIT_SIGNALS_VIEWPORT] Its inspector's position edits a positioned entity
#      (the viewport follows, undone by Ctrl+Z, the 3D view's knob with it); the
#      viewport's camera orbited by a right drag and a finger, zoomed by the wheel
#      and a pinch, none of them begun outside it, the pitch clamped, kept for
#      another entity; a HUD element's viewport as it was; the list and the links
#      scrolled by the wheel and a finger, the camera not moved.
#  14. [KIT_SIGNALS_UI_GROUP] The list's groups: UI elements in UI, a panel's
#      under it, the Scene tab of the Entities panel not split.
# Screenshots kept with KEEP_TMP=1: $t/parent_*.png, $t/popup.png, $t/palette_menu.png, $t/narrow_popup.png, $t/small_popup.png, $t/small_menu.png, $t/menu.png, $t/refit.png, $t/signals.png, $t/added.png, $t/hud.png,
# $t/game_wide.png, $t/wide.png, $t/narrow_*.png; look at them.
#   util/kit_signals_view_check.sh
#  15. [KIT_SIGNALS_DOCS] (the "docs" mode, run at the end too) Every stock type's
#      and signal's description; the signals not linked with their types, a link
#      taking one away and its removal bringing it back, an entity of two components;
#      the descriptions shown and hidden by the button, past a selection and into
#      the next session; the whole text on hover and a finger held; a row pressed
#      opening the Add link form either way; narrow touch inside the column's width.
#      [KIT_SIGNALS_LIVE] An output's row lit, with its value, by a real use and a Test;
#      a timer at most five packets a second, none before a watch or past its stop; Test
#      opening a gate, setting a counter, Running an Ended game; refused: an undeclared
#      input, a wrong type, too large a value, and no edit right by raw packets.
#   util/kit_signals_view_check.sh web    items 12, 13 (but the list's scrolling) and 15 in headless Chrome, mouse and finger
#   util/kit_signals_view_check.sh web docs   item 15 alone
#   util/kit_signals_view_check.sh docs   item 15 alone; screenshots $t/docs_*.png
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
# [KIT_SIGNALS_DOCS] Every stock type says what it is and what each signal does
python3 -I - "$here/builtin/kit/types" <<'PY' || fail "a stock type's about"
import glob, os, re, sys
def block(src, key):
    m = re.search(r"^\t%s = \{" % key, src, re.M)
    if not m:
        return None
    i, d = m.end(), 1
    while d:
        d += {"{": 1, "}": -1}.get(src[i], 0)
        i += 1
    return src[m.end():i - 1]
def pairs(text):
    return dict((a or b, c) for a, b, c in re.findall(
        r'(?:\["(\w+)"\]|(\w+))\s*=\s*"((?:[^"\\]|\\.)*)"', text or ""))
def sub(text, key):
    m = re.search(r"^\t\t%s = \{(.*?)^\t\t\}," % key, text or "", re.M | re.S)
    return pairs(m[1]) if m else {}
bad, n = [], 0
for f in sorted(glob.glob(sys.argv[1] + "/*.lua")):
    if f.endswith(".client.lua"):
        continue
    name = os.path.basename(f)[:-4]
    src = open(f).read()
    about = block(src, "about")
    if about is None or not re.search(r'^\t\twhat = "', about, re.M):
        bad.append(name + ": no about.what")
    for key in ("inputs", "outputs"):
        said = sub(about, key)
        decl = pairs(block(src, key))
        n += len(decl)
        for sig, ty in decl.items():
            t = said.get(sig)
            if not t:
                bad.append("%s: %s %s has no description" % (name, key, sig))
                continue
            first = re.match(r"(.*?[.!?])(\s|$)", t)
            if not first or len(first[1]) > 90 or len(t) > 110:
                bad.append("%s: %s %s: a short sentence, a line or two in all: %s" % (name, key, sig, t))
            if ty != "none" and "Value: " not in t:
                bad.append("%s: %s %s is %s: its text says its value: %s" % (name, key, sig, ty, t))
        for sig in said:
            if sig not in decl:
                bad.append("%s: %s %s described, not declared" % (name, key, sig))
assert n > 150, n
assert not bad, "\n".join(bad)
print("ok:", n, "stock signals described")
PY
if [ "${1:-}" = web ]; then
	# [KIT_SIGNALS_PARENT_BUTTONS] Item 12 in the web client, headless Chrome: by
	# the mouse at 1200x800, then by a finger at 1000x500
	export BUILDAT_WORKBENCH_STONE=1
	check_tmp kit_signals_web; t=$CHECK_TMP
	stub="(function(){ var held = null, refuse = false; Object.defineProperty(document, 'pointerLockElement', {configurable: true, get: function(){ return held; }}); function set(e){ held = e; document.dispatchEvent(new Event('pointerlockchange')); } document.addEventListener('keydown', function(e){ if(e.key === 'Escape') refuse = true; }, true); document.addEventListener('mousedown', function(){ refuse = false; }, true); HTMLCanvasElement.prototype.requestPointerLock = function(){ if(refuse || !window.lockOk){ document.dispatchEvent(new Event('pointerlockerror')); return Promise.reject(new Error('refused')); } if(held !== this) set(this); return Promise.resolve(); }; document.exitPointerLock = function(){ if(held) set(null); }; return 'stub'; })()"
	# [KIT_SIGNALS_VIEWPORT] The viewport's middle and a point over the inspector,
	# in CSS pixels; entity 3 selected, the Inspector column up. A touch client's
	# fingers, a mouse's right drag and wheel; its position by the mouse alone
	viewport_steps() # <click|tap> <cx> <cy> <outside y>
	{
		local p=$1 cx=$2 cy=$3 oy=$4
		cat <<J
	["$p", "Button", "Inspector"], ["frames", 5],
	["shot", "\${OUT}/orbit_0.png"],
J
		if [ "$p" = click ]; then
			cat <<J
	["rdrag", $cx, $oy, $((cx + 80)), $((oy + 20))], ["frames", 3],
	["mouse", $cx, $oy], ["frames", 3], ["wheel", $cx, $oy, -300], ["frames", 3],
	["rdrag", $cx, $cy, $((cx + 60)), $((cy + 30))],
	["waitlog", "the camera on 3 at .*: yaw (?!40.0)", 10], ["frames", 3],
	["shot", "\${OUT}/orbit_1.png"],
	["mouse", $cx, $cy], ["frames", 3], ["wheel", $cx, $cy, -100],
	["waitlog", "the camera on 3 at .*distance (?!6.00)", 10], ["frames", 3],
	["shot", "\${OUT}/orbit_2.png"],
	["click", "LineEdit", "position x"], ["frames", 2], ["key", "End"], ["frames", 2],
	["type", "5"], ["frames", 2], ["click", "Button", "Move"],
	["waitlog", "moved 1 by .* from the inspector", 10],
	["waitlog", "the camera on 3 at ", 10], ["frames", 3],
	["chord", "Ctrl+z"],
	["waitlog", "the camera on 3 at ", 10], ["wait", 1000],
J
		else
			cat <<J
	["drag", $cx, $oy, $((cx + 80)), $((oy + 20)), "touch"], ["frames", 3],
	["drag", $cx, $cy, $((cx + 60)), $((cy + 40)), "touch"],
	["waitlog", "the camera on 3 at .*: yaw (?!40.0)", 10], ["frames", 3],
	["shot", "\${OUT}/orbit_1.png"],
	["fingers", $((cx - 40)), $cy, $((cx + 40)), $cy, $((cx - 80)), $cy, $((cx + 80)), $cy],
	["waitlog", "the camera on 3 at .*distance (?!6.00)", 10], ["frames", 3],
	["shot", "\${OUT}/orbit_2.png"],
J
		fi
	}
	# What the viewport did in a run: none but a gesture begun in it, in the order
	# asked for
	viewport_log() # <page.log> <mouse|touch>
	{
		python3 -I - "$1" "$2" <<'PY'
import re, sys
kind = sys.argv[2]
cam = re.compile(r"the camera on 3 at (\S+) (\S+) (\S+): yaw ([\d.]+), pitch (-?[\d.]+), distance ([\d.]+)")
seq = [[float(x) for x in m.groups()] for m in map(cam.search, open(sys.argv[1], errors="replace")) if m]
assert seq, "no camera line"
start = seq[0]
assert start[3:] == [40, 32, 6], seq[:3]
# The first change is the drag's: what was outside moved nothing
drag = seq[1]
assert drag[3] > 40 and drag[4] > 32 and drag[5] == 6, seq[:3]
zoom = seq[2]
assert zoom[3:5] == drag[3:5] and zoom[5] < 6, seq[:4]
if kind == "mouse":
    # One notch, 100 CSS pixels (the web's wheel is in tenths)
    assert abs(zoom[5] - 4.8) < 0.01, zoom
    # The position, moved and undone: the viewport with it, the view kept
    rest = seq[3:]
    assert any(l[0] != zoom[0] for l in rest) and rest[-1][:3] == zoom[:3], seq
    assert all(l[3:] == zoom[3:] for l in rest), seq
print("the camera:", seq[1:])
PY
	}
	# [KIT_SIGNALS_DOCS] [KIT_SIGNALS_LIVE] The rows of a counter: its text under a
	# pointer or a finger held at <x> <y>, a row opening the Add link form each way, the
	# descriptions' button, a Test with a value lighting an output
	docs_steps() # <click|tap> <x> <y>
	{
		local p=$1
		cat <<J
	["$p", "Button", "select 3"], ["waitlog", "signals: 3 not linked", 10], ["frames", 3],
J
		[ "$p" = click ] || echo '	["tap", "Button", "Links"], ["frames", 5],'
		echo '	["shot", "${OUT}/docs_rows.png"],'
		if [ "$p" = click ]; then
			cat <<J
	["mouse", $2, $3], ["waitlog", "signals: the text of row in ", 5], ["frames", 3],
	["shot", "\${OUT}/docs_hover.png"], ["mouse", 5, 5], ["frames", 3],
J
		else
			echo "	[\"hold\", $2, $3, 800], [\"waitlog\", \"signals: the text of row in \", 5], [\"frames\", 3],"
		fi
		cat <<J
	["$p", "Button", "row in reset"], ["waitlog", "add link: into 3 by its reset", 5], ["frames", 3],
	["shot", "\${OUT}/docs_form_in.png"],
	["$p", "DropDownList", "signals From"], ["frames", 3],
	["$p", "Text", "◆ 5 counter"], ["waitlog", "add link: from 5", 5], ["frames", 3],
	["$p", "Button", "Link"], ["waitlog", "signals: linked 5.changed -> 3.reset", 5],
	["waitlog", "kit editor: state:", 10], ["frames", 3],
	["$p", "Button", "Done"], ["frames", 3],
J
		# (the form scrolled itself into view)
		[ "$p" = click ] || echo '	["drag", 800, 150, 800, 480], ["frames", 5],'
		cat <<J
	["$p", "Button", "Hide descriptions"], ["waitlog", "signals: descriptions hidden", 5], ["frames", 3],
	["shot", "\${OUT}/docs_hidden.png"],
J
		# A short window: a finger scrolls to what is off it
		[ "$p" = click ] || echo '	["drag", 800, 420, 800, 180], ["frames", 5],'
		cat <<J
	["$p", "Button", "row out 0 reached"], ["waitlog", "add link: out of 3 by its reached", 5], ["frames", 3],
	["shot", "\${OUT}/docs_form_out.png"],
	["$p", "DropDownList", "signals Target"], ["frames", 3],
	["$p", "Text", "◆ 4 counter"], ["waitlog", "add link: target 4", 5], ["frames", 3],
	["$p", "Button", "Link"], ["waitlog", "signals: linked 3.reached -> 4.add", 5],
	["waitlog", "kit editor: state:", 10], ["frames", 3],
	["$p", "Button", "Done"], ["frames", 3],
J
		[ "$p" = click ] || echo '	["drag", 800, 150, 800, 480], ["drag", 800, 150, 800, 480], ["frames", 5],'
		cat <<J
	["$p", "Button", "Show descriptions"], ["waitlog", "signals: descriptions shown", 5], ["frames", 5],
J
		[ "$p" = click ] || echo '	["drag", 800, 400, 800, 180], ["frames", 5],'
		cat <<J
	["$p", "LineEdit", "signals value add"], ["frames", 3], ["type", "5"], ["frames", 3],
	["shot", "\${OUT}/docs_field.png"],
	["$p", "Button", "test add"], ["waitlog", "signals: fired 3 0 changed: .5. x1", 20],
	["shot", "\${OUT}/docs_lit.png"], ["sync", 5000]
]
J
	}
	steps() # <click|tap> <x1> <y1> <x2> <y2>: the two flags' cells on the screen; [<x3> <y3> <row x> <row y>]: docs_steps, of three counters; else <cx> <cy> <outside y>: the viewport's point, a point over the inspector
	{
		local p=$1 ty=kit/flag
		[ -z "${9:-}" ] || ty=kit/counter
		cat <<J
[
	["nav", "\${URL}?pref=kit_editor_font=100"],
	["waitlog", "accounts: the login page shown", 120], ["wait", 1000],
J
		[ "$p" = tap ] || echo "	[\"eval\", \"$stub\"],"
		cat <<J
	["key", "Tab"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["key", "Tab"], ["frames", 2], ["key", "Enter"], ["wait", 1000],
	["selall"], ["frames", 2], ["type", "webboss"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["type", "checkpass12"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["type", "checkpass12"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["type", "\${SETUP_CODE}"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["key", "Enter"], ["waitlog", "Joined as webboss", 30],
	["waitlog_any", "server window: the page ntfy", 30], ["frames", 3],
	["$p", "Button", "Don't add"], ["frames", 3],
	["waitlog_any", "world_menu: the list shown, 0 worlds", 30], ["frames", 3],
	["$p", "Button", "New project..."],
	["waitlog", "world_menu: the name screen shown", 10], ["frames", 3],
	["$p", "Button", "Create"],
	["waitlog", "player physics enabled", 120],
J
		if [ "$p" = tap ]; then
			cat <<J
	["waitlog_any", "kit editor: edit rights: yes", 10], ["frames", 5],
	["key", "F6"], ["waitlog", "kit editor: state: 1 entities", 20],
J
		else
			cat <<J
	["waitlog_any", "pause: the menu shown", 10],
	["eval", "window.lockOk = true, 'lock given from here'"],
	["click", 100, 700], ["waitlog", "pause: the menu closed", 10], ["wait", 1000],
	["waitlog_any", "kit editor: edit rights: yes", 10],
	["key", "Escape"], ["waitlog", "pause: the menu shown", 10], ["frames", 3],
	["click", "Button", "Edit", 600, 339], ["waitlog", "kit editor: state: 1 entities", 20],
J
		fi
		cat <<J
	["key", "F1"], ["waitlog", "kit editor: the view is 2D", 10], ["frames", 3],
J
		# A short window: its panels by the bar's buttons, one column at a time
		[ "$p" = click ] || echo '	["tap", "Button", "Tools"], ["frames", 3],'
		cat <<J
	$(pal_find_web "$ty" "$p")
	["$p", "Button", "$ty"], ["waitlog", "kit editor: placing $ty", 10], ["frames", 3],
J
		[ "$p" = click ] || echo '	["tap", "Button", "Tools"], ["frames", 3],'
		cat <<J
	["$p", $2, $3], ["waitlog", "kit editor: state: 2 entities", 10], ["frames", 3],
	["$p", $4, $5], ["waitlog", "kit editor: state: 3 entities", 10], ["frames", 3],
J
		[ -z "${9:-}" ] || echo "	[\"$p\", $6, $7], [\"waitlog\", \"kit editor: state: 4 entities\", 10], [\"frames\", 3],"
		cat <<J
	["key", "Escape"], ["frames", 3],
J
		# None with a position, for its refusal; off the screen of a short window
		[ "$p" = tap ] || [ -n "${9:-}" ] || cat <<J
	$(pal_find_web kit/logic)
	["click", "Button", "kit/logic"], ["waitlog", "the palette's menu of kit/logic", 10], ["frames", 3],
	["click", "Button", "menu Place"], ["waitlog", "kit editor: state: 4 entities", 10], ["frames", 3],
J
		cat <<J
	["key", "F5"], ["waitlog", "kit editor: the view is Signals", 10], ["frames", 5],
J
		[ "$p" = click ] || echo '	["tap", "Button", "Entities"], ["frames", 5],'
		if [ -n "${9:-}" ]; then
			docs_steps "$p" "$8" "$9"
			return
		fi
		cat <<J
	["$p", "Button", "select 3"], ["waitlog", "kit editor: selected 3", 10], ["frames", 3],
	["$p", "Button", "Inspector"], ["frames", 5],
	["$p", "Button", "Switch parent"], ["waitlog", "kit editor: switch parent of 3: armed", 10], ["frames", 3],
	["shot", "\${OUT}/armed.png"],
J
		[ "$p" = tap ] || cat <<J
	["click", "Button", "select 5"], ["waitlog", "switch parent of 3: not 5", 10], ["frames", 3],
J
		cat <<J
	["$p", "Button", "select 3"], ["waitlog", "switch parent of 3: not 3", 10], ["frames", 3],
	["shot", "\${OUT}/refused.png"],
	["$p", "Button", "select 4"], ["waitlog", "signals: list \"\" .*, >3", 10], ["frames", 3],
	["shot", "\${OUT}/under.png"],
	["$p", "Button", "Inspector"], ["frames", 5],
J
		# A short window: the position's row has pushed it off the inspector
		[ "$p" = click ] || echo '	["drag", 500, 270, 500, 170, "touch"], ["frames", 3],'
		cat <<J
	["$p", "Button", "Un-parent"], ["waitlog", "signals: list \"\" [^>]*$", 10], ["frames", 3],
	["$p", "Button", "Inspector"], ["frames", 5],
	["$p", "Button", "Switch parent"], ["waitlog", "switch parent of 3: armed", 10], ["frames", 3],
	["key", "Escape"], ["waitlog", "switch parent cancelled", 10], ["frames", 3],
	["$p", "Button", "Inspector"], ["frames", 5],
	["$p", "Button", "Switch parent"], ["waitlog", "switch parent of 3: armed", 10], ["frames", 3],
	["$p", "Button", "Inspector"], ["frames", 5],
	["$p", "Button", "Switch parent: Cancel"], ["waitlog", "switch parent cancelled", 10], ["frames", 3],
	["shot", "\${OUT}/cancelled.png"],
J
		viewport_steps "$p" "$6" "$7" "$8"
		echo '	["sync", 5000]'
		echo ']'
	}
	web_docs()
	{
		steps click 900 550 650 700 800 650 "$WEB_ROW_X" "$WEB_ROW_Y" > "$t/docs_mouse.json"
		"$here/util/web_drive.sh" "${WEB_BROWSER:-chrome}" workbench "$t/docs_mouse.json" "$t/docs_mouse" ||
			fail "the web drive of the signals by the mouse ($t/docs_mouse)"
		grep -a "a sideways bar: true" "$t/docs_mouse/page.log" && fail "a sideways bar ($t/docs_mouse/page.log)"
		echo "ok: the signals by the mouse in the web client; screenshots $t/docs_mouse/docs_*.png"
		steps tap 500 300 250 250 120 150 "$WEB_FINGER_X" "$WEB_FINGER_Y" > "$t/docs_touch.json"
		TOUCH=1 WEB_DRIVE_VIEWPORT=1000x500@1 "$here/util/web_drive.sh" chrome workbench "$t/docs_touch.json" "$t/docs_touch" ||
			fail "the web drive of the signals by a finger ($t/docs_touch)"
		grep -a "a sideways bar: true" "$t/docs_touch/page.log" && fail "a sideways bar ($t/docs_touch/page.log)"
		echo "ok: the signals by a finger in the web client; screenshots $t/docs_touch/docs_*.png"
	}
	WEB_ROW_X=268 WEB_ROW_Y=347 WEB_FINGER_X=57 WEB_FINGER_Y=434
	if [ "${2:-}" = docs ]; then
		web_docs
		echo "PASS: the signals on the web"
		exit 0
	fi
	steps click 900 550 650 700 711 617 400 > "$t/mouse.json"
	"$here/util/web_drive.sh" "${WEB_BROWSER:-chrome}" workbench "$t/mouse.json" "$t/mouse" ||
		fail "the web drive by the mouse ($t/mouse)"
	viewport_log "$t/mouse/page.log" mouse || fail "the viewport by the mouse ($t/mouse/page.log)"
	# [KIT_SIGNALS_FONT_FIT] At the drive's text size (100 %, its nav's pref): each layout's
	# columns as the frame's text scaling leaves them, not 80 % of their room
	python3 -I - "$t/mouse/page.log" <<'PY' || fail "the columns scaled again ($t/mouse/page.log)"
import re, sys
def rects(s):
    return dict((m[1], m[2]) for m in re.finditer(r"(\w+) (\d+ \d+ \d+ \d+)", s))
laid, n = None, 0
for l in open(sys.argv[1], errors="replace"):
    m = re.search(r"signals: columns in \S+ under \d+: (.*)$", l)
    if m:
        laid = rects(m[1])
    m = re.search(r"signals: columns scaled: (.*)$", l)
    if m and laid:
        got = rects(m[1])
        for k, v in laid.items():
            assert got.get(k, v) == v, f"{k}: laid out {v}, shown {got[k]}"
        n += 1
assert n, "no columns scaled line"
PY
	echo "ok: by the mouse in the web client; screenshots $t/mouse/armed.png $t/mouse/refused.png $t/mouse/under.png $t/mouse/orbit_1.png $t/mouse/orbit_2.png"
	steps tap 500 300 250 250 500 400 240 > "$t/touch.json"
	TOUCH=1 WEB_DRIVE_VIEWPORT=1000x500@1 "$here/util/web_drive.sh" chrome workbench "$t/touch.json" "$t/touch" ||
		fail "the web drive by a finger ($t/touch)"
	viewport_log "$t/touch/page.log" touch || fail "the viewport by a finger ($t/touch/page.log)"
	echo "ok: by a finger in the web client; screenshots $t/touch/armed.png $t/touch/refused.png $t/touch/orbit_1.png $t/touch/orbit_2.png"
	web_docs
	echo "PASS: Switch parent and Un-parent, the position and the viewport's orbit and zoom, and the signals' rows, in the Signals view on the web"
	exit 0
fi
export BUILDAT_WORKBENCH_PROJECT=world
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_signals_view; t=$CHECK_TMP
DOCS=${1:-}
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
# 15. [KIT_SIGNALS_DOCS]
# (Asked for, not F6: the client remembers edit mode, and F6 after that answer turns it off)
join='wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
event kit_edit {"op": "mode", "on": true}
wait_log_any 10000 kit editor: edit mode on
frames 5'
if [ "$DOCS" = docs ]; then
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
		# (within a use's reach of the spawn)
		id=$((id + 1)); LEVER=$id
		edit '{"op": "place", "type": "kit/lever", "pos": [1, 1, 2]}'
		place kit/counter; COUNTER=$id
		place kit/gate; GATE=$id
		place kit/door; DOOR=$id
		place kit/timer; TIMER=$id
		place kit/part; NONE=$id
		link $LEVER on $COUNTER count
		printf 'sync 3000\nquit\n'
	} > "$t/kitboss.cmds"
	serve "$t/srv.log"
	wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
	code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
	[ -n "$code" ] || fail "no setup code ($t/srv.log)"
	BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_ADMIN="setting open_registration on" \
		client kitboss 1024x700 -u 1
	stop_server
	# Two components on one entity: no edit makes that, a save may hold it. A door
	# and a lever: "toggle" in both, "on" and "off" of the lever alone
	python3 -I - "$t/user/apps/workbench/saves/world/save.sqlite" "$DOOR" <<'PY' || fail "the save"
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
a = json.loads(db.execute("SELECT value FROM store WHERE store = 'kit' AND key = 'authored'").fetchone()[0])
e = next(e for e in a["entities"] if e["id"] == int(sys.argv[2]))
e["components"].append({"type": "kit/lever", "version": 2, "params": {}, "links": []})
db.execute("UPDATE store SET value = ? WHERE store = 'kit' AND key = 'authored'", (json.dumps(a),))
db.commit()
PY
	serve "$t/srv2.log"
	{
		echo "$join"
		cat <<EOF
event kit_select $LEVER
frames 3
keypress F5
wait_log 5000 kit editor: signals: $LEVER not linked:
frames 5
screenshot @T@/docs_wide.png
click Button "row out 0 off"
wait_log 5000 kit editor: signals: add link: out of $LEVER by its off
frames 3
screenshot @T@/docs_form_out.png
click DropDownList "signals Target"
frames 3
click Text "◆ $COUNTER counter"
wait_log 5000 kit editor: signals: add link: target $COUNTER
frames 3
click DropDownList "signals Input"
frames 3
click Text "count*"
frames 3
click Button "Link"
wait_log 10000 kit editor: signals: linked $LEVER.off -> $COUNTER.count
wait_log 10000 kit editor: state:
frames 3
click Button "Done"
frames 3
screenshot @T@/docs_linked.png
click Button "signal $LEVER.off $COUNTER.count"
wait_log 5000 kit editor: signals: the menu of $LEVER.off $COUNTER.count
frames 3
click Button "Delete"
wait_log 10000 kit editor: signals: unlinked $LEVER.off
wait_log 10000 kit editor: state:
frames 3
click Button "row in toggle"
wait_log 5000 kit editor: signals: add link: into $LEVER by its toggle
frames 3
screenshot @T@/docs_form_in.png
click DropDownList "signals From"
frames 3
click Text "◆ $TIMER timer"
wait_log 5000 kit editor: signals: add link: from $TIMER
frames 3
click Button "Link"
wait_log 10000 kit editor: signals: linked $TIMER.done -> $LEVER.toggle
EOF
	} > "$t/kitdocs.cmds"
	{
		cat <<EOF
wait_log 10000 kit editor: state:
frames 3
click Button "Done"
frames 3
EOF
		edit "{\"op\": \"unlink\", \"id\": $TIMER, \"comp\": 0, \"output\": \"done\", \"to\": $LEVER, \"input\": \"toggle\"}"
		cat <<EOF
frames 3
mouse_pos 225 279
wait_log 3000 kit editor: signals: the text of row in off
frames 2
screenshot @T@/docs_hover.png
mouse_pos 316 430
wait_log 3000 kit editor: signals: the text of signal $LEVER.on $COUNTER.count
frames 2
screenshot @T@/docs_hover_link.png
mouse_pos 5 5
frames 3
click Button "Hide descriptions"
wait_log 5000 kit editor: signals: descriptions hidden
frames 3
screenshot @T@/docs_hidden.png
event kit_select $COUNTER
wait_log_any 5000 kit editor: signals: rows of $COUNTER: 0 descriptions
frames 3
event kit_select $DOOR
wait_log_any 5000 kit editor: signals: rows of $DOOR: 0 descriptions
frames 3
screenshot @T@/docs_two_hidden.png
delay 1100
sync 3000
quit
EOF
	} >> "$t/kitdocs.cmds"
	BUILDAT_JOIN_NAME=kitboss client kitdocs 1024x700 -u 1
	l=$t/kitdocs.log
	python3 -I - "$l" "$LEVER" "$COUNTER" "$TIMER" "$DOOR" <<'PY' || fail "the signals not linked ($l)"
import re, sys
log = [x for x in open(sys.argv[1], errors="replace") if " I kit " in x]
lever, counter, timer, door = sys.argv[2:]
def at(w, frm=0):
    return next((i for i in range(frm, len(log)) if w in log[i]), None)
# Not linked with their types; a link takes one away, its removal brings it back
free = "signals: %s not linked: in off none, on none, toggle none; out off none" % lever
a = at(free)
assert a is not None, free
b = at("signals: %s not linked: in off none, on none, toggle none; out \n" % lever, a)
assert b is not None, "off linked"
c = at(free, b)
assert c is not None, "off unlinked"
d = at("signals: %s not linked: in off none, on none; out off none" % lever, c)
assert d is not None, "toggle linked into it"
e = at(free, d)
assert e is not None, "toggle unlinked"
# Its neighbour: what is linked left out, inputs by name
assert at("signals: %s not linked: in add number, reset none; out changed number, reached number" % counter) is not None, "the counter"
# Two components: the door's and the lever's outputs, an input they share once
m = [x for x in log if "signals: %s not linked: " % door in x][-1]
ins, outs = re.search(r"in (.*); out (.*)$", m).groups()
ins, outs = ins.split(", "), outs.split(", ")
assert ins.count("toggle none") == 1, m
assert "off none" in ins and "on none" in ins, m
assert "on none" in outs and "off none" in outs, m
# The toggle: on, off at the next selections, off in the view's own rebuild
hide = at("signals: descriptions hidden")
assert hide is not None and at("rows of %s: 0 descriptions" % lever, hide) is not None
assert at("rows of %s: 0 descriptions" % door, hide) is not None
assert at("rows of %s: 0 descriptions" % lever) == at("rows of %s: 0 descriptions" % lever, hide)
print("ok: signals not linked listed with their types, a link taking one away and its removal back, two components; descriptions hidden past selections")
PY
	want "$t/srv2.log" "linked $LEVER.off -> $COUNTER.count" "unlinked $LEVER.off -> $COUNTER.count" \
		"linked $TIMER.done -> $LEVER.toggle"
	want "$l" "add link: out of $LEVER by its off" "add link: into $LEVER by its toggle" \
		"signals: the text of row in off at " "signals: the text of signal $LEVER.on $COUNTER.count at "
	wantp "$l" "the text of row in off at .*: Sets it off"
	wantp "$l" "the text of signal $LEVER.on $COUNTER.count at .*: It flipped on"
	echo "ok: a row opens the Add link form either way; the whole text on hover, of a row and of a link's signal"
	grep -a "signals: a sideways bar: true" "$l" && fail "a sideways bar in 1024x700 ($l)"
	mv "$l" "$t/kitdocs1.log"
	# The next session, its button's choice remembered; a finger on a narrow window
	cat > "$t/kitdocs.cmds" <<EOF
$join
event kit_select $LEVER
frames 3
keypress F5
wait_log_any 5000 kit editor: signals: rows of $LEVER: 0 descriptions
frames 5
screenshot @T@/docs_narrow_hidden.png
click Button "Show descriptions"
wait_log 5000 kit editor: signals: descriptions shown
frames 5
screenshot @T@/docs_narrow.png
finger_down 1 Button "row in off"
wait_log 3000 kit editor: signals: the text of row in off
frames 3
screenshot @T@/docs_narrow_tip.png
finger_up 1
frames 5
event kit_select $DOOR
wait_log_any 5000 kit editor: signals: $DOOR not linked:
frames 5
screenshot @T@/docs_narrow_two.png
event kit_select $NONE
wait_log_any 5000 kit editor: signals: rows of $NONE:
frames 5
screenshot @T@/docs_narrow_none.png
sync 3000
quit
EOF
	BUILDAT_JOIN_NAME=kitboss BUILDAT_TOUCH=1 client kitdocs 600x400 -u 1
	want "$l" "signals: rows of $LEVER: 0 descriptions"
	grep -a "add link: into" "$l" && fail "a finger held to read pressed the row too ($l)"
	python3 -I - "$l" <<'PY' || fail "a row past the column's width ($l)"
import re, sys
n = 0
for x in open(sys.argv[1], errors="replace"):
    m = re.search(r"rows of \d+: \d+ descriptions, \d+ texts, to (\d+) of (\d+), body", x)
    if m:
        assert int(m[1]) <= int(m[2]), x
        n += 1
    m = re.search(r"the text of .* at (\d+) (\d+) (\d+) (\d+) in (\d+)x(\d+)", x)
    if m:
        a, b, w, h, rw, rh = map(int, m.groups())
        assert a >= 0 and b >= 0 and a + w <= rw and b + h <= rh, x
assert n >= 3, n
PY
	grep -a "signals: a sideways bar: true" "$l" && fail "a sideways bar in 600x400 ($l)"
	echo "ok: remembered in the next session; narrow touch: a finger held shows the text, not pressing the row; inside the column"
	# [KIT_SIGNALS_LIVE] Ended; Test Runs it; what fires lights its row with its value
	big=$(printf 'x%.0s' $(seq 1 600))
	{
		echo "$join"
		cat <<EOF
event kit_edit {"op": "set", "id": $TIMER, "comp": 0, "param": "interval", "value": 0.1}
event kit_edit {"op": "stop"}
wait_log_any 10000 kit editor: the server is Ended
event kit_select $LEVER
frames 3
keypress F5
wait_log_any 5000 kit editor: signals: $LEVER not linked:
frames 5
screenshot @T@/docs_live_ended.png
click Button "test on"
wait_log 10000 kit editor: signals: fired $LEVER 0 on: "" x1
screenshot @T@/docs_live_test.png
event kit_use $LEVER
wait_log 5000 kit editor: signals: fired $LEVER 0 off
screenshot @T@/docs_live_use.png
frames 3
event kit_select $COUNTER
frames 5
click LineEdit "signals value add"
frames 2
text 5
frames 2
screenshot @T@/docs_live_field.png
click Button "test add"
wait_log 5000 kit editor: signals: fired $COUNTER 0 changed: "6"
screenshot @T@/docs_live_value.png
frames 3
EOF
		cat <<EOF
event kit_select $GATE
frames 5
click Button "test open"
wait_log 5000 kit editor: signals: fired $GATE 0 opened
frames 2
event kit_edit {"op": "try", "id": $COUNTER, "input": "nosuch"}
wait_log 5000 kit editor: refused: try: input: entity $COUNTER has no input
event kit_edit {"op": "try", "id": $COUNTER, "input": "add", "value": "x"}
wait_log 5000 kit editor: refused: try: value: its input add takes a number
event kit_edit {"op": "try", "id": $COUNTER, "input": "add", "value": "$big"}
wait_log 5000 kit editor: refused: try: value: longer than
event kit_select $TIMER
frames 5
click Button "test start"
wait_log 5000 kit editor: signals: fired $TIMER 0 tick
delay 1000
keypress F2
wait_log 5000 kit editor: the view is 3D
sync 3000
delay 500
sync 3000
quit
EOF
	} > "$t/kitlive.cmds"
	BUILDAT_JOIN_NAME=kitboss client kitlive 1024x700 -u 1
	want "$t/srv2.log" "kitboss tries entity $LEVER's on" "kitboss tries entity $COUNTER's add 5" \
		"kit/gate $GATE: opened by kitboss" "by peer" "An edit (try) by peer" "value: longer than"
	python3 -I - "$t/srv2.log" "$TIMER" <<'PY' || fail "the rate or the watch ($t/srv2.log)"
import re, sys
log = open(sys.argv[1], errors="replace").read().split("\n")
def at(w, frm=0):
    return next((i for i in range(frm, len(log)) if w in log[i]), None)
# Nothing before anyone watched, nothing past the last stop
fired = [i for i, x in enumerate(log) if "Fired for " in x]
assert fired and at("watches entity") < fired[0], "fired before a watch"
stop = [i for i, x in enumerate(log) if "stops watching" in x][-1]
assert fired[-1] < stop, "fired past the stop"
# The timer every 0.1 s: at most one packet each 200 ms
tick = [x for x in log if "Fired for kitboss: entity %s:" % sys.argv[2] in x]
assert len(tick) >= 3, tick
def ms(x):
    h, m, s = re.search(r"(\d+):(\d+):([\d.]+) ", x).groups()
    return (int(h) * 3600 + int(m) * 60 + float(s)) * 1000
gaps = [b - a for a, b in zip(map(ms, tick), map(ms, tick[1:]))]
assert min(gaps) >= 150, gaps
assert any(re.search(r'"tick","[\d.]+",[2-9]', x) for x in tick) or len(tick) <= 12, tick
print("ok: at most a packet in", int(min(gaps)), "ms of a timer every 0.1 s, none before a watch or past its stop")
PY
	want "$t/kitlive.log" "kit editor: the server is Running"
	echo "ok: Test Runs an Ended game and lights the output; a use lights it; a counter set by value, a gate opened; refusals: undeclared, wrong type, too large"
	# A player with no edit right, by raw packets
	cat > "$t/kitbob.cmds" <<EOF
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
frames 5
event kit_edit {"op": "try", "id": $LEVER, "input": "on"}
wait_log 5000 kit editor: refused: try: no edit rights here
event kit_edit {"op": "watch", "id": $LEVER}
wait_log 5000 kit editor: refused: watch: no edit rights here
sync 3000
quit
EOF
	BUILDAT_JOIN_NAME=kitbob client kitbob 1024x700 -u 1
	grep -a "kitbob tries\|kitbob watches" "$t/srv2.log" && fail "kitbob's packet taken ($t/srv2.log)"
	echo "ok: no edit right: try and watch refused"
	# Narrow: the field, and a lit row's value scrolled to by a finger
	cat > "$t/kitlive2.cmds" <<EOF
$join
event kit_select $COUNTER
frames 3
keypress F5
wait_log_any 5000 kit editor: signals: $COUNTER not linked:
frames 5
screenshot @T@/docs_narrow_field.png
finger_down 1 300 340
frames 2
finger_move 1 300 110
frames 2
finger_up 1
frames 5
event kit_edit {"op": "try", "id": $COUNTER, "input": "add", "value": 5}
wait_log 5000 kit editor: signals: fired $COUNTER 0 changed
screenshot @T@/docs_narrow_lit.png
sync 3000
quit
EOF
	BUILDAT_JOIN_NAME=kitboss BUILDAT_TOUCH=1 client kitlive2 600x400 -u 1
	grep -a "signals: a sideways bar: true" "$t/kitlive.log" "$t/kitlive2.log" && fail "a sideways bar with the live columns"
	if grep -aE "attempt to|stack traceback" "$t/kitdocs1.log" "$l" "$t/kitlive.log" "$t/kitlive2.log" "$t/kitbob.log" | head -5 | grep -a .; then
		fail "a Lua error in the logs"
	fi
	stop_server
	echo "PASS: the Signals view's signals and their descriptions; screenshots $t/docs_*.png"
	exit 0
fi
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
event kit_edit {"op": "mode", "on": true}
wait_log_any 10000 kit editor: edit mode on
frames 5
EOF
	place kit/flag; FLAG=$id
	place kit/ui_bar; BAR1=$id
	place kit/ui_bar; BAR2=$id
	place kit/ui_bar; BAR3=$id
	place kit/timer; TIMER=$id
	place kit/game_rules; RULES=$id
	place kit/logic; LOGIC=$id
	id=$((id + 1)); KID=$id
	edit "{\"op\": \"place\", \"type\": \"kit/starting_kit\", \"pos\": [1, 1, 1], \"parent\": $FLAG}"
	id=$((id + 3)); PIE=$id
	edit "{\"op\": \"place\", \"prefab\": \"kit/timer_pie\", \"pos\": [1, 1, 1]}"
	link $FLAG left $BAR1 value
	link $FLAG taken $BAR1 show
	link $FLAG home $BAR1 hide
	link $FLAG taken $BAR2 hide
	link $FLAG home $BAR2 hide
	link $FLAG placed $BAR2 show
	link $TIMER done $FLAG home
	link $FLAG scored $LOGIC a
	cat <<EOF
click Button "Entities"
frames 3
click Button "Scene (*"
wait_log_any 5000 kit editor: list Scene
screenshot @T@/scene_list.png
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
click DropDownList "signals Output"
frames 3
click Text "progress*"
frames 3
click DropDownList "signals Target"
frames 3
screenshot @T@/form_target.png
click Text "◆ $BAR3 ui_bar"
frames 3
click DropDownList "signals Input"
frames 3
click Text "value (number)"
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
click Button "signal $FLAG.taken $BAR2.hide"
frames 3
screenshot @T@/menu.png
keypress Escape
frames 3
click Button "signal in $FLAG.taken $BAR2.hide"
frames 3
keypress Escape
frames 3
mouse_pos 310 613
frames 2
mouse_click right
frames 3
screenshot @T@/menu_right.png
click Button "Delete"
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
click Button "Inspector"
frames 5
screenshot @T@/inspector_tab.png
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
click Button "Links"
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
EOF
	# 10. [KIT_PALETTE_MENU] The list's button, from 3D: its popup, by Escape, a
	# press outside and the button closed
	cat <<EOF
keypress F2
frames 5
keypress F5
frames 5
click Button "Add from palette"
wait_log 5000 signals: the palette's popup
frames 3
screenshot @T@/popup.png
event kit_ui_where popup_up
keypress Escape
frames 3
event kit_ui_where popup_escaped
click Button "Add from palette"
wait_log 5000 signals: the palette's popup
frames 3
mouse_pos 800 600
mouse_click left
frames 3
event kit_ui_where popup_outside
click Button "Add from palette"
wait_log 5000 signals: the palette's popup
frames 3
click Button "Add from palette"
frames 3
event kit_ui_where popup_button
click Button "Add from palette"
wait_log 5000 signals: the palette's popup
frames 3
click Button "kit/timer"
wait_log 5000 signals: picked kit/timer
EOF
	state
	cat <<EOF
frames 5
screenshot @T@/popup_placed.png
EOF
	# A type with a position: armed, the view left, placed by a click there
	cat <<EOF
click Button "Add from palette"
wait_log 5000 signals: the palette's popup
frames 3
click Button "kit/flag"
wait_log 5000 kit editor: placing kit/flag
frames 5
screenshot @T@/popup_armed.png
mouse_pos 550 400
frames 3
mouse_click left
EOF
	state
	# (Escape: the placed one's inspector is up where the right click was)
	cat <<EOF
keypress Escape
wait_log 5000 kit editor: placing nothing
frames 3
EOF
	# 11. [KIT_PALETTE_MENU] The palette: a type with no position has its menu:
	# Cancel, Escape, a press on another's button, a press on the view; Favourite
	# keeps it up; Place is an edit with no click on the view. A drag still places
	# ("signals" finds kit/logic and kit/action both, kit/action under it: its
	# menu is the one a press on the other's button goes past). The view
	# pressed at 300,400: the placed flag's inspector is up over 550,400
	cat <<EOF
$(pal_find signals)
click Button "kit/logic"
wait_log 5000 the palette's menu of kit/logic
frames 3
screenshot @T@/palette_menu.png
event kit_ui_where menu_up
click Button "Cancel"
frames 3
event kit_ui_where menu_cancelled
screenshot @T@/palette_cancelled.png
click Button "kit/logic"
wait_log 5000 the palette's menu of kit/logic
frames 3
keypress Escape
frames 3
event kit_ui_where menu_escaped
click Button "kit/action"
wait_log 5000 the palette's menu of kit/action
frames 3
click Button "kit/logic"
wait_log 5000 the palette's menu of kit/logic
frames 3
screenshot @T@/palette_menu_other.png
mouse_pos 300 400
mouse_click left
frames 3
event kit_ui_where menu_outside
screenshot @T@/palette_outside.png
$(pal_find kit/flag)
click Button "kit/flag"
wait_log 5000 kit editor: placing kit/flag
frames 3
screenshot @T@/palette_positioned.png
click Button "kit/flag"
wait_log 5000 kit editor: placing nothing
$(pal_find kit/action)
mouse_pos 114 187
frames 3
mouse_down left
frames 3
mouse_pos 300 400
wait_log 5000 kit editor: dragging kit/action from the palette
frames 3
mouse_up left
EOF
	state
	cat <<EOF
frames 3
event kit_ui_where after_drag
$(pal_find kit/logic)
click Button "kit/logic"
wait_log 5000 the palette's menu of kit/logic
frames 3
click Button "Favourite kit/logic"
wait_log 5000 kit editor: kit/logic a favourite
frames 3
screenshot @T@/palette_favourite.png
click Button "Unfavourite kit/logic"
wait_log 5000 kit editor: kit/logic not a favourite
frames 3
click Button "menu Place"
EOF
	state
	cat <<EOF
frames 5
screenshot @T@/palette_placed.png
$(pal_find kit/environment)
click Button "kit/environment"
wait_log 5000 the palette's menu of kit/environment
frames 3
screenshot @T@/palette_menu_root.png
click Button "menu Place"
EOF
	state
	cat <<EOF
frames 3
keypress F5
frames 5
click Button "Add from palette"
wait_log 5000 signals: the palette's popup
frames 3
click Button "kit/game_rules"
wait_log 5000 signals: picked kit/game_rules
EOF
	state
	cat <<EOF
frames 3
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
# 0. No position, in the Scene group
# A bar going leaves the body at the left (the engine's ScrollView kept its view
# size smaller than the panel)
grep -a "signals: a body off by" "$b" && fail "the links body sideways ($b)"
want "$s" "placed kit/ui_bar $BAR1, no position" "placed kit/timer $TIMER, no position" \
	"placed kit/starting_kit $KID, no position under $FLAG"
# (as first listed: what the popup and the palette add comes later)
kit "$b" | sed '/the view is Signals/q' | grep -a "kit editor: list Scene (" | tail -1 | grep -aq " $BAR1, $BAR2, $BAR3, $TIMER, $LOGIC, $KID, $((PIE - 2)), $((PIE - 1)), $PIE\$" ||
	fail "the Scene list ($b)"
echo "ok: types with no position placed: none, in the Scene list"
# 1. Two columns side by side, the slot taken by turns, under the bar, inside
# the window
kit "$b" > "$t/kit.txt"
python3 -I - "$t/kit.txt" <<'PY' || fail "the columns ($t/kit.txt)"
import re, sys
lines = [l for l in open(sys.argv[1], errors="replace") if "signals: columns in 1024x700" in l]
assert lines, "no columns line"
def columns(line):
    m = re.search(r"under (\d+): (.*)$", line)
    cols = {}
    for c in m[2].split(", "):
        n, x, y, w, h = c.split()
        cols[n] = (int(x), int(y), int(w), int(h))
    return int(m[1]), cols
links = [columns(l) for l in lines if " sg_links " in l]
right = [columns(l) for l in lines if " inspector " in l]
assert links and right, lines
top, cols = links[-1]
assert set(cols) == {"sg_list", "sg_links"}, cols
l, c = cols["sg_list"], cols["sg_links"]
assert l[0] + l[2] <= c[0] and c[0] + c[2] <= 1024 and l[1] + l[3] <= 700, cols
assert min(l[1], c[1]) >= top > 10, (top, cols)
top, cols = right[-1]
assert set(cols) == {"sg_list", "inspector", "sg_view"}, cols
i, v = cols["inspector"], cols["sg_view"]
assert i[0] == c[0] and i[2] == c[2] and cols["sg_list"] == l, (cols, c, l)
assert i[1] + i[3] <= v[1] and i[0] == v[0], cols
assert v[0] + v[2] <= 1024 and v[1] + v[3] <= 700, cols
assert i[1] >= top > 10, (top, cols)
PY
wantp "$b" "the windows at bar \d+ \d+ \d+ \d+, sg_list \d+ \d+ \d+ \d+, sg_links \d+ \d+ \d+ \d+ \(signals\)"
wantp "$b" "the view Signals|the view signals, the tabs"
want "$b" "kit editor: the view is Signals"
before=$(grep -a "the 3D camera at .*(before)" "$b" | sed 's/.*camera at //; s/ (.*//')
after=$(grep -a "the 3D camera at .*(after)" "$b" | sed 's/.*camera at //; s/ (.*//')
[ -n "$before" ] && [ "$before" = "$after" ] || fail "the 3D camera moved: $before, $after"
echo "ok: F5: the list beside the links or the inspector under the bar in 1024x700, no other panel; the 3D camera kept"
# 2.
[ "$(grep -ac "signals: the menu of $FLAG.taken $BAR2.hide" "$b")" = 3 ] || fail "a signal's menu by either button"
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
wantp "$b" "signals: list \"ui_bar\" \(4\): .*$BAR1, .*$BAR2, .*$BAR3"
wantp "$b" "signals: list \"home F\" \(1\): .*$FLAG\$"
echo "ok: the filter, by type and by name"
# Marked: from a link and to a link; game_rules and the unlinked third bar not,
# the bar once its link is added
want "$b" "signals: linked marks: $FLAG, $BAR1, $BAR2, $TIMER, $LOGIC" \
	"signals: linked marks: $FLAG, $BAR1, $BAR2, $BAR3, $TIMER, $LOGIC"
kit "$b" | grep -a "signals: linked marks: " | sed "s/.*marks: //" | grep -aw "$RULES" && fail "game_rules marked ($b)"
echo "ok: a list's symbols marked by links, either way"
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
want "$b" "signals: the viewport shows entity $FLAG" \
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
# 10. The popup: up, closed each way with the view kept, inside the window; a
# type with no position placed with none and selected, a positioned one armed
# back in 3D and placed by the click there
wantp "$b" "the windows at .*ctx 12 \d+ \d+ \d+ \(popup_up\)"
for w in popup_escaped popup_outside popup_button menu_cancelled menu_escaped menu_outside after_drag; do
	kit "$b" | grep -a "the windows at .*($w)" | grep -aqv " ctx " || fail "a menu still up: $w ($b)"
done
kit "$b" > "$t/kit.txt"
python3 -I - "$t/kit.txt" 1024 700 <<'PY' || fail "the popup ($t/kit.txt)"
import re, sys
n = 0
for l in open(sys.argv[1], errors="replace"):
    m = re.search(r"the palette's popup, (\d+) items in (\d+) columns, (\d+) (\d+) (\d+) (\d+) in", l)
    if m:
        x, y, w, h = map(int, m.groups()[2:])
        assert x >= 0 and y >= 0 and x + w <= int(sys.argv[2]) and y + h <= int(sys.argv[3]), l
        n += 1
assert n >= 5, n
PY
seq=$(kit "$b" | grep -a "kit editor: the view is " | sed 's/.*view is //' | tr '\n' ' ')
case $seq in
*"Walk Signals 3D Signals 3D Signals ") ;;
*) fail "the views past the popup: $seq ($b)" ;;
esac
placed=$(grep -aoP "An edit by kitboss: placed kit/timer \K\d+(?=, no position)" "$s" | tail -1)
[ "$placed" != "$TIMER" ] || fail "the popup's timer not placed ($s)"
kit "$b" | sed -n '/signals: picked kit\/timer/,$p' | grep -aq "selected $placed " || fail "the popup's timer not selected ($b)"
wantp "$s" "An edit by kitboss: placed kit/flag \d+ at \[5,1,10\]"
echo "ok: Add from palette: closed by Escape, a press outside and its button; a type with no position placed and selected; a positioned one armed for the click in the view it came from"
# 11. The palette's menu: nothing placed until Place; a drag places
[ "$(grep -ac "An edit by kitboss: placed kit/logic" "$s")" = 2 ] || fail "kit/logic placed but for its Place ($s)"
[ "$(grep -ac "An edit by kitboss: placed kit/action" "$s")" = 1 ] || fail "kit/action placed but for its drag ($s)"
wantp "$s" "An edit by kitboss: placed kit/action \d+, no position"
placed=$(grep -aoP "An edit by kitboss: placed kit/logic \K\d+" "$s" | tail -1)
want "$b" "kit editor: selected $placed " "kit editor: kit/logic a favourite" "kit editor: kit/logic not a favourite" \
	"kit editor: placing kit/flag"
echo "ok: a type with no position has the palette's menu: Cancel, Escape, a press elsewhere place nothing, Place at once and selected, Favourite kept; a drag places, a positioned one arms"
# A type the root or the scene takes: the menu, not armed; a second kit/game_rules is not refused
wantp "$s" "An edit by kitboss: placed kit/environment \d+ (on the app root|on the scene)"
[ "$(grep -ac "An edit by kitboss: placed kit/game_rules [0-9]*  *on the app root" "$s")" = 2 ] || fail "the popup's kit/game_rules ($s)"
kit "$b" | grep -aE "placing kit/(environment|game_rules)" && fail "armed ($b)"
echo "ok: kit/environment and kit/game_rules have the palette's menu, placed on the root at once; the same from Add from palette"
# 5. The name after a restart; 8. A wide window, a narrow touch one
stop_server
python3 -I - "$t/user/apps/workbench/saves/world/save.sqlite" "$FLAG" "$BAR1" "$TIMER" "$LOGIC" "$KID" "$PIE" <<'PY' || fail "the save"
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
a = json.loads(db.execute("SELECT value FROM store WHERE store = 'kit' AND key = 'authored'").fetchone()[0])
e = next(e for e in a["entities"] if e["id"] == int(sys.argv[2]))
assert e["name"] == "Home flag", e["name"]
ls = {(l["output"], l["to"], l["input"]): l.get("visible") for l in e["components"][0]["links"]}
assert ls[("left", int(sys.argv[3]), "value")] is True, ls
assert not ls[("home", int(sys.argv[3]), "hide")], ls
for i in sys.argv[3:]:
    x = next(e for e in a["entities"] if e["id"] == int(i))
    assert "pos" not in x, x
assert next(e for e in a["entities"] if e["id"] == int(sys.argv[6]))["parent"] == int(sys.argv[2])
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
keypress F6
wait_log 10000 kit editor: edit mode off
frames 30
screenshot @T@/wide_play.png
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
click Button "Entities"
frames 5
click Button "Add from palette"
wait_log 5000 signals: the palette's popup
frames 3
screenshot @T@/narrow_popup.png
click Button "kit/action"
wait_log 5000 signals: picked kit/action
wait_log 10000 kit editor: state:
frames 5
screenshot @T@/narrow_placed.png
sync 3000
quit
EOF
# A small window at a UI scale of 2: 400x250 of UI
cat > "$t/kitsmall.cmds" <<EOF
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log_any 10000 kit editor: edit mode on
frames 5
screenshot @T@/small_walk.png
click Button "Tools"
frames 3
screenshot @T@/small_tools.png
$(pal_find kit/action)
click Button "kit/action"
wait_log 5000 the palette's menu of kit/action
frames 3
screenshot @T@/small_menu.png
keypress Escape
frames 3
keypress F5
frames 8
click Button "Entities"
frames 5
click Button "Add from palette"
wait_log 5000 signals: the palette's popup
frames 3
screenshot @T@/small_popup.png
sync 3000
quit
EOF
# [KIT_SIGNALS_HSCROLL] Long parameter lists at the editor's default text size
cat > "$t/kitwide80.cmds" <<EOF
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log_any 10000 kit editor: edit mode on
frames 5
event kit_select $RULES
frames 3
keypress F5
frames 10
screenshot @T@/wide80_rules.png
event kit_select $FLAG
frames 10
screenshot @T@/wide80_flag.png
sync 3000
quit
EOF
serve "$t/srv2.log"
BUILDAT_JOIN_NAME=kitboss client kitwide 1800x1000 -u 1
BUILDAT_JOIN_NAME=kitboss BUILDAT_TEST_EDITOR_FONT=80 client kitwide80 1600x1000 -u 1
BUILDAT_JOIN_NAME=kitboss BUILDAT_TOUCH=1 client kitnarrow 600x400 -u 1
BUILDAT_JOIN_NAME=kitboss client kitsmall 800x500 -u 2
for l in kitnarrow kitsmall; do
	kit "$t/$l.log" > "$t/kit.txt"
	python3 -I - "$t/kit.txt" <<'PY' || fail "the popup in $l ($t/kit.txt)"
import re, sys
m = re.findall(r"the palette's popup, \d+ items in \d+ columns, (\d+) (\d+) (\d+) (\d+) in (\d+)x(\d+)", open(sys.argv[1], errors="replace").read())
assert m
for x, y, w, h, rw, rh in m:
    x, y, w, h, rw, rh = map(int, (x, y, w, h, rw, rh))
    assert x >= 0 and y >= 0 and x + w <= rw and y + h <= rh, (x, y, w, h, rw, rh)
PY
done
# 12. [KIT_SIGNALS_PARENT_BUTTONS] Switch parent and Un-parent in this view: the
# parent picked in its list
p_join='wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
event kit_edit {"op": "mode", "on": true}
wait_log_any 10000 kit editor: edit mode on
frames 5'
last=$(grep -ahoP "An edit by kitboss: placed kit/\S+ \K\d+" "$t/srv2.log" "$s" | sort -n | tail -1)
PARENT=$((last + 1))
{
	echo "$p_join"
	edit '{"op": "place", "type": "kit/flag", "pos": [9, 1, 9]}'
	cat <<EOF
event kit_select $FLAG
frames 3
keypress F5
frames 8
click Button "Inspector"
frames 5
screenshot @T@/parent_buttons.png
click Button "Switch parent"
wait_log 5000 kit editor: switch parent of $FLAG: armed
frames 3
screenshot @T@/parent_armed.png
click Button "select $TIMER"
wait_log 5000 kit editor: switch parent of $FLAG: not $TIMER
frames 3
screenshot @T@/parent_refused.png
click LineEdit "signals filter"
frames 2
text flag
wait_log 5000 kit editor: signals: list "flag"
frames 3
click Button "select $FLAG"
wait_log 5000 kit editor: switch parent of $FLAG: not $FLAG
frames 3
EOF
	# Armed past the filter's rebuild above, an edit's and another view
	edit '{"op": "place", "type": "kit/timer", "pos": [1, 1, 1]}'
	cat <<EOF
frames 3
keypress F2
wait_log 5000 kit editor: the view is 3D
frames 3
screenshot @T@/parent_armed_3d.png
keypress F5
wait_log 5000 kit editor: the view is Signals
frames 5
click Button "select $PARENT"
wait_log 10000 kit editor: signals: list "flag"
frames 3
screenshot @T@/parent_under.png
click Button "Un-parent"
wait_log 10000 kit editor: signals: list "flag"
frames 3
click Button "Switch parent"
wait_log 5000 kit editor: switch parent of $FLAG: armed
frames 2
keypress Escape
wait_log 5000 kit editor: switch parent cancelled
frames 3
click Button "Switch parent"
wait_log 5000 kit editor: switch parent of $FLAG: armed
frames 2
click Button "Switch parent: Cancel"
wait_log 5000 kit editor: switch parent cancelled
frames 3
screenshot @T@/parent_cancelled.png
event kit_select $BAR1
frames 3
click Button "Switch parent"
wait_log 5000 kit editor: switch parent of $BAR1: armed
frames 2
click Button "select $PARENT"
wait_log 10000 kit editor: state:
frames 3
click Button "Un-parent"
wait_log 10000 kit editor: state:
frames 3
click Button "Switch parent"
wait_log 5000 kit editor: switch parent of $BAR1: armed
frames 2
click Button "Links"
frames 5
click Button "goto $FLAG"
wait_log 5000 kit editor: switch parent of $BAR1 to $FLAG
sync 3000
quit
EOF
} > "$t/kitparent.cmds"
{
	echo "$p_join"
	cat <<EOF
event kit_select $FLAG
frames 3
keypress F5
frames 8
click Button "Entities"
frames 5
click LineEdit "signals filter"
frames 2
text flag
wait_log 5000 kit editor: signals: list "flag"
frames 3
click Button "Inspector"
frames 5
screenshot @T@/parent_narrow_buttons.png
click Button "Switch parent"
wait_log 5000 kit editor: switch parent of $FLAG: armed
frames 5
screenshot @T@/parent_narrow_armed.png
click Button "select $FLAG"
wait_log 5000 kit editor: switch parent of $FLAG: not $FLAG
frames 3
screenshot @T@/parent_narrow_refused.png
click Button "select $PARENT"
wait_log 10000 kit editor: signals: list "flag"
frames 5
click Button "Inspector"
frames 5
click Button "Un-parent"
wait_log 10000 kit editor: signals: list "flag"
sync 3000
quit
EOF
} > "$t/kitparent2.cmds"
BUILDAT_JOIN_NAME=kitboss client kitparent 1024x700 -u 1
BUILDAT_JOIN_NAME=kitboss BUILDAT_TOUCH=1 client kitparent2 600x400 -u 1
kit "$t/kitparent.log" | grep -a "switch parent\|un-parent\|signals: list \"flag\"\|the view is" > "$t/parent_seq.txt"
python3 -I - "$t/parent_seq.txt" "$FLAG" "$PARENT" <<'PY' || fail "the Signals list's Switch parent ($t/parent_seq.txt)"
import sys
flag, parent = sys.argv[2:]
ls = open(sys.argv[1], errors="replace").read().split("\n")
def at(w, frm=0):
    return next(i for i in range(frm, len(ls)) if w in ls[i])
armed = at("switch parent of %s: armed" % flag)
picked = at("switch parent of %s to %s" % (flag, parent), armed)
assert not any("cancelled" in l for l in ls[armed:picked]), ls[armed:picked]
under = at('list "flag"', picked)
ids = ls[under].split("):")[1].split(", ")
assert ">" + flag in [i.strip() for i in ids], ls[under]
after = at('list "flag"', at("un-parent " + flag, under))
assert ">" + flag not in ls[after], ls[after]
PY
wantp "$t/kitparent2.log" "signals: list \"flag\".*>$FLAG\b"
want "$t/kitparent.log" "kit editor: switch parent of $BAR1 to $PARENT" "kit editor: un-parent $BAR1"
# [KIT_SIGNALS_PARENT_LEFTOVERS] A name in the links table picked, not selected;
# the cancel worded for the keyboard, and on touch for the Inspector's button
want "$t/kitparent.log" "switch parent of $FLAG: armed (Escape: cancel)"
want "$t/kitparent2.log" "switch parent of $FLAG: armed (Cancel: the Inspector's button)"
grep -aq "kit editor: selected $FLAG " <(sed -n "/switch parent of $BAR1 to $FLAG/,\$p" "$t/kitparent.log") &&
	fail "the links table's name selected while armed ($t/kitparent.log)"
# The view not left by the Escape that cancelled
seq=$(grep -a "the view is\|cancelled" "$t/parent_seq.txt" | sed 's/.*: //' | tr '\n' ',')
case $seq in
*"the view is Signals,switch parent cancelled,switch parent cancelled,") ;;
*) fail "the cancels or the view: $seq ($t/parent_seq.txt)" ;;
esac
if grep -aE "attempt to|stack traceback" "$t/kitparent.log" "$t/kitparent2.log" | head -5 | grep -a .; then
	fail "a Lua error in the logs"
fi
echo "ok: Switch parent and Un-parent in Signals: refusals stay armed, past a rebuild and another view, picked in the list, indented, Escape and the button cancel; narrow touch"
# 13, 14. [KIT_SIGNALS_VIEWPORT], [KIT_SIGNALS_UI_GROUP]
read -r vx vy vw vh < <(grep -a "signals: columns in 1024x700 .*sg_view" "$b" | tail -1 | sed 's/.*sg_view //')
cx=$((vx + vw / 2)) cy=$((vy + vh / 2)) oy=$((vy - 40))
last=$(grep -ahoP "An edit by kitboss: placed kit/\S+ \K\d+" "$t/srv2.log" "$s" | sort -n | tail -1)
PANEL=$((last + 1))
mark() { printf 'frames 3\nevent kit_sg_scroll %s\nframes 2\n' "$1"; }
{
	echo "$p_join"
	edit '{"op": "place", "type": "kit/ui_panel", "pos": [1, 1, 1]}'
	edit "{\"op\": \"parent\", \"id\": $BAR3, \"parent\": $PANEL}"
	cat <<EOF
event kit_select $FLAG
frames 3
keypress F5
wait_log 5000 kit editor: the view is Signals
frames 8
screenshot @T@/ui_group.png
click Button "Inspector"
frames 5
screenshot @T@/position_fields.png
EOF
	mark start
	cat <<EOF
click LineEdit "position x"
frames 2
keypress End
keypress Backspace
keypress Backspace
keypress Backspace
text 7
frames 2
click Button "Move"
wait_log 10000 kit editor: state:
wait_log 5000 signals: the camera on $FLAG at 7.00 1.00 6.00
EOF
	mark moved
	cat <<EOF
event kit_cam3d 7 6 16 7 1 6
frames 5
event kit_knob_where
frames 2
screenshot @T@/moved_3d.png
keypress F5
wait_log 5000 kit editor: the view is Signals
frames 5
keydown ctrl
keypress Z
keyup ctrl
wait_log 10000 kit editor: state:
wait_log 5000 signals: the camera on $FLAG at 3.00 1.00 6.00
EOF
	mark undone
	cat <<EOF
event kit_cam3d 7 6 16 7 1 6
frames 5
event kit_knob_where
frames 2
keypress F5
wait_log 5000 kit editor: the view is Signals
frames 5
mouse_pos $cx $cy
frames 2
mouse_down right
frames 2
mouse_pos $((cx + 60)) $((cy + 30))
frames 2
mouse_up right
EOF
	mark drag
	echo "screenshot @T@/orbit_drag.png"
	cat <<EOF
mouse_wheel 2
EOF
	mark wheel
	echo "screenshot @T@/orbit_wheel.png"
	cat <<EOF
mouse_pos $cx $oy
frames 2
mouse_down right
frames 2
mouse_pos $((cx + 80)) $((oy + 10))
frames 2
mouse_up right
frames 2
mouse_wheel 2
EOF
	mark outside
	cat <<EOF
mouse_pos $cx $cy
frames 2
mouse_down right
frames 2
mouse_pos $cx 0
frames 2
mouse_up right
EOF
	mark clamp
	cat <<EOF
mouse_pos $cx $cy
frames 2
mouse_down right
frames 2
mouse_pos $cx $((cy + 150))
frames 2
mouse_up right
EOF
	mark back
	cat <<EOF
event kit_select $PARENT
frames 3
EOF
	mark other
	cat <<EOF
event kit_select $BAR1
frames 5
mouse_pos $cx $cy
frames 2
mouse_down right
frames 2
mouse_pos $((cx + 60)) $((cy + 30))
frames 2
mouse_up right
frames 2
mouse_wheel 2
EOF
	mark hud
	cat <<EOF
screenshot @T@/orbit_hud.png
event kit_select $FLAG
EOF
	mark hud_after
	echo "sync 3000"
	echo "quit"
} > "$t/kitorbit.cmds"
cat > "$t/kitfinger.cmds" <<EOF
$p_join
event kit_select $FLAG
frames 3
keypress F5
wait_log 5000 kit editor: the view is Signals
frames 8
click Button "Inspector"
frames 5
event kit_ui_where where
frames 3
EOF
{
	mark start
	cat <<EOF
finger_down 1 $cx $oy
frames 2
finger_move 1 $((cx + 80)) $oy
frames 2
finger_up 1
EOF
	mark outside
	cat <<EOF
finger_down 1 $cx $cy
frames 2
finger_move 1 $((cx + 60)) $((cy + 40))
frames 2
finger_up 1
EOF
	mark drag
	echo "screenshot @T@/finger_drag.png"
	cat <<EOF
finger_down 1 $((cx - 40)) $cy
finger_down 2 $((cx + 40)) $cy
frames 2
finger_move 1 $((cx - 80)) $cy
frames 2
finger_move 2 $((cx + 80)) $cy
frames 2
finger_up 1
frames 2
finger_up 2
EOF
	mark pinch
	echo "screenshot @T@/finger_pinch.png"
	echo "sync 3000"
	echo "quit"
} >> "$t/kitfinger.cmds"
# A short window, where the list and the links overflow
{
	echo "$p_join"
	cat <<EOF
event kit_select $FLAG
frames 3
keypress F5
wait_log 5000 kit editor: the view is Signals
frames 8
EOF
	mark s0
	cat <<EOF
mouse_pos 60 250
frames 2
mouse_wheel -3
EOF
	mark s_list
	cat <<EOF
mouse_pos 600 250
frames 2
mouse_wheel -3
EOF
	mark s_links
	echo "screenshot @T@/scrolled.png"
	echo "sync 3000"
	echo "quit"
} > "$t/kitscroll.cmds"
{
	echo "$p_join"
	cat <<EOF
event kit_select $FLAG
frames 3
keypress F5
wait_log 5000 kit editor: the view is Signals
frames 8
EOF
	mark s0
	cat <<EOF
finger_down 1 60 340
frames 2
finger_move 1 60 240
frames 2
finger_move 1 60 140
frames 2
finger_up 1
EOF
	mark s_list
	cat <<EOF
finger_down 1 600 340
frames 2
finger_move 1 600 240
frames 2
finger_move 1 600 140
frames 2
finger_up 1
EOF
	mark s_links
	echo "sync 3000"
	echo "quit"
} > "$t/kitscrollf.cmds"
BUILDAT_JOIN_NAME=kitboss client kitorbit 1024x700 -u 1
BUILDAT_JOIN_NAME=kitboss BUILDAT_TOUCH=1 client kitfinger 1024x700 -u 1
BUILDAT_JOIN_NAME=kitboss client kitscroll 1024x560 -u 1
BUILDAT_JOIN_NAME=kitboss BUILDAT_TOUCH=1 client kitscrollf 1024x560 -u 1
python3 -I - "$t" "$FLAG" "$PARENT" "$BAR1" "$BAR2" "$BAR3" "$PANEL" "$TIMER" "$LOGIC" "$KID" "$RULES" "$cx" "$cy" <<'PY' || fail "the viewport or the groups ($t/kitorbit.log, $t/kitfinger.log, $t/kitscroll.log, $t/kitscrollf.log)"
import re, sys
t, FLAG, PARENT, BAR1, BAR2, BAR3, PANEL, TIMER, LOGIC, KID, RULES, cx, cy = sys.argv[1:]
cam_re = re.compile(r"signals: the camera on (\d+) at (\S+) (\S+) (\S+): yaw ([\d.]+), pitch (-?[\d.]+), distance ([\d.]+)")
mark_re = re.compile(r"signals: scrolled: list (-?\d+), links (-?\d+) \((\w+)\)")
def read(name):
    # At each mark: the last camera line before it, and the scroll
    cam, r, scroll, lines = None, {}, {}, open("%s/%s.log" % (t, name), errors="replace").read().split("\n")
    for l in lines:
        m = cam_re.search(l)
        if m:
            cam = (m[1],) + tuple(float(x) for x in m.groups()[1:])
        m = mark_re.search(l)
        if m:
            r[m[3]], scroll[m[3]] = cam, (int(m[1]), int(m[2]))
    return r, scroll, lines
o, _, lines = read("kitorbit")
print("orbit:", o)
assert o["start"][0] == FLAG and o["start"][4:] == (40, 32, 6), o["start"]
# The position: the viewport on it, x by what was typed; back by the undo
assert o["moved"][1] == 7 and o["moved"][2:] == o["start"][2:], (o["start"], o["moved"])
assert o["undone"] == o["start"], o["undone"]
knobs = [l for l in lines if "the knob on the screen at" in l or "no knob on the screen" in l]
assert len(knobs) == 2 and "no knob" not in knobs[0], knobs
assert knobs[0].split("at ")[-1] != knobs[1].split("at ")[-1], knobs
# Orbit and zoom
assert abs(o["drag"][4] - 58) < 0.01 and abs(o["drag"][5] - 41) < 0.01 and o["drag"][6] == 6, o["drag"]
assert o["wheel"][4:6] == o["drag"][4:6] and abs(o["wheel"][6] - 6 * 0.64) < 0.01, o["wheel"]
assert o["outside"] == o["wheel"], o["outside"]
assert o["clamp"][5] == -89, o["clamp"]
assert abs(o["back"][5] - (-89 + 45)) < 0.01 and o["back"][4] == o["clamp"][4], o["back"]
# Kept for another, centred on it
assert o["other"][0] == PARENT and o["other"][4:] == o["back"][4:] and o["other"][1:4] != o["back"][1:4], o["other"]
# One with no position: none of it, and the walk camera shown
assert o["hud_after"][0] == FLAG and o["hud_after"][4:] == o["back"][4:], o["hud_after"]
text = "\n".join(lines)
assert re.search(r"the viewport shows what the walk camera shows", text), "walk"
assert "signals: the HUD in the viewport on" in text
# Fingers
f, _, flines = read("kitfinger")
print("fingers:", f)
assert f["outside"] == f["start"], f["outside"]
assert abs(f["drag"][4] - 49) < 0.01 and abs(f["drag"][5] - 38) < 0.01 and f["drag"][6] == 6, f["drag"]
assert f["pinch"][4:6] == f["drag"][4:6] and abs(f["pinch"][6] - 3) < 0.05, f["pinch"]
m = [re.search(r"sg_view (\d+) (\d+) (\d+) (\d+)", l) for l in flines if "(where)" in l]
assert m and m[0], "the touch client's viewport"
vx, vy, vw, vh = map(int, m[0].groups())
assert vx <= int(cx) < vx + vw and vy <= int(cy) < vy + vh, (m[0][0], cx, cy)
# The list and the links scroll, by wheel and finger; the camera stays
for n in ("kitscroll", "kitscrollf"):
    c, s, _ = read(n)
    print(n, s, c)
    assert s["s0"] == (0, 0), s
    assert s["s_list"][0] > 0 and s["s_list"][1] == 0, s
    assert s["s_links"][0] == s["s_list"][0] and s["s_links"][1] > 0, s
    assert c["s_links"] == c["s0"], c
# 14. The groups, the last as listed
def group(name):
    g = [re.search(r"signals: group %s: (.*)" % re.escape(name), l) for l in lines]
    g = [x[1] for x in g if x]
    assert g, name
    return [x.split()[0] for x in g[-1].split(", ")]
gw, sc, ui, po = group("Game-wide"), group("Scene"), group("UI"), group("Positioned")
print("groups:", gw, sc, ui, po)
for x in (BAR1, BAR2, BAR3, PANEL):
    assert x in ui, x
for x in (TIMER, LOGIC, KID):
    assert x in sc and x not in ui, x
assert RULES in gw
assert FLAG in po and FLAG not in ui
assert not set(ui) & set(sc), (ui, sc)
ids = [re.search(r'signals: list "" \(\d+\): (.*)', l) for l in lines]
ids = [x[1] for x in ids if x][-1]
assert re.search(r"\b%s, >%s\b" % (PANEL, BAR3), ids), ids
# In the order they are shown
order = [x.lstrip(">") for x in ids.split(", ")]
assert order == gw + sc + ui + po, (order, gw, sc, ui, po)
PY
if grep -aE "attempt to|stack traceback" "$t/kitorbit.log" "$t/kitfinger.log" "$t/kitscroll.log" "$t/kitscrollf.log" | head -5 | grep -a .; then
	fail "a Lua error in the logs"
fi
echo "ok: the position in Signals' inspector, undone, in 3D; orbit and zoom by mouse and fingers begun on the viewport; the list and the links scroll; the UI group. Screenshots $t/position_fields.png $t/moved_3d.png $t/orbit_drag.png $t/orbit_wheel.png $t/orbit_hud.png $t/finger_pinch.png $t/ui_group.png $t/scrolled.png"
# 9. A real window (no -w: the fit is on) made small and large again: the UI
# back at its full scale, the Signals view's panels not holding the fit down
cat > "$t/kitfit.cmds" <<EOF
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log_any 10000 kit editor: edit mode on
frames 5
event kit_select $FLAG
frames 3
keypress F5
wait_log_any 10000 signals: columns in
wait_log_any 20000 screen mode: 500x400
wait_log_any 20000 UI scale fitted to the screen: x0
wait_log_any 20000 screen mode: 1400x900
wait_log_any 20000 UI scale fitted to the screen: x1
frames 5
screenshot @T@/refit.png
quit
EOF
sed -i "s|@T@|$t|g" "$t/kitfit.cmds"
BUILDAT_TEST_REAL_WINDOW=1 BUILDAT_JOIN_NAME=kitboss timeout 120 bin/buildat -C "$t/client_cache" -D "$t/cu_kitfit" \
	-s localhost:$SERVER_PORT -l 3 -c @"$t/kitfit.cmds" > "$t/kitfit.log" 2>&1 &
fit_pid=$!
CHECK_PIDS+=($fit_pid)
wait_for_log "$t/kitfit.log" "signals: columns in" 60
win=$(xdotool search --pid "$(pgrep -P "$fit_pid")" 2>/dev/null | tail -1)
[ -n "$win" ] || fail "no window of the client to resize"
xdotool windowsize "$win" 500 400
wait_for_log "$t/kitfit.log" "I __app   : UI scale fitted to the screen: x0" 20
xdotool windowsize "$win" 1400 900
wait "$fit_pid" || fail "the UI's scale did not come back in a larger window ($t/kitfit.log)"
grep -a "I __app   : UI scale [0-9]" "$t/kitfit.log" | tail -1 | grep -q "UI scale 0.833333 (1400x900)" || fail "the last scale ($t/kitfit.log)"
echo "ok: a window made small and large again has the UI at its full scale"
# [KIT_SIGNALS_HSCROLL] [KIT_SIGNALS_INSPECTOR_HBAR] No sideways bar in the
# inspector: long lists at 100 and 80 %, and after the refit
want "$t/kitwide80.log" "the inspector's sideways bar: false of $RULES" \
	"the inspector's sideways bar: false of $FLAG"
grep -a "the inspector's sideways bar: true" "$t/kitwide.log" "$t/kitwide80.log" &&
	fail "a sideways bar in the inspector ($t/wide80_*.png)"
grep -a "the inspector's sideways bar: " "$t/kitfit.log" | tail -1 | grep -q "bar: false" ||
	fail "a sideways bar in the inspector after the refit ($t/kitfit.log, $t/refit.png)"
echo "ok: no sideways bar in the inspector at 100 and 80 %, nor after a refit"
stop_server
want "$t/kitwide.log" "signals: $FLAG $FLAG Home flag: " "signals: columns in 1800x1000 "
wantp "$t/kitwide.log" "signals: columns in 1800x1000 under \d+: sg_list \d+ \d+ \d+ \d+, sg_links \d+ \d+ \d+ \d+, inspector \d+ \d+ \d+ \d+, sg_view "
# What the arrow says: a value's type, nothing for a trigger
wantp "$t/kitwide.log" "signals: $FLAG $FLAG Home flag: .*left>value number"
# A string's label
wantp "$t/kitwide.log" "signals: $FLAG $FLAG Home flag: .*scored>a team"
if grep -a "signals: $FLAG $FLAG Home flag: " "$t/kitwide.log" | grep -aq "home>hide"; then
	fail "a trigger shown as carrying a value ($t/kitwide.log)"
fi
wantp "$t/kitwide.log" "signals: the HUD in the viewport on"
# [KIT_WATCH_REFUSED_PLAY] Play mode from the view, an entity selected: no
# watch asked out of edit mode, so none refused over the guide
want "$t/kitwide.log" "kit editor: edit mode off"
grep -aq "refused: watch" "$t/kitwide.log" && fail "a watch refused in play ($t/kitwide.log, $t/wide_play.png)"
wantp "$t/kitnarrow.log" "signals: columns in 600x400 under \d+: sg_links \d+ \d+ 588 \d+"
wantp "$t/kitnarrow.log" "signals: columns in 600x400 under \d+: sg_list \d+ \d+ 588 \d+"
wantp "$t/kitnarrow.log" "signals: columns in 600x400 under \d+: inspector \d+ \d+ 588 \d+$"
echo "ok: the name after a restart, read by another client; a wide window; one column at a time on a narrow touch one"
if grep -aE "kit: ui: |kit: ui handles: |attempt to|stack traceback" "$b" "$t/kitwide.log" "$t/kitnarrow.log" | grep -av " I kit editor" | head -5 | grep -a .; then
	fail "a Lua error in the logs"
fi
"$here/util/kit_signals_view_check.sh" docs || fail "item 13"
echo "PASS: the Signals view: its columns by width, links added, unlinked and hidden, names followed, a rename kept, the filter, the viewport and its HUD; screenshots $t/signals.png $t/added.png $t/hud.png $t/wide.png $t/narrow_links.png"
