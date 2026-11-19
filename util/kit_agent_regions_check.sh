#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2.5 min (2026-11-17; about 1 min of it the token's 120 calls a
# minute waited out)
# covers: builtin/kit/kit.cpp builtin/kit/client_lua/editor_input.lua
# [KIT_AGENT_NEXT_2] An agent's bulk edits, marker and sounds through MCP on
# Workbench. kitboss (the admin) makes a builder token on a headless
# weston's Xwayland of the check's own and stays, in edit mode:
#   1. edit_voxels: fill, hollow, replace, copy, paste turned 90, move, each
#      read back with get_voxels; one undo puts the move back; caps and bad
#      arguments refused; a 32^3 fill and replace timed and undone (the
#      server logs each region edit's ms); edit_terrain on a
#      voxel World refused;
#   2. batch: place, rename by {"id_of": 0}, set_comments, edit_voxels as one
#      undo; a bad op in the middle leaves nothing changed (entities, cells,
#      the undo stack); a tool a batch has not and 65 ops refused;
#   3. scatter_prefab: 5 copies in an area (spacing kept, each the same
#      height over get_ground's), 5 along a path, one undo each;
#   4. show: the marker in kitboss's client (its log line), cleared;
#   5. put_sound: a table packed as extensions/blip/blip_gen.lua packs it
#      (luajit's G.pack(G.params(t))), list_sounds' table packed again the
#      same, refusals, delete;
#   6. edit_terrain on a 256x256 heightmap: raise, flatten, smooth read back
#      with get_ground, each one undo; a whole-map raise timed; batch with
#      two terrain ops one undo; the cap refused;
#   7. the token revoked: the marker cleared in kitboss's client.
#   util/kit_agent_regions_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
for c in weston xclip luajit; do
	command -v $c > /dev/null || skip "no $c"
done
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_agent_regions; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_JOIN_PASSWORD=checkpass12
check_build
sock=buildat-regions-$$
weston --backend=headless --xwayland --socket=$sock --width=1100 \
	--height=800 > "$t/weston.log" 2>&1 &
CHECK_PIDS+=($!)
for i in $(seq 50); do
	d=$(grep -ao "xserver listening on display :[0-9]*" "$t/weston.log" | grep -o ":[0-9]*$")
	[ -n "$d" ] && break
	sleep 0.2
done
[ -n "$d" ] || fail "weston's Xwayland ($t/weston.log)"
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
# 0. A builder's token
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
    # (a token's 120 calls a minute: waited out)
    for i in range(40):
        s, b = post(m)
        if s != 429:
            break
        time.sleep(1)
    assert s == 200, (method, s, b)
    return json.loads(b)
def call(name, args={}, error=False):
    # (a token's 120 calls a minute: waited out)
    for i in range(60):
        r = rpc("tools/call", {"name": name, "arguments": args})["result"]
        text = r["content"][0]["text"]
        if not text.startswith("Over 120 calls a minute"):
            break
        time.sleep(1)
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
def saved():
    try:
        return json.load(open(out + "/ids.json"))
    except FileNotFoundError:
        return {}
def save(**kw):
    s = saved()
    s.update(kw)
    json.dump(s, open(out + "/ids.json", "w"))
def edit(args, error=False):
    """edit_voxels, its sections loaded first (called again meanwhile)"""
    def go():
        r = rpc("tools/call", {"name": "edit_voxels", "arguments": args})["result"]
        text = r["content"][0]["text"]
        if r["isError"] and ("call again in a moment" in text or
                text.startswith("Over 120 calls a minute")):
            return None
        print("  edit_voxels", json.dumps(args)[:200], "->", text[:300])
        assert r["isError"] == error, (args, text)
        return text
    return until(go, "edit_voxels' sections", 30)
def voxels(at, size):
    """The box's cells as voxel names, [y][z][x]; none unloaded"""
    def go():
        v = json.loads(call("get_voxels", {"at": at, "size": size}))
        return None if "not_loaded" in v else v
    v = until(go, "get_voxels' sections", 30)
    return [[[v["key"][c] for c in row] for row in layer] for layer in v["layers"]]
def cells(at, size):
    return [c for layer in voxels(at, size) for row in layer for c in row]
def ground(at, size=(1, 1)):
    return json.loads(call("get_ground", {"at": list(at), "size": list(size)}))["heights"]
def history():
    return [x["what"] for x in json.loads(call("get_history", {"limit": 20}))]
init = {"protocolVersion": "2025-11-25", "capabilities": {},
        "clientInfo": {"name": "kit_agent_regions_check", "version": "1"}}
rpc("initialize", init)
s = saved()
if phase == "voxels":
    r = rpc("initialize", init)["result"]
    assert len(r["instructions"]) < 4096, len(r["instructions"])
    print("  instructions: %d characters" % len(r["instructions"]))
    if state(ids=[])["running"]:
        call("stop")
    top = ground((0, 0))[0][0]
    V = [v["name"] for v in json.loads(call("list_voxel_types"))
        if v.get("solid") and v.get("kind", "solid") == "solid" and ":" not in v["name"]]
    v1, v2 = V[0], V[1]
    A = [0, top + 3, 0]
    # (1) fill, hollow, replace
    assert "(60 cells): " in edit({"action": "fill", "at": A, "size": [5, 3, 4],
        "voxel": v1})
    assert set(cells(A, [5, 3, 4])) == {v1}
    edit({"action": "hollow", "at": A, "size": [5, 3, 4]})
    c = voxels(A, [5, 3, 4])
    assert c[1][1][1:4] == ["air"] * 3 and c[1][2][1:4] == ["air"] * 3, c
    assert c[0][0] == [v1] * 5 and c[1][0][0] == v1 and c[2][3] == [v1] * 5, c
    edit({"action": "replace", "at": A, "size": [5, 3, 4], "voxel": v1, "with": v2})
    assert set(cells(A, [5, 3, 4])) == {v2, "air"}
    # copy, paste turned 90 (the 5 x 4 box 4 x 5 there), move it
    assert "copied the box [5, 3, 4]" in edit({"action": "copy", "at": A, "size": [5, 3, 4]})
    B = [10, top + 3, 0]
    edit({"action": "paste", "at": B, "turn": 90})
    pb = voxels(B, [4, 3, 5])
    assert pb[1][1][1:3] == ["air"] * 2 and pb[1][0] == [v2] * 4 and pb[0][4] == [v2] * 4, pb
    C = [10, top + 3, 10]
    edit({"action": "move", "at": B, "size": [4, 3, 5], "to": C})
    assert set(cells(B, [4, 3, 5])) == {"air"} and voxels(C, [4, 3, 5]) == pb
    # one undo: the move back
    assert "Undone" in call("undo")
    assert voxels(B, [4, 3, 5]) == pb and set(cells(C, [4, 3, 5])) == {"air"}
    # caps and bad arguments
    assert "size: three whole numbers 1...32" in edit({"action": "fill", "at": A,
        "size": [33, 1, 1], "voxel": v1}, True)
    assert "action: fill, hollow" in edit({"action": "explode", "at": A, "size": [1, 1, 1]}, True)
    assert "is not one of the scene's voxels" in edit({"action": "fill", "at": A,
        "size": [1, 1, 1], "voxel": "nope"}, True)
    assert "turn: a multiple of 90" in edit({"action": "paste", "at": B, "turn": 45}, True)
    assert "a voxel World: edit_voxels" in refused("edit_terrain", {"tool": "raise",
        "area": [0, 0, 4, 4]})
    # the largest box, over the ground there, timed (with its sections'
    # loads: the call that writes it)
    # (in the World's map, its corner)
    mp = json.loads(call("get_ground", {"at": [0, 0], "size": [1, 1]})).get("map",
        [-200, -200, 400, 400])
    assert mp[2] >= 32 and mp[3] >= 32, mp
    hi = max(h for row in ground(mp[:2], (32, 32)) for h in row if h is not None)
    D = [mp[0], hi + 16, mp[1]]
    t0 = time.time()
    r = edit({"action": "fill", "at": D, "size": [32, 32, 32], "voxel": v1})
    print("  fill 32^3: %.0f ms (from the first call)" % ((time.time() - t0) * 1000))
    assert "(32768 cells): 32768 cells written" in r, r
    assert set(cells([D[0], D[1] + 31, D[2]], [32, 1, 32])) == {v1}
    # (its sections there: the write alone)
    t0 = time.time()
    edit({"action": "replace", "at": D, "size": [32, 32, 32], "voxel": v1, "with": v2})
    print("  replace 32^3: %.0f ms" % ((time.time() - t0) * 1000))
    for k in range(2):
        t0 = time.time()
        call("undo")
        print("  an undo: %.0f ms" % ((time.time() - t0) * 1000))
    assert set(cells([D[0], D[1] + 31, D[2]], [32, 1, 32])) == {"air"}
    save(top=top, v1=v1, v2=v2, A=A, B=B)
elif phase == "batch":
    top, v1, A = s["top"], s["v1"], s["A"]
    E = [0, top + 8, 0]
    n0 = len(state(type="kit/counter")["entities"])
    r = call("batch", {"ops": [
        {"tool": "place", "args": {"type": "kit/counter", "pos": [3, top + 1, -6]}},
        {"tool": "rename", "args": {"id": {"id_of": 0}, "name": "bc"}},
        {"tool": "set_comments", "args": {"id": {"id_of": 0}, "text": "batched"}},
        {"tool": "edit_voxels", "args": {"action": "fill", "at": E, "size": [2, 1, 2], "voxel": v1}}]})
    assert r.startswith("batch of 4 edits, one undo:"), r
    bc = [e for e in state(type="kit/counter")["entities"] if e.get("name") == "bc"]
    assert len(bc) == 1 and set(cells(E, [2, 1, 2])) == {v1}, bc
    assert "batch of 4 edits" in history()[-1], history()[-3:]
    call("undo")
    assert len(state(type="kit/counter")["entities"]) == n0
    assert set(cells(E, [2, 1, 2])) == {"air"}
    # A bad op in the middle: nothing changed, the undo stack as it was
    edit({"action": "fill", "at": [0, top + 9, 0], "size": [1, 1, 1], "voxel": v1})
    u0 = state(ids=[])["undo"]
    r = refused("batch", {"ops": [
        {"tool": "place", "args": {"type": "kit/counter", "pos": [3, top + 1, -6]}},
        {"tool": "edit_voxels", "args": {"action": "fill", "at": E, "size": [2, 1, 2], "voxel": v1}},
        {"tool": "set_param", "args": {"id": 99999999, "comp": 0, "param": "x", "value": 1}},
        {"tool": "place", "args": {"type": "kit/counter", "pos": [4, top + 1, -6]}}]})
    assert r.startswith("Refused: op 2 (set_param) refused: ") and "nothing changed" in r, r
    assert len(state(type="kit/counter")["entities"]) == n0
    assert set(cells(E, [2, 1, 2])) == {"air"} and state(ids=[])["undo"] == u0
    call("undo")
    assert cells([0, top + 9, 0], [1, 1, 1]) == ["air"]
    # Refused before anything runs
    assert "a batch has no start" in refused("batch", {"ops": [{"tool": "start"}]})
    assert "ops: a list of 1 to 64" in refused("batch", {"ops": [{"tool": "undo"}] * 65})
    assert "op 1: {\"id_of\": k}: k an op before this one" in refused("batch", {"ops": [
        {"tool": "place", "args": {"type": "kit/counter", "pos": [0, 0, 0]}},
        {"tool": "rename", "args": {"id": {"id_of": 1}, "name": "x"}}]})
    assert "rename needs id" in refused("batch", {"ops": [{"tool": "rename", "args": {"name": "x"}}]})
    assert "write up to 65536 cells" in refused("batch", {"ops": [
        {"tool": "edit_voxels", "args": {"action": "fill", "at": E, "size": [32, 32, 32], "voxel": v1}}] * 2})
    assert len(state(type="kit/counter")["entities"]) == n0
elif phase == "scatter":
    top = s["top"]
    P = placed(call("place", {"type": "kit/counter", "pos": [-30, top + 0.5, -30]}))
    call("save_prefab", {"ids": [P], "name": "post"})
    call("delete", {"id": P})
    # (each copy's root, where it was placed: its members are under it)
    def posts():
        return state(type="kit/prefab_copy")["entities"]
    ids0 = {e["id"] for e in posts()}
    n0 = len(ids0)
    def news():
        return [e for e in posts() if e["id"] not in ids0]
    r = call("scatter_prefab", {"prefab": "kitboss/post", "area": [-20, -20, 20, 20],
        "count": 5, "spacing": 6, "seed": 7})
    assert r.startswith("scatter_prefab kitboss/post: 5 copies, one undo:"), r
    new = news()
    assert len(new) == 5, new
    xz = [(e["pos"][0], e["pos"][2]) for e in new]
    assert all((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2 >= 36 for i, a in enumerate(xz)
        for b in xz[i + 1:]), xz
    up = {round(e["pos"][1] - ground((round(e["pos"][0]), round(e["pos"][2])))[0][0], 2)
        for e in new}
    assert len(up) == 1 and 0 <= up.pop() <= 2, new
    call("undo")
    assert len(posts()) == n0
    r = call("scatter_prefab", {"prefab": "kitboss/post", "path": [[0, 0, -20], [20, 0, -20]],
        "spacing": 5, "turn": "random"})
    new = news()
    assert len(new) == 5 and sorted(e["pos"][0] for e in new) == [0, 5, 10, 15, 20], new
    call("undo")
    assert "no prefab \"nope\"" in refused("scatter_prefab", {"prefab": "nope", "area": [0, 0, 1, 1]})
    assert "area or path, one of them" in refused("scatter_prefab", {"prefab": "kitboss/post"})
    assert "count: 1 to 64" in refused("scatter_prefab", {"prefab": "kitboss/post",
        "area": [0, 0, 9, 9], "count": 65})
elif phase == "show":
    top = s["top"]
    r = call("show", {"at": [1, top + 1, 2], "box": [0, top, 0, 4, top + 2, 3],
        "label": "the porch"})
    assert r.startswith("Shown in 1 client(s) of kitboss's"), r
elif phase == "unshow":
    assert call("show").startswith("Cleared in 1 client(s)")
    assert "ids: no entity 99999999" in refused("show", {"ids": [99999999]})
    assert "label: 80 bytes at most" in refused("show", {"label": "x" * 81})
elif phase == "reshow":
    call("show", {"at": [0, 0, 0]})
elif phase == "sound":
    T = json.load(open(out + "/sound.json"))
    r = call("put_sound", {"name": "zap", "sound": T})
    m = re.match(r"made sound kitboss/zap version 1: (blip1:\S+)$", r)
    assert m, r
    open(out + "/packed.txt", "w").write(m.group(1))
    l = [x for x in json.loads(call("list_sounds")) if x["name"] == "kitboss/zap"]
    assert len(l) == 1 and l[0]["version"] == 1 and l[0]["params"] == m.group(1), l
    tb = json.loads(call("list_sounds", {"sound": "kitboss/zap"}))
    assert tb["wave"] == "saw" and tb["seed"] == 42 and len(tb["layers"]) == 1, tb
    r = call("put_sound", {"name": "kitboss/zap", "sound": tb})
    assert r == "made sound kitboss/zap version 2: " + m.group(1), r
    assert "wave: square, saw" in refused("put_sound", {"name": "z2", "sound": {"wave": "bogus"}})
    assert "no parameter nope" in refused("put_sound", {"name": "z2", "sound": {"nope": 1}})
    assert "not blip1's compact form" in refused("put_sound", {"name": "z2", "sound": "blip1:xyz"})
    assert "layers: a list of 15 at most" in refused("put_sound", {"name": "z2",
        "sound": {"layers": [{}] * 16}})
    assert "is Kit's" in refused("put_sound", {"name": "kit/click", "sound": m.group(1)})
    assert "made sound kitboss/zap version 2" in history()[-1]
elif phase == "unsound":
    assert call("put_sound", {"name": "kitboss/zap", "delete": True}) == "deleted sound kitboss/zap"
    assert not [x for x in json.loads(call("list_sounds")) if x["name"] == "kitboss/zap"]
elif phase == "heightmap":
    if state(ids=[])["running"]:
        call("stop")
    call("place", {"type": "kit/terrain", "pos": [0, 1, 0], "params": {"biome": "grassland",
        "generator": "noise", "height": 3, "level": 3, "surface": "heightmap",
        "width": 256, "depth": 256}})
elif phase == "terrain":
    def area(a, s=5):
        return [h for row in ground((a[0], a[1]), (s, s)) for h in row]
    h0 = area((4, 4))
    r = call("edit_terrain", {"tool": "raise", "area": [4, 4, 8, 8], "amount": 2})
    assert r.startswith("raise (4,4) to (8,8) by 2 on the heightmap: 25 samples"), r
    h1 = area((4, 4))
    assert all(abs(b - a - 2) < 0.02 for a, b in zip(h0, h1)), (h0, h1)
    call("edit_terrain", {"tool": "flatten", "area": [4, 4, 8, 8], "level": 5})
    assert set(area((4, 4))) == {5}
    rim = area((3, 3), 7)
    call("edit_terrain", {"tool": "smooth", "area": [3, 3, 9, 9], "strength": 4})
    sm = area((3, 3), 7)
    assert sm != rim and sm[3 * 7 + 3] == 5, (rim, sm)
    call("undo")
    assert area((3, 3), 7) == rim
    call("undo")
    assert area((4, 4)) == h1
    call("undo")
    assert area((4, 4)) == h0
    # batch: two terrain ops, one undo
    call("batch", {"ops": [
        {"tool": "edit_terrain", "args": {"tool": "raise", "area": [4, 4, 8, 8], "amount": 3}},
        {"tool": "edit_terrain", "args": {"tool": "lower", "area": [6, 6, 8, 8]}}]})
    h2 = area((4, 4))
    assert abs(h2[0] - h0[0] - 3) < 0.02 and abs(h2[24] - h0[24] - 2) < 0.02, (h0, h2)
    call("undo")
    assert area((4, 4)) == h0
    # the whole map, timed; the cap
    t0 = time.time()
    r = call("edit_terrain", {"tool": "raise", "area": [-128, -128, 127, 127]})
    print("  raise 256x256: %.0f ms" % ((time.time() - t0) * 1000))
    assert "65536 samples" in r, r
    t0 = time.time()
    call("undo")
    print("  its undo: %.0f ms" % ((time.time() - t0) * 1000))
    assert area((4, 4)) == h0
    assert "256 cells a side at most" in refused("edit_terrain", {"tool": "raise",
        "area": [0, 0, 256, 0]})
    assert "area: a heightmap's raise, lower, flatten or smooth" in refused("edit_terrain",
        {"tool": "paint", "area": [0, 0, 1, 1]})
print("ok:", phase)
PY
mcp() # <phase>: the MCP client's phase; its output in $t/mcp_<phase>.log
{
	python3 -I "$t/mcp.py" "$1" "$url" "$tok" "$t" > "$t/mcp_$1.log" 2>&1 ||
		fail "the MCP phase $1: $(tail -5 "$t/mcp_$1.log") ($t/mcp_$1.log, $SL)"
	cat "$t/mcp_$1.log"
}
for p in voxels batch scatter; do
	mcp $p
done
echo "ok: edit_voxels, batch, scatter_prefab"

# 4. The marker in kitboss's client
m=$(mark "$CL")
mcp show
await "$CL" "$m" 10 "kit: agent marker from kitboss's agent: at [-0-9]+,[-0-9]+,2 box .* label the porch"
m=$(mark "$CL")
mcp unshow
await "$CL" "$m" 10 "kit: agent marker from kitboss's agent cleared"
echo "ok: the marker shown and cleared in kitboss's client"

# 5. A sound: the same compact form as blip_gen.lua's
cat > "$t/sound.json" <<'EOF'
{"wave": "saw", "seed": 42, "base_freq": 0.55, "freq_ramp": -0.3,
 "env_decay": 0.2, "crackle": 0.3, "volume": 2,
 "layers": [{"at": 0.05, "wave": "sine", "base_freq": 0.3, "duty_ramp": -1}]}
EOF
cat > "$t/sound.lua" <<'EOF'
local G = dofile(arg[1])
io.write(G.pack(G.params({wave = "saw", seed = 42, base_freq = 0.55,
	freq_ramp = -0.3, env_decay = 0.2, crackle = 0.3, volume = 2,
	layers = {{at = 0.05, wave = "sine", base_freq = 0.3, duty_ramp = -1}}})))
EOF
mcp sound
want=$(luajit "$t/sound.lua" "$here/extensions/blip/blip_gen.lua") ||
	fail "luajit's blip_gen.lua"
[ "$(cat "$t/packed.txt")" = "$want" ] ||
	fail "put_sound packed $(cat "$t/packed.txt"), blip_gen.lua $want"
grep -aq "kitboss's agent made sound kitboss/zap version 1: $want" "$SL" ||
	fail "no sound made in $SL"
mcp unsound
echo "ok: put_sound's $want as blip_gen.lua packs it"

# 6. A heightmap's ground
m=$(mark "$SL")
mcp heightmap
await "$SL" "$m" 20 "heightmap: generated 256x256"
mcp terrain
echo "ok: edit_terrain"

# 7. Revoked on the page: the marker gone with the agent
mcp reshow
step 10 "pause: the menu shown" "keypress Escape"
step 10 "accounts: agents: 1 tokens, on" "frames 3" 'click Button "My account*"' \
	"frames 5" 'click Button "Connect an agent..."'
m=$(mark "$CL")
cmd "frames 3" 'click Button "Revoke My agent"'
await "$CL" "$m" 10 "kit: agent marker from kitboss's agent cleared"
grep -aq "kitboss's agent left: its token was revoked" "$SL" || fail "not revoked ($SL)"
echo "ok: the marker cleared as the agent left"

cmd "sync 2000" quit
exec 3>&-
wait $CLIENT 2>/dev/null
CLIENT=$SERVER_PID
grep -rqaF "${tok#bat_}" "$t"/*.log && fail "a token in a log"
echo "PASS: an agent's edit_voxels, edit_terrain, scatter_prefab, batch (all or nothing, one undo), its marker in the builder's client and its sounds"
