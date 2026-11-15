#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min (2026-11-15)
# covers: builtin/accounts/accounts.cpp builtin/accounts/oauth.h builtin/accounts/client_lua/accounts.lua builtin/network/network.cpp builtin/network/api.h builtin/kit/kit.cpp builtin/starport_announce/**
# [KIT_AGENTS_OAUTH] A tool that signs in by OAuth (claude.ai's connectors)
# reaches Kit's MCP endpoint by its URL alone. A local Starport and a
# Workbench listed on it (IDs taken), boss its admin by first_admin; reader,
# a Starport ID, joins once from a native client (headless weston) so that
# it has an account there; carl, a builder with a password and no admin,
# made by boss's admin script. A Python client with a loopback redirect, and
# headless Chrome (Playwright) where a browser would be, a phone's size:
#   1. discovery: the 401's resource_metadata, the resource's metadata at
#      both paths, the server's; the origin by Host and a trusted proxy's
#      X-Forwarded-Proto, a bad Host none;
#   2. registration: a public client and one with a secret; bad redirect
#      URIs, grant types and sizes refused; a page's /register and /token
#      (an Origin), a text/plain /register refused;
#   3. /authorize's refusals: an unknown client and an unregistered
#      redirect stay on the page; no PKCE S256, another resource, another
#      response type too, with a link back with the error (no redirect);
#   4. boss's password on the page (Chrome), then the admin's step
#      ([KIT_AGENTS_OAUTH_ADMIN_BOX]): the Host's box unticked, the text
#      following it ticked and unticked; left unticked (the tool asked for
#      admin): builder, list_projects refused; the code back with its state
#      and iss; a wrong verifier, redirect_uri, resource, client refused;
#      the tokens, MCP initialize and tools/list by the access token; the
#      code again: refused, and what it gave revoked;
#   5. the page's forms by Python: another origin's post refused; the box
#      ticked (the tool asked for builder): an Admin grant, list_projects
#      answered, its refresh token rotated (the old access token gone), the
#      one before used again ending the grant; Deny back with access_denied;
#      a box's value on the password's form not the step's: builder; one two
#      rotations old ending a grant too; carl (no admin): no step, back at
#      once, host=1 posted giving builder; a rebound name's Host
#      (evil.example, its own X-Forwarded-For each time) refused before
#      any password; a network's 31st page in 10 minutes refused while
#      another's sign-in goes on; tokenless MCP probes not counted against
#      a network, bad tokens counted;
#   6. reader's Starport ID (Chrome, the Starport's own window): the code,
#      the client by HTTP Basic, MCP; reader banned by boss's admin script
#      (a native client): the grant's MCP call and refresh refused, its
#      agent gone; unbanned;
#   7. reader's client again: My account, Connect an agent... lists the
#      grant by the client's name, "signed in"; Revoke; its access and
#      refresh tokens refused;
#   8. a wrong password, then the address's wait; registration's cap of
#      100 an hour;
#   9. starport.json's "address" https://wb.example.org (the Public
#      address): by a proxy under that name, registration, the page, the
#      sign-in and the token; no token, code, secret or password in the
#      server's log.
# Screenshots, kept with KEEP_TMP=1: $t/authorize.png (the page on the
# phone: Server login or Starport ID login), $t/authorize_local.png (the
# name and password after Server login), $t/authorize_host.png (boss's
# step, the Host's box ticked), $t/authorize_id_window.png (the
# Starport's window),
# $t/tokens.png (My account's list with the grant)
#   util/kit_agents_oauth_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
command -v weston > /dev/null || skip "no weston"
command -v node > /dev/null || skip "no node"
export NODE_PATH=${PLAYWRIGHT_NODE:-$HOME/.local/share/playwright-node}/node_modules
[ -d "$NODE_PATH/playwright" ] || skip "no Playwright in $NODE_PATH"
export CHROME=${CHROME:-$(command -v google-chrome || command -v chromium || true)}
[ -n "$CHROME" ] || skip "no Chrome"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_agents_oauth; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_WORKBENCH_PROJECT=world
check_build
sock=buildat-oauth-$$
weston --backend=headless --xwayland --socket=$sock --width=900 \
	--height=700 > "$t/weston.log" 2>&1 &
CHECK_PIDS+=($!)
for i in $(seq 50); do
	d=$(grep -ao "xserver listening on display :[0-9]*" "$t/weston.log" | grep -o ":[0-9]*$")
	[ -n "$d" ] && break
	sleep 0.2
done
[ -n "$d" ] || fail "weston's Xwayland ($t/weston.log)"

# The Starport verifies the Workbench by connecting to it: its port first
while WB=$((29700 + RANDOM % 300)); port_taken $WB; do :; done
export BUILDAT_CONNECT_PORTS="$WB"
start_server "$t/sp.log" "setup code" 120 auto \
	bin/buildat_server -m ../apps/starport -D "$t/sp" -l 3 ||
	fail "the Starport did not start ($t/sp.log)"
CHECK_PIDS+=($SERVER_PID)
SP=$SERVER_PORT
mkdir -p "$t/wb/apps/workbench"
echo "name boss checkpass12" > "$t/wb/first_admin"
cat > "$t/wb/apps/workbench/starport.json" <<J
{"starports": ["http://127.0.0.1:$SP"], "name": "Check workbench", "ids": "anyone",
 "kind": "app", "audience": "everyone", "access": "auto",
 "descriptors": {"violence": "none", "chat": "moderated", "ugc": "moderated",
  "language": "no", "sexual": "no", "drugs": "no", "purchases": "no",
  "gambling": "no", "personal_data": "no"}}
J
export BUILDAT_CONNECT_PORTS="$SP,$WB"
start_server "$t/wb.log" "Listening at" 300 $WB \
	bin/buildat_server -m ../apps/workbench -D "$t/wb" -l 3 \
	--sim-rate "$CHECK_RATE" || fail "the Workbench did not start ($t/wb.log)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$t/sp.log" "verified ok" 60 || fail "the Workbench was not listed ($t/sp.log)"

# reader's client: a Starport ID signed in, the Starport accepted
session=$(python3 - "$SP" <<'PY'
import json, sys, time, urllib.request
r = json.loads(urllib.request.urlopen("http://127.0.0.1:%s/api/v1/id/register" %
    sys.argv[1], json.dumps(dict(name="reader", password="secret1",
    birth_year=time.gmtime().tm_year - 40)).encode()).read())
assert r["ok"], r
print(r["result"]["session"])
PY
) || fail "the ID API"
mkdir -p "$t/u"
printf '{"starports": ["http://127.0.0.1:%s"],\n "ids": {"http://127.0.0.1:%s": {"session": "%s", "name": "reader"}}}\n' \
	$SP $SP "$session" > "$t/u/starport.json"
printf 'accepted,address,description,created,last_attempt,name,icon,server\n"true","http://127.0.0.1:%s","Starport","%s","%s","","",""\n' \
	$SP $(date +%s) $(date +%s) > "$t/u/network_addresses.csv"
join() # <log> <commands>
{
	printf "$2" > "$t/$1.cmds"
	DISPLAY=$d WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11 timeout 120 \
		bin/buildat -C "$t/client_cache" -D "$t/u" -s 127.0.0.1:$WB \
		-w 800x600 -l 3 -o sound_mute=1 -c @"$t/$1.cmds" > "$t/$1.log" 2>&1
}
join j1 'wait_log_any 60000 accounts: the login page shown\nframes 5\nkeypress Return\nwait_log 20000 ID name prompt:\nframes 5\nclick Button "Use it"\nwait_log 30000 Joined as\nquit\n' ||
	fail "reader's join ($t/j1.log)"
grep -aq "Joined as reader" "$t/j1.log" ||
	fail "reader's join: $(grep -a 'Joined\|refused' "$t/j1.log" | head -2)"
echo "ok: reader joined by its Starport ID"

cat > "$t/authorize.js" <<'JS'
// The page as a phone's browser has it: name and password, or the
// Starport's window; done when it goes back to the tool's redirect
"use strict";
const pw = require("playwright");
const [mode, url, redirect, shot, name, password, host] = process.argv.slice(2);
(async () => {
	const browser = await pw.chromium.launch({executablePath: process.env.CHROME,
		headless: true});
	const ctx = await browser.newContext({viewport: {width: 412, height: 915},
		isMobile: true, hasTouch: true});
	const page = await ctx.newPage();
	// What the page's policy refused, and what its script threw
	const problems = [];
	page.on("console", m => {
		if(m.type() === "error" && /Content.Security.Policy/i.test(m.text()))
			problems.push(m.text());
	});
	page.on("pageerror", e => problems.push(e.message));
	await page.goto(url);
	await page.waitForSelector("#pw", {state: "attached"});
	await page.waitForLoadState("load");
	// The choice of logins first, where a Starport ID signs in too
	const two = await page.$("#choose");
	if(two && (await page.isVisible("#pw") || !await page.isVisible("#local")))
		problems.push("not the choice of logins first");
	if(!await page.evaluate(() => document.querySelector("header img").naturalWidth))
		problems.push("no logo");
	await page.screenshot({path: shot});
	const done = page.waitForURL(u => u.href.startsWith(redirect + "?"),
		{timeout: 60000});
	if(mode === "password"){
		if(two){
			await page.tap("#local");
			await page.tap("#back");
			if(!await page.isVisible("#local"))
				problems.push("Back not back at the choice");
			await page.tap("#local");
			await page.screenshot({path: shot.replace(/\.png$/, "_local.png")});
		}
		await page.fill("#pw input[name=name]", name);
		await page.fill("#pw input[name=password]", password);
		await page.tap("#pw button[value=allow]");
		// An admin's step: the Host's box, unticked, the text following it
		if(host){
			await page.waitForSelector("#host");
			const says = () => page.textContent("#rights");
			if(await page.isChecked("#host") || !/builder rights/.test(await says()))
				problems.push("the box not unticked first with the builder's text");
			await page.tap("#host");
			if(!/the Host's actions included/.test(await says()))
				problems.push("the text not the ticked box's");
			await page.screenshot({path: shot.replace(/\.png$/, "_host.png")});
			if(host === "untick"){
				await page.tap("#host");
				if(!/builder rights/.test(await says()))
					problems.push("the text not back at the builder's");
			}
			await page.tap("#pw button[value=allow]");
		}
	} else {
		const opened = ctx.waitForEvent("page");
		await page.tap("button.sp");
		const w = await opened;
		await w.waitForFunction(() => location.pathname == "/authorize" &&
			document.readyState == "complete" &&
			!document.getElementById("login").classList.contains("hide"));
		await w.fill("#name", name);
		await w.fill("#password", password);
		await w.evaluate(() => document.getElementById("login").requestSubmit());
		await w.waitForFunction(() =>
			!document.getElementById("allow").classList.contains("hide"));
		await w.screenshot({path: shot.replace(/\.png$/, "_window.png")});
		await w.evaluate(() => document.getElementById("allow").requestSubmit());
	}
	await done;
	if(problems.length)
		throw new Error("the page: " + problems.join("; "));
	console.log("ok: the page in Chrome (" + mode + "), back at the tool");
	await browser.close();
})().catch(e => { console.error(e); process.exit(1); });
JS

cat > "$t/oauth.py" <<'PY'
import base64, hashlib, html, http.server, json, os, re, secrets, subprocess, sys
import threading, urllib.error, urllib.parse, urllib.request
phase, B, T = sys.argv[1:4]
MCP = B + "/api/v1/mcp"
FORM = {"Content-Type": "application/x-www-form-urlencoded"}
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None
op = urllib.request.build_opener(NoRedirect)
def req(method, url, body=None, headers={}):
    if isinstance(body, dict):
        body = urllib.parse.urlencode(body).encode()
        headers = dict(FORM, **headers)
    r = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with op.open(r, timeout=15) as x:
            return x.status, x.read().decode(), x.headers
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(), e.headers
def jpost(url, obj, headers={}):
    return req("POST", url, json.dumps(obj).encode(),
            dict({"Content-Type": "application/json"}, **headers))
def ok(what):
    print("ok:", what, flush=True)
st_path = T + "/oauth_state.json"
state = json.load(open(st_path)) if os.path.exists(st_path) else \
        {"registers": 0, "secrets": ["checkpass12", "secret1", "carlpass123"]}
def keep(*s):
    state["secrets"].extend(s)
# The tool's redirect: a loopback listener, as a desktop tool's
got = []
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/cb"): # (not the browser's /favicon.ico)
            got.append(self.path)
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"done")
    def log_message(self, *a):
        pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
REDIR = "http://127.0.0.1:%d/cb" % srv.server_port
def pkce():
    v = secrets.token_urlsafe(48)
    return v, base64.urlsafe_b64encode(
            hashlib.sha256(v.encode()).digest()).decode().rstrip("=")
def register_raw(meta):
    state["registers"] += 1
    return jpost(B + "/api/v1/oauth/register", meta)
def register(name, auth="none"):
    m = {"redirect_uris": [REDIR], "client_name": name,
         "grant_types": ["authorization_code", "refresh_token"],
         "response_types": ["code"]}
    if auth:
        m["token_endpoint_auth_method"] = auth
    s, b, h = register_raw(m)
    assert s == 201, (s, b)
    j = json.loads(b)
    assert re.fullmatch("[0-9a-f]{32}", j["client_id"]), j
    assert j["redirect_uris"] == [REDIR], j
    if "client_secret" in j:
        keep(j["client_secret"])
    return j
def auth_url(cid, challenge, st, **over):
    q = {"response_type": "code", "client_id": cid, "redirect_uri": REDIR,
         "state": st, "code_challenge": challenge,
         "code_challenge_method": "S256", "scope": "builder", "resource": MCP}
    q.update(over)
    return B + "/api/v1/oauth/authorize?" + urllib.parse.urlencode(
            {k: v for k, v in q.items() if v is not None})
def back(url, st):
    assert url.startswith(REDIR + "?"), url
    q = {k: v[0] for k, v in urllib.parse.parse_qs(
            urllib.parse.urlparse(url).query).items()}
    assert q.get("state") == st and q.get("iss") == B, q
    if "code" in q:
        assert re.fullmatch("[0-9a-f]{64}", q["code"]), q
        keep(q["code"])
    return q
def browser(mode, url, shot, st, *creds):
    got.clear()
    r = subprocess.run(["node", T + "/authorize.js", mode, url, REDIR, shot] +
            list(creds), capture_output=True, text=True, timeout=150)
    print(r.stdout, end="")
    assert r.returncode == 0, r.stderr[-3000:]
    assert len(got) == 1, got
    return back("http://127.0.0.1:%d%s" % (srv.server_port, got[0]), st)
def rid_of(b):
    return re.search(r'name="rid" value="([0-9a-f]{32})"', b).group(1)
def post_form(fields, origin=B):
    return req("POST", B + "/api/v1/oauth/authorize", fields,
            {"Origin": origin} if origin else {})
def token(fields, basic=None):
    h = {}
    if basic:
        h["Authorization"] = "Basic " + base64.b64encode(
                ("%s:%s" % basic).encode()).decode()
    s, b, hd = req("POST", B + "/api/v1/oauth/token", fields, h)
    assert hd.get("Cache-Control") == "no-store", dict(hd)
    assert "Access-Control-Allow-Origin" not in hd, dict(hd)
    j = json.loads(b)
    if s == 200:
        assert j["token_type"] == "Bearer" and j["expires_in"] == 3600, j
        assert re.fullmatch("bao_[0-9a-f]{32}_[0-9a-f]{64}", j["access_token"]), j
        assert re.fullmatch("bar_[0-9a-f]{32}_[0-9a-f]{64}", j["refresh_token"]), j
        keep(j["access_token"], j["refresh_token"])
    return s, j
def refused(fields, error, status=400, basic=None):
    s, j = token(fields, basic)
    assert s == status and j["error"] == error, (fields, s, j)
def mcp(tok, method, params=None, nid=1):
    m = {"jsonrpc": "2.0", "method": method}
    if nid is not None:
        m["id"] = nid
    if params is not None:
        m["params"] = params
    return jpost(MCP, m, {"Accept": "application/json, text/event-stream",
            "Authorization": "Bearer " + tok})
def mcp_works(tok):
    s, b, h = mcp(tok, "initialize", {"protocolVersion": "2025-06-18",
            "capabilities": {}, "clientInfo": {"name": "oauth check",
            "version": "1"}})
    assert s == 200, (s, b)
    assert json.loads(b)["result"]["protocolVersion"] == "2025-06-18", b
    s, b, h = mcp(tok, "notifications/initialized", nid=None)
    assert s in (200, 202), (s, b)
    s, b, h = mcp(tok, "tools/list", {}, 2)
    assert s == 200, (s, b)
    tools = [x["name"] for x in json.loads(b)["result"]["tools"]]
    assert "get_state" in tools, tools
    return len(tools)
def mcp_refused(tok):
    s, b, h = mcp(tok, "tools/list", {}, 3)
    assert s == 401 and 'error="invalid_token"' in h["WWW-Authenticate"], \
            (s, b, dict(h))
# list_projects, one of the Host's actions: answered, or refused as an
# admin's; its text
def projects(tok, answered):
    s, b, h = mcp(tok, "tools/call", {"name": "list_projects", "arguments": {}}, 6)
    assert s == 200, (s, b)
    r = json.loads(b)["result"]
    text = r["content"][0]["text"]
    assert r["isError"] != answered and (answered or "an admin's" in text), text
    return text

if phase == "a":
    # 1. Discovery, as MCP's spec has a client do it
    s, b, h = jpost(MCP, {"jsonrpc": "2.0", "id": 1, "method": "initialize"},
            {"Accept": "application/json, text/event-stream"})
    assert s == 401, (s, b)
    m = re.fullmatch(r'Bearer resource_metadata="([^"]+)", scope="builder"',
            h["WWW-Authenticate"])
    assert m and m.group(1) == B + \
            "/.well-known/oauth-protected-resource/api/v1/mcp", dict(h)
    mcp_refused("bao_" + "0" * 32 + "_" + "0" * 64)
    for u in (m.group(1), B + "/.well-known/oauth-protected-resource"):
        s, b, h = req("GET", u)
        j = json.loads(b)
        assert s == 200 and j["resource"] == MCP and \
                j["authorization_servers"] == [B] and \
                j["scopes_supported"] == ["builder"], (u, s, b)
    s, b, h = req("GET", B + "/.well-known/oauth-authorization-server")
    j = json.loads(b)
    assert s == 200 and j["issuer"] == B, b
    for k, v in (("authorization_endpoint", "/api/v1/oauth/authorize"),
            ("token_endpoint", "/api/v1/oauth/token"),
            ("registration_endpoint", "/api/v1/oauth/register")):
        assert j[k] == B + v, j
    assert j["code_challenge_methods_supported"] == ["S256"], j
    assert "none" in j["token_endpoint_auth_methods_supported"], j
    assert j["grant_types_supported"] == ["authorization_code",
            "refresh_token"], j
    # The origin is the one the client reached: Host, and the scheme a
    # trusted proxy's (loopback by default: a TLS proxy here) says
    for xfp, scheme in (("https", "https"), ("http", "http"), ("gopher", "http")):
        s, b, h = req("GET", B + "/.well-known/oauth-authorization-server",
                headers={"Host": "WB.example.org", "X-Forwarded-Proto": xfp})
        assert s == 200 and json.loads(b)["issuer"] == scheme + \
                "://wb.example.org", (xfp, b)
    for host in ("evil.example/x", "a b", "x:1:2"):
        s, b, h = req("GET", B + "/.well-known/oauth-authorization-server",
                headers={"Host": host})
        assert s in (400, 404), (host, s, b)
    s, b, h = req("GET", B + "/.well-known/openid-configuration")
    assert s == 404, (s, b)
    ok("discovery: the 401's resource_metadata, both of the resource's "
            "paths, the server's metadata; the origin by Host")

    # 2. Registration
    pub = register("Check <tool>")
    assert pub["token_endpoint_auth_method"] == "none" and \
            "client_secret" not in pub, pub
    conf = register("Check ID tool", None)
    assert conf["token_endpoint_auth_method"] == "client_secret_basic" and \
            re.fullmatch("[0-9a-f]{64}", conf["client_secret"]), conf
    for bad in ([], ["http://evil.example/cb"], ["javascript:alert(1)"],
            ["https://user@x.example/cb"], ["https://x.example/cb#f"],
            ["cursor://anysphere.cursor-retrieval/oauth/callback"]):
        s, b, h = register_raw({"redirect_uris": bad})
        assert s == 400 and json.loads(b)["error"] == "invalid_redirect_uri", \
                (bad, s, b)
    s, b, h = register_raw({"redirect_uris": [REDIR], "grant_types": ["implicit"]})
    assert s == 400 and json.loads(b)["error"] == "invalid_client_metadata", b
    state["registers"] += 1
    s, b, h = req("POST", B + "/api/v1/oauth/register", b"[" * 9000,
            {"Content-Type": "application/json"})
    assert s == 400, (s, b)
    # A page's (any site's visitors filling the cap): by its Origin, and a
    # no-cors fetch's type; neither counts toward the network's 100 an hour
    meta = json.dumps({"redirect_uris": [REDIR]}).encode()
    s, b, h = req("POST", B + "/api/v1/oauth/register", meta,
            {"Content-Type": "application/json", "Origin": "https://evil.example"})
    assert s == 403 and json.loads(b)["error"] == "invalid_request", (s, b)
    s, b, h = req("POST", B + "/api/v1/oauth/register", meta,
            {"Content-Type": "text/plain"})
    assert s == 400 and json.loads(b)["error"] == "invalid_client_metadata", (s, b)
    s, b, h = req("POST", B + "/api/v1/oauth/token", {"grant_type":
            "refresh_token", "refresh_token": "x"}, {"Origin": "https://evil.example"})
    assert s == 403 and json.loads(b)["error"] == "invalid_request", (s, b)
    ok("registration: a public client, one with a secret; bad redirect URIs "
            "(and a custom scheme), grant types and sizes refused; a page's "
            "/register and /token by its Origin, a text/plain one")

    # 3. /authorize's refusals
    cid = pub["client_id"]
    v, ch = pkce()
    s, b, h = req("GET", auth_url("0" * 32, ch, "s0"))
    assert s == 400 and "Location" not in h and "not registered here" in b, (s, b)
    s, b, h = req("GET", auth_url(cid, ch, "s0",
            redirect_uri="http://127.0.0.1:1/other"))
    assert s == 400 and "Location" not in h, (s, b)
    # Before the user acts, never a redirect (anyone's phishing link): the
    # page says why, with a link back to the tool
    for over, error in (({"code_challenge_method": "plain"}, "invalid_request"),
            ({"code_challenge_method": None, "code_challenge": None},
                "invalid_request"),
            ({"resource": "http://127.0.0.1:1/api/v1/mcp"}, "invalid_target"),
            ({"response_type": "token"}, "unsupported_response_type")):
        s, b, h = req("GET", auth_url(cid, ch, "s0", **over))
        assert s == 400 and "Location" not in h and \
                "not one this server takes" in b, (over, s, b, dict(h))
        link = re.search(r'<a href="([^"]+)">Back to 127\.0\.0\.1</a>', b)
        assert link and back(html.unescape(link.group(1)), "s0")["error"] == \
                error, (over, b)
    ok("/authorize: an unknown client and an unregistered redirect stay on "
            "the page; no S256, another resource or response type too, with "
            "a link back, no redirect")

    # 4. boss's password on the page, in Chrome; boss, an admin, then has
    # the Host's box: ticked, its text read, unticked again; builder, the
    # tool's admin scope not read
    v, ch = pkce()
    st = secrets.token_hex(16)
    q = browser("password", auth_url(cid, ch, st, scope="admin"),
            T + "/authorize.png", st, "boss", "checkpass12", "untick")
    code = {"grant_type": "authorization_code", "code": q["code"],
            "redirect_uri": REDIR, "code_verifier": v, "client_id": cid,
            "resource": MCP}
    refused(dict(code, code_verifier=pkce()[0]), "invalid_grant")
    refused(dict(code, redirect_uri=REDIR + "x"), "invalid_grant")
    refused(dict(code, resource="http://127.0.0.1:1/api/v1/mcp"),
            "invalid_target")
    refused(dict(code, client_id=conf["client_id"]), "invalid_client", 401)
    refused(dict(code, grant_type="password"), "unsupported_grant_type")
    s, j = token(code)
    assert s == 200 and j["scope"] == "builder", j
    n = mcp_works(j["access_token"])
    projects(j["access_token"], False)
    refused(code, "invalid_grant")
    mcp_refused(j["access_token"])
    ok("boss's password in Chrome, the Host's box unticked (the tool asked "
            "for admin): builder, list_projects refused; the code; a wrong "
            "verifier, redirect_uri, resource, client refused; MCP by the "
            "token (%d tools); the code again revoking what it gave" % n)

    # 5. The page's forms as a browser posts them
    v, ch = pkce()
    s, b, h = req("GET", auth_url(cid, ch, "s2"))
    assert s == 200 and "Connect Check &lt;tool&gt;?" in b and \
            "<tool>" not in b and 'name="host"' not in b, b
    csp = h["Content-Security-Policy"]
    assert "frame-ancestors 'none'" in csp and h["X-Frame-Options"] == "DENY", \
            dict(h)
    assert "form-action 'self' http://127.0.0.1:%d;" % srv.server_port in csp, csp
    assert "connect-src http://127.0.0.1:" in csp, csp
    assert h["Cache-Control"] == "no-store", dict(h)
    rid = rid_of(b)
    login = {"rid": rid, "name": "boss", "password": "checkpass12",
            "action": "allow"}
    s, b, h = post_form(login, "https://evil.example")
    assert s == 400 and "Location" not in h, (s, b)
    s, b, h = post_form(login)
    # The admin's step, the box ticked: the tool asked for builder
    assert s == 200 and 'name="host"' in b and "Signed in as <b>boss</b>" in b, \
            (s, b)
    s, b, h = post_form({"rid": rid, "action": "allow", "host": "1"})
    assert s == 303, (s, b)
    q = back(h["Location"], "s2")
    s, j = token({"grant_type": "authorization_code", "code": q["code"],
            "redirect_uri": REDIR, "code_verifier": v, "client_id": cid})
    assert s == 200 and j["scope"] == "admin", j
    a1, r1 = j["access_token"], j["refresh_token"]
    mcp_works(a1)
    text = projects(a1, True)
    assert '"world"' in text, text
    s, j = token({"grant_type": "refresh_token", "refresh_token": r1,
            "client_id": cid, "resource": MCP})
    assert s == 200 and j["scope"] == "admin", j
    a2, r2 = j["access_token"], j["refresh_token"]
    assert a2 != a1 and r2 != r1
    mcp_refused(a1)
    mcp_works(a2)
    refused({"grant_type": "refresh_token", "refresh_token": r2,
            "client_id": cid, "resource": "http://127.0.0.1:1/api/v1/mcp"},
            "invalid_target")
    refused({"grant_type": "refresh_token", "refresh_token": r1,
            "client_id": cid}, "invalid_grant")
    mcp_refused(a2)
    refused({"grant_type": "refresh_token", "refresh_token": r2,
            "client_id": cid}, "invalid_grant")
    s, b, h = req("GET", auth_url(cid, ch, "s3"))
    rid = rid_of(b)
    s, b, h = post_form({"rid": rid, "action": "deny"})
    assert s == 303 and back(h["Location"], "s3")["error"] == "access_denied", \
            (s, b, dict(h))
    s, b, h = post_form(dict(login, rid=rid))
    assert s == 400 and "has ended" in b, (s, b)
    ok("the page's forms: another origin's refused; the admin's step, the "
            "box ticked: an Admin grant, list_projects listed; its refresh "
            "token rotated, the one before again ending it; Deny")

    # A thief of R1 rotates twice: the tool's R1, two behind, ends the grant
    def sign_in(st, hdr={}, origin=B):
        v, ch = pkce()
        s, b, h = req("GET", auth_url(cid, ch, st), headers=hdr)
        assert s == 200, (s, b)
        # (the box's value on the password's form is not the step's)
        rid = rid_of(b)
        s, b, h = req("POST", B + "/api/v1/oauth/authorize", {"rid": rid,
                "name": "boss", "password": "checkpass12", "action": "allow",
                "host": "1"}, dict(hdr, Origin=origin))
        assert s == 200 and 'name="host"' in b, (s, b)
        s, b, h = req("POST", B + "/api/v1/oauth/authorize", {"rid": rid,
                "action": "allow"}, dict(hdr, Origin=origin))
        assert s == 303, (s, b)
        return v, h["Location"]
    v, loc = sign_in("s5")
    s, j = token({"grant_type": "authorization_code", "code": back(loc, "s5")["code"],
            "redirect_uri": REDIR, "code_verifier": v, "client_id": cid})
    assert s == 200 and j["scope"] == "builder", j
    r1 = j["refresh_token"]
    for i in range(2):
        s, j = token({"grant_type": "refresh_token", "refresh_token":
                j["refresh_token"], "client_id": cid})
        assert s == 200, j
    a3, r3 = j["access_token"], j["refresh_token"]
    mcp_works(a3)
    refused({"grant_type": "refresh_token", "refresh_token": r1,
            "client_id": cid}, "invalid_grant")
    mcp_refused(a3)
    refused({"grant_type": "refresh_token", "refresh_token": r3,
            "client_id": cid}, "invalid_grant")
    ok("a refresh token two rotations old ends the grant")

    # carl, no admin, never has the box: back at once, and the box's value
    # posted (the tool asking for admin too) gives builder
    v, ch = pkce()
    s, b, h = req("GET", auth_url(cid, ch, "s8", scope="admin"))
    assert s == 200 and 'name="host"' not in b, (s, b)
    s, b, h = post_form({"rid": rid_of(b), "name": "carl", "password":
            "carlpass123", "action": "allow", "host": "1"})
    assert s == 303, (s, b)
    s, j = token({"grant_type": "authorization_code", "code":
            back(h["Location"], "s8")["code"], "redirect_uri": REDIR,
            "code_verifier": v, "client_id": cid})
    assert s == 200 and j["scope"] == "builder", j
    mcp_works(j["access_token"])
    projects(j["access_token"], False)
    ok("carl (no admin): no box, back at once; host=1 posted gives builder, "
            "list_projects refused")

    # DNS rebinding: a page of evil.example rebound to 127.0.0.1, its own
    # origin to the browser, posting with an X-Forwarded-For of its choice
    # each time (loopback is a trusted proxy): its Host is no name of this
    # server's, refused before any password is looked at
    s, b, h = req("GET", auth_url(cid, pkce()[1], "s6"))
    rid = rid_of(b)
    evil = "evil.example:" + B.rsplit(":", 1)[1]
    for i, pw in enumerate(("wrong-1", "wrong-2", "checkpass12")):
        s, b, h = req("POST", B + "/api/v1/oauth/authorize", {"rid": rid,
                "name": "boss", "password": pw, "action": "allow"},
                {"Host": evil, "Origin": "http://" + evil, "X-Forwarded-For":
                "198.18.%d.1" % i, "X-Forwarded-Proto": "http"})
        assert s == 403 and "Location" not in h and \
                "not set up for the name evil.example" in b and \
                "Wrong name" not in b, (s, b)
    s, b, h = req("GET", auth_url(cid, pkce()[1], "s6"), headers={"Host": evil})
    assert s == 403 and "not set up for the name" in b, (s, b)
    s, b, h = req("POST", B + "/api/v1/oauth/register", meta,
            {"Content-Type": "application/json", "Host": evil})
    assert s == 403, (s, b)
    ok("a rebound name's Host refused on the form, the page and /register")

    # One network's flood of pages refuses that network only: another's
    # sign-in goes on (both by a trusted proxy's X-Forwarded-For)
    flood = {"X-Forwarded-For": "203.0.113.7", "X-Forwarded-Proto": "http"}
    for i in range(31):
        s, b, h = req("GET", auth_url(cid, pkce()[1], "f%d" % i), headers=flood)
        assert s == (200 if i < 30 else 429), (i, s, b)
    assert "Too many sign-ins from your network" in b, b
    v, loc = sign_in("s7", {"X-Forwarded-For": "198.51.100.7",
            "X-Forwarded-Proto": "http"})
    assert "code" in back(loc, "s7"), loc
    ok("a network's 31st page in 10 minutes refused; another network signs in")

    # MCP: requests with no token (a tool's probe before it signs in) count
    # as no try of the network's; tokens that match nothing do
    s, j = token({"grant_type": "authorization_code", "code": back(loc, "s7")["code"],
            "redirect_uri": REDIR, "code_verifier": v, "client_id": cid})
    assert s == 200, j
    good = j["access_token"]
    def mcp_from(ip, tok):
        h = {"Accept": "application/json, text/event-stream", "X-Forwarded-For": ip}
        if tok:
            h["Authorization"] = "Bearer " + tok
        return jpost(MCP, {"jsonrpc": "2.0", "id": 1, "method": "ping"}, h)[0]
    for i in range(35):
        assert mcp_from("192.0.2.10", None) == 401, i
    assert mcp_from("192.0.2.10", good) == 200
    for i in range(30):
        assert mcp_from("192.0.2.77", "bao_" + "0" * 32 + "_" + "%064d" % i) == 401
    assert mcp_from("192.0.2.77", good) == 429
    ok("35 tokenless MCP probes leave a network's valid token working; 30 "
            "bad tokens do not")

    # 6. reader's Starport ID, in the Starport's own window
    v, ch = pkce()
    st = secrets.token_hex(16)
    q = browser("id", auth_url(conf["client_id"], ch, st), T + "/authorize_id.png",
            st, "reader", "secret1")
    basic = (conf["client_id"], conf["client_secret"])
    code = {"grant_type": "authorization_code", "code": q["code"],
            "redirect_uri": REDIR, "code_verifier": v, "resource": MCP}
    refused(code, "invalid_client", 401, (conf["client_id"], "0" * 64))
    s, j = token(code, basic)
    assert s == 200 and j["scope"] == "builder", j
    n = mcp_works(j["access_token"])
    # A call: reader's agent is here (its ban below sends it off)
    s, b, h = mcp(j["access_token"], "tools/call", {"name": "get_state",
            "arguments": {}}, 5)
    assert s == 200 and "result" in json.loads(b), (s, b)
    state.update(access=j["access_token"], refresh=j["refresh_token"],
            basic=basic)
    ok("reader's Starport ID in the Starport's window: the code, the client "
            "by HTTP Basic, MCP (%d tools)" % n)
elif phase == "ban":
    # 6b. reader banned (boss's admin script): its grant's MCP call and its
    # refresh refused, the grant kept for the unban
    s, b, h = mcp(state["access"], "tools/list", {}, 4)
    assert s == 403 and "banned" in json.loads(b)["error"]["message"], (s, b)
    s, j = token({"grant_type": "refresh_token", "refresh_token":
            state["refresh"]}, tuple(state["basic"]))
    assert s == 400 and j["error"] == "invalid_grant" and \
            "banned" in j["error_description"], j
    ok("a ban: the grant's MCP call and its refresh refused")
elif phase == "b":
    # 7. Revoked on My account
    mcp_refused(state["access"])
    refused({"grant_type": "refresh_token", "refresh_token": state["refresh"]},
            "invalid_grant", 400, tuple(state["basic"]))
    ok("revoked on My account: its access and refresh tokens refused")
    # 8. A wrong password, then the address waits as a join's does
    pub = register("Check late")
    v, ch = pkce()
    s, b, h = req("GET", auth_url(pub["client_id"], ch, "s4"))
    login = {"rid": rid_of(b), "name": "boss", "password": "wrong-password",
            "action": "allow"}
    s, b, h = post_form(login)
    assert s == 403 and "Wrong name or password" in b, (s, b)
    s, b, h = post_form(dict(login, password="checkpass12"))
    assert s == 429 and "Too many failed logins" in b, (s, b)
    ok("a wrong password refused, and the next try waits")
    # Registration's cap: 100 an hour from a network
    while state["registers"] < 100:
        register("Check filler")
    s, b, h = register_raw({"redirect_uris": [REDIR]})
    assert s == 429, (s, b)
    ok("registration's cap: the 101st in the hour refused")
else:
    # 9. Behind a TLS proxy by the name the server is set up with (its
    # Public address, starport.json's "address"): registration, the page,
    # the sign-in and the token; another name still refused
    W = "https://wb.example.org"
    px = {"Host": "wb.example.org", "X-Forwarded-For": "192.0.2.50",
            "X-Forwarded-Proto": "https"}
    s, b, h = req("POST", B + "/api/v1/oauth/register", json.dumps(
            {"redirect_uris": [REDIR], "client_name": "Check proxied",
            "token_endpoint_auth_method": "none"}).encode(),
            dict(px, **{"Content-Type": "application/json"}))
    assert s == 201, (s, b)
    pcid = json.loads(b)["client_id"]
    v, ch = pkce()
    s, b, h = req("GET", auth_url(pcid, ch, "s9", resource=W + "/api/v1/mcp"),
            headers=px)
    assert s == 200 and "<b>wb.example.org</b>" in b, (s, b)
    rid = rid_of(b)
    s, b, h = req("POST", B + "/api/v1/oauth/authorize", {"rid": rid,
            "name": "boss", "password": "checkpass12", "action": "allow"},
            dict(px, Origin=W))
    assert s == 200 and 'name="host"' in b, (s, b)
    s, b, h = req("POST", B + "/api/v1/oauth/authorize", {"rid": rid,
            "action": "allow"}, dict(px, Origin=W))
    assert s == 303, (s, b)
    q = {k: x[0] for k, x in urllib.parse.parse_qs(
            urllib.parse.urlparse(h["Location"]).query).items()}
    assert q.get("iss") == W and q.get("state") == "s9", q
    keep(q["code"])
    s, b, h = req("POST", B + "/api/v1/oauth/token", {"grant_type":
            "authorization_code", "code": q["code"], "redirect_uri": REDIR,
            "code_verifier": v, "client_id": pcid}, px)
    assert s == 200, (s, b)
    j = json.loads(b)
    keep(j["access_token"], j["refresh_token"])
    s, b, h = req("GET", auth_url(pcid, ch, "s9"),
            headers=dict(px, Host="evil.example"))
    assert s == 403 and "not set up for the name evil.example" in b, (s, b)
    ok("by the proxy as https://wb.example.org (its Public address): "
            "registered, signed in, the token; evil.example refused")
    log = open(T + "/wb.log", errors="replace").read()
    for x in state["secrets"]:
        assert x not in log, "in the log: " + x[:12]
    assert re.search(r"OAuth: boss allowed \"Check <tool>\" \(builder\) by "
            r"a password from 127\.0\.0\.1", log), "no allow logged"
    assert re.search(r"OAuth: reader allowed \"Check ID tool\" \(builder\) "
            r"by a Starport ID", log), "no ID allow logged"
    ok("no token, code, secret or password in the log (%d looked for)" %
            len(state["secrets"]))
json.dump(state, open(st_path, "w"))
PY
admin() # <log> <the admin script> [<the result waited for>]
{
	mkdir -p "$t/ub"
	# (not "admin script: done": a second instance of accounts.lua gets
	# the result in Workbench, and it counts nothing)
	printf 'wait_log_any 60000 %s\nquit\n' "${3:-admin result}" > "$t/$1.cmds"
	DISPLAY=$d WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11 BUILDAT_JOIN_NAME=boss \
		BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_ADMIN="$2" timeout 120 \
		bin/buildat -C "$t/client_cache" -D "$t/ub" -s 127.0.0.1:$WB \
		-w 800x600 -l 3 -o sound_mute=1 -c @"$t/$1.cmds" > "$t/$1.log" 2>&1
}
# carl: a builder with a password, no admin
admin add1 "add carl carlpass123
priv carl builder" "admin result: carl is a builder" || fail "boss's add ($t/add1.log)"
grep -aq "admin result: carl is a builder" "$t/add1.log" ||
	fail "boss's add: $(grep -a 'admin result\|refused' "$t/add1.log" | head -2)"
python3 "$t/oauth.py" a "http://127.0.0.1:$WB" "$t" || fail "the OAuth client ($t/wb.log)"

# 6b. A ban stops a grant: boss bans reader by an admin script, the grant's
# MCP call and refresh refused and its agent gone; then unbanned
admin ban1 "ban reader" || fail "boss's ban ($t/ban1.log)"
grep -aq "admin result: reader was banned" "$t/ban1.log" ||
	fail "boss's ban: $(grep -a 'admin result\|refused' "$t/ban1.log" | head -2)"
python3 "$t/oauth.py" ban "http://127.0.0.1:$WB" "$t" || fail "the OAuth client while banned ($t/wb.log)"
grep -aq "reader's agent left: its account is banned" "$t/wb.log" ||
	fail "the banned account's agent stayed ($t/wb.log)"
admin ban2 "unban reader" || fail "boss's unban ($t/ban2.log)"
grep -aq "admin result: reader was unbanned" "$t/ban2.log" || fail "boss's unban ($t/ban2.log)"
echo "ok: reader's ban refused its grant, its agent left; unbanned"

# 7. reader's client, signed in by the ID by itself: the grant on My
# account, revoked there
join j2 'wait_log_any 60000 Joined as reader\nwait_log_any 60000 player physics enabled\nframes 5\nkeypress Escape\nwait_log_any 10000 pause: the menu shown\nframes 3\nclick Button "My account*"\nframes 5\nclick Button "Connect an agent..."\nwait_log_any 10000 accounts: agents: 1 tokens, on\nframes 5\nscreenshot '"$t"'/tokens.png\nclick Button "Revoke Check ID tool"\nwait_log_any 10000 accounts: agents: revoked Check ID tool\nquit\n' ||
	fail "the revoke on My account ($t/j2.log)"
grep -aq "reader revoked the agent token [0-9a-f]* (\"Check ID tool\")" "$t/wb.log" ||
	fail "the revoke not logged ($t/wb.log)"
echo "ok: My account listed the grant, and revoked it"
python3 "$t/oauth.py" b "http://127.0.0.1:$WB" "$t" || fail "the OAuth client after the revoke ($t/wb.log)"

# 9. A hosted server's setting: its Public address names it behind the
# proxy (no Starport, which would try to verify wb.example.org)
python3 - "$t/wb/apps/workbench/starport.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
c.update(starports=[], address="https://wb.example.org")
json.dump(c, open(sys.argv[1], "w"))
PY
wait_for_log "$t/wb.log" "Announcing to 0 Starport" 30 ||
	fail "starport.json not read again ($t/wb.log)"
python3 "$t/oauth.py" c "http://127.0.0.1:$WB" "$t" || fail "the OAuth client by the Public address ($t/wb.log)"
echo "PASS: OAuth for Kit's MCP: discovery, registration, the page by a password and by a Starport ID, an admin's Host box choosing the scope (ticked admin, unticked and a non-admin builder), PKCE, codes once, refresh rotation and reuse, revocation, bans, a rebound name, the Public address and the limits"
