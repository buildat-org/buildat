#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1.5 min (2026-11-23)
# covers: builtin/kit/kit.cpp builtin/kit/client_lua/rec.lua builtin/kit/client_lua/input.lua builtin/kit/client_lua/editor_input.lua builtin/kit/client_lua/module.lua extensions/pause_menu/init.lua
# [KIT_PLAYTEST_REC] (kit_plan 4z37zzf) A builder's playtest recorded for
# the game's agent. Workbench's server of Puzzle room (a project made of
# the template's zip); kitboss (the admin) on a headless weston's
# Xwayland of the check's own (its clipboard carries the agent token):
#   1. kitboss makes a builder token, leaves edit mode (F6), walks (W),
#      presses a kit/ui_button "Press me" the agent placed, marks a moment
#      by the key (F8): the note typed, Enter; the pause menu's "Mark this
#      moment" opened and Escape: cancelled, back to the menu. kitbob (no
#      edit rights) plays beside him and is not recorded.
#   2. get_session: the list has kitboss's session with its summary
#      (player, start, length, scene, median fps, 1 mark, no errors) and
#      none of kitbob's; its rows: the session's start (native, the
#      window's size, keyboard/mouse), pos rows (one moving), the press,
#      perf (fps, the tick's gaps), the mark (note, pos, scene, picture
#      480 wide) and its picture as an image block of that size; kinds
#      filters; a session not there refused.
#   3. The server again with BUILDAT_KIT_REC_CAP a little over the first
#      session's bytes: the first still listed; kitboss's second session's
#      mark puts the store past it: the first is dropped, the second kept
#      at its end (the newest never is, past the cap alone or not).
#   4. Workbench's web client in headless Firefox (skipped without it or
#      web/): webboss New from Puzzle room, F6: recorded as web, its perf
#      report, a mark by the pause menu's item with a picture 480 wide.
# The mark's picture, kept with KEEP_TMP=1: $t/mark.png
#   util/kit_playtest_rec_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
for c in weston xclip zip; do
	command -v $c > /dev/null || skip "no $c"
done
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_playtest_rec; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12
check_build
sock=buildat-rec-$$
weston --backend=headless --xwayland --socket=$sock --width=1100 \
	--height=800 > "$t/weston.log" 2>&1 &
CHECK_PIDS+=($!)
for i in $(seq 50); do
	d=$(grep -ao "xserver listening on display :[0-9]*" "$t/weston.log" | grep -o ":[0-9]*$")
	[ -n "$d" ] && break
	sleep 0.2
done
[ -n "$d" ] || fail "weston's Xwayland ($t/weston.log)"
SL=$t/srv.log CL=$t/boss.log FD=3 CLIENT=
mark() { wc -c < "$1"; }
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
client() # <name> <fd>: its commands from the fifo $t/<name>.cmd, its log $t/<name>.log
{
	[ -p "$t/$1.cmd" ] || mkfifo "$t/$1.cmd"
	sleep 600 > "$t/$1.cmd" &
	CHECK_PIDS+=($!)
	DISPLAY=$d WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11 BUILDAT_JOIN_NAME=kit$1 \
		timeout 400 bin/buildat -C "$t/client_cache_$1" -D "$t/cu_$1" \
		-s localhost:$SERVER_PORT -w 1024x700 -l 3 -o sound_mute=1 -c - \
		< "$t/$1.cmd" > "$t/$1.log" 2>&1 &
	CLIENT=$!
	CHECK_PIDS+=($CLIENT)
	eval "exec $2> \"\$t/\$1.cmd\""
}
srv() # <log> <the template's zip|""> <cap|"">: Workbench's server of the project "room"
{
	local log=$1
	SL=$log
	BUILDAT_WORKBENCH_PROJECT=room BUILDAT_WORKBENCH_FROM=$2 BUILDAT_KIT_REC_CAP=$3 \
		start_server "$log" "Listening at" 300 auto \
		bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
		--sim-rate "$CHECK_RATE" || fail "the server did not come up ($log)"
	CHECK_PIDS+=($SERVER_PID)
	url=http://localhost:$SERVER_PORT/api/v1/mcp
}
cat > "$t/mcp.py" <<'PY'
import base64, json, re, struct, sys, urllib.error, urllib.request
phase, url, tok, out = sys.argv[1:5]
def post(msg):
    h = {"Content-Type": "application/json",
         "Accept": "application/json, text/event-stream",
         "Authorization": "Bearer " + tok}
    req = urllib.request.Request(url, data=json.dumps(msg).encode(), headers=h)
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
    """Its text and its images (PNG bytes)"""
    r = rpc("tools/call", {"name": name, "arguments": args})["result"]
    c = r["content"]
    assert c[0]["type"] == "text" and r["isError"] == error, (name, args, str(r)[:800])
    imgs = []
    for x in c[1:]:
        assert x["type"] == "image" and x["mimeType"] == "image/png", str(x)[:200]
        imgs.append(base64.b64decode(x["data"]))
    print(" ", name, json.dumps(args), "->", c[0]["text"][:300],
        "(%d images)" % len(imgs) if imgs else "")
    return c[0]["text"], imgs
def size(b):
    assert b[:8] == b"\x89PNG\r\n\x1a\n" and b[12:16] == b"IHDR", b[:16]
    return struct.unpack(">II", b[16:24])
rpc("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
    "clientInfo": {"name": "kit_playtest_rec_check", "version": "1"}})
def sessions(**a):
    s = json.loads(call("get_session", a)[0])
    assert "KiB of these at most" in s["store"], s
    return s["sessions"]
if phase == "button":
    # A kit/ui_button "Press me" on a kit/ui_panel (a bare one is not up in
    # mouse look), placed in the round after the walk (a panel with a
    # button stops the walk: it wants the clicks)
    num = lambda text: int(re.search(r"placed \S+ (\d+)", text).group(1))
    P = num(call("place", {"type": "kit/ui_panel", "pos": [0, 0, 0],
        "params": {"title": "Test", "shown": True}})[0])
    num(call("place", {"type": "kit/ui_button", "pos": [0, 0, 0], "parent": P,
        "params": {"label": "Press me"}})[0])
elif phase == "list":
    ss = sessions()
    boss = [s for s in ss if s["summary"].startswith("kitboss, ")]
    assert len(boss) == 1 and not any("kitbob" in s["summary"] for s in ss), ss
    s = boss[0]
    assert re.match(r"kitboss, \d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ, \d+ min \d+ s, "
        r"scenes world, median [0-9.]+ fps, 1 mark, 0 errors$", s["summary"]), s
    assert s["platform"] == "native" and s["input"] == "keyboard/mouse", s
    assert sessions(player="kitbob") == [], "kitbob's"
    open(out + "/session", "w").write("%d %d" % (s["session"], s["bytes"]))
elif phase == "rows":
    sid = int(open(out + "/session").read().split()[0])
    text, imgs = call("get_session", {"session": sid})
    r = json.loads(text)
    rows, kinds = r["rows"], {}
    for x in rows:
        kinds.setdefault(x["kind"], []).append(x)
    assert r["head"]["player"] == "kitboss", r["head"]
    st = kinds["session"][0]
    assert st["what"] == "start" and st["t"] == 0 and st["platform"] == "native" and \
        st["input"] == "keyboard/mouse" and st["screen"] == [1024, 700], st
    assert kinds["session"][-1]["what"] == "end", kinds["session"]
    pos = kinds["pos"]
    assert len(pos) >= 3 and all(len(p["pos"]) == 3 and "scene" in p for p in pos), pos
    assert any(p["speed"] > 0.5 for p in pos), ("never moving", pos)
    ev = kinds["event"]
    assert any(e["what"] == "ui" and e["label"] == "Press me" for e in ev), ev
    assert any(e["what"] == "emit" and e["output"] == "pressed" and
        e["entity"] == ui["entity"] for e in ev for ui in ev if ui["what"] == "ui"), ev
    assert any(e["what"] == "edit" and e["on"] is False for e in ev), ev
    pf = kinds["perf"][0]
    assert pf["fps"] > 0 and pf["fps5"] > 0 and pf["fps5"] <= pf["fps"] + 0.1 and \
        pf["worst_ms"] > 0 and pf["frames"] > 10 and "tick_ms" in pf and \
        pf["tick_max_ms"] >= pf["tick_ms"], pf
    mk = kinds["mark"]
    assert len(mk) == 1, mk
    m = mk[0]
    assert m["note"] == "the door here sticks" and len(m["pos"]) == 3 and \
        "scene" in m and m["picture"] == 0 and m["size"] == [480, 328] and \
        m["image"] == 1, m
    assert "error" not in kinds, kinds["error"]
    assert len(imgs) == 1 and size(imgs[0]) == (480, 328), [size(b) for b in imgs]
    open(out + "/mark.png", "wb").write(imgs[0])
    # Only the kinds asked, from a t on
    text, imgs = call("get_session", {"session": sid, "kinds": ["mark", "perf"]})
    k = {x["kind"] for x in json.loads(text)["rows"]}
    assert k == {"mark", "perf"} and len(imgs) == 1, (k, len(imgs))
    late = pos[-1]["t"]
    text, imgs = call("get_session", {"session": sid, "kinds": ["pos"], "since": late})
    assert all(x["t"] >= late for x in json.loads(text)["rows"]) and not imgs, text
    assert "No session 999" in call("get_session", {"session": 999}, True)[0]
    assert "kinds:" in call("get_session", {"session": sid, "kinds": ["nope"]}, True)[0]
    print("ok: %d rows: %s" % (len(rows), {k: len(v) for k, v in kinds.items()}))
elif phase == "again":
    sid = int(open(out + "/session").read().split()[0])
    assert [s["session"] for s in sessions()] == [sid], "the first not kept"
elif phase == "capped":
    sid = int(open(out + "/session").read().split()[0])
    ss = sessions()
    assert [s["session"] for s in ss] == [sid + 1], ss
    assert ss[0]["summary"].startswith("kitboss, ") and \
        ss[0]["summary"].endswith(", 1 mark, 0 errors"), ss
print("ok:", phase)
PY
mcp() # <phase>: the MCP client's phase; its output in $t/mcp_<phase>.log
{
	python3 -I "$t/mcp.py" "$1" "$url" "$tok" "$t" > "$t/mcp_$1.log" 2>&1 ||
		fail "the MCP phase $1: $(tail -5 "$t/mcp_$1.log") ($t/mcp_$1.log, $SL)"
	cat "$t/mcp_$1.log"
}
f8_mark() # <note>: by the key, sent by Enter
{
	local ms
	step 10 "kit: mark: the note asked$" "frames 3" "keypress F8"
	await "$CL" 0 10 "kit: mark: the picture taken, [0-9]+ bytes"
	ms=$(mark "$SL")
	cmd "frames 2" "text $1" "frames 2"
	step 10 "kit: mark: sent, ${#1} bytes of note, [0-9]+ bytes of picture" "keypress Return"
	await "$SL" "$ms" 10 "Playtest session [0-9]+: kitboss marked a moment \([0-9]+ bytes of note, a picture 480x328"
}

# 1. kitboss plays, kitbob beside him
mkdir -p "$t/user/shared"
(cd "$here/apps/workbench/templates/puzzle_room" && zip -qrX "$t/user/shared/room.zip" .) ||
	fail "the template not zipped"
srv "$t/srv.log" "$t/user/shared/room.zip" ""
wait_for_log "$SL" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$SL" | head -1)
[ -n "$code" ] || fail "no setup code ($SL)"
BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client boss 3
BOSS=$CLIENT
await "$CL" 0 120 "Joined as kitboss"
cmd "wait_log_any 30000 server window: the page ntfy" "frames 3" 'click Button "Don'"'"'t add"'
# (a template opens in edit mode: recorded from the join all the same)
await "$CL" 0 120 "player physics enabled"
await "$CL" 0 60 "kit editor: edit mode on"
await "$CL" 0 10 "kit: rec: this playtest is recorded"
await "$SL" 0 10 "Playtest session 1: kitboss's play recorded"
menu
step 10 "accounts: agents: 0 tokens, on" "frames 3" 'click Button "My account*"' \
	"frames 5" 'click Button "Connect an agent..."'
step 10 "accounts: agents: a token made, builder" "frames 3" \
	'click Button "Make a token..."' "frames 3" 'click Button "Make a token"'
step 10 "accounts: agents: the token copied" "frames 3" 'click Button "copy token"'
tok=$(clip)
[[ $tok =~ ^bat_[0-9a-f]{64}$ ]] || fail "kitboss's builder token: $tok"
cmd "frames 3" 'click Button "Done"'
step 10 "pause: the menu shown" "frames 3" "keypress Escape"
step 10 "pause: the menu closed" "frames 3" "keypress Escape"
mc=$(mark "$CL")
step 10 "kit editor: edit mode off" "frames 3" "keypress F6"
# Walks: two goes at it (a held key may read as not held for a while)
for i in 1 2; do
	step 10 "kit: body at" "frames 3" "keydown w" "frames 60" "keyup w" "frames 3" \
		"event kit_body"
done
mc=$(mark "$CL")
mcp button
await "$CL" "$mc" 10 'kit: ui [0-9]+ button .* shown.*: "Press me"'
m=$(mark "$SL")
cmd "frames 10" 'click Button "Press me"'
await "$SL" "$m" 10 "UI button [0-9]+ pressed by kitboss"
f8_mark "the door here sticks"
await "$CL" 0 10 "kit: rec: the first perf report sent, [0-9]+ frames"
# kitbob now (his window takes the input focus: kitboss's held keys would
# read as not held)
BUILDAT_JOIN_CREATE=1 client bob 4
BOB=$CLIENT
CL=$t/bob.log
await "$CL" 0 120 "Joined as kitbob"
await "$CL" 0 120 "player physics enabled"
CL=$t/boss.log CLIENT=$BOSS
# The pause menu's item: the field, Escape back to the menu
menu
step 10 "kit: mark: the note asked \(from the pause menu\)" "frames 3" 'click Button "Mark this moment"'
cmd "frames 3" "text never sent" "frames 2"
m=$(mark "$CL")
cmd "keypress Escape"
await "$CL" "$m" 10 "kit: mark: cancelled"
await "$CL" "$m" 10 "pause: the menu shown"
step 10 "pause: the menu closed" "frames 3" "keypress Escape"
grep -aq "Playtest session [0-9]*: kitbob" "$SL" && fail "kitbob recorded ($SL)"
grep -aq "kit: rec: this playtest is recorded" "$t/bob.log" && fail "kitbob's client told it is recorded"
m=$(mark "$SL")
cmd "sync 2000" quit
exec 3>&-
wait $BOSS 2>/dev/null
await_srv() { CLIENT=$SERVER_PID; await "$SL" "$@"; }
await_srv "$m" 10 "Playtest session 1 \(kitboss\) ended"
echo "ok: kitboss's play recorded (walked, pressed, marked by F8; the menu's mark cancelled), kitbob not"

# 2. The agent reads it
mcp list
mcp rows
read sid bytes < "$t/session"
printf '%s\n' "sync 2000" quit >&4
exec 4>&-
wait $BOB 2>/dev/null
echo "ok: get_session lists session $sid ($bytes bytes) and gives its rows and the mark's picture"

# 3. The cap: a little over the first session's bytes; the second's mark
# puts the store past it
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
srv "$t/srv2.log" "" $((bytes + 4000))
CLIENT=$SERVER_PID
mcp again
client boss 3
BOSS=$CLIENT CL=$t/boss.log
await "$CL" 0 120 "Joined as kitboss"
# (the page asking to add the server not again: Don't add was clicked)
await "$CL" 0 120 "player physics enabled"
await "$CL" 0 30 "kit: rec: this playtest is recorded"
await "$SL" 0 10 "Playtest session $((sid + 1)): kitboss's play recorded"
f8_mark "again"
await "$SL" 0 10 "Playtest session $sid dropped: past the cap of $((bytes + 4000)) bytes"
cmd "sync 2000" quit
exec 3>&-
wait $BOSS 2>/dev/null
CLIENT=$SERVER_PID
await "$SL" 0 10 "Playtest session $((sid + 1)) \(kitboss\) ended"
# (the newest kept at its end, maybe past the cap alone)
mcp capped
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
echo "ok: the first session dropped past the cap at the second's mark, the second kept"

# 4. The web client (Firefox; skipped without it or web/): webboss (the
# admin) New from Puzzle room, F6: recorded (web), the first perf report,
# a mark with its picture 480 wide by the pause menu's item (a headless
# page is given no pointer lock: the menu is up, and F8 is not a key there)
web=skipped
if command -v "${FIREFOX:-firefox}" > /dev/null && [ -f "$here/web/buildat.wasm" ]; then
	cat > "$t/steps.json" <<'J'
[
 ["nav", "${URL}"],
 ["waitlog", "accounts: the login page shown", 120], ["wait", 1000],
 ["key", "Tab"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["key", "Tab"], ["frames", 2], ["key", "Enter"], ["wait", 1000],
 ["selall"], ["frames", 2], ["type", "webboss"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["type", "checkpass12"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["type", "checkpass12"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["type", "${SETUP_CODE}"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["key", "Enter"], ["waitlog", "Joined as webboss", 30],
 ["waitlog_any", "server window: the page ntfy", 30], ["frames", 3],
 ["click", "Button", "Don't add"], ["frames", 3],
 ["waitlog_any", "world_menu: the list shown", 30], ["frames", 3],
 ["click", "Button", "New game..."],
 ["waitlog", "world_menu: the name screen shown", 10], ["frames", 3],
 ["click", "DropDownList", "▼"], ["waitlog", "dropdown_[0-9]+ open", 10], ["frames", 3],
 ["click", "Text", "Puzzle room"], ["waitlog", "world_menu: template picked", 10],
 ["frames", 3], ["click", "Button", "Create"],
 ["waitlog", "kit editor: edit mode on", 120], ["frames", 5],
 ["key", "F6"], ["waitlog", "kit editor: edit mode off", 10],
 ["waitlog_any", "kit: rec: this playtest is recorded", 20],
 ["waitlog_any", "kit: rec: the first perf report sent", 20],
 ["waitlog_any", "pause: the menu shown", 20], ["frames", 5],
 ["click", "Button", "Mark this moment"],
 ["waitlog", "kit: mark: the note asked \\(from the pause menu\\)", 10],
 ["waitlog", "kit: mark: the picture taken, [0-9]+ bytes", 10], ["frames", 2],
 ["type", "on the web"], ["frames", 2], ["key", "Enter"],
 ["waitlog", "kit: mark: sent, 10 bytes of note, [0-9]+ bytes of picture", 10],
 ["frames", 10]
]
J
	"$here/util/web_drive.sh" firefox workbench "$t/steps.json" "$t/web" ||
		fail "the web drive ($t/web)"
	for re in "Playtest session 1: webboss's play recorded" \
			"Playtest session 1: webboss's client: web, [0-9]+x[0-9]+, keyboard/mouse" \
			"Playtest session 1: webboss marked a moment \(10 bytes of note, a picture 480x[0-9]+"; do
		grep -aqE "$re" "$t/web/server.log" || fail "no \"$re\" in $t/web/server.log"
	done
	web="recorded, its perf report and a mark with its picture"
fi
echo "ok: the web client: $web"
for f in "$t"/*.log; do
	grep -qaF "${tok#bat_}" "$f" && fail "the token in $f"
done
echo "PASS: a builder's playtest recorded (start, places, a UI press, perf, a mark with its 480x328 picture by F8; the pause menu's mark cancelled by Escape), a non-builder's not; get_session's list and rows, kinds and since; the oldest session dropped past BUILDAT_KIT_REC_CAP; the web client: $web; $t/mark.png"
