#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~4 min (2026-11-16)
# covers: builtin/kit/kit.cpp builtin/kit/client_lua/editor.lua builtin/kit/client_lua/module.lua builtin/kit/types/ui_scene_list.lua builtin/accounts/accounts.cpp apps/workbench/main/main.cpp apps/workbench/main/client_lua/init.lua apps/workbench/templates/crag_trial/** src/impl/aitta.cpp src/boot/autodetect.cpp
# [KIT_SERVER_PUBLISH] A Workbench server publishing to a local Aitta as
# itself, and installing through it; [KIT_SCENE_ADD_LIVE] a scene added
# while Running; 4z20's integration: Crag Trial's The Loop published from a
# Crag Trial project and added back into one without it. kitboss (the
# admin) and kitbob (a builder) on a headless weston's Xwayland of the
# check's own (its clipboard carries kitboss's agent tokens):
#   1. New "crag" from Crag Trial; a Builder and an Admin token (My
#      account); kitbob joins, a builder by set_builder; his server_publish
#      refused: no right.
#   2. The Server window's Admin / Publishing: the key made (author
#      crags; publish.key mode 600), the Aitta listed, not bound; bound on
#      the Aitta (its bind request); Check again: bound; kitbob given the
#      right (page.png).
#   3. kitbob in the scene loop: the New tab asks through the server;
#      Publish this scene..., As this server (crags), the form (form.png),
#      its licence CC-BY-4.0: crags/loop 1.0.0 on the Aitta.
#   4. MCP with kitboss's tokens: list_aitta lists it (its
#      buildat_version); publish_scene the next (1.0.1, unasked); an
#      unlisted Aitta refused for both a publish and an install; a template's
#      install refused to the Builder token, publish_log too; the Admin
#      token's publish_log: kitbob's 1.0.0 and kitboss's 1.0.1; each release
#      on the Aitta crags', published_by its builder, buildat_version in its
#      meta.json, its LICENSE naming the builder.
#   5. Stopped: the project's local/crag_gem changed (a clash to come);
#      Remove the scene loop, its undo (back), removed again. Running,
#      kitbob riding The Crags: install_from_aitta adds it (unlisted, the
#      differing crag_gem the project's, logged); the track list without it
#      until list_scene, then with The Loop; kitbob's run unbroken. His
#      finish, the Lobby, The Loop picked: its run entered, the root's
#      bike's crash by name to its run, its finish the root's lobby's
#      "over" and result card (loop.png). Remove refused with him on it,
#      the agent's undo of its install too; done once he left.
#   6. The web client (headless Chrome; skipped without web/ or Chrome),
#      kitbob: the New tab through the server, The Loop added from the
#      server's Aitta, then published as the server (1.0.2, its publisher
#      kitbob). The key's private half in no file of the run but its own.
# The alpha gate's self-check (autodetect.cpp) runs at each start.
# Screenshots, kept with KEEP_TMP=1: $t/page.png, $t/form.png, $t/loop.png,
# $t/web/web_form.png
#   util/kit_server_publish_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
for c in weston xclip unzip; do
	command -v $c > /dev/null || skip "no $c"
done
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_server_publish; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12
check_build
web=""
if command -v "${CHROME:-google-chrome}" > /dev/null && [ -f "$here/web/buildat.wasm" ]; then
	web="-W $here/web"
fi
sock=buildat-srvpub-$$
weston --backend=headless --xwayland --socket=$sock --width=1100 \
	--height=900 > "$t/weston.log" 2>&1 &
CHECK_PIDS+=($!)
for i in $(seq 50); do
	d=$(grep -ao "xserver listening on display :[0-9]*" "$t/weston.log" | grep -o ":[0-9]*$")
	[ -n "$d" ] && break
	sleep 0.2
done
[ -n "$d" ] || fail "weston's Xwayland ($t/weston.log)"
SL=$t/srv.log CL=$t/boss.log FD=3 CLIENT=
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
		[ -z "$CLIENT" ] || kill -0 $CLIENT 2>/dev/null || fail "the client is gone ($CL)"
		sleep 0.2
	done
	fail "no \"$4\" in $1 in $3 s ($SL, $CL)"
}
seen() { tail -c +$(($2 + 1)) "$1" | grep -qaE "$3"; } # <log> <offset> <regex>
cmd() { printf '%s\n' "$@" >&$FD; }
step() # <seconds> <regex in the client's log> <command>...
{
	local s=$1 re=$2 m
	shift 2
	m=$(mark "$CL")
	cmd "$@"
	await "$CL" "$m" "$s" "$re"
}
edit() # <seconds> <regex in the server's log> <kit:edit JSON>
{
	local m
	m=$(mark "$SL")
	cmd "event kit_edit $3"
	await "$SL" "$m" "$1" "$2"
}
menu() # Escape until the pause menu is up (the editor's own Escapes first)
{
	local i k m
	for i in 1 2 3; do
		m=$(mark "$CL")
		cmd "frames 3" "keypress Escape"
		for k in $(seq 15); do
			seen "$CL" "$m" "pause: the menu shown" && return 0
			sleep 0.2
		done
	done
	fail "no pause menu ($CL)"
}
clip() # <last>: the clipboard once it holds a token other than <last>
{
	local i got
	for i in $(seq 50); do
		got=$(DISPLAY=$d xclip -selection clipboard -o 2>/dev/null)
		[[ $got =~ ^bat_[0-9a-f]{64}$ ]] && [ "$got" != "$1" ] && break
		sleep 0.2
	done
	printf '%s' "$got"
}
body() # the body's x and y now, into bx and by
{
	step 5 "kit: body at" "event kit_body"
	read bx by <<< "$(tail -c 3000 "$CL" | grep -aoP 'kit: body at \K-?[0-9.]+,-?[0-9.]+' |
		tail -1 | tr , ' ')"
}
client() # <name>: kit<name>, its commands from the fifo $t/<name>.cmd, its log $t/<name>.log
{
	mkfifo "$t/$1.cmd"
	sleep 900 > "$t/$1.cmd" &
	CHECK_PIDS+=($!)
	DISPLAY=$d WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11 BUILDAT_JOIN_NAME=kit$1 \
		timeout 600 bin/buildat -C "$t/client_cache_$1" -D "$t/cu_$1" \
		-s localhost:$WP -w 1024x700 -l 3 -o sound_mute=1 -c - \
		< "$t/$1.cmd" > "$t/$1.log" 2>&1 &
	CHECK_PIDS+=($!)
}

# The Aitta; the server may reach its port
start_server "$t/aitta.log" "setup code" 120 auto \
	bin/buildat_server -m ../apps/aitta -D "$t/aitta" -l 3 ||
	fail "Aitta did not start ($t/aitta.log)"
CHECK_PIDS+=($SERVER_PID)
P=$SERVER_PORT
A=http://127.0.0.1:$P
AR="http://127\.0\.0\.1:$P"
acode=$(grep -ao "setup code [A-Z0-9]*" "$t/aitta.log" | cut -d' ' -f3)
export BUILDAT_CONNECT_PORTS=$P
start_server "$SL" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 $web \
	--sim-rate "$CHECK_RATE" || fail "the server did not come up ($SL)"
CHECK_PIDS+=($SERVER_PID)
WP=$SERVER_PORT
wait_for_log "$SL" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$SL" | head -1)
[ -n "$code" ] || fail "no setup code ($SL)"
url=http://localhost:$WP/api/v1/mcp
cat > "$t/mcp.py" <<'PY'
import io, json, sys, urllib.error, urllib.request, zipfile
phase, url, tok, adm, aitta = sys.argv[1:6]
args = sys.argv[6:]
def post(token, msg):
    h = {"Content-Type": "application/json",
         "Accept": "application/json, text/event-stream",
         "Authorization": "Bearer " + token}
    req = urllib.request.Request(url, data=json.dumps(msg).encode(), headers=h)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
n = 0
def rpc(token, method, params=None):
    global n
    n += 1
    m = {"jsonrpc": "2.0", "id": n, "method": method}
    if params is not None:
        m["params"] = params
    s, b = post(token, m)
    assert s == 200, (method, s, b)
    return json.loads(b)
def call(name, a={}, error=False, token=None):
    r = rpc(token or tok, "tools/call", {"name": name, "arguments": a})["result"]
    text = r["content"][0]["text"]
    assert r["isError"] == error, (name, a, text[:2000])
    print(" ", name, json.dumps(a)[:100], "->", text[:160].replace("\n", " "))
    return text
for k in (tok, adm):
    rpc(k, "initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
        "clientInfo": {"name": "kit_server_publish_check", "version": "1"}})
def aitta_get(path):
    with urllib.request.urlopen(aitta + path, timeout=30) as r:
        return r.read()
def releases(name):
    rs = [r for r in json.loads(aitta_get("/api/v1/aitta/list"))["releases"]
          if r["author"] == "crags" and r["name"] == name]
    return sorted(rs, key=lambda r: [int(x) for x in r["version"].split(".")])
def release(r, builder):
    z = zipfile.ZipFile(io.BytesIO(aitta_get("/api/v1/aitta/archive/%s.zip" % r["sha256"])))
    m = json.loads(z.read("meta.json"))
    lic = z.read("LICENSE").decode()
    assert m["kind"] == "scene" and m["author"] == "crags" and m["name"] == r["name"], m
    assert m["published_by"]["account"] == builder, (m["published_by"], builder)
    assert m.get("buildat_version"), m
    assert "by " + builder + "," in lic and "published by crags" in lic, lic
    return m
def log_is(want):
    rows = json.loads(call("publish_log", token=adm))
    got = [(r["builder"]["account"], r["package"], r["version"], r["aitta"]) for r in rows]
    assert got == [(b, "crags/loop", v, aitta) for b, v in want], got
    rs = releases("loop")
    assert [r["version"] for r in rs] == [v for _, v in want], rs
    for r, row in zip(rs, rows):
        assert r["sha256"] == row["sha256"], (r, row)
        release(r, row["builder"]["account"])
    return rs
if phase == "builder":
    call("set_builder", {"name": "kitbob", "on": True}, token=adm)
    print("kitbob a builder")
elif phase == "pub":
    l = json.loads(call("list_aitta", {"kind": "scene"}))
    it = [i for i in l["items"] if i["author"] == "crags" and i["name"] == "loop"]
    assert len(it) == 1 and it[0]["version"] == "1.0.0" and it[0]["title"] == "The Loop" \
        and it[0]["buildat_version"] and it[0]["aitta"] == aitta, l
    key = it[0]["key"]
    t = call("publish_scene", {"scene": "loop", "name": "loop", "license": "MIT",
        "aitta": aitta, "description": "The Loop again, by the agent"})
    assert t.startswith("Published crags/loop 1.0.1 as the server on " + aitta), t
    bad = "http://127.0.0.1:1"
    t = call("publish_scene", {"scene": "loop", "name": "loop", "license": "MIT", "aitta": bad}, error=True)
    assert "is not one the server publishes to" in t, t
    t = call("install_from_aitta", {"kind": "scene", "key": key, "aitta": bad}, error=True)
    assert "is not one the server fetches from" in t, t
    t = call("install_from_aitta", {"kind": "template", "key": key, "aitta": aitta}, error=True)
    assert "a template's install is an admin's" in t, t
    t = call("publish_log", error=True)
    assert "an admin's" in t, t
    rs = log_is([("kitbob", "1.0.0"), ("kitboss", "1.0.1")])
    assert release(rs[0], "kitbob")["license_code"] == "CC-BY-4.0"
    assert release(rs[1], "kitboss")["description"] == "The Loop again, by the agent"
    open(args[0], "w").write(key)
    print("ok: list_aitta lists crags/loop 1.0.0 (made with %s); publish_scene 1.0.1; an unlisted Aitta refused (publish, install), a template's install and publish_log to the Builder token; the log kitbob 1.0.0, kitboss 1.0.1, the Aitta's releases crags', published_by each builder, buildat_version in each, the LICENSE naming the builder"
        % it[0]["buildat_version"])
elif phase == "add":
    assert json.loads(call("get_state"))["running"]
    t = call("install_from_aitta", {"kind": "scene", "key": args[0], "aitta": aitta})
    import re
    m = re.match(r"Installed: the scene (loop\w*) \(crags/loop 1\.0\.1 from ", t)
    assert m, t
    open(args[1], "w").write(m[1])
    print("ok: install_from_aitta added The Loop while Running, as " + m[1])
elif phase == "undo":
    t = call("undo", error=True)
    assert "the undo takes a scene away: 1 player on it" in t, t
    print("ok: the agent's undo of its install refused, kitbob on the scene")
elif phase == "final":
    log_is([("kitbob", "1.0.0"), ("kitboss", "1.0.1"), ("kitbob", "1.0.2")])
    print("ok: the web's release crags/loop 1.0.2 on the Aitta, published_by kitbob; the log's third row")
PY
mcp() # <phase> <args...>
{
	local p=$1
	shift
	python3 -I "$t/mcp.py" "$p" "$url" "$tok" "$adm" "$A" "$@" > "$t/mcp_$p.log" 2>&1 ||
		fail "the MCP $p run: $(tail -5 "$t/mcp_$p.log") ($t/mcp_$p.log, $SL)"
	grep -v "^  " "$t/mcp_$p.log"
}

# 1. Crag Trial; the tokens; kitbob a builder without the right
BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client boss
BOSS=$!
exec 3> "$t/boss.cmd"
as boss
await "$CL" 0 120 "Joined as kitboss"
cmd "wait_log_any 30000 server window: the page ntfy" "frames 3" 'click Button "Don'"'"'t add"'
await "$CL" 0 30 "world_menu: the list shown"
step 10 "world_menu: the name screen shown" "frames 3" 'click Button "New game..."'
cmd "frames 3" "keydown ctrl" "keypress a" "keyup ctrl" "text crag" "frames 2"
cmd 'click DropDownList "▼"' "delay 300" "frames 3"
step 10 "world_menu: template picked: crag_trial" 'click Text "Crag Trial"'
step 60 "kit editor: edit mode on" "frames 3" 'click Button "Create"'
await "$CL" 0 30 "player physics enabled"
menu
step 10 "accounts: agents: 0 tokens, on" "frames 3" 'click Button "My account*"' \
	"frames 5" 'click Button "Connect an agent..."'
step 10 "accounts: agents: a token made, builder" "frames 3" \
	'click Button "Make a token..."' "frames 3" 'click Button "Make a token"'
step 10 "accounts: agents: the token copied" "frames 3" 'click Button "copy token"'
tok=$(clip "")
[[ $tok =~ ^bat_ ]] || fail "no Builder token on the clipboard: $tok"
cmd "frames 3" 'click Button "Done"' "frames 3" 'click Button "Scope: Builder*"' \
	"frames 3" 'click LineEdit "My agent"' "delay 300" "keydown ctrl" \
	"keypress a" "keyup ctrl" "text admin agent" "frames 2"
step 10 "accounts: agents: a token made, admin" 'click Button "Make a token"'
step 10 "accounts: agents: the token copied" "frames 3" 'click Button "copy token"'
adm=$(clip "$tok")
[[ $adm =~ ^bat_ ]] || fail "no Admin token on the clipboard: $adm"
cmd "frames 3" 'click Button "Done"'
BUILDAT_JOIN_CREATE=1 client bob
BOB=$!
exec 4> "$t/bob.cmd"
as bob
await "$CL" 0 120 "Joined as kitbob"
await "$CL" 0 60 "player physics enabled"
mcp builder
await "$CL" 0 10 "kit editor: edit rights: yes"
step 10 "kit editor: edit mode on" 'event kit_edit {"op": "mode", "on": true}'
edit 5 "An edit \(server_publish\) by peer [0-9]+ refused: kitbob may not publish as the server" \
	"{\"op\": \"server_publish\", \"what\": \"scene\", \"scene\": \"loop\", \"name\": \"loop\", \"license\": \"CC0-1.0\", \"aitta\": \"$A\"}"
echo "ok: Crag Trial; kitboss's two tokens; kitbob a builder, his publish as the server refused (no right)"

# 2. The Publishing page: the key, the Aitta, bound there, kitbob's right
as boss
step 10 "kit editor: the Publishing page, key none, 0 Aittas, 0 published" \
	"frames 3" 'click Button "Publishing*"'
m=$(mark "$SL")
step 10 "kit editor: the Publishing page, key made" "frames 3" \
	'click LineEdit "publishing author"' "delay 300" "text crags" "frames 2" \
	'click Button "publishing keygen"'
await "$SL" "$m" 5 "Publishing: kitboss made the server's key, author crags, its public half [0-9a-f]+"
pub=$(grep -aoP "the server's key, author crags, its public half \K[0-9a-f]+" "$SL" | head -1)
kf=$(find "$t/user" -name publish.key | head -1)
[ -n "$kf" ] || fail "no publish.key in $t/user"
[ "$(stat -c %a "$kf")" = 600 ] || fail "$kf is mode $(stat -c %a "$kf")"
m=$(mark "$SL")
step 10 "kit editor: the Publishing page, key made, 1 Aittas" "frames 3" \
	'click LineEdit "publishing aittas"' "delay 300" "text $A" "frames 2" \
	'click Button "publishing save aittas"'
await "$SL" "$m" 5 "Publishing: kitboss set the Aittas: "
await "$SL" "$m" 10 "Publishing: $AR "
seen "$SL" "$m" "Publishing: $AR binds" && fail "bound before the bind ($SL)"
printf 'wait_log_any 20000 ai: {"id":1,\nquit\n' > "$t/bind.cmds"
DISPLAY=$d WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11 BUILDAT_AITTA_CREATE=1 \
	BUILDAT_AITTA_NAME=admin BUILDAT_AITTA_PASSWORD=checkpass \
	BUILDAT_AITTA_CODE=$acode \
	BUILDAT_AITTA_REQS="{\"cmd\":\"bind\",\"author\":\"crags\",\"key\":\"$pub\"}" \
	timeout 90 bin/buildat -o launch_ui=launch_menu -o sound_mute=1 -D "$t/bind" \
	-w 800x600 -l 3 -s 127.0.0.1:$P -c @"$t/bind.cmds" > "$t/bind.log" 2>&1 ||
	fail "the bind's client ($t/bind.log)"
grep -aq 'ai: {"id":1,"ok":true' "$t/bind.log" || fail "the bind ($t/bind.log)"
m=$(mark "$SL")
cmd "frames 3" 'click Button "Check again"'
await "$SL" "$m" 10 "Publishing: $AR binds the server's key to crags"
m=$(mark "$SL")
cmd "frames 3" 'click Button "publisher kitbob"'
await "$SL" "$m" 5 "Publishing: kitboss gave kitbob the right to publish as the server"
cmd "frames 10" "screenshot $t/page.png"
step 10 "pause: the menu shown" "frames 3" "keypress Escape"
step 10 "pause: the menu closed" "frames 3" "keypress Escape"
echo "ok: the Publishing page: the key made (mode 600), the Aitta listed, bound there, kitbob's right given"

# 3. kitbob publishes The Loop through the editor
as bob
step 10 "kit editor: in the scene loop" 'event kit_edit {"op": "scene", "name": "loop"}'
m=$(mark "$SL")
cmd "frames 3" 'click Button "New"'
await "$SL" "$m" 20 "The Aittas' scene packages for peer [0-9]+: 0 \(0 Aittas failed\)"
step 10 "kit editor: publish this scene: [0-9]+ goal warnings" "frames 3" 'click Button "publish scene"'
warn=
if ! grep -aq "kit editor: publish this scene: 0 goal warnings" "$CL"; then
	warn=1
	step 10 "kit editor: published with goal warnings" "frames 3" 'click Button "Publish anyway"'
fi
await "$CL" 0 10 "kit editor: publish as: this server \(crags\) or my own key"
step 10 "kit editor: the publish form, scene loop 1\.0\.0 to $AR, CC0-1\.0, as crags by kitbob" \
	"frames 3" 'click Button "publish as server"'
step 10 "kit editor: the publish form, scene loop 1\.0\.0 to $AR, CC-BY-4\.0" \
	"frames 3" 'click Button "publish licence"'
cmd "frames 5" "screenshot $t/form.png"
m=$(mark "$SL")
step 30 "kit editor: Published crags/loop 1\.0\.0 as the server on $AR" "frames 3" 'click Button "publish go"'
await "$SL" "$m" 5 "kitbob publishes crags/loop 1\.0\.0 \(scene, [0-9]+ bytes, sha256 [0-9a-f]{64}\) as the server to $AR"
step 10 "kit editor: in the scene world" 'event kit_edit {"op": "scene", "name": "world"}'
echo "ok: kitbob's Publish this scene..., As this server (crags), the form: crags/loop 1.0.0 published"

# 4. The tools
mcp pub "$t/loop.key"
key=$(cat "$t/loop.key")

# 5. A Crag Trial project without The Loop, The Loop added while Running
as boss
# (said on a change: none, Ended)
if grep -a "kit editor: the server is" "$CL" | tail -1 | grep -q Running; then
	step 10 "kit editor: the server is Ended" 'event kit_edit {"op": "stop"}'
fi
python3 -I - "$here/apps/workbench/templates/crag_trial/types/crag_gem.lua" > "$t/gem.cmd" <<'PY'
import json, sys
s = open(sys.argv[1]).read()
assert "version = 1," in s
s = s.replace("version = 1,", "version = 2,", 1) + "-- the project's own\n"
print("event kit_type " + json.dumps({"op": "put", "name": "crag_gem", "source": s}))
PY
m=$(mark "$SL")
cmd "$(cat "$t/gem.cmd")"
await "$SL" "$m" 10 "A type put \(local/crag_gem\) by peer [0-9]+ (done|refused)"
seen "$SL" "$m" "A type put \(local/crag_gem\) by peer [0-9]+ done" || fail "crag_gem not put ($SL)"
edit 5 "An edit by kitboss: removed the scene loop \([0-9]+ entities changed\)" \
	'{"op": "remove_scene", "name": "loop"}'
edit 5 "An undo by kitboss: [0-9]+ entities put back" '{"op": "undo"}'
edit 5 "An edit by kitboss: removed the scene loop" '{"op": "remove_scene", "name": "loop"}'
edit 5 "An edit \(remove_scene\) by peer [0-9]+ refused: the scene world is the game's first: it stays" \
	'{"op": "remove_scene", "name": "world"}'
step 10 "kit editor: the server is Running" 'event kit_edit {"op": "play"}'
as bob
m=$(mark "$SL")
step 10 "kit editor: edit mode off" 'event kit_edit {"op": "mode", "on": false}'
await "$CL" 0 20 "kit: ui full screen 45 up"
step 10 "kit: ui full screen none" "frames 5" 'click Button "The Crags*"'
await "$SL" "$m" 10 "local/crag_run 7: kitbob: off you go, the run starts over"
echo "ok: Stopped, crag_gem changed, Remove the scene loop: undone, removed again; the World's own refused; Running, kitbob riding The Crags"
madd=$(mark "$SL")
mcp add "$key" "$t/added"
# (loop_2: the removed scene's World and rows stay, its name with them)
sc=$(cat "$t/added")
await "$SL" "$madd" 5 "adds the scene $sc \(crags/loop 1\.0\.1 from [^)]*\): .* \(Running: unlisted\)"
await "$SL" "$madd" 5 "The scene $sc's local/crag_gem differs from the project's"
as boss
mlist=$(mark "$SL")
for i in $(seq 10); do
	m=$(mark "$SL")
	cmd "event kit_edit {\"op\": \"list_scene\", \"name\": \"$sc\", \"on\": true}"
	await "$SL" "$m" 5 "An edit by kitboss: set [0-9]+'s kit/scene_info listed to true|An edit \(list_scene\) by peer [0-9]+ refused"
	seen "$SL" "$m" "An edit by kitboss: " && break
	seen "$SL" "$m" "World is not ready yet" || fail "list_scene refused: $(tail -c +$((m + 1)) "$SL" | grep -a refused) ($SL)"
	[ $i = 10 ] && fail "The Loop's World never ready ($SL)"
	sleep 0.5
done
tail -c +$((madd + 1)) "$SL" | head -c $((mlist - madd)) | grep -aq "scenes: .*$sc=" &&
	fail "The Loop in the track list before it was listed ($SL)"
await "$SL" "$mlist" 5 "kit/ui_scene_list 47: scenes: world=The Crags/buildat, $sc=The Loop/celeron55"
seen "$SL" "$madd" "kitbob: off you go|kit/lobby 44: kitbob: playing ->" &&
	fail "kitbob's run broken by the add ($SL)"
echo "ok: The Loop added unlisted (the clashing crag_gem the project's), listed: in the track list; kitbob's run on The Crags unbroken"
# kitbob's finish, the lobby, The Loop: entered, the root's links by name
as bob
step 10 "kit editor: edit mode on" 'event kit_edit {"op": "mode", "on": true}'
m=$(mark "$SL")
for g in 1 2 3; do
	cmd 'event kit_edit {"op": "try", "id": 7, "comp": 0, "input": "gem"}'
done
await "$SL" "$m" 5 "local/crag_run 7: kitbob has 3 of 3 gems"
cmd 'event kit_edit {"op": "try", "id": 7, "comp": 0, "input": "finish"}'
await "$SL" "$m" 5 "kit/lobby 44: kitbob: playing -> over"
step 10 "kit editor: edit mode off" 'event kit_edit {"op": "mode", "on": false}'
m=$(mark "$SL")
step 10 "kit: ui full screen 45 up" "frames 5" 'click Button "Lobby"'
await "$CL" 0 10 'kit: ui 47 list .* shown, layer 45: "Pick a track \| The Crags, by buildat \| The Loop, by celeron55"'
mc=$(mark "$CL")
step 10 "kit: ui full screen none" "frames 5" 'click Button "The Loop*"'
await "$SL" "$m" 5 "kit/lobby 44: kitbob goes to $sc"
await "$SL" "$m" 10 "local/crag_run [0-9]+: kitbob: off you go, the run starts over"
run=$(tail -c +$((m + 1)) "$SL" | grep -aoP "local/crag_run \K[0-9]+(?=: kitbob: off you go)" | tail -1)
[ "$run" != 7 ] || fail "The Crags' run, not The Loop's ($SL)"
await "$CL" "$mc" 30 "player physics enabled"
for i in $(seq 20); do
	body
	awk -v x="$bx" 'BEGIN { exit !(x > -61 && x < -59) }' && break
	cmd "delay 200"
done
for try in 1 2; do
	m2=$(mark "$SL")
	cmd "keydown W" "delay 800" "keydown A"
	for i in $(seq 25); do
		cmd "delay 150"
		seen "$SL" "$m2" "local/crag_run $run: kitbob: crashed" && break
		sleep 0.2
	done
	cmd "keyup A" "keyup W"
	seen "$SL" "$m2" "local/crag_run $run: kitbob: crashed" && break
	[ $try = 2 ] && fail "no crash on the added loop reaching its run ($SL)"
	echo "no crash yet: W and A again"
done
step 10 "kit editor: edit mode on" 'event kit_edit {"op": "mode", "on": true}'
m=$(mark "$SL")
for g in 1 2 3 4; do
	cmd "event kit_edit {\"op\": \"try\", \"id\": $run, \"comp\": 0, \"input\": \"gem\"}"
done
await "$SL" "$m" 5 "local/crag_run $run: kitbob has 4 of 4 gems"
cmd "event kit_edit {\"op\": \"try\", \"id\": $run, \"comp\": 0, \"input\": \"finish\"}"
await "$SL" "$m" 5 "local/crag_run $run: kitbob finished in [0-9.]+"
await "$SL" "$m" 5 "kit/lobby 44: kitbob: playing -> over"
mc=$(mark "$CL")
step 10 "kit editor: edit mode off" 'event kit_edit {"op": "mode", "on": false}'
await "$CL" "$mc" 5 "kit: ui 50 panel .* shown, layer 50: \"Finished\""
cmd "frames 10" "screenshot $t/loop.png"
grep -a "dropped: " "$SL" && fail "a link by name dropped ($SL)"
echo "ok: The Loop picked in the lobby: its run ($run) entered, the root's bike's crash by name to it, its finish the root's lobby's over and result card"
as boss
edit 5 "An edit \(remove_scene\) by peer [0-9]+ refused: 1 player on it: unlist it; they leave as they finish" \
	"{\"op\": \"remove_scene\", \"name\": \"$sc\"}"
mcp undo
FD=4 cmd "sync 2000" quit
exec 4>&-
wait $BOB 2>/dev/null
for i in $(seq 10); do
	m=$(mark "$SL")
	cmd "event kit_edit {\"op\": \"remove_scene\", \"name\": \"$sc\"}"
	await "$SL" "$m" 5 "An edit by kitboss: removed the scene $sc|An edit \(remove_scene\) by peer [0-9]+ refused"
	seen "$SL" "$m" "An edit by kitboss: removed the scene $sc" && break
	[ $i = 10 ] && fail "$sc not removed once kitbob left ($SL)"
	sleep 0.5
done
echo "ok: Remove refused with kitbob on The Loop, done once he left"

# 6. The web: kitbob adds The Loop from the server's Aitta and publishes it
webpass=""
if [ -n "$web" ]; then
	anyway=""
	[ -z "$warn" ] || anyway='["waitlog", "kit editor: publish this scene: [0-9]+ goal warnings", 10], ["frames", 3], ["click", "Button", "Publish anyway"],'
	cat > "$t/web.json" <<J
[["nav", "\${URL}"], ["waitlog", "accounts: the login page shown", 120], ["wait", 1000],
 ["selall"], ["frames", 2], ["type", "kitbob"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["type", "checkpass12"], ["frames", 2], ["key", "Enter"], ["waitlog", "Joined as kitbob", 30],
 ["waitlog_any", "kit editor: edit rights: yes", 60],
 ["event", "kit_edit {\"op\": \"mode\", \"on\": true}"], ["waitlog_any", "kit editor: edit mode on", 20],
 ["frames", 10], ["click", "Button", "New"],
 ["waitlog", "kit editor: scene package crags/loop 1\\\\.0\\\\.1 on ", 20], ["frames", 5],
 ["click", "Button", "Add The Loop"], ["waitlog", "kit editor: Added the scene loop_[0-9]+ ", 30],
 ["frames", 5], ["click", "Button", "OK"], ["waitlog", "kit editor: the scene added closed", 10],
 ["frames", 5], ["click", "Button", "publish scene"], $anyway
 ["waitlog", "kit editor: the publish form, scene loop_[0-9]+ 1\\\\.0\\\\.0 to .*, as crags by kitbob", 20],
 ["frames", 5], ["click", "LineEdit", "publish name"], ["selall"], ["frames", 2],
 ["type", "loop"], ["frames", 5], ["shot", "\${OUT}/web_form.png"],
 ["click", "Button", "publish go"],
 ["waitlog", "kit editor: Published crags/loop 1\\\\.0\\\\.2 as the server on ", 30]
]
J
	WEB_DRIVE_VIEWPORT=1024x700@1 WEB_DRIVE_URL="http://127.0.0.1:$WP/" \
		"$here/util/web_drive.sh" chrome workbench "$t/web.json" "$t/web" > "$t/web.txt" 2>&1 ||
		fail "the web: $(tail -2 "$t/web.txt") ($t/web/page.log, $SL)"
	grep -aqE "kitbob adds the scene loop_[0-9]+ \(crags/loop 1\.0\.1 from [^)]*\): .* \(Running: unlisted\)" "$SL" ||
		fail "the web's add ($SL)"
	mcp final
	webpass=" The web client: The Loop added from the server's Aitta, then published as the server."
else
	echo "SKIPPED: 6., the web: no Chrome or web/buildat.wasm"
fi
priv=$(awk '{print $NF}' "$kf")
[[ $priv =~ ^[0-9a-f]{64}$ ]] || fail "the key file's last field is not a key's hex ($kf)"
grep -raqF --exclude=publish.key "$priv" "$t" && fail "the server's private key in a file of the run: $(grep -rlaF --exclude=publish.key "$priv" "$t")"
grep -aqF "${tok#bat_}" "$SL" "$t"/boss.log "$t"/bob.log && fail "a token is in a log"
echo "PASS: the server's key made and bound on the Aitta from the Publishing page; kitbob, given the right, published as the server through the editor and kitboss's agent through the tools, both logged and named in their releases (buildat_version in them); no right, an unlisted Aitta refused; The Loop installed through the server into the Crag Trial project without it while Running, unlisted until listed, the clashing type kept, the root's by-name links reaching its run, Remove refused with a rider on it.$webpass Screenshots in $t"
