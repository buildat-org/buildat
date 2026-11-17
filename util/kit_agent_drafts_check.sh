#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~3 min (2026-11-17)
# covers: builtin/kit/kit.cpp builtin/kit/types/bot.lua builtin/kit/types/goal.lua builtin/kit/types/spawner.lua
# [KIT_AGENT_NEXT_1] 2, 3b: an agent's sandbox and playtests, through MCP.
# One Workbench server, its camera on a headless weston's Xwayland of the
# check's own; kitboss (the admin) makes a builder token and leaves. The
# main round Stopped first:
#   1. draft: get_state's session a draft; a magenta part and 4 voxels
#      there, the camera's picture of it magenta; get_state main: true (the
#      main round's) without the part, diff: the part added, 4 cells in one
#      area; start in the draft its round again; leave_draft: the main
#      round's state, its voxels and its picture as before;
#   2. publish: refused with a goal warning, done without it; the main
#      round's state has the part, diff none; after leave_draft the main
#      round's picture magenta, its voxels set;
#   3. checkpoints: one of the start; a part and voxels; diff against it;
#      restore refused from a draft and Running; restore: the part and
#      voxels gone, "before restore cp1" kept, its diff the other way; the
#      count cap (BUILDAT_CHECKPOINT_CAPS 4 here) and the bytes cap (20000)
#      refused, a name replaced and deleted;
#   4. playtest: refused outside a draft and for a Running main round; a
#      course in a draft: two lanes from a spawner of players (spread 4)
#      to one reach goal, lane B cut by a pit; 2 bots for 20 s: the report
#      has lane A's bot finished, lane B's stuck at the pit, no goal
#      warnings; meanwhile a second playtest and start refused; after it
#      the draft at its start (the spawner's joins 0);
#   5. a draft left unused ends at the agent's idle time
#      (BUILDAT_AGENT_IDLE_S 15 here), not before; the agent back in the
#      main round;
#   6. the server stopped: its camera gone with it.
# Pictures and the playtest's report, kept with KEEP_TMP=1: $t/*.png,
# $t/report.json
#   util/kit_agent_drafts_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
for c in weston xclip; do
	command -v $c > /dev/null || skip "no $c"
done
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_agent_drafts; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_JOIN_PASSWORD=checkpass12
export BUILDAT_STARPORT_DEFAULT=https://127.0.0.1:9 BUILDAT_AITTA_DEFAULT=https://127.0.0.1:9 \
	BUILDAT_HEARTH_DEFAULT=https://127.0.0.1:9 SDL_VIDEO_X11_XRANDR=0
IDLE=15
check_build
sock=buildat-drafts-$$
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
menu() # Escape until the pause menu is up
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

BUILDAT_AGENT_IDLE_S=$IDLE BUILDAT_CHECKPOINT_CAPS="4 20000" \
	start_server "$SL" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
	--sim-rate "$CHECK_RATE" --camera-display "$d" ||
	fail "the server did not come up ($SL)"
CHECK_PIDS+=($SERVER_PID)
CLIENT=$SERVER_PID
url=http://localhost:$SERVER_PORT/api/v1/mcp

cat > "$t/mcp.py" <<'PY'
import base64, json, re, struct, sys, time, urllib.error, urllib.request, zlib
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
    # (a builder token's 120 calls a minute: waited out)
    for i in range(40):
        s, b = post(m)
        if s != 429:
            break
        time.sleep(1)
    assert s == 200, (method, s, b)
    return json.loads(b)
def tool(name, args):
    r = rpc("tools/call", {"name": name, "arguments": args})["result"]
    return r
def call(name, args={}, error=False):
    r = tool(name, args)
    c = r["content"]
    assert c[0]["type"] == "text", (name, str(r)[:500])
    assert r["isError"] == error, (name, args, str(r)[:1500])
    print(" ", name, json.dumps(args)[:200], "->", c[0]["text"][:400])
    return c[0]["text"], [base64.b64decode(x["data"]) for x in c[1:]]
def text(name, args={}):
    return call(name, args)[0]
def refused(name, args={}):
    return call(name, args, True)[0]
def js(name, args={}):
    return json.loads(text(name, args))
def decode(b):
    """A PNG's (w, h, px): px(x, y) its (r, g, b); 8-bit RGB or RGBA"""
    assert b[:8] == b"\x89PNG\r\n\x1a\n", b[:16]
    i, idat = 8, b""
    while i < len(b):
        ln, typ = struct.unpack(">I4s", b[i:i + 8])
        body = b[i + 8:i + 8 + ln]
        i += 12 + ln
        if typ == b"IHDR":
            w, h, depth, ct = struct.unpack(">IIBB", body[:10])
        elif typ == b"IDAT":
            idat += body
    assert depth == 8 and ct in (2, 6), (depth, ct)
    bpp = 3 if ct == 2 else 4
    raw, stride, rows, p = zlib.decompress(idat), w * bpp, [], 0
    prev = bytearray(stride)
    for y in range(h):
        f, line = raw[p], bytearray(raw[p + 1:p + 1 + stride])
        p += 1 + stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            c = prev[x - bpp] if x >= bpp else 0
            u = prev[x]
            if f == 1:
                line[x] = (line[x] + a) & 255
            elif f == 2:
                line[x] = (line[x] + u) & 255
            elif f == 3:
                line[x] = (line[x] + (a + u) // 2) & 255
            elif f == 4:
                pa, pb, pc = abs(u - c), abs(a - c), abs(a + u - 2 * c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else
                    u if pb <= pc else c)) & 255
        rows.append(line)
        prev = line
    return w, h, lambda x, y: tuple(rows[y][x * bpp:x * bpp + 3])
def mag(img):
    """The 5x5 in the middle mostly magenta"""
    w, h, px = img
    x0, y0, k = w // 2, h // 2, 0
    for y in range(y0 - 2, y0 + 3):
        for x in range(x0 - 2, x0 + 3):
            r, g, b = px(x, y)
            k += r > 110 and b > 110 and g < 0.65 * min(r, b)
    return k > 12
# The marker in the sky, the camera 8 before it
M, C = [0, 40, 10], [0, 40, 2]
def view(name):
    """The camera's picture of M (waited for while it starts)"""
    t0 = time.time()
    while True:
        r = tool("get_view", {"pos": C, "look_at": M, "width": 160, "height": 120})
        tx = r["content"][0]["text"]
        if not r["isError"]:
            break
        print("  get_view ->", tx[:200])
        assert "is starting" in tx or "on its way" in tx, tx
        assert time.time() - t0 < 150, "no picture in 150 s"
        time.sleep(0.5)
    png = base64.b64decode(r["content"][1]["data"])
    with open("%s/%s.png" % (out, name), "wb") as f:
        f.write(png)
    print("  get_view ->", tx[:160])
    return decode(png)
def ids(st):
    return {e["id"] for e in st["entities"]}
def placed(tx):
    return int(re.search(r"placed \S+ (\d+)", tx).group(1))
def state():
    try:
        return json.load(open(out + "/state.json"))
    except FileNotFoundError:
        return {}
def save(**kw):
    s = state()
    s.update(kw)
    json.dump(s, open(out + "/state.json", "w"))
def cells(at, size):
    """get_voxels' layers as the voxel names, one a cell"""
    g = js("get_voxels", {"at": at, "size": size})
    return [g["key"].get(ch, ch).replace("air", ".") for layer in g["layers"]
        for row in layer for ch in row]
def wait_cells(box, want):
    """The box's cells as want, once what a restore or publish puts is in"""
    t0 = time.time()
    while cells(**box) != want:
        assert time.time() - t0 < 15, (box, cells(**box), want)
        time.sleep(0.5)
init ={"protocolVersion": "2025-11-25", "capabilities": {},
        "clientInfo": {"name": "kit_agent_drafts_check", "version": "1"}}
ins = rpc("initialize", init)["result"]["instructions"]
V = [v["name"] for v in js("list_voxel_types")
    if v.get("solid") and v.get("kind") == "solid"][0]
BOX = {"at": [2, 30, 2], "size": [2, 1, 2]}
PART = {"type": "kit/part", "pos": M, "params": {"size": [4, 4, 4],
    "color": "#ff00ff", "material": "glow", "collision": False}}
if phase == "draft":
    # The guide's sandbox line, the types still in Claude Code's 4096
    assert len(ins) <= 4096 and "draft" in ins and "kit/counter" in ins, ins
    print("  instructions:", len(ins), "characters")
    text("stop") # (Workbench's world Running from its start)
    st = js("get_state")
    assert st["session"]["kind"] == "main" and st["round"]["state"] == "Ended", st["session"]
    before = ids(st)
    assert not mag(view("main_before"))
    tx = text("draft")
    sid = int(re.search(r"In your draft \(session (\d+)\)", tx).group(1))
    st = js("get_state")
    assert st["session"]["kind"] == "draft" and st["session"]["id"] == sid, st["session"]
    assert ids(st) == before, (ids(st), before)
    assert "already" in refused("draft")
    part = placed(text("place", PART))
    c = cells(**BOX)
    assert c == ["."] * 4, c
    assert "in 4 of 4 cells" in text("set_voxels", dict(BOX, voxel=V))
    assert mag(view("draft"))
    main = js("get_state", {"main": True})
    assert main["session"]["kind"] == "main" and part not in ids(main), main["session"]
    assert part in ids(js("get_state"))
    d = js("diff")
    print("  diff:", json.dumps(d))
    assert [a["id"] for a in d["added"]] == [part], d
    assert d["voxels"]["cells"] == 4 and len(d["voxels"]["areas"]) == 1, d
    a = d["voxels"]["areas"][0]
    assert a["min"] == [2, 30, 2] and a["max"] == [3, 30, 3] and a["cells"] == 4, a
    assert "1 added" in d["summary"] and "4 voxel cells" in d["summary"], d["summary"]
    assert "from its start again" in text("start")
    assert "Back in the main round" in text("leave_draft")
    assert "not in a draft" in refused("leave_draft")
    st = js("get_state")
    assert st["session"]["kind"] == "main" and ids(st) == before, st["session"]
    assert V not in cells(**BOX)
    assert not mag(view("main_after"))
    save(sid=sid)
elif phase == "publish":
    tx = text("draft")
    part = placed(text("place", PART))
    cells(**BOX) # (its section loaded)
    assert "in 4 of 4 cells" in text("set_voxels", dict(BOX, voxel=V))
    goal = placed(text("place", {"type": "kit/goal", "pos": [8, 1, 8]}))
    tx = refused("publish")
    assert "goal warnings" in tx and "anyway" in tx, tx
    text("delete", {"id": goal})
    tx = text("publish")
    assert "Published into the game's start: " in tx, tx
    assert part in ids(js("get_state", {"main": True}))
    d = js("diff")
    for k in ("added", "removed", "moved", "params"):
        assert k not in d, d
    text("leave_draft")
    st = js("get_state")
    assert st["session"]["kind"] == "main" and part in ids(st)
    wait_cells(BOX, [V] * 4)
    assert mag(view("main_published"))
    save(published=part)
elif phase == "checkpoint":
    pub = state()["published"]
    tx = text("checkpoint", {"name": "cp1"})
    assert tx.startswith('Checkpoint "cp1": the game\'s start'), tx
    l = js("list_checkpoints")
    assert [c["name"] for c in l["checkpoints"]] == ["cp1"], l
    assert l["max_checkpoints"] == 4 and l["max_bytes"] == 20000, l
    assert l["checkpoints"][0]["cells"] >= 4, l
    p2 = placed(text("place", {"type": "kit/part", "pos": [0, 30, -6]}))
    B2 = {"at": [4, 30, 4], "size": [2, 1, 2]}
    cells(**B2) # (its section loaded)
    assert "in 4 of 4 cells" in text("set_voxels", dict(B2, voxel=V))
    d = js("diff", {"checkpoint": "cp1"})
    print("  diff:", json.dumps(d))
    assert [a["id"] for a in d["added"]] == [p2] and d["voxels"]["cells"] == 4, d
    assert "no checkpoint" in refused("diff", {"checkpoint": "nope"})
    text("draft")
    assert "in your draft" in refused("restore_checkpoint", {"name": "cp1"})
    text("leave_draft")
    text("start")
    assert "Running" in refused("restore_checkpoint", {"name": "cp1"})
    text("stop")
    t0 = time.time()
    while True:
        r = tool("restore_checkpoint", {"name": "cp1"})
        tx = r["content"][0]["text"]
        if not r["isError"] or "wait for their load" not in tx:
            break
        assert time.time() - t0 < 30, tx
        time.sleep(0.5)
    print("  restore_checkpoint ->", tx)
    assert not r["isError"] and "is the game's start again" in tx, tx
    assert '"before restore cp1"' in tx, tx
    st = js("get_state")
    assert p2 not in ids(st) and pub in ids(st), ids(st)
    wait_cells(B2, ["."] * 4)
    wait_cells(BOX, [V] * 4)
    l = js("list_checkpoints")
    assert sorted(c["name"] for c in l["checkpoints"]) == ["before restore cp1", "cp1"], l
    d = js("diff", {"checkpoint": "before restore cp1"})
    assert [a["id"] for a in d["removed"]] == [p2] and d["voxels"]["cells"] == 4, d
    # The caps: 4 a game here, 20000 bytes
    text("checkpoint", {"name": "cp2"})
    text("checkpoint", {"name": "cp3"})
    assert "4 checkpoints a game at most" in refused("checkpoint", {"name": "cp4"})
    text("checkpoint", {"name": "cp3"})
    assert len(js("list_checkpoints")["checkpoints"]) == 4
    assert "deleted" in text("checkpoint", {"name": "cp3", "delete": True})
    assert "deleted" in text("checkpoint", {"name": "cp2", "delete": True})
    assert "1 to 64 bytes" in refused("checkpoint", {"name": ""})
    assert "1 to 64 bytes" in refused("checkpoint", {"name": "x" * 65})
    big = []
    for i in range(5):
        big.append(placed(text("place", {"type": "kit/part", "pos": [i * 2, 30, -10]})))
        text("set_comments", {"id": big[-1], "text": "%d" % i * 4096})
    tx = refused("checkpoint", {"name": "big"})
    assert "20000 bytes at most" in tx, tx
    for b in big:
        text("delete", {"id": b})
    l = js("list_checkpoints")
    assert len(l["checkpoints"]) == 2 and l["bytes"] < 20000, l
elif phase == "playtest":
    assert "not in a draft" in refused("playtest")
    text("start")
    assert "Running" in refused("playtest", {"main": True})
    text("stop")
    sid = int(re.search(r"session (\d+)", text("draft")).group(1))
    # Two lanes along +x from the spawner (bots at z 0 and 4), a wall
    # between, lane B cut by a pit (x 8 to 10); the goal over both ends
    cells([-2, 20, -1], [23, 3, 7])
    for at, size in (([-2, 20, -1], [23, 1, 3]), ([-2, 20, 2], [23, 3, 1]),
            ([-2, 20, 3], [10, 1, 3]), ([11, 20, 3], [10, 1, 3])):
        n = size[0] * size[1] * size[2]
        assert "in %d of %d cells" % (n, n) in text("set_voxels",
            {"voxel": V, "at": at, "size": size})
    sp = placed(text("place", {"type": "kit/spawner", "pos": [0, 21, 0],
        "params": {"players": True, "spread": 4}}))
    placed(text("place", {"type": "kit/goal", "pos": [16, 21, -1],
        "params": {"size": [5, 2, 7], "autostart": True, "text": "The end"}}))
    assert "1 to 8" in refused("playtest", {"bots": 9})
    assert "5 to 120" in refused("playtest", {"seconds": 200})
    assert "No playtest yet" in refused("playtest_report")
    tx = text("playtest", {"bots": 2, "seconds": 30})
    assert tx.startswith("Playtest: 2 bots in your draft"), tx
    assert "a playtest runs" in refused("playtest")
    assert "a playtest runs" in refused("start")
    t0 = time.time()
    while True:
        r = js("playtest_report")
        if r["state"] == "done":
            break
        assert time.time() - t0 < 120, r
        time.sleep(1)
    with open(out + "/report.json", "w") as f:
        json.dump(r, f, indent=1)
    print("  report:", json.dumps(r))
    assert r["where"] == "a draft (session %d)" % sid, r
    assert r["ended"] == "after its 30 s, the world back at its start", r
    assert r["goal_warnings"] == [], r
    done = [b for b in r["bots"] if b["finished"] is not None]
    left = [b for b in r["bots"] if b["finished"] is None]
    assert len(done) == 1 and len(left) == 1, r
    assert done[0]["at"][2] < 2 and done[0]["at"][0] >= 15, done
    assert left[0]["at"][2] > 2 and left[0]["at"][0] < 12, left
    assert left[0]["outcome"].startswith("not there, on goal "), left
    spots = [s for s in r["stuck_spots"] if 4 <= s["at"][0] <= 12 and
        2 <= s["at"][2] <= 7 and left[0]["name"] in s["bots"]]
    assert spots or left[0]["deaths"], r
    assert "1 of 2 bots finished" in r["summary"], r["summary"]
    # Its draft from its start again: the spawner's joins
    st = js("get_state")
    sc = [e for e in st["entities"] if e["id"] == sp][0]["components"][0]
    assert sc.get("state", {}).get("joins", 0) == 0, sc
    text("leave_draft")
elif phase == "idle":
    sid = int(re.search(r"session (\d+)", text("draft")).group(1))
    save(idle_sid=sid)
elif phase == "after_idle":
    assert js("get_state")["session"]["kind"] == "main"
print("ok:", phase)
PY
mcp() # <phase>: the MCP client's phase; its output in $t/mcp_<phase>.log
{
	python3 -I "$t/mcp.py" "$1" "$url" "$tok" "$t" > "$t/mcp_$1.log" 2>&1 ||
		fail "the MCP phase $1: $(tail -5 "$t/mcp_$1.log") ($t/mcp_$1.log, $SL)"
	cat "$t/mcp_$1.log"
}

# 0. kitboss's builder token, kitboss gone
wait_for_log "$SL" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$SL" | head -1)
[ -n "$code" ] || fail "no setup code ($SL)"
mkfifo "$t/boss.cmd"
sleep 900 > "$t/boss.cmd" &
CHECK_PIDS+=($!)
env BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 DISPLAY=$d WAYLAND_DISPLAY= \
	SDL_VIDEODRIVER=x11 BUILDAT_JOIN_NAME=kitboss \
	timeout 600 bin/buildat -C "$t/client_cache_boss" -D "$t/cu_boss" \
	-s localhost:$SERVER_PORT -w 1024x700 -l 3 -o sound_mute=1 -c - \
	< "$t/boss.cmd" > "$CL" 2>&1 &
BOSS=$! CLIENT=$!
CHECK_PIDS+=($BOSS)
exec 3> "$t/boss.cmd"
await "$CL" 0 120 "Joined as kitboss"
cmd "wait_log_any 30000 server window: the page ntfy" "frames 3" 'click Button "Don'"'"'t add"'
await "$CL" 0 120 "player physics enabled"
menu
step 10 "accounts: agents: 0 tokens, on" "frames 3" 'click Button "My account*"' \
	"frames 5" 'click Button "Connect an agent..."'
step 10 "accounts: agents: a token made, builder" "frames 3" \
	'click Button "Make a token..."' "frames 3" 'click Button "Make a token"'
step 10 "accounts: agents: the token copied" "frames 3" 'click Button "copy token"'
for i in $(seq 50); do
	tok=$(DISPLAY=$d xclip -selection clipboard -o 2>/dev/null)
	[[ $tok =~ ^bat_[0-9a-f]{64}$ ]] && break
	sleep 0.2
done
[[ $tok =~ ^bat_[0-9a-f]{64}$ ]] || fail "kitboss's builder token: $tok"
cmd "frames 3" 'click Button "Done"' "sync 2000" quit
exec 3>&-
wait $BOSS 2>/dev/null
CLIENT=$SERVER_PID
await "$SL" 0 10 "workbench: kitboss left"
echo "ok: kitboss's builder token, kitboss gone"

# 1. A draft: edits there, the main round as it was
m=$(mark "$SL")
mcp draft
sid=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["sid"])' "$t/state.json")
await "$SL" "$m" 5 "Session $sid ended by kitboss's agent"
echo "ok: a draft's edits and picture, the main round's state, voxels and picture as before; diff; left"

# 2. Publish
mcp publish
echo "ok: publish refused with a goal warning, done; the main round has it"

# 3. Checkpoints
mcp checkpoint
grep -aq "kitboss's agent restores checkpoint \"cp1\"" "$SL" || fail "no restore logged ($SL)"
echo "ok: checkpoint, diff, restore (refused from a draft and Running), before restore kept, the caps"

# 4. A playtest
mcp playtest
echo "ok: a playtest: a finish, a stuck spot at the pit, the draft at its start after"

# 5. Idle: the draft ends at the agent's idle time, not before
m=$(mark "$SL")
mcp idle
t0=$(date +%s)
sid=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["idle_sid"])' "$t/state.json")
await "$SL" "$m" $((IDLE + 15)) "Session $sid ended by kitboss's agent \(idle\)"
el=$(($(date +%s) - t0))
[ $el -ge $((IDLE - 2)) ] || fail "the draft ended after $el s, before the idle time $IDLE"
mcp after_idle
echo "ok: the unused draft ended after $el s (idle $IDLE s)"

# 6. The server stopped: its camera too
CP=$(grep -aoE "The server's camera is process [0-9]+" "$SL" | tail -1 | grep -oE "[0-9]+$")
[ -n "$CP" ] || fail "no camera process in $SL"
kill $SERVER_PID
wait $SERVER_PID 2>/dev/null
for i in $(seq 25); do
	kill -0 "$CP" 2>/dev/null || break
	sleep 0.2
done
kill -0 "$CP" 2>/dev/null && fail "the camera (pid $CP) still running after its server"
grep -rqaF "${tok#bat_}" "$t"/*.log && fail "the token in a log"
echo "PASS: an agent's draft (its edits and picture, the main round unchanged, diff, publish), checkpoints (restore, before restore, caps), a playtest (finish, stuck at the pit), the draft's idle end; report $t/report.json"
