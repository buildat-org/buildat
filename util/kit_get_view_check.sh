#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min (2026-11-16)
# covers: extensions/weave/** builtin/voxelworld/client_lua/module.lua builtin/kit/kit.cpp builtin/kit/client_lua/module.lua builtin/kit/types/parallax.lua builtin/kit/client_lua/editor.lua builtin/accounts/accounts.cpp builtin/accounts/client_lua/accounts.lua src/client/main.cpp src/client/state.cpp src/lua_bindings/misc_urho3d.cpp client/core/urho3d/init.lua 3rdparty/Urho3D/Source/Urho3D/Graphics/OpenGL/OGLTexture2D.cpp 3rdparty/Urho3D/Source/ThirdParty/SDL/src/video/offscreen/** 3rdparty/Urho3D/Source/ThirdParty/GLEW/glew.c
# [KIT_AGENT_VISUALS] An agent's picture (Kit's get_view) and a client logged
# in by an agent token. One Workbench server; kitboss (the admin) and kitbob
# (made a builder by kitboss's admin token) on a headless weston's Xwayland
# of the check's own (its clipboard carries the tokens):
#   1. kitboss makes a builder token and an admin token, kitbob a builder
#      token (My account, Connect an agent...);
#   2. kitboss's agent places a glowing magenta kit/part and asks for
#      pictures: from a pose looking at it (320x240, magenta in the middle,
#      not in the corners), looking below it (magenta in the top half only:
#      the picture is upright), by yaw 0 (along +z: magenta) and 180 (not),
#      and its own view (512x384 by default); kitboss's window the same
#      before and after (only the notice, "Your agent took a picture", at
#      its top); a scene kitboss is not in, a size past 1024x768 and
#      look_at without pos refused; kitbob's client never asked;
#      [KIT_SIDE_SCENERY] (8) a kit/parallax at follow 0 by place, a part
#      under it by place's parent and one by set_parent (get_state's
#      parent): a pose 40 over draws them in its middle column;
#   2b. [KIT_TEXTURE_DESIGNER] recipe textures by put_texture (a table
#      packed as weave_gen.lua packs it, read back by list_textures and put
#      again; bad ones refused), a voxel type wearing one on its sides and
#      one on its top, set in cells and worn by a kit/polygon: pictures
#      until the cells' top is yellow and the polygon's face green, both
#      clients having made the textures from their names (5b: the web
#      client's pictures of them too);
#   3. kitboss's client stopped (SIGSTOP): the call answered in 5 s, and
#      the picture it sends once continued refused as late;
#   4. a client with no display (no X, no Wayland: SDL's offscreen driver,
#      as the recipe has it): -T with kitboss's builder token
#      refused (kitboss is the Host), the token gone from its command line;
#      BUILDAT_AGENT_TOKEN with kitbob's while kitbob is here refused;
#   5. kitbob's client gone: his agent's get_view refused with the way to
#      run one; kitboss's client not asked; then kitbob's web client
#      (headless Chrome; skipped without it or web/): its pictures magenta
#      and upright as in 2, its window the same, and no WebGL warning
#      ([KIT_GET_VIEW_WEB_BLACK]: "Read buffer is GL_NONE", black);
#   6. the token client as kitbob: joined, on the offscreen driver, its
#      picture served (magenta);
#   7. kitboss revokes his builder token: a client with it refused; Agents
#      (MCP) off: kitbob's token client kicked;
#   8. no token in any log, the clients' user and cache dirs.
# Pictures and screenshots, kept with KEEP_TMP=1: $t/view_*.png,
# $t/agent_*.png, $t/web_*.png, $t/before.png, $t/after.png
#   util/kit_get_view_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
for c in weston xclip; do
	command -v $c > /dev/null || skip "no $c"
done
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_get_view; t=$CHECK_TMP
# [KIT_TEXTURE_DESIGNER] weave1 in plain Lua: presets' pixels, seams, the
# compact form and tables
(cd "$here" && luajit extensions/weave/test/gen_test.lua) || fail "weave's gen_test.lua"
cd "$here/Build"
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_JOIN_PASSWORD=checkpass12
check_build
sock=buildat-view-$$
weston --backend=headless --xwayland --socket=$sock --width=1100 \
	--height=800 > "$t/weston.log" 2>&1 &
CHECK_PIDS+=($!)
for i in $(seq 50); do
	d=$(grep -ao "xserver listening on display :[0-9]*" "$t/weston.log" | grep -o ":[0-9]*$")
	[ -n "$d" ] && break
	sleep 0.2
done
[ -n "$d" ] || fail "weston's Xwayland ($t/weston.log)"
SL=$t/srv.log CL=$t/boss.log FD=3
mark() { wc -c < "$1"; }
as() # <boss|bob>: the client the next commands drive
{
	if [ "$1" = bob ]; then
		CL=$t/bob.log CLIENT=$BOB FD=4
	else
		CL=$t/boss.log CLIENT=$BOSS FD=3
	fi
}
await() # <log> <offset> <seconds> <regex>
{
	local i
	for i in $(seq $(($3 * 5))); do
		tail -c +$(($2 + 1)) "$1" | grep -qaE "$4" && return 0
		kill -0 $CLIENT 2>/dev/null || fail "the client is gone ($1)"
		sleep 0.2
	done
	fail "no \"$4\" in $1 in $3 s ($SL)"
}
cmd() { printf '%s\n' "$@" >&$FD; }
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
start_server "$SL" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
	--sim-rate "$CHECK_RATE" || fail "the server did not come up ($SL)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$SL" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$SL" | head -1)
[ -n "$code" ] || fail "no setup code ($SL)"
url=http://localhost:$SERVER_PORT/api/v1/mcp
client() # <name>: its commands from the fifo $t/<name>.cmd, its log $t/<name>.log
{
	mkfifo "$t/$1.cmd"
	sleep 900 > "$t/$1.cmd" &
	CHECK_PIDS+=($!)
	DISPLAY=$d WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11 BUILDAT_JOIN_NAME=kit$1 \
		timeout 600 bin/buildat -C "$t/client_cache_$1" -D "$t/cu_$1" \
		-s localhost:$SERVER_PORT -w 1024x700 -l 3 -o sound_mute=1 -c - \
		< "$t/$1.cmd" > "$t/$1.log" 2>&1 &
	CHECK_PIDS+=($!)
}
# A client with no display ([KIT_AGENT_VISUALS] 3, the README's recipe):
# no X, no Wayland, SDL's offscreen driver (EGL), no drive, no join
# variables; its log <log>, $HL its PID. Mesa's EGL when it is there, as
# a box with no GPU has: glvnd would offer a GPU vendor's device first.
mesa_egl=$(ls /usr/share/glvnd/egl_vendor.d/*_mesa.json 2>/dev/null | head -1)
headless() # <log> <dirs: client_cache_<name>, cu_<name>> [NAME=value ...] bin/buildat [-T token]
{
	local log=$1 cache=$2
	shift 2
	env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY -u BUILDAT_JOIN_PASSWORD \
		${mesa_egl:+__EGL_VENDOR_LIBRARY_FILENAMES=$mesa_egl} \
		SDL_VIDEODRIVER=offscreen "$@" -C "$t/client_cache_$cache" -D "$t/cu_$cache" \
		-s localhost:$SERVER_PORT -w 640x480 -l 4 -o sound_mute=1 \
		> "$log" 2>&1 &
	HL=$!
	CHECK_PIDS+=($HL)
}
cat > "$t/mcp.py" <<'PY'
import base64, json, os, re, struct, sys, time, urllib.error, urllib.request, zlib
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
    s, b = post(m)
    assert s == 200, (method, s, b)
    return json.loads(b)
def call(name, args={}, error=False):
    r = rpc("tools/call", {"name": name, "arguments": args})["result"]
    c = r["content"]
    assert len(c) == 1 and c[0]["type"] == "text", (name, str(r)[:500])
    assert r["isError"] == error, (name, args, r)
    print(" ", name, json.dumps(args), "->", c[0]["text"][:200])
    return c[0]["text"]
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
def mag(img, fx, fy):
    """The 5x5 around (fx, fy) of the picture's size mostly magenta"""
    w, h, px = img
    x0, y0, k = int(fx * (w - 1)), int(fy * (h - 1)), 0
    for y in range(max(0, y0 - 2), min(h, y0 + 3)):
        for x in range(max(0, x0 - 2), min(w, x0 + 3)):
            r, g, b = px(x, y)
            k += r > 110 and b > 110 and g < 0.65 * min(r, b)
    return k > 12
def view(args, name, error=False):
    """get_view: its text, and the picture saved as <out>/<name>.png"""
    t0 = time.time()
    r = rpc("tools/call", {"name": "get_view", "arguments": args})["result"]
    c = r["content"]
    assert r["isError"] == error, (args, str(r)[:500])
    if error:
        assert len(c) == 1 and c[0]["type"] == "text", str(r)[:500]
        print(" ", "get_view", json.dumps(args), "->", c[0]["text"][:200],
            "(%.1f s)" % (time.time() - t0))
        return c[0]["text"], time.time() - t0
    assert [x["type"] for x in c] == ["text", "image"], str(r)[:500]
    assert c[1]["mimeType"] == "image/png", c[1]["mimeType"]
    png = base64.b64decode(c[1]["data"])
    with open(out + "/" + name + ".png", "wb") as f:
        f.write(png)
    print(" ", "get_view", json.dumps(args), "->", c[0]["text"][:200],
        "(%d bytes, %.1f s)" % (len(png), time.time() - t0))
    return c[0]["text"], decode(png)
def hue(img, fx, fy, want):
    """The 5x5 around (fx, fy) mostly green (g over r and b) or yellow (r
    and g over b)"""
    w, h, px = img
    x0, y0, k = int(fx * (w - 1)), int(fy * (h - 1)), 0
    for y in range(max(0, y0 - 2), min(h, y0 + 3)):
        for x in range(max(0, x0 - 2), min(w, x0 + 3)):
            r, g, b = px(x, y)
            k += (g > r + 40 and g > b + 40) if want == "green" else \
                (r > b + 50 and g > b + 50)
    return k > 12
# [KIT_TEXTURE_DESIGNER] The woven type's top from above (yellow) and a
# polygon's face wearing its side (green): pictures until both are drawn
WT, WP = [-8, 36, 10], [8, 40, 10]
def woven(name):
    for i in range(20):
        top = view({"pos": [WT[0], WT[1] + 6, WT[2] - 3], "look_at": [WT[0],
            WT[1] + 1, WT[2]], "width": 128, "height": 96}, name + "_top")[1]
        side = view({"pos": [WP[0], WP[1], WP[2] - 6], "look_at": WP,
            "width": 128, "height": 96}, name + "_side")[1]
        if hue(top, 0.5, 0.5, "yellow") and hue(side, 0.5, 0.5, "green"):
            return i + 1
        time.sleep(0.5)
    assert False, ("the woven type not drawn", top[2](64, 48), side[2](64, 48))
init = {"protocolVersion": "2025-11-25", "capabilities": {},
        "clientInfo": {"name": "kit_get_view_check", "version": "1"}}
rpc("initialize", init)
# The marker in the sky over the players' start (the world project's, by
# the origin; the ground there below 20), the camera 8 before it
M = [0, 40, 10]
C = [0, 40, 2]
if phase == "builder":
    assert call("set_builder", {"name": "kitbob", "on": True}) == "kitbob is a builder"
elif phase == "views":
    assert "placed kit/part" in call("place", {"type": "kit/part", "pos": M,
        "params": {"size": [4, 4, 4], "color": "#ff00ff", "material": "glow",
        "collision": False}})
    # (the client draws it once it has it)
    time.sleep(1)
    text, img = view({"pos": C, "look_at": M, "width": 320, "height": 240}, "view_at")
    assert "kitboss's client drew this 320x240 from" in text and \
        "in the scene" in text, text
    assert img[:2] == (320, 240), img[:2]
    assert mag(img, 0.5, 0.5), "not magenta in the middle: %s" % (img[2](160, 120),)
    for x, y in ((0, 0), (1, 0), (0, 1), (1, 1)):
        assert not mag(img, x, y), ("magenta at a corner", x, y)
    # Below it: the marker in the top half (upright, not upside down)
    text, img = view({"pos": C, "look_at": [M[0], M[1] - 3, M[2]]}, "view_below")
    assert img[:2] == (512, 384), img[:2]
    assert mag(img, 0.5, 0.25) and not mag(img, 0.5, 0.75), \
        ("not upright", img[2](256, 96), img[2](256, 288))
    # Yaw 0 looks along +z, 180 away
    text, img = view({"pos": C, "yaw": 0, "pitch": 0, "width": 64, "height": 48}, "view_yaw0")
    assert mag(img, 0.5, 0.5), img[2](32, 24)
    text, img = view({"pos": C, "yaw": 180, "pitch": 0, "width": 64, "height": 48}, "view_yaw180")
    assert not mag(img, 0.5, 0.5), img[2](32, 24)
    # Its own view, the default size
    text, img = view({}, "view_own")
    assert img[:2] == (512, 384) and "its own view" in text, (img[:2], text)
    # Refused
    assert "is in the scene" in view({"scene": "nope"}, "", True)[0]
    assert "16 to 1024" in view({"width": 2000}, "", True)[0]
    assert "go with a pos" in view({"look_at": M}, "", True)[0]
    # [KIT_SIDE_SCENERY] (8) kit/parallax at follow 0 (moving with the
    # camera), high over the others' views: a magenta part under it by
    # place's parent, one put under it by set_parent. From 40 over both are
    # drawn in the picture's middle column (where authored, out of it); then
    # deleted, the views after these as before
    import re
    def num(text):
        return int(re.search(r"placed \S+ (\d+)", text).group(1))
    mp = {"size": [2, 2, 2], "color": "#ff00ff", "material": "glow", "collision": False}
    L = num(call("place", {"type": "kit/parallax", "pos": [0, 80, 20], "params": {"follow": 0}}))
    A = num(call("place", {"type": "kit/part", "pos": [0, 80, 20], "parent": L, "params": mp}))
    B = num(call("place", {"type": "kit/part", "pos": [0, 76, 20], "params": mp}))
    call("set_parent", {"id": B, "parent": L})
    parents = {e["id"]: e.get("parent") for e in json.loads(call("get_state", {"ids": [A, B]}))["entities"]}
    assert parents == {A: L, B: L}, parents
    time.sleep(1)
    text, img = view({"pos": [40, 80, 2], "look_at": [40, 80, 20], "width": 320, "height": 240}, "view_parallax")
    col = [mag(img, 0.5, y / 20) for y in range(21)]
    assert mag(img, 0.5, 0.5) and any(col[12:]) and not mag(img, 0.1, 0.5), \
        ("the parallax parts not in the middle column", col)
    for i in (A, B, L):
        call("delete", {"id": i})
elif phase == "weave":
    # A recipe texture by a table, packed as weave_gen.lua packs it (the
    # check's WEAVE_GREEN); a second one the top of a voxel type wearing
    # the first on its sides
    text = call("put_texture", {"name": "agentgreen", "recipe": {"pattern": "none",
        "color_a": "#20b030", "color_b": "#30d040", "contrast": 0.1}})
    G = re.search(r"generated/weave/weave1/[0-9a-v]{53}", text)[0]
    assert G == "generated/weave/weave1/" + os.environ["WEAVE_GREEN"][7:], (G, os.environ["WEAVE_GREEN"])
    assert "made texture kitboss/agentgreen version 1" in text, text
    text = call("put_texture", {"name": "agenttop", "recipe": {"pattern": "tiles",
        "count": 2, "color_a": "#e0c020", "color_b": "#d0b818", "gap_color": "#a08010"},
        "voxel": {"name": "woven", "face": "top", "texture": G}})
    assert "voxel type kitboss/woven wears it on its top" in text, text
    # Listed with their recipes; one's table read back and put again: the
    # same recipe, its next version
    lt = json.loads(call("list_textures"))
    rs = {x["name"]: x for x in lt["recipes"]}
    assert rs["kitboss/agentgreen"]["texture"] == G and \
        len(lt["presets"]) == 10 and "kitboss/agenttop" in rs, lt
    t = json.loads(call("list_textures", {"texture": "kitboss/agentgreen"}))
    assert t["color_a"] == "#20b030" and t["pattern"] == "none" and t["size"] == 16, t
    text = call("put_texture", {"name": "agentgreen", "recipe": t})
    assert "version 2: " + G in text, text
    assert "recipe" in call("put_texture", {"name": "x", "recipe": "weave1:zz"}, True)
    assert "pattern" in call("put_texture", {"name": "x", "recipe": {"pattern": "plaid"}}, True)
    # Worn by a box of cells and by a polygon
    assert "in 9 of 9 cells" in call("set_voxels", {"at": [WT[0] - 1, WT[1],
        WT[2] - 1], "size": [3, 1, 3], "voxel": "kitboss/woven"})
    assert "placed kit/polygon" in call("place", {"type": "kit/polygon", "pos": WP,
        "params": {"points": [[-2, -2], [2, -2], [2, 2], [-2, 2]],
        "voxel": "kitboss/woven"}})
    print("  the woven type drawn in %d tries" % woven("view_woven"))
elif phase == "pose":
    text, img = view({"pos": C, "look_at": M}, "view_pose")
elif phase == "timeout":
    text, took = view({"pos": C, "look_at": M}, "", True)
    assert "No picture from kitboss's client in 5 s" in text and 4 < took < 8, (text, took)
elif phase == "none":
    text = view({"pos": C, "look_at": M}, "", True)[0]
    assert "No client of kitbob's is connected" in text and \
        "run one yourself" in text, text
elif phase == "web":
    # kitbob's web client: read back by glReadPixels, not glGetTexImage
    text, img = view({"pos": C, "look_at": M, "width": 320, "height": 240}, "web_at")
    assert text.startswith("kitbob's client drew this 320x240 from"), text
    assert mag(img, 0.5, 0.5), "not magenta in the middle: %s" % (img[2](160, 120),)
    for x, y in ((0, 0), (1, 0), (0, 1), (1, 1)):
        assert not mag(img, x, y), ("magenta at a corner", x, y)
    text, img = view({"pos": C, "look_at": [M[0], M[1] - 3, M[2]]}, "web_below")
    assert mag(img, 0.5, 0.25) and not mag(img, 0.5, 0.75), \
        ("not upright", img[2](256, 96), img[2](256, 288))
    # [KIT_TEXTURE_DESIGNER] the recipe textures made in the browser too;
    # then a marker cleared, for the drive's last screenshot
    print("  the woven type drawn in %d tries" % woven("web_woven"))
    call("show")
elif phase == "agent":
    text, img = view({"pos": C, "look_at": M}, "agent_at")
    assert text.startswith("kitbob's client drew this 512x384 from"), text
    assert mag(img, 0.5, 0.5) and not mag(img, 0, 0), img[2](256, 192)
    text, img = view({}, "agent_own")
    assert img[:2] == (512, 384), img[:2]
elif phase == "same":
    # Two screenshots of a window: the same but for the top (the notice)
    a = decode(open(sys.argv[5], "rb").read())
    b = decode(open(sys.argv[6], "rb").read())
    assert a[:2] == b[:2], (a[:2], b[:2])
    w, h = a[:2]
    diff = total = 0
    for y in range(int(h * 0.25), int(h * 0.85), 2):
        for x in range(0, w, 2):
            total += 1
            diff += max(abs(p - q) for p, q in zip(a[2](x, y), b[2](x, y))) > 40
    print("  the window: %d of %d pixels differ" % (diff, total))
    assert diff < total * 0.02, (diff, total)
print("ok:", phase)
PY
mcp() # <phase> <token> [args...]: the MCP client's phase; its output in $t/<phase>.log
{
	local p=$1
	shift
	python3 -I "$t/mcp.py" "$p" "$url" "$@" > "$t/mcp_$p.log" 2>&1 ||
		fail "the MCP phase $p: $(tail -5 "$t/mcp_$p.log") ($t/mcp_$p.log, $SL)"
	cat "$t/mcp_$p.log"
}
pictures() # <log>: the pictures its client has taken
{
	grep -ac "kit: Your agent took a picture" "$1"
}

# 1. The tokens ([KIT_AGENT_NEXT_1] the server's camera off: the clients
# here draw, and with none get_view is refused as before it;
# util/kit_server_camera_check.sh has the camera)
BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on
setting server_camera off" client boss
BOSS=$!
exec 3> "$t/boss.cmd"
as boss
await "$CL" 0 120 "Joined as kitboss"
cmd "wait_log_any 30000 server window: the page ntfy" "frames 3" 'click Button "Don'"'"'t add"'
await "$CL" 0 120 "player physics enabled"
await "$CL" 0 30 "accounts: admin result: The server.s camera is off"
menu
step 10 "accounts: agents: 0 tokens, on" "frames 3" 'click Button "My account*"' \
	"frames 5" 'click Button "Connect an agent..."'
step 10 "accounts: agents: a token made, builder" "frames 3" \
	'click Button "Make a token..."' "frames 3" 'click Button "Make a token"'
step 10 "accounts: agents: the token copied" "frames 3" 'click Button "copy token"'
tok_b=$(clip "")
[[ $tok_b =~ ^bat_[0-9a-f]{64}$ ]] || fail "kitboss's builder token: $tok_b"
cmd "frames 3" 'click Button "Done"' "frames 3" 'click Button "Scope: Builder*"' \
	"frames 3" 'click LineEdit "My agent"' "delay 300" "keydown ctrl" \
	"keypress a" "keyup ctrl" "text admin agent" "frames 2"
step 10 "accounts: agents: a token made, admin" 'click Button "Make a token"'
step 10 "accounts: agents: the token copied" "frames 3" 'click Button "copy token"'
tok_a=$(clip "$tok_b")
[[ $tok_a =~ ^bat_[0-9a-f]{64}$ ]] || fail "kitboss's admin token: $tok_a"
cmd "frames 3" 'click Button "Done"'
step 10 "pause: the menu shown" "frames 3" "keypress Escape"
step 10 "pause: the menu closed" "frames 3" "keypress Escape"
BUILDAT_JOIN_CREATE=1 client bob
BOB=$!
exec 4> "$t/bob.cmd"
as bob
await "$CL" 0 120 "Joined as kitbob"
await "$CL" 0 120 "player physics enabled"
mcp builder "$tok_a" "$t"
menu
step 10 "accounts: agents: 0 tokens, on" "frames 3" 'click Button "My account*"' \
	"frames 5" 'click Button "Connect an agent..."'
step 10 "accounts: agents: a token made, builder" "frames 3" \
	'click Button "Make a token..."' "frames 3" 'click Button "Make a token"'
step 10 "accounts: agents: the token copied" "frames 3" 'click Button "copy token"'
tok_bob=$(clip "$tok_a")
[[ $tok_bob =~ ^bat_[0-9a-f]{64}$ ]] || fail "kitbob's token: $tok_bob"
cmd "frames 3" 'click Button "Done"'
step 10 "pause: the menu shown" "frames 3" "keypress Escape"
step 10 "pause: the menu closed" "frames 3" "keypress Escape"
echo "ok: kitboss's builder and admin tokens, kitbob a builder and his token"

# 2. kitboss's agent's pictures; kitboss's window the same around one
mcp views "$tok_b" "$t"
as boss
step 10 "Wrote screenshot .*before.png" "frames 5" "screenshot $t/before.png"
m=$(mark "$CL")
mcp pose "$tok_b" "$t"
await "$CL" "$m" 5 "kit: the picture sent, [0-9]+ bytes"
step 10 "Wrote screenshot .*after.png" "frames 2" "screenshot $t/after.png"
mcp same "$tok_b" "$t" "$t/before.png" "$t/after.png"
[ "$(pictures "$t/boss.log")" = 7 ] || fail "kitboss's client took $(pictures "$t/boss.log") pictures, not 7"
grep -aq "kit: Your agent took a picture (320x240, its pose)" "$t/boss.log" ||
	fail "no notice of the 320x240 picture in $t/boss.log"
for re in "kitboss's agent asks kitboss's client \(peer [0-9]+, scene [^)]+\) for a picture 320x240" \
		"A picture from kitboss's client \(peer [0-9]+\) for its agent: 320x240"; do
	grep -aqE "$re" "$SL" || fail "no \"$re\" in $SL"
done
[ "$(pictures "$t/bob.log")" = 0 ] || fail "kitbob's client was asked ($t/bob.log)"
# [KIT_SIDE_SCENERY] (8) The parallax pose's camera placed the layers in
# kitboss's window for its picture's frame alone
offs=$(grep -aoP "kit: parallax: a get_view pose's camera off after \K\d+(?= frames drawn)" "$t/boss.log" | sort -u | tr '\n' ' ')
grep -aq "kit: parallax: a get_view pose's camera on" "$t/boss.log" && [ "$offs" = "1 " ] ||
	fail "the pose's camera on the layers in kitboss's window past its picture's frame: off after $offs frames ($t/boss.log)"
echo "ok: kitboss's agent's pictures, from a pose, upright, by yaw and its own view; the window the same; a pose's parallax offsets in it for its picture's frame alone"
# [KIT_TEXTURE_DESIGNER] Recipe textures by put_texture, worn by cells and a
# polygon, drawn by kitboss's client (made from their names; kitbob's too)
export WEAVE_GREEN
WEAVE_GREEN=$(cd "$here" && luajit -e 'local G = dofile("extensions/weave/weave_gen.lua")
	io.write(G.pack(G.params({pattern = "none", color_a = "#20b030", color_b = "#30d040", contrast = 0.1})))')
mcp weave "$tok_b" "$t"
for f in "$t/boss.log" "$t/bob.log"; do
	grep -aq "weave *: made ${WEAVE_GREEN}" "$f" || fail "no texture made of the recipe in $f"
done
echo "ok: recipe textures put (a table packed as weave_gen.lua packs it), listed and read back; a voxel type wearing two (one its top), its cells and a polygon drawn"

# 3. A client that does not answer
bpid=$(pgrep -P $BOSS)
[ -n "$bpid" ] || fail "no client under $BOSS"
m=$(mark "$SL")
kill -STOP $bpid
mcp timeout "$tok_b" "$t"
kill -CONT $bpid
await "$SL" "$m" 10 "A picture from peer [0-9]+ refused: not one asked of it \(or late\)"
echo "ok: a stopped client's picture answered in 5 s, its late one refused"

# 4. Token clients refused: a builder token for the Host; kitbob already here
headless "$t/agent_host.log" agent bin/buildat -T "$tok_b"
CLIENT=$HL
await "$t/agent_host.log" 0 120 "Login refused: kitboss is a Host: an agent's client logs in as one only with an admin token"
tr '\0' ' ' < /proc/$HL/cmdline | grep -qF "${tok_b#bat_}" &&
	fail "the token in the client's command line"
kill $HL
headless "$t/agent_here.log" agent BUILDAT_AGENT_TOKEN=$tok_bob bin/buildat
CLIENT=$HL
await "$t/agent_here.log" 0 60 "Login refused: kitbob is already here"
kill $HL
echo "ok: token clients refused: the Host's by a builder token, kitbob's while he is here"

# 5. kitbob's client gone: his agent refused, kitboss's client not asked
as bob
cmd "sync 2000" quit
exec 4>&-
wait $BOB 2>/dev/null
n=$(pictures "$t/boss.log")
mcp none "$tok_bob" "$t"
echo "ok: no client of kitbob's: his agent told how to run one"

# 5b. kitbob's web client (headless Chrome; skipped without web/ or
# Chrome): its pictures magenta and upright, and no WebGL warning (Chrome's
# "Read buffer is GL_NONE" was a black picture: web_drive fails on it)
if command -v "${CHROME:-google-chrome}" > /dev/null && [ -f "$here/web/buildat.wasm" ]; then
	cat > "$t/web.json" <<'J'
[
	["nav", "${URL}"], ["waitlog", "accounts: the login page shown", 120], ["wait", 1000],
	["selall"], ["frames", 2], ["type", "kitbob"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["type", "checkpass12"], ["frames", 2], ["key", "Enter"], ["waitlog", "Joined as kitbob", 30],
	["waitlog_any", "player physics enabled", 120], ["frames", 30],
	["shot", "${OUT}/before.png"],
	["waitlog", "kit: the picture sent", 60], ["waitlog", "kit: the picture sent", 10],
	["waitlog", "kit: agent marker from", 60],
	["frames", 5], ["shot", "${OUT}/after.png"]
]
J
	m=$(mark "$SL")
	# (timeout: stopped at a fail, its process group goes, the drive's node too)
	WEB_DRIVE_VIEWPORT=1024x700@1 WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/" timeout 300 \
		"$here/util/web_drive.sh" chrome workbench "$t/web.json" "$t/web" > "$t/web.txt" 2>&1 &
	CLIENT=$!
	CHECK_PIDS+=($CLIENT)
	for i in $(seq 900); do
		[ -s "$t/web/before.png" ] && break
		kill -0 $CLIENT 2>/dev/null || break
		sleep 0.2
	done
	[ -s "$t/web/before.png" ] ||
		fail "kitbob's web client did not come in: $(tail -3 "$t/web.txt") ($t/web/page.log)"
	mcp web "$tok_bob" "$t"
	wait $CLIENT || fail "kitbob's web client: $(tail -3 "$t/web.txt") ($t/web/page.log)"
	mcp same "$tok_bob" "$t" "$t/web/before.png" "$t/web/after.png"
	# Gone before his token client comes in
	CLIENT=$SERVER_PID
	await "$SL" "$m" 10 "workbench: kitbob left"
	echo "ok: kitbob's web client's pictures, magenta and upright; its window the same; no WebGL warning"
else
	echo "(no web part: no web/buildat.wasm or Chrome)"
fi

# 6. A token client as kitbob: its picture
headless "$t/agent.log" agent BUILDAT_AGENT_TOKEN=$tok_bob bin/buildat
AGENT=$HL CLIENT=$HL
await "$t/agent.log" 0 120 "Joined as kitbob"
await "$t/agent.log" 0 120 "player physics enabled"
grep -aq "accounts: logged in as kitbob by agent token" "$t/agent.log" ||
	fail "no login by the agent token in $t/agent.log"
grep -aq "video driver offscreen" "$t/agent.log" ||
	fail "the token client not on SDL's offscreen driver ($t/agent.log)"
grep -aqE "kitbob joined from .* by an agent token \(\"My agent\", builder token\)" "$SL" ||
	fail "no join by an agent token in $SL"
mcp agent "$tok_bob" "$t"
[ "$(pictures "$t/agent.log")" = 2 ] || fail "the token client took $(pictures "$t/agent.log") pictures"
[ "$(pictures "$t/boss.log")" = "$n" ] || fail "kitboss's client was asked for kitbob's agent"
echo "ok: a client logged in by kitbob's token with no display (offscreen), its pictures"

# 7. Revoked: refused; Agents (MCP) off: kicked
as boss
menu
step 10 "accounts: agents: 2 tokens, on" "frames 3" 'click Button "My account*"' \
	"frames 5" 'click Button "Connect an agent..."'
m=$(mark "$SL")
step 10 "accounts: agents: revoked My agent" "frames 3" 'click Button "Revoke My agent"'
await "$SL" "$m" 5 "kitboss's agent left: its token was revoked"
headless "$t/agent_revoked.log" revoked BUILDAT_AGENT_TOKEN=$tok_b bin/buildat
CLIENT=$HL
await "$t/agent_revoked.log" 0 120 "Login refused: Not an agent token of this server's"
kill $HL
as boss
step 10 "[0-9]+ accounts listed" "frames 3" 'click Button "Accounts*"'
m=$(mark "$CL") ms=$(mark "$SL")
cmd "frames 3" 'click Button "Agents (MCP): on*"'
await "$CL" "$m" 10 "admin result: Agent access is off"
await "$SL" "$ms" 10 "kitbob kicked: Agent access is off on this server"
# (CLIENT kitboss's: the kicked one may be gone)
await "$t/agent.log" 0 10 "Left the server: Agent access is off on this server"
echo "ok: a revoked token's client refused; agent access off kicks the token client"
cmd "sync 2000" quit
exec 3>&-
wait $BOSS 2>/dev/null

# 8. No token anywhere it should not be
for k in "$tok_a" "$tok_b" "$tok_bob"; do
	for f in "$t"/*.log "$t"/cu_* "$t"/client_cache_*; do
		grep -rqaF "${k#bat_}" "$f" && fail "a token in $f"
	done
done
echo "PASS: get_view draws on a client of the agent's own account (pose, yaw, its own view, upright), its window untouched but for the notice, another's never asked, a stopped one answered in 5 s, none refused with the way to run one; a client logs in by an agent token (a Host by an admin token only, not where the account is, revoked refused, kicked when agents go off) and serves it; no token logged or saved; pictures $t/view_*.png $t/agent_*.png"
