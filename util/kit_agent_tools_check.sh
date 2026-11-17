#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min (2026-11-17)
# covers: builtin/kit/kit.cpp builtin/kit/types/ui_button.lua builtin/kit/types/ui_scene_list.lua
# [KIT_AGENT_FEEDBACK_1117] An agent's tools as a claude.ai agent asked for
# them on testbench, through MCP on Workbench. kitboss (the admin) makes a
# builder and an admin token on a headless weston's Xwayland of the
# check's own and stays, in edit mode; the server's camera on SDL's
# offscreen driver:
#   1. tools/list: the builder token's without the admin's tools (14), the
#      admin token's with them; both instructions under 4096 characters;
#   2. types: put_type with client left out keeps the client part, "" takes
#      it away (2); edit_type's find-and-replace in the source and the
#      client part, refused (nothing changed) for a find not there, there
#      twice, a type not there and a result that does not load (1); a param
#      added to a type while play had removed its entity shows on it at its
#      default once Stop puts it back (3);
#   3. links by name (7): a root entity (local/hub) linked by to_name
#      "target" into a counter so named in two scenes; try_input as nobody
#      (the default: by "app", nothing reached), as kitboss (the world's
#      target), as "me" (the body's scene's, moon) and refusals (5);
#   4. play_input's press (8): a kit/ui_button by its label, a
#      kit/ui_scene_list's row by its title (its "picked"), an unknown one
#      refused naming the screen's buttons;
#   5. get_state's filters: scene, ids, type, state false (10);
#   6. get_goal_warnings' level lines: default names, a scene with no way
#      in, the timer with no link of four (12);
#   7. get_history: the edits by who, limit, since (11);
#   8. restore_checkpoint puts a heightmap's samples back (4z26): kitboss
#      raises a sample after a checkpoint, the restore lowers it, the
#      restore of "before restore ..." raises it again (column reads).
#   util/kit_agent_tools_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
for c in weston xclip; do
	command -v $c > /dev/null || skip "no $c"
done
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_agent_tools; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_JOIN_PASSWORD=checkpass12
check_build
sock=buildat-tools-$$
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
# A heightmap sample's height as kitboss's column read logs it, into $H
column() # <x> <z>
{
	step 10 "kit editor: terrain: column at \\($1,$2\\)" "frames 2" \
		'event kit_edit {"op": "terrain", "tool": "column", "x": '$1', "y": 0, "z": '$2'}'
	H=$(grep -aoP "column at \\($1,$2\\) .*\\($1,$2\\) at \\K[-0-9.]+" "$CL" | tail -1)
	[ -n "$H" ] || fail "no column read at ($1,$2) in $CL"
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
# 0. The tokens: a builder's, then an admin's
step 10 "pause: the menu shown" "frames 3" "keypress Escape"
step 10 "accounts: agents: 0 tokens, on" "frames 3" 'click Button "My account*"' \
	"frames 5" 'click Button "Connect an agent..."'
step 10 "accounts: agents: a token made, builder" "frames 3" \
	'click Button "Make a token..."' "frames 3" 'click Button "Make a token"'
step 10 "accounts: agents: the token copied" "frames 3" 'click Button "copy token"'
tok=$(clip "")
[[ $tok =~ ^bat_[0-9a-f]{64}$ ]] || fail "kitboss's builder token: $tok"
cmd "frames 3" 'click Button "Done"' "frames 3" 'click Button "Scope: Builder*"' \
	"frames 3" 'click LineEdit "My agent"' "delay 300" "keydown ctrl" \
	"keypress a" "keyup ctrl" "text admin agent" "frames 2"
step 10 "accounts: agents: a token made, admin" 'click Button "Make a token"'
step 10 "accounts: agents: the token copied" "frames 3" 'click Button "copy token"'
adm=$(clip "$tok")
[[ $adm =~ ^bat_[0-9a-f]{64}$ ]] && [ "$adm" != "$tok" ] || fail "kitboss's admin token: $adm"
cmd "frames 3" 'click Button "Done"'
step 10 "pause: the menu shown" "keypress Escape"
step 10 "pause: the menu closed" "frames 3" "keypress Escape"
step 10 "kit editor: edit mode on" "frames 3" 'event kit_edit {"op": "mode", "on": true}'
echo "ok: kitboss's builder and admin tokens; kitboss in edit mode"

cat > "$t/mcp.py" <<'PY'
import json, re, sys, time, urllib.error, urllib.request
phase, url, tok, adm, out = sys.argv[1:6]
def post(msg, tk):
    h = {"Content-Type": "application/json",
         "Accept": "application/json, text/event-stream",
         "Authorization": "Bearer " + tk}
    req = urllib.request.Request(url, data=json.dumps(msg).encode(), headers=h,
        method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
n = 0
def rpc(method, params=None, tk=tok):
    global n
    n += 1
    m = {"jsonrpc": "2.0", "id": n, "method": method}
    if params is not None:
        m["params"] = params
    # (a token's 120 calls a minute: waited out)
    for i in range(40):
        s, b = post(m, tk)
        if s != 429:
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
def get_type(name):
    return json.loads(call("get_type", {"type": name}))
def saved():
    try:
        return json.load(open(out + "/ids.json"))
    except FileNotFoundError:
        return {}
def save(**kw):
    s = saved()
    s.update(kw)
    json.dump(s, open(out + "/ids.json", "w"))
def tried(entity_id):
    """The next try's emits ([[output, value]...])"""
    def got():
        for ev in json.loads(call("get_events")):
            if ev["event"] == "tried" and ev["data"]["id"] == entity_id:
                return ev["data"]["emitted"] or [["(none)", None]]
    return until(got, "the try's answer")
def to_start():
    if state(ids=[])["running"]:
        call("stop")
init = {"protocolVersion": "2025-11-25", "capabilities": {},
        "clientInfo": {"name": "kit_agent_tools_check", "version": "1"}}
s = saved()
HUB = '''return {
	version = 1,
	root = true,
	about = {what = "The check's hub."},
	params = {a = {type = "number", default = 1}},
	inputs = {ping = "none", gone = "none"},
	outputs = {pong = "number", who = "string"},
	on_input = function(c, input, value, by)
		if input == "gone" then c:remove() return end
		c:emit("who", tostring(by))
		c:emit("pong", c.params.b or -1)
	end,
}
'''
CL1 = 'return {on_add = function(e) e:log("hub client v1") end}\n'
if phase == "tools":
    hidden = {"set_builder", "list_games", "copy_game", "rename_game", "publish_log"}
    for tk, admin in ((tok, False), (adm, True)):
        r = rpc("initialize", init, tk)["result"]
        assert len(r["instructions"]) < 4096, len(r["instructions"])
        names = [t["name"] for t in rpc("tools/list", None, tk)["result"]["tools"]]
        assert {"edit_type", "get_history"} <= set(names), names
        if admin:
            assert hidden <= set(names), names
        else:
            assert not hidden & set(names), names
        # kitboss, the server's admin, publishes as the server by either
        assert "publish_game" in names, names
        print("  %s token: %d tools, instructions %d characters" % (
            "the admin" if admin else "a builder", len(names), len(r["instructions"])))
    rpc("initialize", init)
    assert "only the server's admin" in refused("set_builder", {"name": "kitboss", "on": True})
    st = state()
    save(main=st["scene"])
elif phase == "types":
    rpc("initialize", init)
    to_start()
    call("put_type", {"name": "hub", "source": HUB, "client": CL1})
    assert get_type("local/hub")["client"] == CL1
    # (2) left out: kept
    call("put_type", {"name": "hub", "source": HUB.replace("check's hub", "check's hub again")})
    g = get_type("local/hub")
    assert g["client"] == CL1 and "hub again" in g["source"], g
    call("put_type", {"name": "hub", "source": HUB, "client": ""})
    assert get_type("local/hub")["client"] == ""
    call("put_type", {"name": "hub", "source": HUB, "client": CL1})
    # (1) edit_type
    r = call("edit_type", {"name": "hub", "edits": [
        {"find": "default = 1", "replace": "default = 2"},
        {"find": "hub client v1", "replace": "hub client v2", "client": True}]})
    assert r.startswith("the type local/hub changed"), r
    g = get_type("local/hub")
    assert "default = 2" in g["source"] and "hub client v2" in g["client"], g
    for edits, why in (
            ([{"find": "default = 2", "replace": "default = 3"},
              {"find": "nothing like this", "replace": "x"}],
             "edits[1]'s find \"nothing like this\" is not in the source (after the edits before it); nothing changed"),
            ([{"find": "c:emit", "replace": "c:emit"}],
             "edits[0]'s find \"c:emit\" is more than once in the source"),
            ([{"find": "v2", "replace": "v3"}], "is not in the source"),
            ([{"find": "", "replace": "x"}], "edits[0]: {find (not \"\"), replace, client}"),
            ([{"find": "return {", "replace": "return {{"}], "local/hub")):
        r = refused("edit_type", {"name": "hub", "edits": edits})
        assert r.startswith("Refused: ") and why in r, (why, r)
    assert "no custom type local/nohub (put_type makes one)" in refused("edit_type",
        {"name": "nohub", "edits": [{"find": "a", "replace": "b"}]})
    g = get_type("local/hub")
    assert "default = 2" in g["source"] and "hub client v2" in g["client"], g
    # (3) a param added: on the placed entity at its default, one play
    # removed included (back at Stop)
    H = placed(call("place", {"type": "local/hub", "pos": [0, 0, 0]}))
    e = entity(H)
    assert e["parent"] == 1 and e["components"][0]["params"] == {"a": 2}, e
    assert call("start") == "Running"
    call("try_input", {"id": H, "input": "gone"})
    until(lambda: "Entity %d removed %d " % (H, H) in open(out + "/srv.log",
        errors="replace").read(), "the hub removed by play")
    call("edit_type", {"name": "hub", "edits": [{"find": "params = {a = {type = \"number\", default = 2}}",
        "replace": "params = {a = {type = \"number\", default = 2}, b = {type = \"number\", default = 7}}"}]})
    # (get_state's authored entities: the removed one among them)
    e = entity(H)
    assert e["components"][0]["params"] == {"a": 2, "b": 7}, e
    call("stop")
    e = entity(H)
    assert e["components"][0]["params"] == {"a": 2, "b": 7}, e
    save(H=H)
elif phase == "links":
    rpc("initialize", init)
    H, main = s["H"], s["main"]
    call("new_scene", {"name": "moon"})
    MT = placed(call("place", {"type": "kit/counter", "pos": [0, 1, 0]}))
    call("rename", {"id": MT, "name": "target"})
    call("place", {"type": "kit/scene_info", "pos": [0, 0, 0], "params": {"title": "Moon run"}})
    B = placed(call("place", {"type": "kit/ui_button", "pos": [0, 0, 0], "params": {"label": "Go"}}))
    L = placed(call("place", {"type": "kit/ui_scene_list", "pos": [0, 0, 0]}))
    call("new_scene", {"name": "attic"})
    call("switch_scene", {"name": main})
    WT = placed(call("place", {"type": "kit/counter", "pos": [2, 1, 0]}))
    call("rename", {"id": WT, "name": "target"})
    # (7) by name: each signal to the "target" of its setter's scene
    r = call("link", {"id": H, "output": "pong", "to_name": "target", "input": "add"})
    assert "\"target\" in the player's scene" in r, r
    T = [placed(call("place", {"type": "kit/timer", "pos": [4 + k, 1, 0]})) for k in range(4)]
    for k in range(3):
        call("rename", {"id": T[k], "name": "timer %d" % k})
        call("link", {"id": T[k], "output": "tick", "to": WT, "input": "count"})
    assert call("start") == "Running"
    # (5) as: nobody unless given
    assert "as: \"me\" is your body: play_join first" in refused("try_input",
        {"id": H, "input": "ping", "as": "me"})
    assert "no player named \"nobody_here\" in this round" in refused("try_input",
        {"id": H, "input": "ping", "as": "nobody_here"})
    call("get_events")
    call("try_input", {"id": H, "input": "ping"})
    em = tried(H)
    assert ["who", "app"] in em and ["pong", 7] in em, em
    time.sleep(0.4)
    assert count(WT) == 0 and count(MT) == 0, (count(WT), count(MT))
    call("try_input", {"id": H, "input": "ping", "as": "kitboss"})
    em = tried(H)
    assert any(o == "who" and re.match(r"^player:\d+$", v) for o, v in em), em
    until(lambda: count(WT) == 7, "the world's target reached")
    assert count(MT) == 0
    save(MT=MT, WT=WT, B=B, L=L, T=T)
elif phase == "play":
    rpc("initialize", init)
    H, MT, WT, B, L = s["H"], s["MT"], s["WT"], s["B"], s["L"]
    call("switch_scene", {"name": "moon"})
    t0 = time.time()
    while True:
        r = rpc("tools/call", {"name": "play_join", "arguments": {}})["result"]
        text = r["content"][0]["text"]
        if not r["isError"]:
            break
        print("  play_join ->", text[:200])
        assert "is starting" in text or "on its way" in text, text
        assert time.time() - t0 < 150, "the camera not in in 150 s"
        time.sleep(0.5)
    print("  play_join ->", text[:400])
    body = json.loads(re.search(r"\): (\{.*\})\. play_input", text).group(1))
    assert body["scene"] == "moon", body
    # The screen's buttons (the list's rows filled within a second)
    def buttons():
        b = json.loads(re.search(r"Played [^:]*: (\{.*\})", call("play_input",
            {"seconds": 0.2})).group(1)).get("buttons", [])
        return b if any(x["id"] == L and x.get("rows") for x in b) else None
    bs = until(buttons, "the scene list's rows")
    assert {"id": B, "label": "Go"}.items() <= next(x for x in bs if x["id"] == B).items(), bs
    assert next(x for x in bs if x["id"] == L)["rows"] == ["Moon run"], bs
    # (5) as me: the body's scene's target
    call("try_input", {"id": H, "input": "ping", "as": "me"})
    tried(H)
    until(lambda: count(MT) == 7, "the moon's target reached")
    assert count(WT) == 7
    # (8) press
    def played(args):
        return json.loads(re.search(r"Played [^:]*: (\{.*\})", call("play_input",
            args)).group(1))
    ev = played({"press": "Go", "seconds": 0.3})["events"]
    assert any(e["id"] == B and e["output"] == "pressed" for e in ev), ev
    ev = played({"press": "moon run", "seconds": 0.3})["events"]
    assert any(e["id"] == L and e["output"] == "picked" and e.get("value") == "moon"
        for e in ev), ev
    ev = played({"press": L, "row": 1, "seconds": 0.3})["events"]
    assert any(e["id"] == L and e["output"] == "picked" for e in ev), ev
    r = refused("play_input", {"press": "Nope"})
    assert "press: no button \"Nope\" on your body's screen (its buttons: " in r and "Go" in r, r
    assert "row: 1 to 1" in refused("play_input", {"press": L})
    assert "Your body is gone" in call("play_leave")
elif phase == "state":
    rpc("initialize", init)
    MT, WT, T = s["MT"], s["WT"], s["T"]
    all_ = state()
    moon = state(scene="moon")
    ids = {e["id"] for e in moon["entities"]}
    assert MT in ids and WT not in ids and s["H"] not in ids, ids
    assert any(e.get("kind") == "scene" and e["name"] == "moon" for e in moon["entities"])
    assert len(all_["entities"]) > len(moon["entities"])
    one = state(ids=[WT])["entities"]
    assert [e["id"] for e in one] == [WT] and "state" in one[0]["components"][0], one
    one = state(ids=[WT], state=False)["entities"]
    assert "state" not in one[0]["components"][0], one
    tm = state(type="kit/timer")["entities"]
    assert sorted(e["id"] for e in tm) == sorted(T), tm
    assert "no scene named" in refused("get_state", {"scene": "nope"})
    assert "ids: a list" in refused("get_state", {"ids": 5})
elif phase == "goals":
    rpc("initialize", init)
    T = s["T"]
    w = json.loads(call("get_goal_warnings"))
    for l in w:
        print("   |", l)
    names = [l for l in w if "still on a default name" in l]
    assert len(names) == 1 and str(T[3]) in names[0] and str(T[0]) not in names[0], names
    assert any(l.startswith("scene attic: no way in") for l in w), w
    assert not any(l.startswith("scene moon") for l in w), w
    assert "kit/timer: 1 of 4 have no link out (the others do): %d" % T[3] in w, w
elif phase == "history":
    rpc("initialize", init)
    h = json.loads(call("get_history"))
    for x in h[-6:]:
        print("   |", x)
    mine = [x["what"] for x in h if x["by"] == "kitboss's agent"]
    for w in ("the type local/hub changed", "placed kit/timer", "linked %d.pong -> \"target\"" % s["H"],
            "renamed %d to target" % s["WT"]):
        assert any(w in x for x in mine), (w, mine)
    assert all(re.match(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$", x["time"]) and
        x["where"] == "in the main round" for x in h), h[:3]
    assert json.loads(call("get_history", {"limit": 2})) == h[-2:]
    assert json.loads(call("get_history", {"since": "2999-01-01T00"})) == []
    assert json.loads(call("get_history", {"since": 0, "limit": 200}))[-len(h):] == h
    assert "since: a time" in refused("get_history", {"since": "yesterday"})
elif phase == "heightmap":
    rpc("initialize", init)
    to_start()
    call("switch_scene", {"name": s["main"]})
    call("place", {"type": "kit/terrain", "pos": [0, 1, 0], "params": {"biome": "grassland",
        "generator": "noise", "height": 3, "level": 3, "surface": "heightmap"}})
elif phase == "checkpoint":
    rpc("initialize", init)
    call("checkpoint", {"name": "flat"})
elif phase in ("restore", "back"):
    rpc("initialize", init)
    name = "flat" if phase == "restore" else "before restore flat"
    def restored():
        r = rpc("tools/call", {"name": "restore_checkpoint", "arguments": {"name": name}})["result"]
        text = r["content"][0]["text"]
        if r["isError"]:
            assert "wait for their load" in text, text
            return None
        return text
    text = until(restored, "the restore")
    print("  restore_checkpoint ->", text[:400])
    m = re.search(r", 1 heightmaps generated again under its (\d+) edited samples", text)
    assert m and (int(m.group(1)) == 0) == (phase == "restore"), text
    if phase == "back":
        h = json.loads(call("get_history", {"limit": 200}))
        assert any(x["by"] == "kitboss" and x["what"] == "terrain: raise" for x in h), h[-8:]
        assert any(x["what"] == "restored checkpoint \"flat\"" for x in h), h[-8:]
print("ok:", phase)
PY
mcp() # <phase>: the MCP client's phase; its output in $t/mcp_<phase>.log
{
	python3 -I "$t/mcp.py" "$1" "$url" "$tok" "$adm" "$t" > "$t/mcp_$1.log" 2>&1 ||
		fail "the MCP phase $1: $(tail -5 "$t/mcp_$1.log") ($t/mcp_$1.log, $SL)"
	cat "$t/mcp_$1.log"
}
for p in tools types links play state goals history; do
	mcp $p
done
grep -aqE "kitboss's agent tries entity [0-9]+'s ping null as kitboss \(player:[0-9]+\)" "$SL" ||
	fail "no try as kitboss in $SL"
echo "ok: tools listed by the token; edit_type, a client part kept, a param's default; links by name; try_input as; press; filters; level warnings; history"

# 8. A heightmap's samples restored
# (each map generated in the server's call: its line before the answer)
m=$(mark "$SL")
mcp heightmap
await "$SL" "$m" 10 "heightmap: generated 64x64"
mcp checkpoint
column 10 10; h0=$H
step 10 "kit editor: terrain: raise" "frames 2" \
	'event kit_edit {"op": "terrain", "tool": "raise", "x": 10, "y": 0, "z": 10, "size": 2, "strength": 5, "stroke": 1}'
column 10 10; h1=$H
awk -v a="$h0" -v b="$h1" 'BEGIN { exit !(b > a + 0.5) }' ||
	fail "the raise: $h0 -> $h1 ($CL)"
m=$(mark "$SL")
mcp restore
await "$SL" "$m" 10 "heightmap: generated 64x64"
column 10 10; h2=$H
[ "$h2" = "$h0" ] || fail "restored: the sample at $h2, the checkpoint's $h0 (raised $h1) ($CL)"
m=$(mark "$SL")
mcp back
await "$SL" "$m" 10 "heightmap: generated 64x64"
column 10 10; h3=$H
[ "$h3" = "$h1" ] || fail "restored back: the sample at $h3, not $h1 ($CL)"
echo "ok: the heightmap's sample $h0, raised $h1, restored $h2, back $h3"

cmd "sync 2000" quit
exec 3>&-
wait $CLIENT 2>/dev/null
CLIENT=$SERVER_PID
for k in "${tok#bat_}" "${adm#bat_}"; do
	grep -rqaF "$k" "$t"/*.log && fail "a token in a log"
done
echo "PASS: an agent's tools: hidden by the token, edit_type, put_type keeping the client part, a new param's default, links by name, try_input as nobody/a player/its body, play_input's press, get_state's filters, the level warnings, get_history, a checkpoint's heightmap restored"
