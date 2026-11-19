#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~3 min (2026-11-17)
# covers: src/server/confine.cpp src/client/command_seq.cpp src/server/main.cpp builtin/kit/kit.cpp builtin/kit/client_lua/module.lua builtin/accounts/accounts.cpp builtin/network/network.cpp apps/workbench/main/main.cpp builtin/voxelworld/client_lua/module.lua client/api.lua extensions/weave/init.lua
# [KIT_AGENT_NEXT_1] The server's camera: a headless client of the
# server's own draws an agent's get_view when no client of its account is
# there, and plays a body for it (play_join, play_input, play_leave). One
# Workbench server; kitboss (the admin) makes a builder token on a headless
# weston's Xwayland of the check's own, and leaves:
#   1. the agent places a glowing magenta part; get_view starts the camera
#      (answers "starting" until it is in), then its pictures: from a pose
#      (magenta in the middle, not in the corners), below it (upright), by
#      yaw 0 and 180, and with no pose (over the agent's last place);
#   2. views: two poses in a call; preset map (orthographic, over an area),
#      turn (4 round the part, magenta in each) and frame; compare (the
#      pose's last picture first); a call past 1572864 pixels refused; a
#      polygon wearing a recipe texture ([KIT_TEXTURE_DESIGNER]) green;
#   3. trust: /health counts no player; the camera's one-time secret, read
#      off its environment, refused when replayed, and from this machine's
#      LAN address (not loopback); not in any log;
#   4. idle 2 s it draws 4 frames a second, a picture asked wakes it to 20
#      ([KIT_AGENT_FEEDBACK_1117]; its idle CPU printed); unused for
#      BUILDAT_CAMERA_IDLE_S (10 here) it stops, its process gone;
#   5. play: play_join refused while Stopped; start; play_join (the camera
#      started again); a trigger zone placed ahead; play_input walks into
#      it: the zone's "entered" among the events, the body moved, a picture
#      at the end; play_leave;
#   6. the server stopped: its camera gone with it;
#   7. (CAMERA_X11=1) a server given no display, offscreen failing:
#      get_view says what its host needs;
#   8. kitboss turns the camera off (Accounts): get_view refused as before
#      the camera (no word of it), no start.
# The camera on SDL's offscreen driver (Mesa's EGL vendor when installed),
# no display given; CAMERA_X11=1: offscreen made to fail (an EGL vendor
# file that is not there) and the check's weston's Xwayland given, the
# fallback.
# Pictures, kept with KEEP_TMP=1: $t/*.png; the camera's log
# $t/user/camera/workbench/client.log
#   util/kit_server_camera_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
for c in weston xclip curl; do
	command -v $c > /dev/null || skip "no $c"
done
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_server_camera; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_JOIN_PASSWORD=checkpass12
export BUILDAT_STARPORT_DEFAULT=https://127.0.0.1:9 BUILDAT_AITTA_DEFAULT=https://127.0.0.1:9 \
	BUILDAT_HEARTH_DEFAULT=https://127.0.0.1:9 SDL_VIDEO_X11_XRANDR=0
check_build
sock=buildat-cam-$$
weston --backend=headless --xwayland --socket=$sock --width=1100 \
	--height=800 > "$t/weston.log" 2>&1 &
CHECK_PIDS+=($!)
for i in $(seq 50); do
	d=$(grep -ao "xserver listening on display :[0-9]*" "$t/weston.log" | grep -o ":[0-9]*$")
	[ -n "$d" ] && break
	sleep 0.2
done
[ -n "$d" ] || fail "weston's Xwayland ($t/weston.log)"
cam_display= cam_egl=$(ls /usr/share/glvnd/egl_vendor.d/*_mesa.json 2>/dev/null | head -1)
[ -n "${CAMERA_X11:-}" ] && cam_display=$d cam_egl=/nonexistent/egl_vendor.json
# (the camera's and kitboss's; kitboss draws by GLX)
[ -n "$cam_egl" ] && export __EGL_VENDOR_LIBRARY_FILENAMES=$cam_egl
SL=$t/srv.log CL=$t/boss.log CAMLOG=$t/user/camera/workbench/client.log
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
server() # <log> [--camera-display's :N; none: not given at all]
{
	SL=$1
	local disp=()
	[ -n "$2" ] && disp=(--camera-display "$2")
	BUILDAT_CAMERA_IDLE_S=10 \
		start_server "$SL" "Listening at" 300 auto \
		bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
		--sim-rate "$CHECK_RATE" "${disp[@]}" ||
		fail "the server did not come up ($SL)"
	CHECK_PIDS+=($SERVER_PID)
	CLIENT=$SERVER_PID
	url=http://localhost:$SERVER_PORT/api/v1/mcp
}
boss() # [env...]: kitboss's client, driven from $t/boss.cmd (fd 3)
{
	rm -f "$t/boss.cmd"
	mkfifo "$t/boss.cmd"
	sleep 900 > "$t/boss.cmd" &
	CHECK_PIDS+=($!)
	env "$@" DISPLAY=$d WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11 BUILDAT_JOIN_NAME=kitboss \
		timeout 600 bin/buildat -C "$t/client_cache_boss" -D "$t/cu_boss" \
		-s localhost:$SERVER_PORT -w 1024x700 -l 3 -o sound_mute=1 -c - \
		< "$t/boss.cmd" > "$CL" 2>&1 &
	BOSS=$! CLIENT=$!
	CHECK_PIDS+=($BOSS)
	exec 3> "$t/boss.cmd"
}
boss_quit()
{
	cmd "sync 2000" quit
	exec 3>&-
	wait $BOSS 2>/dev/null
	CLIENT=$SERVER_PID
}
# A token client, no drive: its only display the check's X server
token_client() # <log> <server address> <token>
{
	env -u WAYLAND_DISPLAY -u XAUTHORITY -u BUILDAT_JOIN_PASSWORD \
		DISPLAY=$d SDL_VIDEODRIVER=x11 BUILDAT_AGENT_TOKEN=$3 \
		timeout 120 bin/buildat -C "$t/client_cache_tok" -D "$t/cu_tok" \
		-s "$2" -w 320x240 -l 4 -o sound_mute=1 > "$1" 2>&1 &
	HL=$! CLIENT=$!
	CHECK_PIDS+=($HL)
}
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
    s, b = post(m)
    assert s == 200, (method, s, b)
    return json.loads(b)
def tool(name, args):
    t0 = time.time()
    r = rpc("tools/call", {"name": name, "arguments": args})["result"]
    return r, time.time() - t0
def call(name, args={}, error=False):
    r, took = tool(name, args)
    c = r["content"]
    assert c[0]["type"] == "text", (name, str(r)[:500])
    assert r["isError"] == error, (name, args, str(r)[:800])
    print(" ", name, json.dumps(args), "->", c[0]["text"][:300], "(%.1f s)" % took)
    return c[0]["text"], [base64.b64decode(x["data"]) for x in c[1:]]
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
def view(args, name, count=1):
    """get_view's text and its pictures (saved as <out>/<name>_<k>.png)"""
    text, pngs = call("get_view", args)
    assert len(pngs) == count, (len(pngs), text)
    imgs = []
    for k, png in enumerate(pngs):
        with open("%s/%s_%d.png" % (out, name, k), "wb") as f:
            f.write(png)
        imgs.append(decode(png))
    return text, imgs
def refused(name, args):
    return call(name, args, True)[0]
def state():
    try:
        return json.load(open(out + "/state.json"))
    except FileNotFoundError:
        return {}
def save(**kw):
    s = state()
    s.update(kw)
    json.dump(s, open(out + "/state.json", "w"))
init = {"protocolVersion": "2025-11-25", "capabilities": {},
        "clientInfo": {"name": "kit_server_camera_check", "version": "1"}}
rpc("initialize", init)
# The marker in the sky over the players' start, the camera 8 before it
M = [0, 40, 10]
C = [0, 40, 2]
if phase == "first":
    text = call("place", {"type": "kit/part", "pos": M, "params": {"size":
        [4, 4, 4], "color": "#ff00ff", "material": "glow", "collision": False}})[0]
    part = int(re.search(r"placed kit/part (\d+)", text).group(1))
    save(part=part)
    # Started by the call, in by a later one
    t0, a = time.time(), {"pos": C, "look_at": M, "width": 320, "height": 240}
    while True:
        r, took = tool("get_view", a)
        text = r["content"][0]["text"]
        if not r["isError"]:
            break
        print("  get_view ->", text[:200], "(%.1f s)" % took)
        assert "The server's camera is starting" in text, text
        assert took < 9.5, took
        assert time.time() - t0 < 150, "the camera not in in 150 s"
        time.sleep(0.5)
    print("  the first picture %.1f s after the first call" % (time.time() - t0))
    text, img = view(a, "cam_at")
    assert text.startswith("The server's camera drew this 320x240 from"), text
    assert "as far as this server has it loaded" in text, text
    img = img[0]
    assert mag(img, 0.5, 0.5), "not magenta in the middle: %s" % (img[2](160, 120),)
    for x, y in ((0, 0), (1, 0), (0, 1), (1, 1)):
        assert not mag(img, x, y), ("magenta at a corner", x, y)
    text, img = view({"pos": C, "look_at": [M[0], M[1] - 3, M[2]]}, "cam_below")
    img = img[0]
    assert img[:2] == (512, 384), img[:2]
    assert mag(img, 0.5, 0.25) and not mag(img, 0.5, 0.75), \
        ("not upright", img[2](256, 96), img[2](256, 288))
    img = view({"pos": C, "yaw": 0, "pitch": 0, "width": 64, "height": 48}, "cam_yaw0")[1][0]
    assert mag(img, 0.5, 0.5), img[2](32, 24)
    img = view({"pos": C, "yaw": 180, "pitch": 0, "width": 64, "height": 48}, "cam_yaw180")[1][0]
    assert not mag(img, 0.5, 0.5), img[2](32, 24)
    # No pose: over what the agent placed last
    text, img = view({}, "cam_own")
    assert re.search(r"from \[6\D+45\D+16\] looking at \[0\D+41\D+10\]", text), text
    assert mag(img[0], 0.5, 0.5), img[0][2](256, 192)
elif phase == "views":
    part = state()["part"]
    text, imgs = view({"views": [{"pos": C, "look_at": M, "width": 64, "height": 48},
        {"pos": C, "yaw": 180, "pitch": 0, "width": 64, "height": 48}]}, "two", 2)
    assert "drew 2 views" in text and "1. 64x48" in text and "2. 64x48" in text, text
    assert mag(imgs[0], 0.5, 0.5) and not mag(imgs[1], 0.5, 0.5)
    # compare: the pose's last picture (the first of those two) first
    text, imgs = view({"pos": C, "look_at": M, "width": 64, "height": 48,
        "compare": True}, "compare", 2)
    assert "two pictures: before" in text, text
    assert mag(imgs[0], 0.5, 0.5) and mag(imgs[1], 0.5, 0.5)
    text, imgs = view({"preset": "map", "area": [M[0] - 12, M[2] - 12, M[0] + 12,
        M[2] + 12], "width": 256, "height": 256}, "map")
    assert "orthographic" in text, text
    assert mag(imgs[0], 0.5, 0.5) and not mag(imgs[0], 0.05, 0.05), imgs[0][2](128, 128)
    text, imgs = view({"preset": "turn", "id": part, "width": 128, "height": 96},
        "turn", 4)
    for k, img in enumerate(imgs):
        assert mag(img, 0.5, 0.5), ("turn", k, img[2](64, 48))
    text, imgs = view({"preset": "frame", "id": part, "width": 128, "height": 96},
        "frame")
    assert mag(imgs[0], 0.5, 0.5), imgs[0][2](64, 48)
    text = refused("get_view", {"views": [{"pos": C, "yaw": 0, "width": 1024,
        "height": 768}] * 3})
    assert "1572864 at most per call" in text, text
    assert "turn around" in refused("get_view", {"preset": "turn", "id": 999999})
    # [KIT_TEXTURE_DESIGNER] a recipe texture the camera makes from its name:
    # a polygon wearing a green one, its face green
    text = call("put_texture", {"name": "camgreen", "recipe": {"pattern": "none",
        "color_a": "#20b030", "color_b": "#30d040", "contrast": 0.1},
        "voxel": {"name": "camwoven"}})[0]
    assert "wears it" in text, text
    call("place", {"type": "kit/polygon", "pos": [8, 40, 10], "params": {"points":
        [[-2, -2], [2, -2], [2, 2], [-2, 2]], "voxel": "kitboss/camwoven"}})
    for i in range(20):
        w, h, px = view({"pos": [8, 40, 4], "look_at": [8, 40, 10], "width": 64,
            "height": 48}, "woven")[1][0]
        r, g, b = px(32, 24)
        if g > r + 40 and g > b + 40:
            break
        time.sleep(0.5)
    assert g > r + 40 and g > b + 40, ("the recipe texture not drawn", (r, g, b))
elif phase == "health":
    with urllib.request.urlopen(url.replace("/api/v1/mcp", "/health"),
            timeout=10) as r:
        h = json.loads(r.read().decode())
    assert h["players"] == 0, h
    print("  /health:", {k: h[k] for k in ("players",) if k in h})
elif phase == "wake":
    # [KIT_AGENT_FEEDBACK_1117] idle at 4 frames a second: the call's picture
    text, imgs = view({"pos": C, "look_at": M, "width": 320, "height": 240}, "wake")
    assert mag(imgs[0], 0.5, 0.5), imgs[0][2](160, 120)
elif phase == "play":
    call("stop") # (Workbench's world Running from its start)
    text = refused("play_join", {})
    assert "(Stopped)" in text and "start runs it" in text, text
    call("start")
    t0 = time.time()
    while True:
        r, took = tool("play_join", {})
        text = r["content"][0]["text"]
        if not r["isError"]:
            break
        print("  play_join ->", text[:200], "(%.1f s)" % took)
        assert "is starting" in text or "on its way" in text, text
        assert time.time() - t0 < 150, "the camera not in in 150 s"
        time.sleep(0.5)
    print("  play_join ->", text[:300])
    body = json.loads(re.search(r"\): (\{.*\})\. play_input", text).group(1))
    assert body["name"] == "kitboss's agent", body
    x, y, z = body["pos"]
    # A zone ahead (+z), the body's height in it
    text = call("place", {"type": "kit/trigger_zone", "pos": [round(x) - 2,
        round(y) - 1, round(z) + 2], "params": {"size": [5, 4, 3]}})[0]
    zone = int(re.search(r"placed kit/trigger_zone (\d+)", text).group(1))
    text, imgs = call("play_input", {"yaw": 0, "pitch": 0, "keys": ["W"],
        "seconds": 2, "picture": True})
    assert len(imgs) == 1 and decode(imgs[0])[:2] == (512, 384), text
    with open(out + "/play_end.png", "wb") as f:
        f.write(imgs[0])
    got = json.loads(re.search(r"Played 2 s: (\{.*\})\n", text).group(1))
    assert got["moved"] > 1, got
    assert any(e["id"] == zone and e["output"] == "entered" for e in got["events"]), got
    assert "0.1 to 4" in refused("play_input", {"seconds": 9})
    text = call("play_leave")[0]
    assert "Your body is gone" in text, text
    assert "You play no body" in refused("play_input", {})
elif phase == "nodisplay":
    text = refused("get_view", {"pos": C, "look_at": M})
    assert "the server's camera cannot draw" in text or \
        "the server's camera could not start" in text, text
    assert "--camera-display" in text and "offscreen" in text, text
elif phase == "off":
    text = refused("get_view", {"pos": C, "look_at": M})
    assert "No client of kitboss's is connected to this server: get_view" in text \
        and "camera" not in text, text
    tool("start", {}) # (Running or not after the restart)
    text = refused("play_join", {})
    assert "The server's camera cannot play: the server's camera is off" in text, text
print("ok:", phase)
PY
mcp() # <phase>: the MCP client's phase; its output in $t/mcp_<phase>.log
{
	python3 -I "$t/mcp.py" "$1" "$url" "$tok" "$t" > "$t/mcp_$1.log" 2>&1 ||
		fail "the MCP phase $1: $(tail -5 "$t/mcp_$1.log") ($t/mcp_$1.log, $SL)"
	cat "$t/mcp_$1.log"
}
cam_pid() { grep -aoE "The server's camera is process [0-9]+" "$SL" | tail -1 | grep -oE "[0-9]+$"; }
# What the camera costs: its CPU ticks now, and its memory said
ticks() { awk '{ print $14 + $15 }' "/proc/$CP/stat" 2>/dev/null; }
now_ms() { echo $(($(date +%s%N) / 1000000)); }
cpu() # <what> <ticks before> <ms before>: the CPU it took since, of one core
{
	echo "  the camera $1: $(awk -v t=$(($(ticks) - $2)) -v hz=$(getconf CLK_TCK) \
		-v ms=$(($(now_ms) - $3)) 'BEGIN { printf "%.0f %% of a core over %.1f s", \
		t / hz * 100000 / ms, ms / 1000 }'), $(grep -aE "^VmRSS" "/proc/$CP/status" |
		awk '{ printf "RSS %d MB", $2 / 1024 }'), $(grep -aE "^VmHWM" "/proc/$CP/status" |
		awk '{ printf "at most %d MB", $2 / 1024 }')"
}
gone() # <pid> <what>: gone in 5 s
{
	local i
	for i in $(seq 25); do
		kill -0 "$1" 2>/dev/null || return 0
		sleep 0.2
	done
	fail "$2 (pid $1) still running"
}

# 0. The server; kitboss's token, kitboss gone
server "$t/srv.log" "$cam_display"
wait_for_log "$SL" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$SL" | head -1)
[ -n "$code" ] || fail "no setup code ($SL)"
grep -aqE "The camera's launcher: pid [0-9]+" "$SL" || fail "no camera launcher ($SL)"
boss BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1
await "$CL" 0 120 "Joined as kitboss"
cmd "wait_log_any 30000 server window: the page ntfy" "frames 3" 'click Button "Don'"'"'t add"'
await "$CL" 0 120 "player physics enabled"
menu
step 10 "accounts: agents: 0 tokens, on" "frames 3" 'click Button "My account*"' \
	"frames 5" 'click Button "Connect an agent..."'
step 10 "accounts: agents: a token made, builder" "frames 3" \
	'click Button "Make a token..."' "frames 3" 'click Button "Make a token"'
step 10 "accounts: agents: the token copied" "frames 3" 'click Button "copy token"'
tok=$(clip "")
[[ $tok =~ ^bat_[0-9a-f]{64}$ ]] || fail "kitboss's builder token: $tok"
cmd "frames 3" 'click Button "Done"'
boss_quit
await "$SL" 0 10 "workbench: kitboss left"
echo "ok: kitboss's builder token, kitboss gone"

# 1. The camera's pictures
m=$(mark "$SL")
mcp first
await "$SL" "$m" 5 "The server's camera is in \(peer [0-9]+, (x11|offscreen)"
mode=offscreen
[ -n "${CAMERA_X11:-}" ] && mode=x11
grep -aq "The server's camera is in (peer [0-9]*, $mode" "$SL" ||
	fail "not on $mode ($SL)"
grep -aqE "Peer [0-9]+ joined from 127\.0\.0\.1 as the server's camera" "$SL" ||
	fail "no camera login in $SL"
grep -aq "kit: the server's camera is in" "$CAMLOG" || fail "no camera's log at $CAMLOG"
CP=$(cam_pid)
[ -n "$CP" ] || fail "no camera process in $SL"
echo "ok: the camera started by get_view, its pictures (pose, upright, yaw, no pose)"
c0=$(ticks) t0=$(now_ms)
mcp views
cpu "drawing (the views phase)" "$c0" "$t0"
echo "ok: views, map, turn, frame, compare; the pixel cap; a recipe texture drawn"

# 3. Trust: no player counted; the secret once, from loopback only
mcp health
secret=$(tr '\0' '\n' < "/proc/$CP/environ" | grep -aoP '^BUILDAT_AGENT_TOKEN=\Kcam_[0-9a-f]+$')
[ -n "$secret" ] || fail "no camera secret in its environment"
tr '\0' ' ' < "/proc/$CP/cmdline" | grep -qF "$secret" && fail "the secret on the camera's command line"
m=$(mark "$SL")
token_client "$t/replay.log" "127.0.0.1:$SERVER_PORT" "$secret"
await "$t/replay.log" 0 60 "Login refused: No camera is expected"
kill $HL; CLIENT=$SERVER_PID
await "$SL" "$m" 5 "A camera login from 127\.0\.0\.1 refused: No camera is expected"
lan=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9.]+$' | grep -v '^127\.' | head -1)
if [ -n "$lan" ]; then
	m=$(mark "$SL")
	token_client "$t/lan.log" "$lan:$SERVER_PORT" "$secret"
	await "$t/lan.log" 0 60 "Login refused: Not from this machine"
	kill $HL; CLIENT=$SERVER_PID
	await "$SL" "$m" 5 "A camera login from $lan refused: Not from this machine"
	echo "ok: the secret from $lan refused"
else
	echo "(no LAN address: the non-loopback login not tried)"
fi
CLIENT=$SERVER_PID
echo "ok: /health counts no player; the secret replayed refused"
# [KIT_AGENT_FEEDBACK_1117] Idle 2 s: 4 frames a second; a call wakes it
# (20) before its picture is asked
await "$SL" 0 10 "The server's camera at 4 frames a second \(idle\)"
m=$(mark "$SL")
mcp wake
await "$SL" "$m" 1 "The server's camera at 20 frames a second"
echo "ok: idle at 4 frames a second, woken to 20 by a picture"

# 4. Unused: stopped
# (its idle CPU measured meanwhile, from its 4 frames a second on)
m=$(mark "$SL")
await "$SL" "$m" 10 "The server's camera at 4 frames a second \(idle\)"
c0=$(ticks) t0=$(now_ms) idle=
for i in $(seq 200); do
	grep -aq "The server's camera stops: unused for 10 s" "$SL" && break
	[ $i = 25 ] && idle=$(cpu "idle" "$c0" "$t0")
	sleep 0.2
done
[ -n "$idle" ] && echo "$idle"
await "$SL" 0 5 "The server's camera stops: unused for 10 s"
gone "$CP" "the idle camera"
grep -aq "command: max_fps 4" "$CAMLOG" && grep -aq "command: max_fps 20" "$CAMLOG" ||
	fail "the camera did not take max_fps 4 and 20 ($CAMLOG)"
echo "ok: the idle camera stopped, its process gone"

# 5. Play
m=$(mark "$SL")
mcp play
await "$SL" "$m" 5 "The server's camera plays for kitboss's agent no more: play_leave"
CP=$(cam_pid)
echo "ok: play: refused Stopped; joined, walked into a zone (entered), moved, a picture; left"

# 6. The server stopped: its camera too
LP=$(grep -aoE "The camera's launcher: pid [0-9]+" "$SL" | tail -1 | grep -oE "[0-9]+$")
kill $SERVER_PID
wait $SERVER_PID 2>/dev/null
gone "$CP" "the camera after its server stopped"
gone "$LP" "the camera's launcher after its server stopped"
echo "ok: the server's stop took its camera and launcher"

# 7. No display, offscreen failing
if [ -n "${CAMERA_X11:-}" ]; then
	server "$t/srv2.log" ""
	mcp nodisplay
	echo "ok: no display: get_view says what the host needs"
else
	server "$t/srv2.log" ""
fi

# 8. Off (kitboss's Accounts setting): as before the camera
m=$(mark "$SL")
boss BUILDAT_JOIN_ADMIN="setting server_camera off"
# (not "admin script: done": Workbench's second accounts.lua takes the result)
await "$CL" 0 120 "admin result: The server's camera is off"
boss_quit
await "$SL" "$m" 10 "workbench: kitboss left"
m=$(mark "$SL")
mcp off
tail -c +$((m + 1)) "$SL" | grep -aq "The server's camera starts" && fail "the camera started while off"

# No secret or token in a log
for k in "$secret" "${tok#bat_}"; do
	grep -rqaF "$k" "$t"/*.log "$CAMLOG" && fail "a secret in a log"
done
echo "PASS: the server's camera: started by get_view and play_join, its pictures (poses, views, presets, compare, pixel cap), not counted, its secret once and from loopback only, stopped unused and with its server, a body that walks into a trigger, the host told what it needs, off as before; pictures $t/*.png"
