#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~3 min (2026-11-22)
# covers: apps/workbench/main/main.cpp builtin/kit/kit.cpp builtin/storage/storage.cpp builtin/world_menu/client_lua/module.lua src/impl/aitta.cpp
# [KIT_GAME_NOT_HOSTED] A game Kit does not load leaves Workbench's server
# up with no game, on a server no launcher started (kitboss its admin by
# first_admin). "good" made by a first start (BUILDAT_WORKBENCH_PROJECT),
# copied as "old" and "newer", each given a kit/ui_text with a parameter
# zz_gone that no Kit has, old's save last opened by 0.8.0-alpha.9 and
# newer's by 0.8.0-alpha.100 (both past a string compare's order):
#   1. kitboss in good (the server reopens the game that ran last): Games...,
#      old's Play: the switch, old does not load, the server stays up.
#   2. kitboss again: Manage, old's "made with an older Buildat
#      (0.8.0-alpha.9)" over it; kitbob (no admin): "No game is loaded"
#      over the wait; an agent's MCP (OAuth, kitboss's password):
#      initialize and a tools/call say no game is loaded and why.
#   3. kitboss: newer's Play from no game: it does not load, the server
#      stays up; kitboss again: newer's "made with a newer Buildat".
#   4. The server restarted, newer the game that ran last: no game again
#      (not a stop), newer's text over Manage; good's Play: in good.
# Screenshots: $t/manage_old.png, wait_bob.png, manage_newer.png,
# good_again.png (KEEP_TMP=1 keeps them).
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp workbench_not_hosted; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1
mkdir -p "$t/user"
echo "name kitboss checkpass12" > "$t/user/first_admin"
saves=$t/user/apps/workbench/saves
server() # <log> [env...]: up, its pid SERVER_PID
{
	local log=$1
	shift
	start_server "$log" "Listening at" 300 auto env "$@" \
		bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
		fail "the server did not come up ($log)"
	CHECK_PIDS+=($SERVER_PID)
}
stop(){ kill -INT "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; }

# The games: good by a start; old and newer its copies, their rows the check's
server "$t/srv0.log" BUILDAT_WORKBENCH_PROJECT=good
wait_for_log "$t/srv0.log" "Hosted: " 120 || fail "good not hosted ($t/srv0.log)"
stop
for g in old newer; do
	mkdir -p "$saves/$g"
	cp "$saves/good/save.sqlite" "$saves/$g/" || fail "no good save ($saves)"
done
python3 - "$saves" <<'PY' || fail "the rows"
import json, sqlite3, sys
for g, by in (("old", "0.8.0-alpha.9"), ("newer", "0.8.0-alpha.100")):
    db = sqlite3.connect(sys.argv[1] + "/" + g + "/save.sqlite")
    authored = {"next_id": 4, "entities": [
        {"id": 2, "name": "world", "kind": "scene"},
        {"id": 3, "parent": 1, "name": "text", "components": [
            {"type": "kit/ui_text", "params": {"zz_gone": 1}}]}]}
    for store, key, value in (("kit", "authored", json.dumps(authored)),
            ("__save", "version", by)):
        db.execute("INSERT OR REPLACE INTO store VALUES (?, ?, ?)",
                (store, key, value))
    db.execute("DELETE FROM store WHERE store = '__save' AND key = 'was'")
    db.commit()
PY
echo "ok: good made; old (0.8.0-alpha.9's) and newer (0.8.0-alpha.100's) with kit/ui_text's zz_gone"

s=$t/srv1.log
server "$s"
client() # <name> [env...]: its commands in $t/<name>.cmds; 0 when the drive ran to its quit
{
	local n=$1
	shift
	sed -i "s|@T@|$t|g" "$t/$n.cmds"
	env "$@" timeout 300 bin/buildat -C "$t/client_cache" -D "$t/cu_$n" \
		-s localhost:$SERVER_PORT -w 1024x700 -l 3 -o sound_mute=1 \
		-c @"$t/$n.cmds" > "$t/$n.log" 2>&1
	! grep -aq "Command sequence failed" "$t/$n.log" &&
		grep -aq "command: quit" "$t/$n.log"
}
up(){ kill -0 "$SERVER_PID" 2>/dev/null || fail "the server stopped ($s)"; }
JOINED='wait_log_any 60000 player physics enabled
wait_log_any 30000 kit editor: edit rights:'
OLD='This game was made with an older Buildat (0.8.0-alpha.9): kit/ui_text'"'"'s zz_gone is gone in this one'
NEWER='This game was made with a newer Buildat (kit/ui_text'"'"'s zz_gone, Buildat 0.8.0-alpha.100). This Buildat has no such parameter.'

# 1.
cat > "$t/boss1.cmds" <<EOF
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
$JOINED
keypress Escape
wait_log 5000 pause: the menu shown
frames 3
click Button "Games..."
wait_log 10000 world_menu: the list shown, 3 worlds
frames 3
click Button "old"
wait_log 5000 world_menu: the list shown
frames 3
expect_error Disconnected from server: The server is switching
click Button "Play"
wait_log 60000 Disconnected from server: The server is switching to the game old
quit
EOF
client boss1 BUILDAT_JOIN_NAME=kitboss \
	BUILDAT_JOIN_ADMIN="setting open_registration on" || fail "kitboss in good, old's Play ($t/boss1.log)"
wait_for_log "$s" "workbench: no game is loaded: The game old did not load" 120 ||
	fail "old's failure not said ($s)"
grep -aqF "$OLD" "$s" || fail "not the older text ($s)"
sleep 1
up
echo "ok: old's switch: not loaded, the server up"

# 2.
cat > "$t/boss2.cmds" <<EOF
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 world_menu: said: The game old did not load
wait_log_any 10000 world_menu: the list shown, 3 worlds
frames 5
screenshot @T@/manage_old.png
quit
EOF
client boss2 BUILDAT_JOIN_NAME=kitboss || fail "Manage with old's text ($t/boss2.log)"
grep -aqF "$OLD" "$t/boss2.log" || fail "the older text not over Manage ($t/boss2.log)"
cat > "$t/bob.cmds" <<EOF
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 world_menu: the wait shown: No game is loaded
frames 5
screenshot @T@/wait_bob.png
quit
EOF
client bob BUILDAT_JOIN_NAME=kitbob || fail "kitbob's wait ($t/bob.log)"
python3 - "http://localhost:$SERVER_PORT" <<'PY' || fail "MCP with no game"
import base64, hashlib, http.server, json, re, secrets, sys, threading
import urllib.error, urllib.parse, urllib.request
B = sys.argv[1]
MCP = B + "/api/v1/mcp"
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None
op = urllib.request.build_opener(NoRedirect)
def req(url, body, headers={}):
    if isinstance(body, dict):
        body = urllib.parse.urlencode(body).encode()
        headers = dict({"Content-Type": "application/x-www-form-urlencoded"},
                **headers)
    r = urllib.request.Request(url, data=body, headers=headers,
            method="POST" if body is not None else "GET")
    try:
        with op.open(r, timeout=15) as x:
            return x.status, x.read().decode(), x.headers
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(), e.headers
redir = "http://127.0.0.1:9/cb"
s, b, h = req(B + "/api/v1/oauth/register", json.dumps({"redirect_uris": [redir],
        "client_name": "not hosted check", "token_endpoint_auth_method": "none",
        "grant_types": ["authorization_code"], "response_types": ["code"]}).encode(),
        {"Content-Type": "application/json"})
assert s == 201, (s, b)
cid = json.loads(b)["client_id"]
v = secrets.token_urlsafe(48)
ch = base64.urlsafe_b64encode(hashlib.sha256(v.encode()).digest()).decode().rstrip("=")
s, b, h = req(B + "/api/v1/oauth/authorize?" + urllib.parse.urlencode({
        "response_type": "code", "client_id": cid, "redirect_uri": redir,
        "state": "s", "code_challenge": ch, "code_challenge_method": "S256",
        "scope": "builder", "resource": MCP}), None)
assert s == 200, (s, b)
rid = re.search(r'name="rid" value="([0-9a-f]{32})"', b).group(1)
form = lambda f: req(B + "/api/v1/oauth/authorize", f, {"Origin": B})
s, b, h = form({"rid": rid, "name": "kitboss", "password": "checkpass12",
        "action": "allow"})
if s == 200: # the admin's step: builder
    s, b, h = form({"rid": rid, "action": "allow"})
assert s == 303, (s, b)
code = urllib.parse.parse_qs(urllib.parse.urlparse(h["Location"]).query)["code"][0]
s, b, h = req(B + "/api/v1/oauth/token", {"grant_type": "authorization_code",
        "code": code, "redirect_uri": redir, "code_verifier": v, "client_id": cid})
assert s == 200, (s, b)
tok = json.loads(b)["access_token"]
def mcp(n, method, params):
    s, b, h = req(MCP, json.dumps({"jsonrpc": "2.0", "id": n, "method": method,
            "params": params}).encode(), {"Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "Authorization": "Bearer " + tok})
    assert s == 200, (method, s, b)
    return json.loads(b)["result"]
want = "No game is loaded on this server: the game old did not load: entity 3: kit/ui_text has no parameter zz_gone (This game was made with an older Buildat (0.8.0-alpha.9)"
r = mcp(1, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
        "clientInfo": {"name": "check", "version": "1"}})
assert want in r["instructions"], r["instructions"]
r = mcp(2, "tools/call", {"name": "get_state", "arguments": {}})
assert r["isError"] and r["content"][0]["text"].startswith(want), r
print("ok: MCP: " + r["content"][0]["text"])
PY
up
echo "ok: kitboss: Manage, old's older text over it; kitbob: \"No game is loaded\" over the wait"

# 3.
cat > "$t/boss3.cmds" <<EOF
wait_log_any 60000 Joined as kitboss
wait_log_any 10000 world_menu: the list shown, 3 worlds
frames 3
click Button "newer"
wait_log 5000 world_menu: the list shown
frames 3
expect_error Disconnected from server: The game newer did not load
click Button "Play"
wait_log 60000 Disconnected from server: The game newer did not load
quit
EOF
client boss3 BUILDAT_JOIN_NAME=kitboss || fail "newer's Play from no game ($t/boss3.log)"
grep -aqF "$NEWER" "$s" || fail "not the newer text ($s)"
cat > "$t/boss4.cmds" <<EOF
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 world_menu: said: The game newer did not load
wait_log_any 10000 world_menu: the list shown, 3 worlds
frames 5
screenshot @T@/manage_newer.png
quit
EOF
client boss4 BUILDAT_JOIN_NAME=kitboss || fail "Manage with newer's text ($t/boss4.log)"
grep -aqF "$NEWER" "$t/boss4.log" || fail "the newer text not over Manage ($t/boss4.log)"
up
echo "ok: newer from no game: not loaded, the server up, its newer text over Manage"

# 4.
stop
s=$t/srv2.log
server "$s"
wait_for_log "$s" "workbench: no game is loaded: The game newer did not load" 120 ||
	fail "the restart did not come to no game ($s)"
cat > "$t/boss5.cmds" <<EOF
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 world_menu: said: The game newer did not load
wait_log_any 10000 world_menu: the list shown, 3 worlds
frames 3
click Button "good"
wait_log 5000 world_menu: the list shown
frames 3
click Button "Play"
$JOINED
sync 5000
frames 10
screenshot @T@/good_again.png
quit
EOF
client boss5 BUILDAT_JOIN_NAME=kitboss || fail "good after the restart ($t/boss5.log)"
grep -aq 'workbench: the project "good" opens' "$s" || fail "good not opened ($s)"
up
stop
echo "PASS: a game Kit does not load left Workbench's server up with no game: old (0.8.0-alpha.9's) said to be an older Buildat's, newer (0.8.0-alpha.100's) a newer one's, over the admin's Manage; \"No game is loaded\" to a player and to an agent's MCP; a restart with newer last came to no game again; good opened from it"
# vim: set noet ts=4 sw=4:
