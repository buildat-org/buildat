#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min (2026-11-21)
# covers: builtin/kit/kit.cpp builtin/kit/client_lua/editor_input.lua builtin/kit/types/environment.lua builtin/kit/types/controls.lua builtin/kit/types/game_rules.lua 3rdparty/Urho3D/Source/Urho3D/UI/Window.cpp extensions/pause_menu/init.lua builtin/world_menu/client_lua/module.lua extensions/launch_menu/screens.lua client/core/uistack/init.lua
# [KIT_SINGLE] (kit_plan 4z37z) A type with single = true, one a holder
# (the app root, a scene), on Workbench's server of Brimstone Speedway
# (scenes world and trial; kit/game_rules 3 and kit/controls 4 on the
# root), a second kit/game_rules (1331) put on the root in its file;
# kitboss (the admin) on a headless weston's Xwayland of the check's own
# (its clipboard carries the agent token):
#   1. The load warns of the saved duplicate, 1331 named ignored.
#   2. By MCP: kit/controls on the root refused naming 4; on world's own
#      (on "scene") placed, the root's and the scene's both; a second
#      there refused naming it. kit/environment on world (a game of two
#      scenes), on the root, in trial: each placed; a second on world
#      refused; set_parent of the root's into world, world's onto the
#      root and duplicate of world's refused, each naming the one there;
#      a kit/game_rules refused naming 3 (the first of the two).
#      duplicate_scene world: world_2 has its own environment and
#      controls.
#   3. The editor's Place of kit/environment in world (the palette's
#      menu): nothing placed, world's selected in the inspector, the hint
#      in the status.
#   4. [UI_MODAL_DIM] The palette's menu, the pause menu, the Server window
#      over it and Kit's credits each shade the rest of the screen while up
#      and not once a click off it has closed it (the credits' click off
#      was eaten before). (0a84) The click that closes the pause menu is
#      not the view's too; a plain ui_utils dialog over the editor (event
#      message_dialog) has a click beside it and its own Escape (the pause
#      menu opened over it).
#   5. (0a84) The launcher (-a app/workbench/play, a local server): a tap
#      on the start's stripes does not cancel it, one beside the boot list
#      does not leave the server, one off the pause menu leaves it closed
#      (TAP_BACK's Escape opened it again), one beside a dialog over the
#      editor closes it and is not the view's.
# Screenshots, kept with KEEP_TMP=1: $t/selected.png (the inspector on it),
# $t/dim_*.png
#   util/kit_single_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
for c in weston xclip zip; do
	command -v $c > /dev/null || skip "no $c"
done
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_single; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1
check_build
sock=buildat-single-$$
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
	fail "no \"$4\" in $1 in $3 s (${SL:-}, ${CL:-})"
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
menu() # Escape until the pause menu is up (the editor's own Escapes first)
{
	local i k m
	for i in 1 2 3; do
		m=$(mark "$CL")
		cmd "frames 3" "keypress Escape"
		for k in $(seq 15); do
			tail -c +$((m + 1)) "$CL" | grep -qa "pause: the menu shown" && return 0
			sleep 0.2
		done
	done
	fail "no pause menu ($CL)"
}
clip() # the clipboard once it holds a token
{
	local i got
	for i in $(seq 50); do
		got=$(DISPLAY=$d xclip -selection clipboard -o 2>/dev/null)
		[[ $got =~ ^bat_[0-9a-f]{64}$ ]] && break
		sleep 0.2
	done
	printf '%s' "$got"
}

# The template with a second kit/game_rules on the root (a save of a Buildat
# before single = true)
mkdir -p "$t/tpl" "$t/user/shared"
cp -r "$here/apps/workbench/templates/brimstone_speedway/." "$t/tpl/"
python3 -I - "$t/tpl/composition.json" <<'PY' || fail "the template's duplicate"
import json, sys
p = sys.argv[1]
c = json.load(open(p))
gr = next(e for e in c["entities"] if e["id"] == 3)
assert any(x["type"] == "kit/game_rules" for x in gr["components"]), gr
dup = json.loads(json.dumps(gr))
dup["id"], dup["name"] = c["next_id"], "game rules again"
c["entities"].append(dup)
c["next_id"] += 1
json.dump(c, open(p, "w"), indent=1)
print(dup["id"])
PY
(cd "$t/tpl" && zip -qrX "$t/user/shared/brim.zip" .) || fail "the template not zipped"
SL=$t/server.log
BUILDAT_WORKBENCH_PROJECT=brim BUILDAT_WORKBENCH_FROM=$t/user/shared/brim.zip \
	start_server "$SL" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
	--sim-rate "$CHECK_RATE" || fail "the server did not come up ($SL)"
SRV=$SERVER_PID
CHECK_PIDS+=($SRV)
wait_for_log "$SL" "workbench: .*brim" 120 || true
# 1. The saved duplicate warned
wait_for_log "$SL" "the app root has kit/game_rules 3 and 1331: one on the app root, that ignored" 30 ||
	fail "no warning of the second kit/game_rules ($SL)"

url() { echo "http://localhost:$SERVER_PORT/api/v1/mcp"; }
cat > "$t/mcp.py" <<'PY'
import json, re, sys, urllib.error, urllib.request
url, tok, out = sys.argv[1:4]
def post(msg):
    h = {"Content-Type": "application/json",
         "Accept": "application/json, text/event-stream",
         "Authorization": "Bearer " + tok}
    req = urllib.request.Request(url, data=json.dumps(msg).encode(), headers=h)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
n = 0
def rpc(method, params=None):
    global n
    n += 1
    m = {"jsonrpc": "2.0", "id": n, "method": method}
    if params is not None:
        m["params"] = params
    s, b = post(m)
    assert s == 200, (method, s, b)
    return json.loads(b)
def call(name, a={}, error=False):
    r = rpc("tools/call", {"name": name, "arguments": a})["result"]
    text = r["content"][0]["text"]
    assert r["isError"] == error, (name, a, text[:2000])
    print(" ", name, json.dumps(a)[:150], "->", text[:200].replace("\n", " "))
    return text
def refused(name, a, says):
    text = call(name, a, error=True)
    assert says in text, (name, a, says, text)
def placed(text):
    return int(re.search(r"placed \S+ (\d+)", text)[1])
def state(**kw):
    return json.loads(call("get_state", kw))
def of(scene, t):
    return [e["id"] for e in state(scene=scene, state=False)["entities"]
        if e.get("kind") != "scene" and any(c["type"] == t for c in e["components"])]
rpc("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
    "clientInfo": {"name": "kit_single_check", "version": "1"}})
if state(ids=[])["running"]:
    assert call("stop").startswith("Ended")
assert state(ids=[])["scene"] == "world"
assert json.loads(call("list_types", {"type": "kit/environment"})).get("single") is True
P = [0, 0, 0]
# kit/controls: the root's 4, world's own beside it, no second
refused("place", {"type": "kit/controls", "pos": P},
    "the app root has kit/controls 4 already: one on the app root")
c2 = placed(call("place", {"type": "kit/controls", "pos": P, "on": "scene"}))
refused("place", {"type": "kit/controls", "pos": P, "on": "scene"},
    "scene world has kit/controls %d already: one per scene" % c2)
refused("set_parent", {"id": c2, "parent": "root"},
    "the app root has kit/controls 4 already")
# kit/environment: world's, the root's, trial's; no second
ew = placed(call("place", {"type": "kit/environment", "pos": P}))
er = placed(call("place", {"type": "kit/environment", "pos": P, "on": "root"}))
refused("place", {"type": "kit/environment", "pos": P},
    "scene world has kit/environment %d already: one per scene" % ew)
refused("place", {"type": "kit/environment", "pos": P, "on": "root"},
    "the app root has kit/environment %d already: one on the app root" % er)
refused("set_parent", {"id": er, "parent": 0},
    "scene world has kit/environment %d already" % ew)
refused("set_parent", {"id": ew, "parent": "root"},
    "the app root has kit/environment %d already" % er)
refused("duplicate", {"ids": [ew], "by": [0, 0, 0]},
    "scene world has kit/environment %d already" % ew)
call("switch_scene", {"name": "trial"})
et = placed(call("place", {"type": "kit/environment", "pos": P}))
assert of("trial", "kit/environment") == [et]
call("switch_scene", {"name": "world"})
assert of("world", "kit/environment") == [ew], of("world", "kit/environment")
# the saved pair's first named
refused("place", {"type": "kit/game_rules", "pos": P},
    "the app root has kit/game_rules 3 already")
# A copy of world is a scene of its own: its own single ones
call("duplicate_scene", {"name": "world"})
assert len(of("world_2", "kit/environment")) == 1
assert len(of("world_2", "kit/controls")) == 1
call("switch_scene", {"name": "world"})
json.dump({"env": ew}, open(out, "w"))
print("ok")
PY

# kitboss: the setup code, a builder token
wait_for_log "$SL" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$SL" | head -1)
[ -n "$code" ] || fail "no setup code ($SL)"
mkfifo "$t/c.cmd"
sleep 900 > "$t/c.cmd" &
CHECK_PIDS+=($!)
CL=$t/client.log
DISPLAY=$d WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11 BUILDAT_JOIN_NAME=kitboss \
	BUILDAT_JOIN_CODE=$code timeout 600 bin/buildat -C "$t/client_cache" \
	-D "$t/cu" -s localhost:$SERVER_PORT -w 1024x700 -l 3 -o sound_mute=1 \
	-c - < "$t/c.cmd" > "$CL" 2>&1 &
CLIENT=$!
CHECK_PIDS+=($CLIENT)
exec 3> "$t/c.cmd"
await "$CL" 0 120 "Joined as kitboss"
# (awaited here: the page can come before the client reads a wait_log_any)
await "$CL" 0 30 "server window: the page ntfy"
cmd "frames 3" 'click Button "Don'"'"'t add"'
await "$CL" 0 30 "kit editor: edit rights: yes"
await "$CL" 0 30 "kit editor: edit mode on"
menu
step 10 "accounts: agents: 0 tokens, on" "frames 3" 'click Button "My account*"' \
	"frames 5" 'click Button "Connect an agent..."'
step 10 "accounts: agents: a token made, builder" "frames 3" \
	'click Button "Make a token..."' "frames 3" 'click Button "Make a token"'
step 10 "accounts: agents: the token copied" "frames 3" 'click Button "copy token"'
tok=$(clip)
[[ $tok =~ ^bat_ ]] || fail "no Builder token on the clipboard: $tok"
cmd "frames 3" 'click Button "Done"'
step 10 "pause: the menu shown" "frames 3" "keypress Escape"
cmd "frames 3" "keypress Escape" "frames 3"

# 2. MCP
python3 -I "$t/mcp.py" "$(url)" "$tok" "$t/mcp.json" > "$t/mcp.log" 2>&1 ||
	fail "the MCP run: $(tail -5 "$t/mcp.log") ($t/mcp.log, $SL)"
env=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["env"])' "$t/mcp.json")

# 3. The editor's Place of a second kit/environment in world
m=$(mark "$SL") mc=$(mark "$CL")
step 10 "kit editor: the palette's menu of" "$(pal_find kit/environment)" \
	'click Button "kit/environment"'
step 10 "kit editor: refused: place: scene world has kit/environment $env already: one per scene; $env selected" \
	"frames 3" 'click Button "menu Place"'
await "$CL" "$mc" 5 "kit editor: selected $env "
cmd "frames 5" "screenshot $t/selected.png"
tail -c +$((m + 1)) "$SL" | grep -aq "placed kit/environment" &&
	fail "a second kit/environment placed ($SL)"

# 4. [UI_MODAL_DIM] Each menu shades the rest while up ("dim behind:
# <name>"; the view's left edge darker than in dim_none.png), and not once
# it is gone; a click off each closes it
shot() # <name> [0|1]: $t/<name>.png, its view's left edge shaded or not
{
	local m
	m=$(mark "$CL")
	cmd "frames 5" "screenshot $t/$1.png"
	await "$CL" "$m" 10 "Wrote screenshot .*/$1.png"
	[ -z "${2:-}" ] && return 0
	python3 -I - "$t/dim_none.png" "$t/$1.png" "$2" <<'PY' ||
import sys
from PIL import Image, ImageStat
a, b = (ImageStat.Stat(Image.open(p).convert("L").crop((5, 330, 60, 560))).mean[0]
        for p in sys.argv[1:3])
print("%.1f of %.1f" % (b, a))
sys.exit(0 if (b < a * 0.75) == (sys.argv[3] == "1") else 1)
PY
		fail "$1.png: the view's edge $([ "$2" = 1 ] && echo "not shaded" || echo "still shaded") ($t)"
}
OFF=("frames 3" "mouse_pos 30 450" "mouse_click left")
shot dim_none
# The palette's menu
step 10 "dim behind: kit menu" "$(pal_find kit/environment)" 'click Button "kit/environment"'
shot dim_menu 1
cmd "${OFF[@]}"
shot dim_menu_off 0
# The pause menu, the Server window over it (its click off back to the menu)
m=$(mark "$CL")
menu
await "$CL" "$m" 5 "dim behind: pause menu"
shot dim_pause 1
step 10 "dim behind: server window" "frames 3" 'click Button "My account*"'
shot dim_server 1
m=$(mark "$CL")
cmd "${OFF[@]}"
await "$CL" "$m" 10 "server window: closed"
await "$CL" "$m" 10 "pause: the menu shown"
step 10 "pause: a click off the menu" "${OFF[@]}"
shot dim_pause_off 0
# Kit's credits from the pause menu: a click off it was eaten, now its Close
menu
step 10 "dim behind: kit dialog credits" "frames 3" 'click Button "Credits..."'
shot dim_credits 1
m=$(mark "$CL")
cmd "${OFF[@]}"
await "$CL" "$m" 10 "kit editor: the credits closed"
await "$CL" "$m" 10 "pause: the menu shown"
step 10 "pause: a click off the menu" "${OFF[@]}"
shot dim_credits_off 0
# 0a84: a click that closed the menu is eaten (the view under it took it
# too); a plain ui_utils dialog over the editor has the presses and its own
# Escape (the pause menu opened over it)
acted() # <offset>: a press the view took since
{
	tail -c +$(($1 + 1)) "$CL" | grep -aE "kit editor: (selected|into the crosshair|cursor at)" |
		head -1
}
VIEW=("frames 3" "mouse_pos 300 400" "mouse_click left")
menu
m=$(mark "$CL")
step 10 "pause: a click off the menu" "${VIEW[@]}"
shot eaten1
a=$(acted "$m")
[ -z "$a" ] || fail "the click off the pause menu acted in the editor: $a ($CL)"
step 10 "dim behind: message dialog" "event message_dialog A plain dialog"
m=$(mark "$CL")
cmd "${VIEW[@]}"
shot eaten2
a=$(acted "$m")
[ -z "$a" ] || fail "a click beside the dialog acted in the editor: $a ($CL)"
step 10 "show_message_dialog: closed" "frames 3" "keypress Escape"
shot eaten3
tail -c +$((m + 1)) "$CL" | grep -aq "pause: the menu shown" &&
	fail "Escape on the dialog opened the pause menu ($CL)"
cmd "quit"
exec 3>&-
wait $CLIENT
CLIENT=
kill -INT $SRV 2>/dev/null
wait $SRV 2>/dev/null

# 5. 0a84 on the launcher, Workbench on a local server of its own (the
# launcher's placeholder under the game: a tap on nothing is Back, as
# Escape): a tap on the start's stripes does not cancel it; one beside the
# boot list does not leave the server; one off the pause menu closes it
# and it stays closed (the Escape came after the menu's own close and
# opened it again); one beside a dialog over the editor closes it and
# the editor does not take it
CL=$t/launcher.log
mkfifo "$t/l.cmd"
sleep 900 > "$t/l.cmd" &
CHECK_PIDS+=($!)
DISPLAY=$d WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11 timeout 600 bin/buildat \
	-o launch_ui=launch_menu -D "$t/lu" -a app/workbench/play \
	-w 1024x700 -l 3 -o sound_mute=1 -c - < "$t/l.cmd" > "$CL" 2>&1 &
CLIENT=$!
CHECK_PIDS+=($CLIENT)
exec 3> "$t/l.cmd"
await "$CL" 0 60 "launch_menu: start: Starting"
m=$(mark "$CL")
TAP=("mouse_pos 50 350" "mouse_click left")
cmd "${TAP[@]}"
await "$CL" "$m" 120 "world_menu: the list shown, 0 worlds"
tail -c +$((m + 1)) "$CL" | grep -aq "Stopping local server" &&
	fail "a tap on the stripes cancelled the start ($CL)"
m=$(mark "$CL")
step 10 "scan boot: done" "frames 3" "${TAP[@]}" "frames 5" "event scan boot"
tail -c +$((m + 1)) "$CL" | grep -aq 'scan boot: menu ".*world menu: worlds"' ||
	fail "a tap beside the boot list left it ($CL)"
step 10 "world_menu: the name screen shown" "frames 3" 'click Button "New game..."'
step 120 "kit editor: in session" "frames 3" 'click Button "Create"'
step 10 "pause: the menu shown" "frames 10" "keypress Escape"
m=$(mark "$CL")
step 10 "pause: a click off the menu" "frames 3" "${TAP[@]}"
shot off
tail -c +$((m + 1)) "$CL" | grep -aq "pause: the menu shown" &&
	fail "the pause menu came back after a click off it ($CL)"
step 10 "kit editor: edit mode on" "frames 3" "keypress F6"
step 10 "dim behind: message dialog" "frames 3" "event message_dialog A plain dialog"
m=$(mark "$CL")
step 10 "show_message_dialog: closed" "${VIEW[@]}"
shot dialog
a=$(acted "$m")
[ -z "$a" ] || fail "the tap that closed the dialog acted in the editor: $a ($CL)"
tail -c +$((m + 1)) "$CL" | grep -aq "pause: the menu shown" &&
	fail "the tap off the dialog opened the pause menu ($CL)"
cmd "quit"
exec 3>&-
wait $CLIENT
CLIENT=
echo "PASS: one a holder: a saved second kit/game_rules warned; by MCP a second kit/controls and kit/environment on the root and on a scene refused by place, set_parent and duplicate, naming the one there, the root's and a scene's both placed, a duplicated scene its own; the editor's Place selects the one there; the palette's menu, the pause menu, the Server window and the credits shade the rest while up, a click off each closes it; a click off the pause menu or a dialog is eaten, the dialog's Escape its own; on the launcher a tap does not cancel the start nor leave the boot list, and the pause menu stays closed after one off it"
