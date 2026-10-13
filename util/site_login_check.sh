#!/bin/bash
# tier: full
# cost: ~60 s (2026-10-10)
# covers: apps/starport/main/main.cpp apps/starport/main/id_page.h apps/starport/main/client_lua/init.lua
# [STARPORT_SITE_LOGIN]: a website signs in by a Starport ID. A Starport;
# its operator registers two sites by the app's requests (a bad origin
# refused). By the API: authorize_info of a site names it and its
# origin, a token for it is signed with its secret, carries the site and
# the name picked for it, the same sub twice and another for the other
# site; an unknown site refused. Then headless Firefox on the site's own
# page (a static file on its origin): its button opens /authorize?site=,
# the ID logs in and allows in that window, and the token comes back to
# the page by postMessage from the Starport's origin; checked with the
# secret.
#   util/site_login_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp site_login; t=$CHECK_TMP
trap check_cleanup EXIT
cd "$here"

start_server "$t/sp.log" "setup code" 60 auto \
	Build/bin/buildat_server -m apps/starport -D "$t/sp" -l 3 ||
	fail "the Starport did not start"
CHECK_PIDS+=($SERVER_PID)
SP=$SERVER_PORT
code=$(grep -ao "setup code [A-Z0-9]*" "$t/sp.log" | cut -d' ' -f3)
# The site: a page on an origin of its own
WP=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
mkdir -p "$t/site"
cat > "$t/site/index.html" <<H
<!doctype html><meta charset="utf-8"><title>A site</title>
<button id="in" style="position:fixed;inset:0;width:100%;height:100%">Sign in with a Starport ID</button>
<script>
document.getElementById("in").onclick = () => {
	window.open("http://127.0.0.1:$SP/authorize?site=" + location.hash.slice(1), "sp", "width=600,height=700");
	console.log("site: the window opened");
};
addEventListener("message", e => {
	if(e.origin != "http://127.0.0.1:$SP" || !e.data.buildat_starport_token) return;
	console.log("site token: " + e.data.buildat_starport_token + " " + e.data.name + " " + e.data.site);
});
</script>
H
(cd "$t/site" && exec python3 -m http.server -b 127.0.0.1 $WP) > "$t/site.log" 2>&1 &
CHECK_PIDS+=($!)
# Its port, polled
for _i in $(seq 50); do port_taken $WP && break; sleep 0.2; done
port_taken $WP || fail "the site's server ($t/site.log)"

printf 'wait_log_any 20000 sp: {"id":5,\nquit\n' > "$t/reqs.cmds"
BUILDAT_SP_CREATE=1 BUILDAT_SP_NAME=admin BUILDAT_SP_PASSWORD=checkpass BUILDAT_SP_CODE=$code \
BUILDAT_SP_REQS="{\"cmd\":\"set_settings\",\"settings\":{\"email_confirmation\":false}}
{\"cmd\":\"set_email\",\"email\":\"op@example.org\"}
{\"cmd\":\"site_create\",\"name\":\"Bad\",\"origin\":\"https://x.example/path\"}
{\"cmd\":\"site_create\",\"name\":\"Check site\",\"origin\":\"http://127.0.0.1:$WP\"}
{\"cmd\":\"site_create\",\"name\":\"Other site\",\"origin\":\"https://other.example\"}" \
	timeout 90 Build/bin/buildat -o launch_ui=launch_menu -D "$t/cl" -w 800x600 -l 3 \
	-s 127.0.0.1:$SP -c @"$t/reqs.cmds" > "$t/reqs.log" 2>&1 ||
	fail "the requests' client ($t/reqs.log)"
grep -a '"id":3,"ok":false' "$t/reqs.log" | grep -q "origin: https://host" ||
	fail "a bad origin: $(grep -a '"id":3,' "$t/reqs.log")"
grep -ao 'sp: {"id":[45],"ok":true.*' "$t/reqs.log" | sed 's/^sp: //' > "$t/sites.json"
[ "$(wc -l < "$t/sites.json")" = 2 ] || fail "the sites: $(grep -a 'sp: ' "$t/reqs.log")"
echo "ok: two sites registered, a bad origin refused"

python3 - "$SP" "$t/sites.json" "$WP" <<'PY' || fail "the ID API"
import json, sys, time, hmac, hashlib, base64, urllib.request
B = "http://127.0.0.1:%s/api/v1/id/" % sys.argv[1]
sites = [json.loads(l)["result"] for l in open(sys.argv[2])]
def call(w, **k):
    return json.loads(urllib.request.urlopen(B + w, json.dumps(k).encode()).read())
def check(token, site):
    p, mac = token.split(".")
    want = hmac.new(bytes.fromhex(site["secret"]), b"buildat-token-1\n" +
            p.encode(), hashlib.sha256).hexdigest()
    assert hmac.compare_digest(mac, want), "the hmac"
    v = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
    assert v["v"] == 1 and v["typ"] == "site" and v["aud"] == site["id"], v
    assert v["site"] == site["id"] and v["exp"] > time.time(), v
    return v
r = call("authorize_info", site=sites[0]["id"], web=True)
assert r["ok"] and r["result"]["name"] == "Check site" and \
    r["result"]["origin"] == "http://127.0.0.1:" + sys.argv[3], r
r = call("authorize_info", site="nosuchsite", web=True)
assert not r["ok"] and "no such site" in r["error"], r
r = call("register", name="siteid", password="secret1",
        birth_year=time.gmtime().tm_year - 40)
assert r["ok"], r
s = r["result"]["session"]
r = call("token", session=s, site=sites[0]["id"], web=True)
assert r["ok"] and r["result"].get("need_name"), r
r = call("token", session=s, site=sites[0]["id"], web=True, name="sitename")
assert r["ok"] and r["result"]["origin"] == sites[0]["origin"], r
a = check(r["result"]["token"], sites[0])
assert a["name"] == "sitename", a
b = check(call("token", session=s, site=sites[0]["id"], web=True)["result"]["token"], sites[0])
c = check(call("token", session=s, site=sites[1]["id"], web=True,
    name="other")["result"]["token"], sites[1])
assert a["sub"] == b["sub"] != c["sub"], (a, b, c)
open(sys.argv[2] + ".id", "w").write(sites[0]["id"] + " " + sites[0]["secret"] + " " + a["sub"])
print("ok: by the API, the site's token signed with its secret, its own sub and name")
PY

read -r sid secret sub < "$t/sites.json.id"
# nav waits for the page's load. The window's page says nothing in the
# console, so its two moments are awaited in it by an eval that polls
# (10 s at most): the site's words, and the allow form shown after the
# login. The 2 s after the window opened is a settle: it is about:blank
# until its page loads, and an eval there would be lost with it.
cat > "$t/steps.json" <<J
[["nav", "http://127.0.0.1:$WP/#$sid"],
 ["click", 300, 300],
 ["waitlog", "site: the window opened", 10],
 ["wait", 2000],
 ["window", 1],
 ["eval", "new Promise(r => { let n = 0; const f = () => { const t = document.getElementById('what'); t && t.textContent ? r(t.textContent) : ++n > 100 ? r('') : setTimeout(f, 100); }; f(); })"],
 ["shot", "$t/01_authorize.png"],
 ["eval", "document.getElementById('name').value = 'siteid', document.getElementById('password').value = 'secret1', document.getElementById('login').requestSubmit(), 'login'"],
 ["eval", "new Promise(r => { let n = 0; const f = () => !document.getElementById('allow').classList.contains('hide') ? r('allow shown') : ++n > 100 ? r('no allow form') : setTimeout(f, 100); f(); })"],
 ["shot", "$t/02_allow.png"],
 ["eval", "document.getElementById('allow').requestSubmit(), 'allow'"],
 ["window", 0],
 ["waitlog", "site token: ", 20]]
J
WEB_DRIVE_URL="http://127.0.0.1:$WP/" util/web_drive.sh firefox site "$t/steps.json" "$t/drive" \
	> "$t/drive.txt" 2>&1 || fail "the drive ($(tail -3 "$t/drive.txt"); $t/drive)"
grep -aq "Check site.* at http://127.0.0.1:$WP asks who you are" "$t/drive.txt" "$t/drive/page.log" ||
	fail "the window's words ($(grep -a "eval" "$t/drive.txt" | head -2))"
tok=$(grep -ao "site token: [^ ]* sitename $sid" "$t/drive/page.log" | head -1 | cut -d' ' -f3)
[ -n "$tok" ] || fail "no token on the site's page ($t/drive/page.log)"
python3 - "$tok" "$secret" "$sub" <<'PY' || fail "the page's token"
import sys, json, hmac, hashlib, base64
tok, secret, sub = sys.argv[1:4]
p, mac = tok.split(".")
assert mac == hmac.new(bytes.fromhex(secret), b"buildat-token-1\n" + p.encode(),
        hashlib.sha256).hexdigest()
assert json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))["sub"] == sub
PY
echo "ok: the site's page got the token from the Starport's window ($t/01_authorize.png)"
echo "PASS"
