#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min (2026-11-17)
# covers: builtin/kit/kit.cpp builtin/kit/client_lua/editor.lua builtin/kit/client_lua/editor_input.lua builtin/kit/types/lobby.lua builtin/kit/types/ui_scene_list.lua
# [KIT_ROOT_EDIT] The app root by MCP and in the editor, through MCP on
# Workbench. kitboss (the admin) makes a builder token on a headless
# weston's Xwayland of the check's own and stays, in edit mode; the
# server's camera on SDL's offscreen driver:
#   1. Crag Trial's root wiring built by an agent in a fresh game, as a
#      game made before it had it: a kit/lobby, a kit/ui_panel and a
#      kit/ui_scene_list under it in the first scene, linked by id (the
#      list's picked to the lobby's play, the lobby's entered to the scene's
#      "the run" and to "entries"); set_parent "root" moves the lobby and
#      the panel with its list onto the root (get_state marks them
#      app_root, its list still under it, the links kept); a batch swaps
#      the lobby's entered to "the run" by to_name; a second scene, moon,
#      has its own "the run" and a kit/scene_info. Refusals: a positioned
#      type or entity onto the root, a World, a prefab's copy;
#   2. the editor: the root's entities in the Game-wide list, a scene's
#      kit/ui_panel with a kit/ui_text in it moved onto the root by the
#      inspector's button (listed with its text under it) and back,
#      a kit/timer placed on the root from the palette's menu;
#   3. play: the agent's body (play_join) picks "Moon run" on the root's
#      list: it goes to moon, moon's "the run" counts the entry (the first
#      scene's does not), "entries" by id too; delete_scene of moon refused
#      while the body is there;
#   4. each entity tool on a root entity from moon (place, set_param, link,
#      unlink, rename, set_comments, add_component, remove_component,
#      set_parent into moon and back, delete, a batch of them); get_state's
#      filters (scene "" the root's);
#   5. a draft refuses put_type, edit_type, delete_type, new_scene and
#      delete_scene, saying why; outside it they work;
#   6. delete_scene: refused with kitboss on moon, then done; the agent's
#      own scene removed takes its edits to the first.
#   util/kit_root_edit_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
for c in weston xclip; do
	command -v $c > /dev/null || skip "no $c"
done
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_root_edit; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_JOIN_PASSWORD=checkpass12
check_build
sock=buildat-root-$$
weston --backend=headless --xwayland --socket=$sock --width=1100 \
	--height=800 > "$t/weston.log" 2>&1 &
CHECK_PIDS+=($!)
for i in $(seq 50); do
	d=$(grep -ao "xserver listening on display :[0-9]*" "$t/weston.log" | grep -o ":[0-9]*$")
	[ -n "$d" ] && break
	sleep 0.2
done
[ -n "$d" ] || fail "weston's Xwayland ($t/weston.log)"
cam_egl=$(ls /usr/share/glvnd/egl_vendor.d/*_mesa.json 2>/dev/null | head -1)
[ -n "$cam_egl" ] && export __EGL_VENDOR_LIBRARY_FILENAMES=$cam_egl
SL=$t/srv.log CL=$t/boss.log
mark() { wc -c < "$1"; }
await() # <log> <offset> <seconds> <regex>
{
	local i
	for i in $(seq $(($3 * 5))); do
		tail -c +$(($2 + 1)) "$1" 2>/dev/null | grep -qaE "$4" && return 0
		kill -0 $CLIENT 2>/dev/null || fail "gone while waiting for \"$4\" ($1)"
		sleep 0.2
	done
	fail "no \"$4\" in $1 in $3 s ($SL)"
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
sstep() # <seconds> <regex in the server's log> <command>...
{
	local s=$1 re=$2 m
	shift 2
	m=$(mark "$SL")
	cmd "$@"
	await "$SL" "$m" "$s" "$re"
}
clip() # <last>: the clipboard once it holds something else
{
	local i got
	for i in $(seq 50); do
		got=$(DISPLAY=$d xclip -selection clipboard -o 2>/dev/null)
		[ -n "$got" ] && [ "$got" != "$1" ] && break
		sleep 0.2
	done
	printf '%s' "$got"
}

start_server "$SL" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
	--sim-rate "$CHECK_RATE" || fail "the server did not come up ($SL)"
CHECK_PIDS+=($SERVER_PID)
url=http://localhost:$SERVER_PORT/api/v1/mcp
wait_for_log "$SL" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$SL" | head -1)
[ -n "$code" ] || fail "no setup code ($SL)"
mkfifo "$t/boss.cmd"
sleep 900 > "$t/boss.cmd" &
CHECK_PIDS+=($!)
DISPLAY=$d WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11 BUILDAT_JOIN_NAME=kitboss \
	BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	timeout 600 bin/buildat -C "$t/client_cache" -D "$t/cu" \
	-s localhost:$SERVER_PORT -w 1024x700 -l 3 -o sound_mute=1 -c - \
	< "$t/boss.cmd" > "$CL" 2>&1 &
CLIENT=$!
CHECK_PIDS+=($CLIENT)
exec 3> "$t/boss.cmd"
await "$CL" 0 120 "Joined as kitboss"
cmd "wait_log_any 30000 server window: the page ntfy" "frames 3" 'click Button "Don'"'"'t add"'
await "$CL" 0 120 "player physics enabled"
step 10 "pause: the menu shown" "frames 3" "keypress Escape"
step 10 "accounts: agents: 0 tokens, on" "frames 3" 'click Button "My account*"' \
	"frames 5" 'click Button "Connect an agent..."'
step 10 "accounts: agents: a token made, builder" "frames 3" \
	'click Button "Make a token..."' "frames 3" 'click Button "Make a token"'
step 10 "accounts: agents: the token copied" "frames 3" 'click Button "copy token"'
tok=$(clip "")
[[ $tok =~ ^bat_[0-9a-f]{64}$ ]] || fail "kitboss's builder token: $tok"
cmd "frames 3" 'click Button "Done"'
step 10 "pause: the menu shown" "keypress Escape"
step 10 "pause: the menu closed" "frames 3" "keypress Escape"
step 10 "kit editor: edit mode on" "frames 3" 'event kit_edit {"op": "mode", "on": true}'
echo "ok: kitboss's builder token; kitboss in edit mode"

cat > "$t/mcp.py" <<'PY'
import json, re, sys, time, urllib.error, urllib.request
phase, url, tok, out = sys.argv[1:5]
def post(msg):
    h = {"Content-Type": "application/json",
         "Accept": "application/json, text/event-stream",
         "Authorization": "Bearer " + tok}
    req = urllib.request.Request(url, data=json.dumps(msg).encode(), headers=h,
        method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
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
    # (a token's 120 calls a minute: waited out)
    for i in range(70):
        s, b = post(m)
        if s != 429 and not (s == 200 and "calls a minute: wait" in b):
            break
        time.sleep(1)
    assert s == 200, (method, s, b)
    return json.loads(b)
def call(name, args={}, error=False):
    r = rpc("tools/call", {"name": name, "arguments": args})["result"]
    text = r["content"][0]["text"]
    assert r["isError"] == error, (name, args, text[:800])
    print(" ", name, json.dumps(args)[:200], "->", text[:300])
    return text
def refused(name, args={}):
    return call(name, args, True)
def until(f, what, secs=10):
    for i in range(secs * 5):
        v = f()
        if v:
            return v
        time.sleep(0.2)
    raise AssertionError("not in %d s: %s" % (secs, what))
def placed(text):
    return int(re.search(r"placed \S+ (\d+)", text).group(1))
def state(**kw):
    return json.loads(call("get_state", kw))
def entity(i):
    return state(ids=[i])["entities"][0]
def count(i):
    return entity(i)["components"][0].get("state", {}).get("count", 0)
def links(i, c=0):
    return entity(i)["components"][c].get("links", [])
def saved():
    try:
        return json.load(open(out + "/ids.json"))
    except FileNotFoundError:
        return {}
def save(**kw):
    s = saved()
    s.update(kw)
    json.dump(s, open(out + "/ids.json", "w"))
def to_start():
    if state(ids=[])["running"]:
        call("stop")
def played(args):
    return json.loads(re.search(r"Played [^:]*: (\{.*\})", call("play_input",
        args)).group(1))
init = {"protocolVersion": "2025-11-25", "capabilities": {},
        "clientInfo": {"name": "kit_root_edit_check", "version": "1"}}
ins = rpc("initialize", init)["result"]["instructions"]
s = saved()
GADGET = 'return {version = 1, about = {what = "A gadget."}, inputs = {go = "none"}}\n'
if phase == "build":
    names = [t["name"] for t in rpc("tools/list")["result"]["tools"]]
    assert "delete_scene" in names, names
    assert len(ins) < 4096 and "delete_scene" in ins, len(ins)
    to_start()
    main = state()["scene"]
    # (1) As a game made before the root was reachable: in the first scene,
    # linked by id
    R0 = placed(call("place", {"type": "kit/counter", "pos": [0, 1, 0]}))
    call("rename", {"id": R0, "name": "the run"})
    EN = placed(call("place", {"type": "kit/counter", "pos": [2, 1, 0]}))
    call("rename", {"id": EN, "name": "entries"})
    LB = placed(call("place", {"type": "kit/lobby", "pos": [0, 0, 0]}))
    PN = placed(call("place", {"type": "kit/ui_panel", "pos": [0, 0, 0],
        "params": {"to": "player", "title": "The lobby"}}))
    SC = placed(call("place", {"type": "kit/ui_scene_list", "pos": [0, 0, 0],
        "parent": PN, "params": {"title": "Pick a track"}}))
    call("set_param", {"id": LB, "param": "lobby_screen", "value": PN})
    call("link", {"id": SC, "output": "picked", "to": LB, "input": "play"})
    call("link", {"id": LB, "output": "entered", "to": R0, "input": "count"})
    call("link", {"id": LB, "output": "entered", "to": EN, "input": "count"})
    # (the editor's to move: a panel with a text in it)
    EP = placed(call("place", {"type": "kit/ui_panel", "pos": [0, 0, 0],
        "params": {"title": "Moved by the editor"}}))
    UT = placed(call("place", {"type": "kit/ui_text", "pos": [0, 0, 0],
        "parent": EP, "params": {"text": "moved by the editor"}}))
    call("new_scene", {"name": "moon", "copy": True})
    R1 = placed(call("place", {"type": "kit/counter", "pos": [0, 1, 0]}))
    call("rename", {"id": R1, "name": "the run"})
    call("place", {"type": "kit/scene_info", "pos": [0, 0, 0], "params": {"title": "Moon run"}})
    call("switch_scene", {"name": main})
    assert not any(e.get("app_root") for e in state(scene=main)["entities"])
    # Onto the root: the lobby, the panel with its list under it
    assert "put %d on the app root" % LB in call("set_parent", {"id": LB, "parent": "root"})
    assert "put %d on the app root" % PN in call("set_parent", {"id": PN, "parent": 1})
    assert "on the app root already" in refused("set_parent", {"id": PN, "parent": "root"})
    root = {e["id"]: e for e in state(scene="")["entities"]}
    for i in (LB, PN, SC):
        assert root.get(i, {}).get("app_root") is True, (i, root.get(i))
    assert root[LB]["parent"] == 1 and root[PN]["parent"] == 1 and root[SC]["parent"] == PN, root
    assert not root.keys() & {R0, EP, UT}, root
    ids = {e["id"] for e in state(scene=main)["entities"]}
    assert {R0, EP, UT} <= ids and not ids & {LB, PN, SC}, ids
    assert {"output": "picked", "to": LB, "input": "play"}.items() <= links(SC)[0].items(), links(SC)
    assert root[LB]["components"][0]["params"]["lobby_screen"] == PN, root[LB]
    # The lobby's entered to each scene's "the run", by name; entries by id
    r = call("batch", {"ops": [
        {"tool": "unlink", "args": {"id": LB, "output": "entered", "to": R0, "input": "count"}},
        {"tool": "link", "args": {"id": LB, "output": "entered", "to_name": "the run", "input": "count"}}]})
    assert "one undo" in r, r
    ls = links(LB)
    assert any(l.get("to_name") == "the run" and l["output"] == "entered" for l in ls), ls
    assert not any(l.get("to") == R0 for l in ls), ls
    assert any(l.get("to") == EN for l in ls), ls
    # Refusals: a place, a positioned type or entity, a World, a prefab's copy
    assert "kit/counter has a position: the app root holds what has none" in refused("place",
        {"type": "kit/counter", "pos": [0, 1, 0], "parent": "root"})
    assert "entity %d has a position: the app root holds what has none" % R0 in refused(
        "set_parent", {"id": R0, "parent": "root"})
    for e in state(type="kit/terrain")["entities"]:
        assert "kit/terrain is a World: its scene's" in refused("set_parent",
            {"id": e["id"], "parent": "root"})
    assert "a prefab's copy goes in a scene, not on the app root" in refused("place_prefab",
        {"prefab": "kit/hut", "pos": [10, 1, 10], "parent": "root"})
    save(main=main, R0=R0, R1=R1, EN=EN, LB=LB, PN=PN, SC=SC, EP=EP, UT=UT)
elif phase == "play":
    main, R0, R1, EN, LB, SC = s["main"], s["R0"], s["R1"], s["EN"], s["LB"], s["SC"]
    assert call("start") == "Running"
    t0 = time.time()
    while True:
        r = rpc("tools/call", {"name": "play_join", "arguments": {}})["result"]
        text = r["content"][0]["text"]
        if not r["isError"]:
            break
        print("  play_join ->", text[:200])
        assert "is starting" in text or "on its way" in text, text
        assert time.time() - t0 < 150, "the camera not in in 150 s"
        time.sleep(1)
    print("  play_join ->", text[:400])
    def rows():
        b = played({"seconds": 0.2}).get("buttons", [])
        return next((x["rows"] for x in b if x["id"] == SC and x.get("rows")), None)
    assert until(rows, "the root's scene list's rows") == ["Moon run"]
    ev = played({"press": "Moon run", "seconds": 0.3})["events"]
    assert any(e["id"] == SC and e["output"] == "picked" and e.get("value") == "moon"
        for e in ev), ev
    until(lambda: count(R1) == 1, "moon's \"the run\" entered", 20)
    until(lambda: count(EN) == 1, "\"entries\" (by id from the root) counted")
    assert count(R0) == 0, count(R0)
    lobby = state()["round"].get("lobby", {})
    assert "playing" in lobby.values(), lobby
    r = refused("delete_scene", {"name": "moon"})
    assert "you are in the scene moon" in r, r
    assert "Your body is gone" in call("play_leave")
    call("stop")
elif phase == "tools":
    main, R1 = s["main"], s["R1"]
    # (4) a root entity, edited from moon
    call("switch_scene", {"name": "moon"})
    X = placed(call("place", {"type": "kit/timer", "pos": [0, 0, 0], "parent": "root"}))
    e = entity(X)
    assert e["parent"] == 1 and e.get("app_root") is True and "pos" not in e, e
    call("set_param", {"id": X, "param": "interval", "value": 2})
    assert entity(X)["components"][0]["params"]["interval"] == 2
    call("link", {"id": X, "output": "tick", "to": R1, "input": "count"})
    assert any(l.get("to") == R1 for l in links(X)), links(X)
    call("unlink", {"id": X, "output": "tick", "to": R1, "input": "count"})
    call("link", {"id": X, "output": "tick", "to_name": "the run", "input": "count"})
    assert [l.get("to_name") for l in links(X)] == ["the run"], links(X)
    call("rename", {"id": X, "name": "the clock"})
    call("set_comments", {"id": X, "text": "on the root"})
    e = entity(X)
    assert e["name"] == "the clock" and e["comments"] == "on the root", e
    call("add_component", {"id": X, "type": "kit/logic"})
    assert [c["type"] for c in entity(X)["components"]] == ["kit/timer", "kit/logic"]
    call("remove_component", {"id": X, "comp": 1})
    assert [c["type"] for c in entity(X)["components"]] == ["kit/timer"]
    # Into moon (0) and back
    assert "put %d under the scene moon" % X in call("set_parent", {"id": X, "parent": 0})
    assert X in {e["id"] for e in state(scene="moon")["entities"]}
    assert not entity(X).get("app_root")
    call("set_parent", {"id": X, "parent": "root"})
    # get_state's filters
    assert X in {e["id"] for e in state(scene="")["entities"]}
    assert X not in {e["id"] for e in state(scene="moon")["entities"]}
    assert X in {e["id"] for e in state(type="kit/timer")["entities"]}
    assert all(e.get("app_root") for e in state(scene="")["entities"])
    assert "\"\": the app root's" in refused("get_state", {"scene": "nope"})
    call("delete", {"id": X})
    assert X not in {e["id"] for e in state()["entities"]}
    # A batch of them, one undo
    r = call("batch", {"ops": [
        {"tool": "place", "args": {"type": "kit/timer", "pos": [0, 0, 0], "parent": "root"}},
        {"tool": "rename", "args": {"id": {"id_of": 0}, "name": "batched"}},
        {"tool": "set_param", "args": {"id": {"id_of": 0}, "param": "repeats", "value": 3}},
        {"tool": "set_parent", "args": {"id": {"id_of": 0}, "parent": 0}},
        {"tool": "set_parent", "args": {"id": {"id_of": 0}, "parent": "root"}}]})
    Y = int(re.search(r"\n0 place: placed \S+ (\d+)", r).group(1))
    e = entity(Y)
    assert e["name"] == "batched" and e.get("app_root") and \
        e["components"][0]["params"]["repeats"] == 3, e
    call("undo")
    assert Y not in {e["id"] for e in state()["entities"]}
    call("switch_scene", {"name": main})
elif phase == "draft":
    # (5) custom types and scenes are the game's
    EDIT = {"name": "gadget", "edits": [{"find": "A gadget", "replace": "B gadget"}]}
    call("put_type", {"name": "gadget", "source": GADGET})
    call("draft")
    assert state()["session"]["kind"] == "draft"
    WHY = "in a draft: custom types are the game's, a change goes live at once; leave the draft first"
    for name, args in (("put_type", {"name": "gadget", "source": GADGET}),
            ("edit_type", EDIT), ("delete_type", {"name": "gadget"})):
        r = refused(name, args)
        assert WHY in r, (name, r)
    SWHY = "in a draft: scenes are the game's, a scene made or removed is the main round's at once; leave the draft first"
    assert SWHY in refused("new_scene", {"name": "nope"})
    assert SWHY in refused("delete_scene", {"name": "moon"})
    call("leave_draft")
    assert state()["session"]["kind"] == "main"
    assert "changed" in call("edit_type", EDIT)
    call("delete_type", {"name": "gadget"})
elif phase == "busy":
    r = refused("delete_scene", {"name": "moon"})
    assert "1 player on it: unlist it; they leave as they finish" in r, r
elif phase == "delete":
    main, R1 = s["main"], s["R1"]
    r = call("delete_scene", {"name": "moon"})
    assert r.startswith("removed the scene moon"), r
    st = state()
    assert "moon" not in st["scenes"] and R1 not in {e["id"] for e in st["entities"]}, st["scenes"]
    # its own scene: its edits to the first
    call("new_scene", {"name": "attic"})
    assert state()["scene"] == "attic"
    r = call("delete_scene", {"name": "attic"})
    assert "removed the scene attic" in r and "your edits go to the scene %s now" % main in r, r
    assert state()["scene"] == main
    assert "is the game's first: it stays" in refused("delete_scene", {"name": main})
    assert "no scene nope" in refused("delete_scene", {"name": "nope"})
print("ok:", phase)
PY
mcp() # <phase>: the MCP client's phase; its output in $t/mcp_<phase>.log
{
	python3 -I "$t/mcp.py" "$1" "$url" "$tok" "$t" > "$t/mcp_$1.log" 2>&1 ||
		fail "the MCP phase $1: $(tail -5 "$t/mcp_$1.log") ($t/mcp_$1.log, $SL)"
	cat "$t/mcp_$1.log"
}
ids() { python3 -c "import json; print(json.load(open('$t/ids.json'))['$1'])"; }

# 1. The root's wiring
mcp build
LB=$(ids LB) PN=$(ids PN) SC=$(ids SC) EP=$(ids EP) UT=$(ids UT) MAIN=$(ids main)
echo "ok: the lobby ($LB) and the panel ($PN) with its list ($SC) moved onto the root, the links kept, entered by name"

# 2. The editor: the root's in the Game-wide list; a move of a panel with
# a text in it onto the root and back; a place on it
cmd "frames 3" 'click Button "Entities"' "frames 3"
step 10 "kit editor: list Game-wide \\([0-9]+\\): .*\\b$LB, $PN, >$SC\\b" 'click Button "Game-wide (*"'
step 10 "kit editor: selected $EP\\b" "frames 3" "event kit_select $EP"
m=$(mark "$SL") mc=$(mark "$CL")
cmd "frames 3" 'click Button "Onto the app root"'
await "$CL" "$mc" 10 "kit editor: onto the app root $EP\\b"
await "$SL" "$m" 10 "An edit by kitboss: put $EP on the app root"
await "$CL" "$mc" 10 "kit editor: list Game-wide \\([0-9]+\\): .*\\b$EP, >$UT\\b"
m=$(mark "$SL")
step 10 "kit editor: into the scene $EP\\b" "frames 5" 'click Button "Into this scene"'
await "$SL" "$m" 10 "An edit by kitboss: put $EP under the scene $MAIN"
m=$(mark "$SL")
cmd "frames 3" 'click Button "Place"' "frames 5" \
	'click Button "palette filter clear"' "frames 2" 'click LineEdit "palette filter"' \
	"frames 2" "text kit/timer" "frames 3"
step 10 "the palette's menu of kit/timer" 'click Button "kit/timer"'
cmd "frames 3" 'click Button "menu Place on the app root"'
await "$SL" "$m" 10 "An edit by kitboss: placed kit/timer [0-9]+ on the app root"
echo "ok: the editor lists the root's entities, moves $EP (with $UT in it) onto the root and back, places a kit/timer on the root"

# 3.-5.
for p in play tools draft; do
	mcp $p
done
echo "ok: a pick on the root's list entered moon's run by name; a root entity's tools from another scene; a draft refuses types and scenes"

# 6. delete_scene, refused with kitboss on moon, then done
sstep 20 "workbench: kitboss to scene moon" "frames 3" 'event kit_edit {"op": "scene", "name": "moon"}'
mcp busy
sstep 20 "workbench: kitboss to scene $MAIN" "frames 3" \
	"event kit_edit {\"op\": \"scene\", \"name\": \"$MAIN\"}"
mcp delete

cmd "sync 2000" quit
exec 3>&-
wait $CLIENT 2>/dev/null
CLIENT=$SERVER_PID
grep -rqaF "${tok#bat_}" "$t"/*.log && fail "the token in a log"
echo "PASS: the app root by MCP and in the editor: a lobby and its screens moved onto the root with their links, entered by name, a pick entering the picked scene's run; each entity tool on a root entity from another scene; get_state's marks and filters; types and scenes refused in a draft; delete_scene; the editor's Game-wide list, a move onto the root and back, a place on it"
