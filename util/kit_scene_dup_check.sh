#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min (2026-11-20)
# covers: builtin/kit/kit.cpp builtin/kit/client_lua/editor.lua builtin/kit/client_lua/editor_input.lua builtin/kit/types/arena.lua builtin/kit/types/ui_scene_list.lua builtin/kit/types/scene_info.lua apps/workbench/templates/brimstone_speedway/** apps/workbench/templates/arena/**
# [KIT_SCENE_DUPLICATE] (kit_plan 4z37u) A scene duplicated, its start moved
# and a part added in the copy, in two templates. Workbench servers one
# after the other on one user dir, each a project made of a template
# (BUILDAT_WORKBENCH_FROM); kitboss (the admin) on a headless weston's
# Xwayland of the check's own (its clipboard carries the agent token):
#   1. Brimstone Speedway, Stopped: a builder token; by MCP the race
#      track's (world's) heightmap raised; the Scenes window's Duplicate
#      world: world_2, kitboss taken there. By MCP: world_2's entities new
#      ids, as many and named as world's; its links and entity parameters
#      among them onto world_2's (the race's mine, its HUD), those onto the
#      root's (the lobby, Retry, the music, the result) as they were, its
#      link by name kept; its kit/scene_info "Race: The Bone Yard
#      (world_2)", listed; the raised ground copied. In world_2 the start
#      spawner moved, a kit/part put by it, the ground lowered: world's
#      spawner, entities and ground as they were. trial duplicated by MCP
#      (trial_2) and undone in one undo. Running: the lobby's scene list
#      (kit/ui_scene_list) lists world_2 by its title.
#   2. Arena, Stopped: a cell put in meadow; meadow duplicated by MCP
#      (meadow_2): the cell there; kit/arena's maps "meadow, dunes,
#      meadow_2" and its status link into meadow_2's status text too. In
#      meadow_2 the red team (its spawn) moved, a kit/part put by it, a cell
#      put: meadow's team, entities and cells as they were. Running:
#      next_map twice, the lobby's status "Next map: meadow_2".
# Screenshot, kept with KEEP_TMP=1: $t/scenes.png (the Scenes window, its
# Duplicate world)
#   util/kit_scene_dup_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
for c in weston xclip zip; do
	command -v $c > /dev/null || skip "no $c"
done
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_scene_dup; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1
check_build
sock=buildat-sdup-$$
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
server() # <project> <template>: a Workbench server of it, its log $SL
{
	SL=$t/$1.log
	# (a confined server reads <user>/shared only)
	mkdir -p "$t/user/shared"
	(cd "$here/apps/workbench/templates/$2" && zip -qrX "$t/user/shared/$1.zip" .) ||
		fail "the template $2 not zipped"
	BUILDAT_WORKBENCH_PROJECT=$1 BUILDAT_WORKBENCH_FROM=$t/user/shared/$1.zip \
		start_server "$SL" "Listening at" 300 auto \
		bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
		--sim-rate "$CHECK_RATE" || fail "the server did not come up ($SL)"
	SRV=$SERVER_PID
	CHECK_PIDS+=($SRV)
	wait_for_log "$SL" "workbench: .*$1" 120 || true
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
url() { echo "http://localhost:$SERVER_PORT/api/v1/mcp"; }
cat > "$t/mcp.py" <<'PY'
import json, re, sys, time, urllib.error, urllib.request
phase, url, tok, out = sys.argv[1:5]
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
def until(f, what, secs=10):
    for i in range(secs * 5):
        v = f()
        if v:
            return v
        time.sleep(0.2)
    raise AssertionError("not in %d s: %s" % (secs, what))
def placed(text):
    return int(re.search(r"placed \S+ (\d+)", text)[1])
def state(**kw):
    return json.loads(call("get_state", kw))
def scene(name, st=False):
    return {e["id"]: e for e in state(scene=name, state=st)["entities"]}
def comp(e, t):
    return next(c for c in e["components"] if c["type"] == t)
def of(es, t, **ps):
    return [e for e in es.values() if any(c["type"] == t and all(
        c.get("params", {}).get(k) == v for k, v in ps.items())
        for c in e["components"])]
def stopped():
    if state(ids=[])["running"]:
        assert call("stop").startswith("Ended")
def ground(at, size):
    return json.loads(call("get_ground", {"at": at, "size": size, "step": 1}))["heights"]
def refs(e, inside):
    """Each link's and entity parameter's target: (what, id) of e"""
    o = []
    for c in e["components"]:
        for l in c.get("links", []):
            o.append(("link " + l["output"], l.get("to", l.get("to_name"))))
        for k, v in c.get("params", {}).items():
            if k in ENTITY_PARAMS.get(c["type"], ()):
                o.append((k, v))
    return o
ENTITY_PARAMS = {}
def entity_params(es):
    for e in es.values():
        for c in e["components"]:
            if c["type"] not in ENTITY_PARAMS:
                ps = json.loads(call("list_types", {"type": c["type"]})).get("params", {})
                ENTITY_PARAMS[c["type"]] = {k for k, p in ps.items() if p.get("type") == "entity"}
def copied(oname, cname):
    """copy is orig with new ids: as many, the same names; each reference
    into orig onto copy's entity of the same place, the rest as they were"""
    oes, ces = scene(oname), scene(cname)
    assert len(oes) == len(ces), (len(oes), len(ces))
    assert not set(oes) & set(ces), "ids shared"
    names = lambda es: sorted(e["name"] for e in es.values() if e.get("kind") != "scene")
    assert names(oes) == names(ces)
    entity_params(oes)
    # (pair them by name and place: the template's names repeat)
    key = lambda e: (e["name"] if e.get("kind") != "scene" else "", json.dumps(e.get("pos")))
    pair = {}
    for o in oes.values():
        c = [x for x in ces.values() if key(x) == key(o) and x["id"] not in pair.values()]
        assert c, ("no copy of", o["name"])
        pair[o["id"]] = c[0]["id"]
    inner = 0
    for oid, cid in pair.items():
        want = [(w, pair[a] if isinstance(a, int) and a in oes else a)
            for w, a in refs(oes[oid], oes)]
        inner += sum(isinstance(a, int) and a in oes for _, a in refs(oes[oid], oes))
        got = refs(ces[cid], ces)
        assert sorted(want, key=str) == sorted(got, key=str), (oes[oid]["name"], want, got)
    return oes, ces, pair, inner
def answer(text):
    return json.loads(text)
rpc("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
    "clientInfo": {"name": "kit_scene_dup_check", "version": "1"}})
if phase == "brim_pre":
    stopped()
    st = state(ids=[])
    assert st["scene"] == "world", st["scene"]
    call("edit_terrain", {"tool": "raise", "area": [-90, -64, -86, -60], "amount": 3})
    json.dump({"raised": ground([-90, -64], [5, 5])}, open(out, "w"))
elif phase == "brim":
    pre = json.load(open(out))
    st = state(ids=[])
    assert "world_2" in json.dumps(st["scenes"]), st["scenes"]
    oes, ces, pair, inner = copied("world", "world_2")
    assert inner > 5, inner
    race = of(oes, "local/brim_race")[0]
    crace = ces[pair[race["id"]]]
    cp = comp(crace, "local/brim_race")["params"]
    # the root's lobby and Retry, the root's music and result, as they were
    assert cp["lobby"] == 7 and cp["retry"] == 1315, cp
    to = {l["output"]: l["to"] for l in comp(crace, "local/brim_race")["links"]}
    assert to["go"] == 780 and to["result"] == 13, to
    assert to["hud"] in ces and cp["mine"] in ces, (to, cp)
    mine = [e for e in ces.values() if e["name"] == "mine (the race's pattern)"][0]
    assert any({"output": "touched", "to_name": "the race", "input": "mine"}.items() <= l.items()
        for c in mine["components"] for l in c.get("links", [])), mine
    info = comp(of(ces, "kit/scene_info")[0], "kit/scene_info")["params"]
    assert info["title"] == "Race: The Bone Yard (world_2)", info
    assert info.get("listed", True), info
    ot = comp(of(oes, "kit/scene_info")[0], "kit/scene_info")["params"]["title"]
    assert ot == "Race: The Bone Yard", ot
    # the copy's ground the original's (st["scene"]: the agent in world)
    call("switch_scene", {"name": "world_2"})
    assert ground([-90, -64], [5, 5]) == pre["raised"], "the raise not copied"
    # In the copy: the start moved, a part by it, the ground lowered
    sp = of(ces, "kit/spawner", players=True)[0]
    osp = of(oes, "kit/spawner", players=True)[0]
    assert sp["pos"] == osp["pos"], (sp, osp)
    np = [sp["pos"][0] + 6, sp["pos"][1], sp["pos"][2] + 4]
    call("move", {"id": sp["id"], "pos": np})
    part = placed(call("place", {"type": "kit/part", "pos": [np[0] + 2, np[1] + 1, np[2]]}))
    call("edit_terrain", {"tool": "lower", "area": [-70, -40, -66, -36], "amount": 2})
    lowered = ground([-70, -40], [5, 5])
    c2 = scene("world_2")
    assert c2[sp["id"]]["pos"] == np and part in c2 and len(c2) == len(ces) + 1
    call("switch_scene", {"name": "world"})
    o2 = scene("world")
    assert o2 == oes, "world changed"
    assert ground([-70, -40], [5, 5]) != lowered, "the copy's lowering in world"
    assert ground([-90, -64], [5, 5]) == pre["raised"]
    # One undo takes a copy back
    r = answer(call("duplicate_scene", {"name": "trial"}))
    assert r["scene"] == "trial_2" and not r["dropped"], r
    assert "trial_2" in json.dumps(state(ids=[])["scenes"])
    call("undo")
    st = state(ids=[])
    assert "trial_2" not in json.dumps(st["scenes"]), st["scenes"]
    assert "no scene named \"trial_2\"" in call("get_state", {"scene": "trial_2"}, True)
    call("switch_scene", {"name": "world"})
    # Players: the lobby's track list, Running
    assert call("start") == "Running"
    def rows():
        v = comp(state(ids=[8])["entities"][0], "kit/ui_scene_list").get("state", {}).get("value")
        return v if v and any(r[2] == "world_2" for r in v) else None
    v = until(rows, "world_2 in the lobby's track list")
    assert ["Race: The Bone Yard (world_2)", "buildat", "world_2"] in v, v
    assert ["Race: The Bone Yard", "buildat", "world"] in v, v
    print("  the track list:", v)
    call("stop")
elif phase == "arena":
    stopped()
    st = state(ids=[])
    call("switch_scene", {"name": "meadow"})
    vt = [v["name"] for v in json.loads(call("list_voxel_types")) if v.get("solid")][0]
    g = ground([0, 0], [1, 1])[0][0]
    cell = [2, int(g) + 4, 3]
    def voxel(at):
        def got():
            r = json.loads(call("get_voxels", {"at": at, "size": [1, 1, 1]}))
            ch = r["layers"][0][0][0] if "layers" in r else None
            return ch if ch and ch != "?" else None
        ch = until(got, "the cell loaded")
        return json.loads(call("get_voxels", {"at": at, "size": [1, 1, 1]}))["key"].get(ch, ch)
    voxel(cell)
    call("set_voxels", {"voxel": vt, "at": cell})
    until(lambda: voxel(cell) == vt, "the cell set")
    r = answer(call("duplicate_scene", {"name": "meadow"}))
    assert r["scene"] == "meadow_2" and not r["dropped"] and not r["unlisted"], r
    assert state(ids=[])["scene"] == "meadow_2"
    oes, ces, pair, inner = copied("meadow", "meadow_2")
    assert inner >= 4, inner
    # the arena: the copy in its maps, its status into the copy's text too
    world = scene("world")
    ar = of(world, "kit/arena")[0]
    ac = comp(ar, "kit/arena")
    assert ac["params"]["maps"] == "meadow, dunes, meadow_2", ac["params"]
    status = [e for e in oes.values() if e["name"] == "the round's status"][0]
    tos = [l["to"] for l in ac["links"] if l["output"] == "status"]
    assert status["id"] in tos and pair[status["id"]] in tos, (tos, status["id"])
    assert voxel(cell) == vt, "the cell not copied"
    # In the copy: the red team (its spawn) moved, a part by it, a cell
    red = [e for e in ces.values() if e["name"] == "red team"][0]
    np = [red["pos"][0] + 5, red["pos"][1], red["pos"][2] + 3]
    call("move", {"id": red["id"], "pos": np})
    part = placed(call("place", {"type": "kit/part", "pos": [np[0] + 2, np[1] + 1, np[2]]}))
    cell2 = [cell[0] + 2, cell[1], cell[2]]
    voxel(cell2)
    call("set_voxels", {"voxel": vt, "at": cell2})
    until(lambda: voxel(cell2) == vt, "the copy's cell set")
    c2 = scene("meadow_2")
    assert c2[red["id"]]["pos"] == np and part in c2 and len(c2) == len(ces) + 1
    call("switch_scene", {"name": "meadow"})
    assert scene("meadow") == oes, "meadow changed"
    assert voxel(cell2) != vt and voxel(cell) == vt
    # Players: the rotation reaches meadow_2 (the arena in world, the lobby)
    call("switch_scene", {"name": "world"})
    assert call("start") == "Running"
    def status_of():
        return comp(state(ids=[ar["id"]])["entities"][0], "kit/arena").get("state", {}).get("status", "")
    until(lambda: "Next map: meadow" in status_of(), "the lobby's next map")
    for k in range(2):
        call("try_input", {"id": ar["id"], "input": "next_map"})
    s = until(lambda: "Next map: meadow_2" in status_of() and status_of(), "meadow_2 next")
    print("  the arena's status:", s)
    call("stop")
print("ok:", phase)
PY
mcp() # <phase>
{
	python3 -I "$t/mcp.py" "$1" "$(url)" "$tok" "$t/saved.json" > "$t/mcp_$1.log" 2>&1 ||
		fail "the MCP $1 run: $(tail -5 "$t/mcp_$1.log") ($t/mcp_$1.log, $SL)"
	grep -v "^  " "$t/mcp_$1.log"
}

# 1. Brimstone Speedway
server brim brimstone_speedway
wait_for_log "$SL" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$SL" | head -1)
[ -n "$code" ] || fail "no setup code ($SL)"
exec 3>&-
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
cmd "wait_log_any 30000 server window: the page ntfy" "frames 3" 'click Button "Don'"'"'t add"'
await "$CL" 0 30 "kit editor: edit rights: yes"
# (a project from a file opens Stopped in the editor; brim_pre stops it
# otherwise)
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
mcp brim_pre
# The Scenes window's Duplicate (the bar's second list, the first the view's)
cmd "frames 3" 'click DropDownList "▼" 1024 0' "delay 300" "frames 3"
step 10 "kit editor: the Scenes window's rows" 'click Text "Scenes..."'
cmd "frames 5" "screenshot $t/scenes.png"
m=$(mark "$SL") mc=$(mark "$CL")
step 30 "kit editor: Added the scene world_2 \(a copy of world\)" "frames 3" \
	'click Button "Duplicate world"'
await "$SL" "$m" 10 "kitboss adds the scene world_2 \(a copy of world\): [0-9]+ entities, 0 links"
# (taken to the copy)
await "$CL" "$mc" 20 "kit editor: in the scene world_2 "
mcp brim
cmd "quit"
exec 3>&-
wait $CLIENT
CLIENT=
kill -INT $SRV 2>/dev/null
wait $SRV 2>/dev/null

# 2. Arena, the same user dir (the token kept)
server arena arena
mcp arena
kill -INT $SRV 2>/dev/null
wait $SRV 2>/dev/null
echo "PASS: a Brimstone track duplicated by the Scenes window's Duplicate and an arena map by MCP: new ids, links inside onto the copy, outside as they were, the ground and cells copied; the copy's start moved and a part added, the original as it was; the track in the lobby's list by its title, the map in the arena's rotation; a duplicate undone in one undo"
