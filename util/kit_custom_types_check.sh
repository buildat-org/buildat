#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min (2026-11-15)
# covers: builtin/kit/kit.cpp builtin/kit/box/box.c builtin/kit/client_lua/editor.lua builtin/kit/client_lua/module.lua builtin/kit/client_lua/field_entry.lua src/impl/aitta.cpp apps/workbench/main/main.cpp 3rdparty/Urho3D/Source/Urho3D/UI/LineEdit.h
# [KIT_CUSTOM_TYPES] A project's own types, local/<name>, on Workbench; one
# server, kitboss (the admin) and kitbob on a headless weston's Xwayland of the check's
# own (its clipboard carries the agent token):
#   0. a template carrying its own types (types/lamp.lua with a client part,
#      types/chair.lua, a seat whose movement says its version in s.jumps)
#      packed and installed (`buildat aitta pack`, `install`); one with a
#      types/ name that is not plain, one using a local/ type it lacks and
#      one with a link in types/, refused at pack;
#   1. New from it: its types imported, the lamp's client part run;
#   2. the editor's "New type...": the name typed, Save, the type in the
#      palette and armed (new_type.png, palette.png);
#   3. an agent's token by My account, then the MCP tools: list_types and the
#      guide say custom; get_type round-trips the template's files and reads
#      Kit's, not the app's own (workbench/secret, BUILDAT_WORKBENCH_TYPES);
#      names, sizes and bytecode refused; a type of 6 KB (past the
#      edit packet's 4096 bytes) put, placed, linked from a timer and Run;
#      put again while Running: its count kept, the new on_input counting;
#      a syntax error, a load error and a broken client part refused with
#      their errors while the version before counts on (said in the
#      entity's Log); the lamp's client part changed, the client's swap
#      seen; undo puts the version before back;
#   4. "Edit type" on that 6 KB one in the inspector: read and saved over
#      kit:type (edit_type.png); [KIT_CRAG_PLAYTEST_1] the dialog the whole
#      window, the wheel over the server part scrolling its text at kitboss's
#      editor text of 80 % (edit_type_wheel.png);
#   5. the chair used: the client's body steps with version 1, the agent
#      puts version 2, the body steps with it (the client takes the new
#      movement) and the server says the entity reloaded; the chair in
#      kit/controls' movement list;
#   6. delete_type refused while in use, then done; a define that never
#      ends refused (the box's budget), the agent's next put held back, the
#      server and the other types fine;
#   7. kitbob, no builder (registration open): his kit:type put and get
#      refused, and his agent's token gets no put_type, get_type or
#      delete_type.
# kitboss's editor text at its default 80 %, a fractional font size.
# Screenshots, kept with KEEP_TMP=1: $t/new_type.png, $t/palette.png,
# $t/edit_type.png, $t/edit_type_wheel.png
#   util/kit_custom_types_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
for c in weston xclip; do
	command -v $c > /dev/null || skip "no $c"
done
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_custom_types; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12
check_build
b="$here/Build/bin/buildat"

# 0. The template, its types; packed and installed
d0=$t/tmpl/custom_types
mkdir -p "$d0/types"
cat > "$d0/meta.json" <<'EOF'
{
	"kind": "template",
	"author": "checker",
	"name": "custom_types",
	"title": "Custom types check",
	"version": "1.0.0",
	"engine_api": 2,
	"license_code": "CC0-1.0",
	"license_media": "CC0-1.0",
	"description": "A check's: a lamp and a chair of its own."
}
EOF
echo "CC0-1.0" > "$d0/LICENSE"
cat > "$d0/composition.json" <<'EOF'
{
	"entities": [
		{"id": 2, "name": "world", "kind": "scene"},
		{"id": 3, "parent": 2, "name": "the ground", "components": [{"type": "kit/terrain", "params": {"generator": "flat", "surface": "voxels", "biome": "grassland", "decorations": false, "width": 32, "depth": 32}}]},
		{"id": 4, "parent": 2, "name": "start", "pos": [0, 1, -4], "components": [{"type": "kit/spawner", "params": {"players": true}}]},
		{"id": 5, "parent": 2, "name": "lamp", "pos": [3, 1, -4], "components": [{"type": "local/lamp"}]},
		{"id": 6, "parent": 2, "name": "chair", "pos": [0, 1, -2], "components": [{"type": "local/chair"}]}
	]
}
EOF
cat > "$d0/types/lamp.lua" <<'EOF'
-- The template's own: a lamp with a label
return {
	version = 1,
	about = {group = "Building", what = "A lamp of the template's."},
	look = {shape = "box", size = 0.3, color = "#ffe080", text = "label"},
	state = {label = {default = "lamp", shared = true}},
}
EOF
cat > "$d0/types/lamp.client.lua" <<'EOF'
return {
	on_add = function(e)
		e:log("lamp v1 added")
	end,
}
EOF
# (its step's s.jumps: the version stepping it)
cat > "$d0/types/chair.lua" <<'EOF'
-- A seat that holds its player still
return {
	version = 1,
	about = {group = "Vehicles", what = "A chair: sit, and stay."},
	usable = true,
	seat = true,
	look = {shape = "box", size = 0.4, color = "#a06030", solid = true},
	movement = {body = {r = 0.4, h = 1}, camera = "chase"},
	step = function(s, i, dt, w, p)
		s.pos = type(s.pos) == "table" and s.pos or {0, 0, 0}
		s.jumps = 1
	end,
}
EOF
"$b" aitta keygen "$t/key" > "$t/pub" 2>/dev/null || fail "keygen"
zip=$("$b" aitta pack "$d0" "$t/key" "$t/out" 2> "$t/pack.err") || fail "the pack ($t/pack.err)"
"$b" aitta install "$zip" "$t/user" > "$t/install.txt" 2>&1 || fail "the install ($t/install.txt)"
fp=$(aitta_fp "$t/pub")
[ -f "$t/user/installed/$fp/custom_types/1.0.0/types/chair.lua" ] ||
	fail "no types/chair.lua installed ($t/install.txt)"
refused() # <dir> <what>: pack refuses it, saying <what>
{
	if "$b" aitta pack "$1" "$t/key" "$t/out_bad" > /dev/null 2> "$t/bad.err"; then
		fail "packed: $1"
	fi
	grep -qF "$2" "$t/bad.err" || fail "$1 refused, but not for \"$2\": $(cat "$t/bad.err")"
}
cp -r "$d0" "$t/bad1"
cp "$d0/types/lamp.lua" "$t/bad1/types/Lamp-2.lua"
refused "$t/bad1" "types/ holds <name>.lua and <name>.client.lua only"
cp -r "$d0" "$t/bad2"
sed -i 's|"local/chair"|"local/sofa"|' "$t/bad2/composition.json"
refused "$t/bad2" "its own, local/<name> with types/<name>.lua"
cp -r "$d0" "$t/bad3"
ln -sf "$t/key" "$t/bad3/types/lamp.lua"
refused "$t/bad3" "types/lamp.lua: not a regular file of some bytes (a link is refused)"
echo "ok: the template packed and installed with its types; the bad ones (a link too) refused"

sock=buildat-types-$$
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
		kill -0 $CLIENT 2>/dev/null || fail "the client is gone ($CL)"
		sleep 0.2
	done
	fail "no \"$4\" in $1 in $3 s ($SL, $CL)"
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
# An app's own type: listed, its file not served (an app's logic may be private)
mkdir -p "$t/user/apps/workbench/check_types"
echo 'return {version = 1, look = {shape = "box", size = 0.2}} -- secret' \
	> "$t/user/apps/workbench/check_types/secret.lua"
export BUILDAT_WORKBENCH_TYPES=$t/user/apps/workbench/check_types
start_server "$SL" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
	--sim-rate "$CHECK_RATE" || fail "the server did not come up ($SL)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$SL" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$SL" | head -1)
[ -n "$code" ] || fail "no setup code ($SL)"
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
# (registration open for kitbob, who is no builder)
BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 BUILDAT_TEST_EDITOR_FONT=80 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client boss
BOSS=$!
exec 3> "$t/boss.cmd"
as boss
await "$CL" 0 120 "Joined as kitboss"
cmd "wait_log_any 30000 server window: the page ntfy" "frames 3" 'click Button "Don'"'"'t add"'
# 1. New from the template
await "$CL" 0 30 "world_menu: the list shown"
step 10 "world_menu: the name screen shown" "frames 3" 'click Button "New game..."'
cmd "frames 3" 'click DropDownList "▼"' "delay 300" "frames 3"
step 10 "world_menu: template picked" 'click Text "Custom types check (checker, installed, unverified)"'
step 60 "kit editor: edit mode on" "frames 3" 'click Button "Create"'
await "$CL" 0 30 "player physics enabled"
await "$CL" 0 10 "kit: entity 5's client part: lamp v1 added"
for re in "The template's type local/lamp \([0-9]+ bytes\)" "The template's type local/chair " \
		"Custom types: 2"; do
	grep -aqE "$re" "$SL" || fail "no \"$re\" in $SL"
done
echo "ok: a project from the template, its types imported and run"
# 2. New type...: a name, Save; in the palette
step 10 "kit editor: the type dialog, new" "frames 3" 'click Button "type new"'
cmd "frames 3" 'click LineEdit "type name"' "frames 2" "keydown ctrl" "keypress a" \
	"keyup ctrl" "text ui_counter" "frames 3" "screenshot $t/new_type.png"
step 10 "kit editor: type: put local/ui_counter: Saved: the type local/ui_counter put: [0-9]+ bytes" \
	'click Button "type save"'
grep -aq "An edit by kitboss: the type local/ui_counter put" "$SL" || fail "no edit of ui_counter by kitboss ($SL)"
cmd "frames 3" 'click Button "type close"' "frames 3"
m=$(mark "$CL")
cmd "$(pal_find ui_counter)"
await "$CL" "$m" 10 'kit editor: the palette for "ui_counter": 1: local/ui_counter'
step 10 "kit editor: placing local/ui_counter" 'click Button "local/ui_counter"'
cmd "frames 5" "screenshot $t/palette.png"
step 10 "kit editor: placing nothing" 'click Button "local/ui_counter"'
echo "ok: New type..., saved, in the palette"
# 3. The token, then the MCP tools
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
token() # the driven client's agent token, by My account, into $tok
{
	local i old=${tok:-}
	menu
	step 10 "accounts: agents: 0 tokens, on" "frames 3" 'click Button "My account*"' \
		"frames 5" 'click Button "Connect an agent..."'
	step 10 "accounts: agents: a token made, builder" "frames 3" \
		'click Button "Make a token..."' "frames 3" 'click Button "Make a token"'
	step 10 "accounts: agents: the URL copied" "frames 3" 'click Button "copy URL"'
	for i in $(seq 50); do
		url=$(DISPLAY=$d xclip -selection clipboard -o 2>/dev/null)
		[[ $url == http*/api/v1/mcp ]] && break
		sleep 0.2
	done
	step 10 "accounts: agents: the token copied" "frames 3" 'click Button "copy token"'
	for i in $(seq 50); do
		tok=$(DISPLAY=$d xclip -selection clipboard -o 2>/dev/null)
		[[ $tok =~ ^bat_[0-9a-f]{64}$ ]] && [ "$tok" != "$old" ] && break
		sleep 0.2
	done
	[[ $url == http*/api/v1/mcp ]] && [[ $tok =~ ^bat_[0-9a-f]{64}$ ]] && [ "$tok" != "$old" ] ||
		fail "no address or no new token on the clipboard: $url $tok"
	cmd "frames 3" 'click Button "Done"'
	step 10 "pause: the menu shown" "frames 3" "keypress Escape"
	step 10 "pause: the menu closed" "frames 3" "keypress Escape"
}
token
cat > "$t/mcp.py" <<'PY'
import json, re, sys, time, urllib.error, urllib.request
phase, url, tok, tmpl = sys.argv[1:5]
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
    assert len(c) == 1 and c[0]["type"] == "text", r
    shown = {k: (v if len(str(v)) < 60 else "<%d bytes>" % len(v)) for k, v in args.items()}
    assert r["isError"] == error, (name, shown, r)
    print(" ", name, json.dumps(shown), "->", c[0]["text"][:160])
    return c[0]["text"]
def state():
    return json.loads(call("get_state"))
def entity(i):
    return [e for e in state()["entities"] if e["id"] == i][0]
def placed(text):
    return int(re.search(r"placed \S+ (\d+)", text)[1])
def until(f, what, tries=75):
    for i in range(tries):
        v = f()
        if v:
            return v
        time.sleep(0.2)
    raise AssertionError("never: " + what)
def logs(i):
    return json.loads(call("get_log", {"id": i}))
def ids():
    return json.load(open(tmpl + "/../ids.json"))
# A counter past the edit packet's 4096 bytes: on "count" it adds by
PAD = "".join("-- line %02d of the padding: this file is past the 4096 bytes "
    "of an edit packet\n" % i for i in range(64))
def counter(version, by, body=""):
    return PAD + """return {
	version = %d,
	about = {group = "Logic", what = "Counts by %d."},
	look = {shape = "box", size = 0.25, color = "#40e080", text = "count"},
	state = {count = {default = 0, shared = true}},
	inputs = {count = "none"},
	outputs = {changed = "number"},
	on_input = function(c, input, value, by)
		c.state.count = c.state.count + %d
		c:emit("changed", c.state.count)
	end,%s
}
""" % (version, by, by, body)
rpc("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
    "clientInfo": {"name": "kit_custom_types_check", "version": "1"}})
if phase == "main":
    tools = {t["name"]: t for t in rpc("tools/list")["result"]["tools"]}
    d = tools["put_type"]["description"]
    for w in ("step = function(s, i, dt, w, p)", "on_input(c, input, value, by)",
            "c:emit(output, value)", "look = {shape", "migrate(params, from)"):
        assert w in d, (w, d)
    assert "get_type" in tools and "delete_type" in tools
    st = state()
    if st["running"]:
        call("stop")
    types = {t["type"]: t for t in json.loads(call("list_types"))}
    for t in ("local/lamp", "local/chair", "local/ui_counter"):
        assert types[t].get("custom") is True, types.get(t)
    assert not types["kit/counter"].get("custom"), types["kit/counter"]
    assert json.loads(call("list_types", {"type": "local/chair"}))["custom"] is True
    guide = call("get_guide")
    assert re.search(r"\n- local/lamp[^\n]*\(custom\)", guide) and "put_type" in guide, guide[:2000]
    # get_type: the template's files as they were, Kit's to read
    lamp = json.loads(call("get_type", {"type": "lamp"}))
    assert lamp["type"] == "local/lamp" and lamp["custom"] and lamp["by"] == "the template", lamp
    assert lamp["source"] == open(tmpl + "/types/lamp.lua").read(), lamp
    assert lamp["client"] == open(tmpl + "/types/lamp.client.lua").read(), lamp
    k = json.loads(call("get_type", {"type": "kit/counter"}))
    assert k["custom"] is False and "on_input" in k["source"], k
    call("get_type", {"type": "nope"}, error=True)
    assert "workbench/secret" in [t["type"] for t in json.loads(call("list_types"))]
    assert call("get_type", {"type": "workbench/secret"}, error=True).startswith("no type")
    # Refused, before anything is run
    ok = "return {version = 1}"
    for args, why in (
            ({"name": "../x", "source": ok}, "local/<name>"),
            ({"name": "local/../x", "source": ok}, "local/<name>"),
            ({"name": "kit/counter", "source": ok}, "local/<name>"),
            ({"name": "a.b", "source": ok}, "local/<name>"),
            ({"name": "x" * 65, "source": ok}, "local/<name>"),
            ({"name": "big", "source": ""}, "1 to 65536 bytes"),
            ({"name": "big", "source": "-" * 70000}, "1 to 65536 bytes"),
            ({"name": "big", "source": ok, "client": "-" * 40000}, "32768 bytes at most"),
            ({"name": "big", "source": "\x1bLuaQ"}, "precompiled"),
            ({"name": "big", "source": ok, "client": "\x1bLuaQ"}, "precompiled")):
        assert why in call("put_type", args, error=True), (args["name"], why)
    call("place", {"type": "local/big_counter", "pos": [3, 1, 2]}, error=True)
    # Put, placed, linked from a timer, Run
    v1, v2 = counter(1, 1), counter(2, 1000)
    assert len(v1) > 4096, len(v1)
    r = call("put_type", {"name": "big_counter", "source": v1})
    assert r == "the type local/big_counter put: %d bytes" % len(v1), r
    B = placed(call("place", {"type": "local/big_counter", "pos": [3, 1, 2]}))
    T = placed(call("place", {"type": "kit/timer", "pos": [3, 1, 4]}))
    call("set_param", {"id": T, "param": "interval", "value": 0.2})
    call("set_param", {"id": T, "param": "autostart", "value": True})
    call("link", {"id": T, "output": "tick", "to": B, "input": "count"})
    assert call("start") == "Running"
    def count():
        return entity(B)["components"][0]["state"].get("count", 0)
    c0 = until(lambda: (lambda c: c >= 2 and c)(count()), "counting by 1")
    # Again while Running: the count kept, the new handler's step
    r = call("put_type", {"name": "big_counter", "source": v2})
    assert r.startswith("the type local/big_counter changed (version 1 to 2): %d bytes" % len(v2)) and \
        r.endswith(", 1 entities reloaded"), r
    c = until(lambda: (lambda c: c >= 1000 and c)(count()), "counting by 1000")
    kept = c % 1000
    assert c0 <= kept < 1000, (c0, c)
    assert any("local/big_counter reloaded, kitboss's agent's edit" in l for l in logs(B)), logs(B)
    # Broken: refused with the error, the version before counting on
    for args, why in (
            ({"source": counter(3, 5, "\n\ton_use = function(c")},
                "expected"),
            ({"source": counter(3, 5, "\n\tbroken = error(\"no such luck\"),")},
                "no such luck"),
            ({"source": v2, "client": "return {on_add = function(e) end"},
                "local/big_counter.client:1: ")):
        r = call("put_type", dict(args, name="big_counter"), error=True)
        assert r.startswith("Refused: ") and "local/big_counter" in r and why in r, (why, r)
        c = count()
        c = until(lambda: (lambda n: n >= c + 2000 and n)(count()), "counting on")
        assert c % 1000 == kept, (c, kept)
    assert any("local/big_counter not reloaded, the version before runs: " in l and "no such luck" in l
        for l in logs(B)), logs(B)
    got = json.loads(call("get_type", {"type": "local/big_counter"}))
    assert got["source"] == v2 and got["client"] == "" and got["by"] == "kitboss's agent", got["by"]
    # A client part changed: the clients run the new one on the lamp
    call("put_type", {"name": "lamp", "source": lamp["source"],
        "client": lamp["client"].replace("lamp v1", "lamp v2")})
    # Undo: the version before
    assert "Undone: the type local/lamp changed" in call("undo")
    assert json.loads(call("get_type", {"type": "lamp"}))["client"] == lamp["client"]
    assert "Undone: the type local/big_counter changed" in call("undo")
    assert json.loads(call("get_type", {"type": "big_counter"}))["source"] == v1
    c1 = count()
    c = until(lambda: (lambda n: n >= c1 + 2 and n)(count()), "counting by 1 again")
    assert c - c1 < 1000, (c1, c)
    json.dump({"B": B, "T": T}, open(tmpl + "/../ids.json", "w"))
elif phase == "seat":
    ch = json.loads(call("get_type", {"type": "chair"}))
    r = call("put_type", {"name": "chair", "source": ch["source"].replace(
        "s.jumps = 1", "s.jumps = 2")})
    assert r.endswith(", 1 entities reloaded"), r
elif phase == "controls":
    # A custom movement is kit/controls' movement too
    C = placed(call("place", {"type": "kit/controls", "pos": [0, 1, 0]}))
    assert "local/chair" in call("set_param", {"id": C, "param": "movement",
        "value": "local/chair"})
    json.dump(dict(ids(), C=C), open(tmpl + "/../ids.json", "w"))
elif phase == "bob":
    # No builder: his agent gets nothing
    for name, args in (("put_type", {"name": "bob_type", "source": "return {version = 1}"}),
            ("get_type", {"type": "lamp"}), ("delete_type", {"name": "lamp"})):
        assert "No edit rights here" in call(name, args, error=True)
elif phase == "end":
    B = ids()["B"]
    T = ids()["T"]
    assert call("stop").startswith("Ended")
    if any(e["id"] == ids()["C"] for e in state()["entities"]):
        call("delete", {"id": ids()["C"]})
    # A param the file no longer has: dropped from the entity, the round's
    # start still loading
    knob = "return {version = 1, look = {shape = \"box\", size = 0.2}, params = {%s}}"
    call("put_type", {"name": "knob", "source": knob % "turns = {type = \"number\", default = 1, min = 0, max = 9}"})
    K = placed(call("place", {"type": "local/knob", "pos": [5, 1, 0], "params": {"turns": 5}}))
    assert entity(K)["components"][0]["params"]["turns"] == 5
    call("put_type", {"name": "knob", "source": knob % ""})
    assert "turns" not in entity(K)["components"][0].get("params", {}), entity(K)
    assert call("start") == "Running" and entity(K)
    assert call("stop").startswith("Ended") and entity(K)
    assert "is in use: entity %d has it" % B in call("delete_type", {"name": "big_counter"}, error=True)
    call("delete", {"id": B})
    assert call("delete_type", {"name": "big_counter"}) == "the type local/big_counter deleted"
    assert "local/big_counter" not in [t["type"] for t in json.loads(call("list_types"))]
    call("get_type", {"type": "big_counter"}, error=True)
    call("delete_type", {"name": "big_counter"}, error=True)
    # One that never ends: past the box's budget, the next put held back
    r = call("put_type", {"name": "spin", "source": "while true do end"}, error=True)
    assert "past its budget" in r, r
    # (5 times as long as that took; then taken)
    r = call("put_type", {"name": "spin2", "source": "return {version = 1}"}, error=True)
    assert "your last type took a long time to load" in r, r
    until(lambda: not rpc("tools/call", {"name": "put_type", "arguments": {"name":
        "spin2", "source": "return {version = 1}"}})["result"]["isError"],
        "the put after the wait", 25)
    call("delete_type", {"name": "spin2"})
    # The rest as it was
    types = [t["type"] for t in json.loads(call("list_types"))]
    assert "local/lamp" in types and "local/chair" in types and "local/spin" not in types, types
    assert call("start") == "Running"
    assert entity(T)["components"][0]["type"] == "kit/timer"
    assert call("stop").startswith("Ended")
print("ok:", phase)
PY
mcp() # <phase>
{
	python3 -I "$t/mcp.py" "$1" "$url" "$tok" "$d0" > "$t/mcp_$1.log" 2>&1 ||
		fail "the MCP $1 run: $(tail -5 "$t/mcp_$1.log") ($t/mcp_$1.log, $SL)"
	cat "$t/mcp_$1.log"
}
m=$(mark "$CL")
mcp main
for re in "An edit by kitboss's agent: the type local/big_counter put: [0-9]+ bytes" \
		"An edit by kitboss's agent: the type local/big_counter changed \(version 1 to 2\)" \
		"An undo by kitboss's agent: the type local/big_counter changed \(version 2 to 1\)"; do
	grep -aqE "$re" "$SL" || fail "no \"$re\" in $SL"
done
# (the lamp's client part, swapped on the client and back)
await "$CL" "$m" 10 "kit: entity 5's client part: lamp v2 added"
await "$CL" "$m" 10 "kit: entity 5's client part: lamp v1 added"
echo "ok: the agent's types: put, run, reloaded while Running, refused, read back, undone"
# 4. Edit type in the inspector: the 6 KB file read and saved over kit:type
B=$(grep -aoP '"B": \K[0-9]+' "$t/tmpl/ids.json")
step 10 "kit editor: the inspector" "event kit_select $B"
cmd "event kit_inspector_show edit type local/big_counter" "frames 3"
step 10 "kit editor: type: get local/big_counter: read" 'click Button "edit type local/big_counter"'
# [KIT_CRAG_PLAYTEST_1] The dialog the whole window (the parts side by side
# where 2 x 80 characters fit, else under tabs), the server part's text
# from its top; the wheel over it scrolls it. A fractional font size (80 %)
# brought the cursor back into view each frame, undoing the wheel
step 10 "Wrote screenshot $t/edit_type_wheel.png" "frames 5" "screenshot $t/edit_type.png" \
	"mouse_pos 700 400" "frames 3" "mouse_wheel -5" "frames 5" "screenshot $t/edit_type_wheel.png"
python3 -I - "$t/edit_type.png" "$t/edit_type_wheel.png" <<'PY2' || fail "the wheel scrolled no text ($t/edit_type.png, $t/edit_type_wheel.png)"
import sys
from PIL import Image, ImageChops
a, b = (Image.open(p).convert("L").crop((520, 150, 1000, 600)) for p in sys.argv[1:3])
n = sum(1 for v in ImageChops.difference(a, b).getdata() if v > 60)
print(f"the wheel: {n} pixels of the server part's text changed")
sys.exit(0 if n > 2000 else 1)
PY2
step 10 "kit editor: type: put local/big_counter: Saved: the type local/big_counter changed: [0-9]{4} bytes" \
	'click Button "type save"'
grep -aqE "An edit by kitboss: the type local/big_counter changed: [0-9]{4} bytes, 1 entities reloaded" "$SL" ||
	fail "no edit of big_counter by kitboss ($SL)"
cmd "frames 3" 'click Button "type close"' "frames 3"
echo "ok: Edit type: read and saved; $(grep -aoP 'kit editor: type: \K(side by side|tabs, \w+)' "$CL" | tail -1) in the whole window, the wheel scrolled its text at an 80 % text size"
# 5. The chair: its step, then the agent's next one
step 10 "kit editor: edit mode off" "frames 3" "keypress F6"
step 10 "kit: controls: camera chase, pointer crosshair, movement local/chair, seat 6" "frames 10" "event kit_use 6"
step 10 "kit: body at [-0-9.,]+, [0-9]+ acks, [0-9]+ corrections, [0-9]+ pending, 1 jumps" "frames 20" "event kit_body"
m=$(mark "$CL")
mcp seat
await "$CL" "$m" 10 "kit: the movement local/chair$"
step 10 "kit: body at [-0-9.,]+, [0-9]+ acks, [0-9]+ corrections, [0-9]+ pending, 2 jumps" "frames 20" "event kit_body"
grep -aq "An edit by kitboss's agent: the type local/chair changed: [0-9]* bytes, 1 entities reloaded" "$SL" ||
	fail "no chair reload ($SL)"
step 10 "kit: controls: camera [a-z_]+, pointer crosshair, movement kit/walker" "frames 3" "keypress F"
step 10 "kit editor: edit mode on" "frames 3" "keypress F6"
echo "ok: the chair's body stepped with its new version"
# (and it is in kit/controls' movement list)
mcp controls
C=$(grep -aoP '"C": \K[0-9]+' "$t/tmpl/ids.json")
step 10 "kit editor: the movements: .*local/chair" "event kit_select $C"
echo "ok: local/chair in kit/controls' movement list"
# 6. Deleted, and one that never ends
mcp end
grep -aq "A new box after: past its budget" "$SL" || fail "no new box after the endless one ($SL)"
# 7. kitbob, no builder: his kit:type refused, and his agent's tools
boss_tok=$tok
BUILDAT_JOIN_CREATE=1 client bob
BOB=$!
exec 4> "$t/bob.cmd"
as bob
await "$CL" 0 120 "Joined as kitbob"
await "$CL" 0 60 "player physics enabled"
m=$(mark "$SL")
cmd 'event kit_type {"op": "put", "name": "bob_type", "source": "return {version = 1}"}' \
	"frames 3" 'event kit_type {"op": "get", "name": "lamp"}'
await "$SL" "$m" 10 "A type get \(local/lamp\) by peer [0-9]+ refused: no edit rights here"
tail -c +$((m + 1)) "$SL" | grep -aqE "A type put \(local/bob_type\) by peer [0-9]+ refused: no edit rights here" ||
	fail "kitbob's put not refused ($SL)"
# (My account once first: its first page is drawn before the hello comes,
# without "Connect an agent...", then again with it, and token() clicks at
# once; accounts.lua)
menu
step 10 "accounts: hello: logged in already" "frames 3" 'click Button "My account*"'
step 10 "pause: the menu shown" "frames 3" "keypress Escape"
step 10 "pause: the menu closed" "frames 3" "keypress Escape"
token
[ "$tok" != "$boss_tok" ] || fail "kitbob's token is kitboss's"
mcp bob
grep -aq "An edit by kitbob" "$SL" && fail "an edit by kitbob ($SL)"
echo "ok: kitbob, no builder, refused by kit:type and as an agent"
for f in 3 4; do
	FD=$f cmd "sync 2000" quit
done
exec 3>&- 4>&-
wait $BOSS $BOB 2>/dev/null
for p in new_type palette edit_type; do
	[ -s "$t/$p.png" ] || fail "no screenshot $t/$p.png"
done
for k in "$tok" "$boss_tok"; do
	grep -aqF "${k#bat_}" "$SL" "$t/boss.log" "$t/bob.log" && fail "a token is in a log"
done
echo "PASS: custom types from a template, the editor and an agent: put, run, reloaded while Running, refused while the old ran, read back, undone, a movement's body switched and in kit/controls' list, deleted; a non-builder refused; screenshots $t/new_type.png $t/palette.png $t/edit_type.png"
# vim: set noet ts=4 sw=4:
