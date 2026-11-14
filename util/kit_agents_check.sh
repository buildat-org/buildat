#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min (2026-11-14)
# covers: builtin/kit/kit.cpp builtin/accounts/accounts.cpp builtin/accounts/client_lua/accounts.lua builtin/network/network.cpp
# [KIT_AGENTS] A builder's agent on Workbench, through MCP (POST /api/v1/mcp
# on the server's port). kitboss (the admin) on a headless weston's Xwayland
# of the check's own (the user's clipboard is not touched):
#   1. My account, Connect an agent...: a Builder token made and its block
#      copied by Copy (xclip reads it: the server's address and a ready
#      `claude mcp add` line), then an Admin one labelled "admin agent";
#      neither token in a log;
#   2. an MCP client (Python's stdlib) with the builder token: initialize
#      (the version negotiated), notifications/initialized, tools/list, the
#      state and the types; a kit/timer and a kit/counter placed, the timer
#      set, linked to the counter; Start, the count read going up; undo
#      takes the link back; Stop. Refused as tool errors: an unknown
#      parameter, the admin's set_builder; refused by HTTP: GET, an Origin,
#      no token, a wrong one, bad JSON, a version not spoken, a batch.
#      The edits logged as "kitboss's agent", who is in kitboss's builders
#      list;
#   2b. the rest of the tools: the guide in the instructions (within Claude
#      Code's 4096 characters) and get_guide's per type; two counters placed,
#      renamed, moved, a component added and removed, linked (get_links),
#      one put under the other, duplicated, saved as the prefab
#      kitboss/agentpair (the account's, not its agent's) and placed; a box
#      of voxels by the player set, read back and undone as one; a kit/goal
#      warned of until linked; Running, a try_input through the link and a
#      watch read back by get_events, get_log and the state; a new scene
#      taking the agent's edits there and back; every edit of it undone, the
#      entities as before;
#   3. the builder token revoked on the page: its agent gone at once, 401;
#   4. Agents (MCP) off on the Accounts page: the admin token refused with
#      that said; on again: its set_builder done, and past 120 requests a
#      minute, 429.
# Screenshots, kept with KEEP_TMP=1: $t/token.png (the block), $t/tokens.png
# (the list), $t/switch.png (the Accounts page)
#   util/kit_agents_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
for c in weston xclip; do
	command -v $c > /dev/null || skip "no $c"
done
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_agents; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_JOIN_PASSWORD=checkpass12
check_build
sock=buildat-agents-$$
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
		tail -c +$(($2 + 1)) "$1" | grep -qaE "$4" && return 0
		kill -0 $CLIENT 2>/dev/null || fail "the client is gone ($CL)"
		sleep 0.2
	done
	fail "no \"$4\" in $1 in $3 s ($SL, $CL)"
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
# The clipboard once it holds a block other than <last>
clip() # <last>
{
	local i got
	for i in $(seq 50); do
		got=$(DISPLAY=$d xclip -selection clipboard -o 2>/dev/null)
		case $got in *"Bearer bat_"*) [ "$got" != "$1" ] && break;; esac
		sleep 0.2
	done
	printf '%s' "$got"
}
start_server "$SL" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
	--sim-rate "$CHECK_RATE" || fail "the server did not come up ($SL)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$SL" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$SL" | head -1)
[ -n "$code" ] || fail "no setup code ($SL)"
mkfifo "$t/cmd"
sleep 900 > "$t/cmd" &
CHECK_PIDS+=($!)
DISPLAY=$d WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11 BUILDAT_JOIN_NAME=kitboss \
	BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	timeout 600 bin/buildat -C "$t/client_cache" -D "$t/cu" \
	-s localhost:$SERVER_PORT -w 1024x700 -l 3 -o sound_mute=1 -c - \
	< "$t/cmd" > "$CL" 2>&1 &
CLIENT=$!
CHECK_PIDS+=($CLIENT)
exec 3> "$t/cmd"
await "$CL" 0 120 "Joined as kitboss"
cmd "wait_log_any 30000 server window: the page ntfy" "frames 3" 'click Button "Don'"'"'t add"'
await "$CL" 0 120 "player physics enabled"
# 1. The tokens, by the page
step 10 "pause: the menu shown" "frames 3" "keypress Escape"
step 10 "accounts: agents: 0 tokens, on" "frames 3" 'click Button "My account*"' \
	"frames 5" 'click Button "Connect an agent..."'
step 10 "accounts: agents: a token made, builder" "frames 3" 'click Button "Make a token"'
cmd "frames 5" "screenshot $t/token.png"
step 10 "accounts: agents: the block copied" "frames 3" 'click Button "Copy"'
block=$(clip "")
url=$(grep -aoP '^Server: \K\S+' <<< "$block")
tok=$(grep -aoP 'claude mcp add --transport http buildat \S+ --header "Authorization: Bearer \Kbat_[0-9a-f]{64}(?="$)' <<< "$block")
[ "$url" = "http://localhost:$SERVER_PORT/api/v1/mcp" ] ||
	fail "the block's address is \"$url\" ($t/token.png): $block"
[ -n "$tok" ] || fail "no claude mcp add line with a token in the block: $block"
grep -aqF '{"mcpServers": {"buildat": {"type": "http", "url": "'"$url"'", "headers": {"Authorization": "Bearer '"$tok"'"}}}}' <<< "$block" ||
	fail "no MCP config in the block: $block"
cmd "frames 3" 'click Button "Done"' "frames 3" 'click Button "Scope: Builder*"' \
	"frames 3" 'click LineEdit "Claude Code"' "delay 300" "keydown ctrl" \
	"keypress a" "keyup ctrl" "text admin agent" "frames 2"
step 10 "accounts: agents: a token made, admin" 'click Button "Make a token"'
step 10 "accounts: agents: the block copied" "frames 3" 'click Button "Copy"'
adm=$(clip "$block" | grep -aoP 'Bearer \Kbat_[0-9a-f]{64}' | head -1)
[ -n "$adm" ] && [ "$adm" != "$tok" ] || fail "no second token on the clipboard"
cmd "frames 3" 'click Button "Done"' "frames 5" "screenshot $t/tokens.png"
# Out of the window and the menu, into edit mode: the builders' list
step 10 "pause: the menu shown" "keypress Escape"
step 10 "pause: the menu closed" "frames 3" "keypress Escape"
step 20 "kit editor: edit mode on" "frames 3" "keypress F6"
# 2. The MCP client
cat > "$t/mcp.py" <<'PY'
import json, re, sys, time, urllib.error, urllib.request
phase, url = sys.argv[1], sys.argv[2]
def post(token, msg=None, headers={}, method="POST", raw=None):
    h = {"Content-Type": "application/json",
         "Accept": "application/json, text/event-stream"}
    if token:
        h["Authorization"] = "Bearer " + token
    h.update(headers)
    data = raw if raw is not None else (json.dumps(msg).encode() if msg is not None else None)
    req = urllib.request.Request(url, data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            res = r.status, r.read().decode(), r.headers
    except urllib.error.HTTPError as e:
        res = e.code, e.read().decode(), e.headers
    # No CORS on this path, ever
    assert "Access-Control-Allow-Origin" not in res[2], res
    return res
n = 0
def rpc(token, method, params=None, status=200):
    global n
    n += 1
    m = {"jsonrpc": "2.0", "id": n, "method": method}
    if params is not None:
        m["params"] = params
    s, b, h = post(token, m)
    assert s == status, (method, s, b)
    j = json.loads(b)
    assert j["jsonrpc"] == "2.0" and j["id"] == n, j
    return j
def call(token, name, args={}, error=False):
    r = rpc(token, "tools/call", {"name": name, "arguments": args})["result"]
    c = r["content"]
    assert len(c) == 1 and c[0]["type"] == "text", r
    assert r["isError"] == error, (name, args, r)
    print(" ", name, json.dumps(args), "->", c[0]["text"][:120])
    return c[0]["text"]
def refused(status, code, *a, **k):
    s, b, h = post(*a, **k)
    assert s == status, (s, b)
    if code:
        assert json.loads(b)["error"]["code"] == code, b
    return b, h
def state(token):
    return json.loads(call(token, "get_state"))
def entity(st, i):
    return [e for e in st["entities"] if e["id"] == i][0]
if phase == "main":
    tok = sys.argv[3]
    init = {"protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "kit_agents_check", "version": "1"}}
    r = rpc(tok, "initialize", init)["result"]
    assert r["protocolVersion"] == "2025-06-18" and r["capabilities"]["tools"] == {"listChanged": False}, r
    assert r["serverInfo"]["name"] and r["instructions"], r
    init["protocolVersion"] = "2099-01-01"
    assert rpc(tok, "initialize", init)["result"]["protocolVersion"] == "2025-11-25"
    s, b, h = post(tok, {"jsonrpc": "2.0", "method": "notifications/initialized"})
    assert s == 202 and b == "", (s, b)
    assert rpc(tok, "ping")["result"] == {}
    tools = rpc(tok, "tools/list")["result"]["tools"]
    names = [t["name"] for t in tools]
    assert names == ["get_state", "list_types", "get_type", "get_guide",
        "get_links", "get_log", "get_events", "get_goal_warnings",
        "list_prefabs", "list_items", "list_voxel_types", "get_voxels", "place",
        "set_param", "link", "delete", "unlink", "move", "rename",
        "add_component", "remove_component", "set_parent", "duplicate",
        "place_prefab", "save_prefab", "set_voxels", "put_type", "delete_type",
        "new_scene", "switch_scene", "undo", "start", "stop", "try_input",
        "watch", "keep", "set_builder"], names
    for t in tools:
        assert t["description"] and t["inputSchema"]["type"] == "object", t
    st = state(tok)
    assert st["undo"] == 0 and st["entities"][0]["kind"] == "scene", st
    # (a new project is Running)
    if st["running"]:
        assert call(tok, "stop").startswith("Ended")
        call(tok, "stop", error=True)
    types = {t["type"]: t for t in json.loads(call(tok, "list_types"))}
    assert types["kit/counter"]["group"] == "Logic" and types["kit/counter"]["what"], types.get("kit/counter")
    d = json.loads(call(tok, "list_types", {"type": "kit/timer"}))
    assert d["params"]["interval"]["type"] == "number" and "tick" in d["outputs"], d
    call(tok, "list_types", {"type": "kit/nope"}, error=True)
    T = int(re.search(r"placed kit/timer (\d+)", call(tok, "place",
        {"type": "kit/timer", "pos": [0, 1, 0]}))[1])
    call(tok, "set_param", {"id": T, "param": "interval", "value": 0.2})
    call(tok, "set_param", {"id": T, "param": "autostart", "value": True})
    C = int(re.search(r"placed kit/counter (\d+)", call(tok, "place",
        {"type": "kit/counter", "pos": [2, 1, 6]}))[1])
    assert "linked %d.tick -> %d.count" % (T, C) in call(tok, "link",
        {"id": T, "output": "tick", "to": C, "input": "count"})
    # Kit's refusals, as tool errors
    assert "has no parameter" in call(tok, "set_param", {"id": C, "param": "nope", "value": 1}, error=True)
    assert "only the server's admin" in call(tok, "set_builder", {"name": "kitboss", "on": True}, error=True)
    assert rpc(tok, "tools/call", {"name": "nope"})["error"]["code"] == -32602
    assert rpc(tok, "nope/nope")["error"]["code"] == -32601
    assert call(tok, "start") == "Running"
    for i in range(40):
        st = state(tok)
        count = entity(st, C)["components"][0]["state"].get("count", 0)
        if count >= 2:
            break
        time.sleep(0.5)
    assert st["running"] and count >= 2, entity(st, C)
    assert "Undone" in call(tok, "undo")
    st = state(tok)
    assert entity(st, T)["components"][0]["links"] == [], entity(st, T)
    assert call(tok, "stop").startswith("Ended")
    assert state(tok)["running"] is False
    # Refused by HTTP
    b, h = refused(405, -32600, tok, method="GET")
    assert h["Allow"] == "POST", h
    refused(403, -32600, tok, {"jsonrpc": "2.0", "id": 1, "method": "ping"},
        headers={"Origin": "https://example.org"})
    b, h = refused(401, -32001, None, {"jsonrpc": "2.0", "id": 1, "method": "ping"})
    assert "Bearer" in h["WWW-Authenticate"], h
    refused(401, -32001, "bat_" + "0" * 64, {"jsonrpc": "2.0", "id": 1, "method": "ping"})
    refused(400, -32700, tok, raw=b"{\"jsonrpc\": ")
    refused(400, -32600, tok, [{"jsonrpc": "2.0", "id": 1, "method": "ping"}])
    refused(400, -32600, tok, {"jsonrpc": "2.0", "id": 1, "method": "ping"},
        headers={"MCP-Protocol-Version": "2099-01-01"})
    print("ids", T, C)
elif phase == "build":
    tok = sys.argv[3]
    init = {"protocolVersion": "2025-11-25", "capabilities": {},
            "clientInfo": {"name": "kit_agents_check", "version": "1"}}
    ins = rpc(tok, "initialize", init)["result"]["instructions"]
    # The guide: within the 4096 characters Claude Code keeps, whole by tool
    assert len(ins) <= 4096 and "kitboss's agent" in ins and "kit/counter" in ins, ins
    guide = call(tok, "get_guide")
    assert re.search(r"\n- kit/counter: [^\n]*In: [^\n]*add \(number\)", guide), guide[:3000]
    print("instructions", len(ins), "characters, get_guide", len(guide))
    st = state(tok)
    if st["running"]:
        call(tok, "stop")
    undo0, first = st["undo"], st["scene"]
    before = sorted(e["id"] for e in st["entities"])
    assert first in st["scenes"], st
    def placed(text):
        return int(re.search(r"placed \S+ (\d+)", text)[1])
    def ent(i):
        return entity(state(tok), i)
    A = placed(call(tok, "place", {"type": "kit/counter", "pos": [4, 1, 4],
        "params": {"target": 3}}))
    B = placed(call(tok, "place", {"type": "kit/counter", "pos": [6, 1, 4]}))
    call(tok, "rename", {"id": A, "name": "Score"})
    call(tok, "move", {"id": B, "pos": [6, 1, 8], "yaw": 90})
    e = ent(B)
    assert ent(A)["name"] == "Score" and e["pos"] == [6, 1, 8] and e.get("yaw") == 90, (ent(A), e)
    call(tok, "add_component", {"id": B, "type": "kit/health"})
    assert [c["type"] for c in ent(B)["components"]] == ["kit/counter", "kit/health"]
    call(tok, "remove_component", {"id": B, "comp": 1})
    call(tok, "remove_component", {"id": B, "comp": 0}, error=True)
    call(tok, "link", {"id": A, "output": "reached", "to": B, "input": "count"})
    links = json.loads(call(tok, "get_links", {"id": B}))
    assert links == [{"id": A, "comp": 0, "output": "reached", "to": B,
        "input": "count", "sends": "number", "takes": "none"}], links
    call(tok, "set_parent", {"id": B, "parent": A})
    assert ent(B)["parent"] == A
    assert re.search(r"duplicated 2 as \d+\.\.\.\d+", call(tok, "duplicate",
        {"ids": [A], "by": [0, 0, 3]}))
    # A prefab under the account's name (not its agent's)
    assert "saved prefab kitboss/agentpair version 1 of 2 entities" in call(tok,
        "save_prefab", {"ids": [A], "name": "agentpair"})
    pf = {p["prefab"]: p for p in json.loads(call(tok, "list_prefabs"))}
    assert pf["kitboss/agentpair"].get("own") and pf["kitboss/agentpair"]["entities"] == 2, pf
    assert len(json.loads(call(tok, "list_prefabs", {"prefab": "kitboss/agentpair"}))["entities"]) == 2
    assert "placed prefab kitboss/agentpair" in call(tok, "place_prefab",
        {"prefab": "kitboss/agentpair", "pos": [12, 1, 4]})
    assert isinstance(json.loads(call(tok, "list_items")), dict)
    # Voxels in a box by the player, read back, undone as one
    V = [v["name"] for v in json.loads(call(tok, "list_voxel_types"))
        if v.get("solid") and v.get("kind") == "solid"][0]
    box = {"at": [2, 20, 2], "size": [2, 1, 2]}
    assert json.loads(call(tok, "get_voxels", box))["layers"] == [["..", ".."]]
    assert "in 4 of 4 cells" in call(tok, "set_voxels", dict(box, voxel=V))
    g = json.loads(call(tok, "get_voxels", box))
    k = [c for c, n in g["key"].items() if n == V][0]
    assert g["layers"] == [[k * 2, k * 2]], g
    assert "Undone" in call(tok, "undo")
    assert json.loads(call(tok, "get_voxels", box))["layers"] == [["..", ".."]]
    assert "512 cells" in call(tok, "set_voxels", {"voxel": V, "at": [0, 0, 0],
        "size": [8, 8, 9]}, error=True)
    call(tok, "get_voxels", {"at": [0, 0, 0], "size": [17, 16, 16]}, error=True)
    # A goal nothing activates, warned of until linked
    G = placed(call(tok, "place", {"type": "kit/goal", "pos": [8, 1, 8]}))
    def warned():
        return any(w.startswith("entity %d " % G) and "nothing activates" in w
            for w in json.loads(call(tok, "get_goal_warnings")))
    assert warned()
    call(tok, "link", {"id": A, "output": "reached", "to": G, "input": "activate"})
    assert not warned()
    # Run: a Try through the link, the watched one's emits, the log
    assert "Ended" in call(tok, "try_input", {"id": A, "input": "add", "value": 3}, error=True)
    assert call(tok, "start") == "Running"
    call(tok, "watch", {"id": B})
    call(tok, "get_events")
    call(tok, "try_input", {"id": A, "input": "add", "value": 3})
    tried = fired = None
    for i in range(50):
        for ev in json.loads(call(tok, "get_events")):
            if ev["event"] == "tried":
                tried = ev["data"]
            elif ev["event"] == "fired":
                fired = ev["data"]
        if tried and fired:
            break
        time.sleep(0.2)
    assert tried and tried["id"] == A and ["reached", 3] in tried["emitted"], tried
    assert fired and fired["id"] == B and any(f[1] == "changed" for f in fired["fired"]), fired
    assert any("tried: add by kitboss's agent" in l for l in
        json.loads(call(tok, "get_log", {"id": A})))
    assert ent(B)["components"][0]["state"]["count"] == 1, ent(B)
    call(tok, "watch", {"id": 0})
    call(tok, "get_log", {"id": 999999}, error=True)
    assert call(tok, "stop").startswith("Ended")
    assert "no builds discarded" in call(tok, "keep", error=True)
    # A new scene takes the agent's edits there; back again
    if st["can_make_scenes"]:
        call(tok, "new_scene", {"name": "agents2"})
        assert state(tok)["scene"] == "agents2"
        placed(call(tok, "place", {"type": "kit/counter", "pos": [0, 1, 0]}))
        assert call(tok, "switch_scene", {"name": first}) == "In the scene " + first
    call(tok, "switch_scene", {"name": first}, error=True)
    call(tok, "unlink", {"id": A, "output": "reached", "to": B, "input": "count"})
    assert json.loads(call(tok, "get_links", {"id": B})) == []
    # Every edit of this phase taken back
    st = state(tok)
    while st["undo"] > undo0:
        assert "Undone" in call(tok, "undo")
        st = state(tok)
    assert sorted(e["id"] for e in st["entities"]) == before, st["entities"]
elif phase == "gone":
    refused(401, -32001, sys.argv[3], {"jsonrpc": "2.0", "id": 1, "method": "ping"})
elif phase == "off":
    b, h = refused(403, -32001, sys.argv[3], {"jsonrpc": "2.0", "id": 1, "method": "ping"})
    assert "Agent access is off" in b, b
elif phase == "admin":
    adm = sys.argv[3]
    assert call(adm, "set_builder", {"name": "kitboss", "on": True}) == "kitboss is a builder"
    for i in range(130):
        s, b, h = post(adm, {"jsonrpc": "2.0", "id": i, "method": "ping"})
        if s == 429:
            break
        assert s == 200, (s, b)
    assert s == 429 and json.loads(b)["error"]["code"] == -32000, (i, s, b)
    print("429 after", i, "pings")
print("ok:", phase)
PY
python3 -I "$t/mcp.py" main "$url" "$tok" > "$t/main.log" 2>&1 ||
	fail "the MCP run: $(tail -5 "$t/main.log") ($t/main.log, $SL)"
cat "$t/main.log"
for re in "An edit by kitboss's agent: placed kit/timer [0-9]+" \
		"An edit by kitboss's agent: set [0-9]+'s kit/timer interval to 0.2" \
		"An edit by kitboss's agent: linked [0-9]+.tick -> [0-9]+.count" \
		"An undo by kitboss's agent: " "kitboss's agent \(\"Claude Code\", builder token\) is here"; do
	grep -aqE "$re" "$SL" || fail "no \"$re\" in $SL"
done
python3 -I "$t/mcp.py" build "$url" "$tok" > "$t/build.log" 2>&1 ||
	fail "the MCP build run: $(tail -5 "$t/build.log") ($t/build.log, $SL)"
cat "$t/build.log"
for re in "An edit by kitboss's agent: saved prefab kitboss/agentpair " \
		"kitboss's agent: placed .* in 4 of 4 cells .*, one undo" \
		"kitboss's agent tries entity [0-9]+'s add 3" \
		"kitboss's agent watches entity [0-9]+" \
		"kitboss's agent goes to the scene "; do
	grep -aqE "$re" "$SL" || fail "no \"$re\" in $SL"
done
await "$CL" 0 5 "kit editor: builder kitboss's agent "
# 3. Revoked on the page
step 10 "pause: the menu shown" "keypress Escape"
step 10 "accounts: agents: 2 tokens, on" "frames 3" 'click Button "My account*"' \
	"frames 5" 'click Button "Connect an agent..."'
m=$(mark "$SL")
step 10 "accounts: agents: revoked Claude Code" "frames 3" 'click Button "Revoke Claude Code"'
# (gone at once, not at its next request)
await "$SL" "$m" 5 "kitboss's agent left: its token was revoked"
python3 -I "$t/mcp.py" gone "$url" "$tok" || fail "the revoked token not refused"
# 4. The admin's switch
step 10 "[0-9]+ accounts listed" "frames 3" 'click Button "Accounts*"'
# (the page drawn again by the list after the result)
switch() # <on|off>: from the other
{
	local m=$(mark "$CL") from=on
	[ "$1" = on ] && from=off
	cmd "frames 3" "click Button \"Agents (MCP): $from*\""
	await "$CL" "$m" 10 "admin result: Agent access is $1"
	await "$CL" "$m" 10 "[0-9]+ accounts listed"
}
switch off
cmd "frames 5" "screenshot $t/switch.png"
python3 -I "$t/mcp.py" off "$url" "$adm" || fail "the admin token not refused while off"
switch on
python3 -I "$t/mcp.py" admin "$url" "$adm" || fail "the admin token's run ($SL)"
grep -aq "kitboss's agent made builder kitboss" "$SL" || fail "no admin edit by the agent ($SL)"
cmd "sync 2000" quit
exec 3>&-
wait $CLIENT 2>/dev/null
for f in "$SL" "$CL" "$t/main.log"; do
	grep -aqF "${tok#bat_}" "$f" && fail "the builder token is in $f"
	grep -aqF "${adm#bat_}" "$f" && fail "the admin token is in $f"
done
for p in token tokens switch; do
	[ -s "$t/$p.png" ] || fail "no screenshot $t/$p.png"
done
echo "PASS: an agent token made, copied and revoked on My account; Kit's MCP endpoint edits, runs, reads back and undoes as kitboss's agent with all its tools and its guide, refuses what it should; screenshots $t/token.png $t/tokens.png $t/switch.png"
