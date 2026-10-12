#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# cost: 13s (local, 2026-10-02)
# [STARPORT] end to end, on ports of its own in a directory of its own: a
# Starport, and a floorplanner server listed on it by starport.json.
#   1. The announce gets a listing; the challenge verifies it.
#   2. Unclaimed, it is not served; a scripted client (the admin, by the
#      setup code) claims it with the claim code, and then it is.
#   3. A report by a key gets a receipt; the moderator rejects it; the
#      reporter's key asks and gets the outcome.
#   4. The admin makes a fleet; a second server with the fleet's line in
#      its starport.json is served in it without anyone claiming it.
#   5. A Starport ID: an adult's year is not kept, a child needs consent,
#      and the ID's token logs in to the fleet's server, whose account is
#      linked to it.
#   6. The first server reports a ban of the ID; a blocklist it publishes
#      to, which the fleet subscribes to, keeps the ID out of the fleet's
#      server too, and the ban is in the queue as a report about the ID.
#   7. The server's own side (10g), by editing starport.json as its admin's
#      page does, watched: unlisted and IDs "approved only" leave the list
#      and keep the ID login, found by address; a new ID waits for
#      approval; a Starport removed from the file withdraws the listing at
#      once. (5 has the setup code make an ID the server's first admin.)
#   8. The Overview ([STARPORT_UI]): the admin sets a high notice, makes
#      "mod" a moderator (a Steward, accounts' level) and hides the first listing; mod's Overview has
#      the notice and the hide, unseen, and the next one has it seen.
#   9. The hide's second appeal waits for the first; mod's list cannot
#      make the admin's listing a publisher it did not offer.
#  10. With retention_days 0, a restart's daily pass clears the IDs'
#      login and session addresses ([STARPORT_ADDR_RETENTION]).
#  11. mod reverses the appeal; with a low threshold a new key's report
#      hides the listing at once, with a statement; mod upholds it as a
#      delist, and the reporter's key sees it upheld ([MODERATION_MODULE]).
#
#   KEEP_TMP=1 apps/starport/check.sh
set -u
. "$(dirname "$0")/../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "/tmp/buildat_starport.XXXXXX")
SP=29641
AN=29642
AN2=29643
# The box lets a server connect to the usual ports only ([PROCESS_SANDBOX]
# A); these are this check's own
export BUILDAT_CONNECT_PORTS="$SP,$AN,$AN2"
pids=()
cleanup() {
	for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
	[ -n "${KEEP_TMP:-}" ] && echo "kept $tmp" || rm -rf "$tmp"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; exit 1; }
api() { curl -s -m 10 "$@"; }

mkdir -p "$tmp/sp" "$tmp/an/apps/floorplanner" "$tmp/an2/apps/floorplanner" \
	"$tmp/cl"
cat > "$tmp/an/apps/floorplanner/starport.json" <<EOF
{"starports": ["http://127.0.0.1:$SP"], "name": "Check house",
 "kind": "app", "audience": "everyone", "access": "open",
 "descriptors": {"violence": "none", "chat": "moderated", "ugc": "none",
  "language": "no", "sexual": "no", "drugs": "no", "purchases": "no",
  "gambling": "no", "personal_data": "no"}}
EOF
cd "$here"
start_server "$tmp/sp.log" "setup code" 120 $SP \
	Build/bin/buildat_server -m apps/starport -D "$tmp/sp" -l 3 ||
	fail "the Starport did not start (sp.log)"
pids+=($SERVER_PID)
code=$(grep -o "setup code [A-Z0-9]*" "$tmp/sp.log" | cut -d' ' -f3)
[ -n "$code" ] || fail "the Starport did not start (sp.log)"
[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$SP/brand/overpass.ttf")" = 200 ] ||
	fail "the ID page's font ([HTML_BRAND])"

Build/bin/buildat_server -m apps/floorplanner -D "$tmp/an" -P $AN -l 3 \
	> "$tmp/an.log" 2>&1 &
pids+=($!)
claim="$tmp/an/apps/floorplanner/starport_claim.txt"
for _ in $(seq 120); do
	grep -q "verified ok" "$tmp/sp.log" && break
	sleep 1
done
grep -q "verified ok" "$tmp/sp.log" || fail "no verified listing (sp.log, an.log)"
read -r _ _ id _ _ ccode < <(grep -v "^#" "$claim")
echo "ok: listed as $id and verified"
# The challenge signs a Starport's nonce and nothing else: the same secret
# makes the claim code and ID tokens ([SECURITY_RUN_1])
[ "$(api -o /dev/null -w '%{http_code}' \
	"localhost:$AN/api/v1/starport/challenge?listing=$id&nonce=claim")" = 404 ] ||
	fail "the challenge answered for the nonce \"claim\""

api "localhost:$SP/api/v1/list" | grep -q "\"$id\"" &&
	fail "an unclaimed listing was served"
echo "ok: unclaimed, not served"
# A port out of int64's range is refused, not cast ([REWORK_FIXES])
api -d '{"unlisted":true,"access":"open","port":1e300}' "localhost:$SP/api/v1/announce" |
	grep -q '"port: 1 to 65535"' || fail "a port of 1e300 was not refused"

key=$(head -c32 /dev/urandom | od -An -tx1 | tr -d ' \n')
receipt=$(api -d "{\"listing\":\"$id\",\"reason\":\"spam\",\"key\":\"$key\"}" \
	"localhost:$SP/api/v1/report" | python3 -c \
	"import json,sys; print(json.load(sys.stdin)['receipt'])") ||
	fail "no receipt for a report"
echo "ok: report receipt $receipt"

# The admin's client: claim, then reject the report
printf 'delay 8000\nquit\n' > "$tmp/cmds.txt"
BUILDAT_SP_CREATE=1 BUILDAT_SP_NAME=admin BUILDAT_SP_PASSWORD=checkpass BUILDAT_SP_CODE=$code \
BUILDAT_SP_REQS="{\"cmd\":\"set_settings\",\"settings\":{\"email_confirmation\":false}}
{\"cmd\":\"set_email\",\"email\":\"op@example.org\"}
{\"cmd\":\"claim\",\"listing\":\"$id\",\"code\":\"$ccode\"}
{\"cmd\":\"decide\",\"group\":\"$id|spam\",\"decision\":\"dismiss\"}
{\"cmd\":\"fleet_create\",\"name\":\"Check fleet\"}" \
	timeout 90 Build/bin/buildat -o launch_ui=launch_menu -D "$tmp/cl" -w 800x600 -l 3 \
	-s 127.0.0.1:$SP -c @"$tmp/cmds.txt" > "$tmp/cl.log" 2>&1
n=$(grep -c 'sp: {"id":[0-9]*,"ok":true' "$tmp/cl.log")
[ "$n" -ge 5 ] || fail "$n of 5 commands went through (cl.log)"

api "localhost:$SP/api/v1/list" | grep -q "\"$id\"" ||
	fail "the claimed listing is not served"
echo "ok: claimed and served"

api -d "{\"key\":\"$key\",\"receipts\":[\"$receipt\"]}" \
	"localhost:$SP/api/v1/report_status" | grep -q '"state":"rejected"' ||
	fail "the reporter does not see the outcome"
echo "ok: the reporter sees the report rejected"

fleet=$(grep -o '"code":"[0-9a-f]*","description":"","id":"[0-9a-f]*"' \
	"$tmp/cl.log" | head -1 | sed 's/"code":"\([0-9a-f]*\)".*"id":"\([0-9a-f]*\)"/\2:\1/')
[ -n "$fleet" ] || fail "no fleet made (cl.log)"
sed "s/\"Check house\"/\"Check main\", \"fleet\": \"$fleet\", \"pool\": \"main\", \"login\": \"both\"/" \
	"$tmp/an/apps/floorplanner/starport.json" \
	> "$tmp/an2/apps/floorplanner/starport.json"
Build/bin/buildat_server -m apps/floorplanner -D "$tmp/an2" -P $AN2 -l 3 \
	> "$tmp/an2.log" 2>&1 &
pids+=($!)
for _ in $(seq 120); do
	[ "$(grep -c "verified ok" "$tmp/sp.log")" -ge 2 ] && break
	sleep 1
done
api "localhost:$SP/api/v1/list" | python3 -c "
import json, sys
s = [x for x in json.load(sys.stdin)['servers'] if x['name'] == 'Check main']
assert s and s[0]['fleet']['name'] == 'Check fleet' and s[0]['pool'] == 'main', s
" || fail "the fleet's server is not served in the fleet (sp.log, an2.log)"
echo "ok: a server joined the fleet by its config line"
# 10g: access from the Accounts settings, not the file's "open": invite
# only (a server the launcher did not start), with IDs or without
api "localhost:$SP/api/v1/list" | python3 -c "
import json, sys
a = {x['name']: x['access'] for x in json.load(sys.stdin)['servers']}
assert a.get('Check main') == 'starport' and a.get('Check house') == 'invite', a
" || fail "access is not derived from the Accounts settings"
echo "ok: access from the Accounts settings: starport, invite"

token=$(python3 - "$SP" <<'PY'
import json, sys, time, urllib.request
B = "http://127.0.0.1:%s/api/v1/" % sys.argv[1]
def call(w, **k):
    return json.loads(urllib.request.urlopen(B + w, json.dumps(k).encode()).read())
y = time.gmtime().tm_year
r = call("id/register", name="kid", password="secret1", birth_year=y - 10)
assert not r["ok"] and "consent" in r["error"], r
r = call("id/register", name="grown", password="secret1", birth_year=y - 40)
assert r["ok"] and r["result"]["me"]["adult"] and \
		"birth_year" not in r["result"]["me"], r
s = r["result"]["session"]
lid = [x["id"] for x in call("list")["servers"] if x["name"] == "Check main"][0]
r = call("id/token", session=s, listing=lid)
assert r["ok"] and r["result"]["need_name"], r
r = call("id/token", session=s, listing=lid, name="grownup")
assert r["ok"], r
print(r["result"]["token"])
PY
) || fail "the ID API"
echo "ok: IDs made, an adult's year not kept, a token got"
printf 'delay 8000\nquit\n' > "$tmp/cmds2.txt"
# The server has no admin yet: the setup code makes the ID it (10g)
setup=$(grep -ao "setup code [A-Z0-9]*" "$tmp/an2.log" | tail -1 | cut -d' ' -f3)
BUILDAT_FP_STARPORT=$token timeout 90 Build/bin/buildat -o launch_ui=launch_menu -D "$tmp/cl" \
	-w 800x600 -l 3 -s 127.0.0.1:$AN2 -c @"$tmp/cmds2.txt" \
	> "$tmp/cl2.log" 2>&1
grep -q "Login refused: This server has no admin yet" "$tmp/cl2.log" ||
	fail "an ID got in before the server had an admin (cl2.log)"
BUILDAT_FP_STARPORT=$token BUILDAT_FP_CODE=$setup timeout 90 \
	Build/bin/buildat -o launch_ui=launch_menu -D "$tmp/cl" -w 800x600 -l 3 -s 127.0.0.1:$AN2 \
	-c @"$tmp/cmds2.txt" > "$tmp/cl2.log" 2>&1
grep -q "Joined as grownup" "$tmp/cl2.log" &&
	grep -q "New account grownup for a Starport ID" "$tmp/an2.log" &&
	grep -q "grownup claimed the server with the setup code" "$tmp/an2.log" ||
	fail "the token did not log in as the first admin (cl2.log, an2.log)"
echo "ok: the ID's token logged in to the fleet's server, its first admin"
# [COMPAT_BREAK_07] 8g: a token of 0.6's format, and a site's, refused
read -r old site < <(python3 - "$token" "$tmp/an2/apps/floorplanner/starport_state.json" <<'PY'
import base64, hashlib, hmac, json, sys
sec = list(json.load(open(sys.argv[2])).values())[0]["secret"]
p = sys.argv[1].split(".")[0]
v = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
def sign(v, prefix):
    q = base64.urlsafe_b64encode(json.dumps(v).encode()).decode().rstrip("=")
    return q + "." + hmac.new(bytes.fromhex(sec), prefix + q.encode(),
            hashlib.sha256).hexdigest()
print(sign({k: v[k] for k in ("sub", "name", "listing", "exp")}, b""),
        sign(dict(v, typ="site"), b"buildat-token-1\n"))
PY
)
for x in "old:The token is not from a Starport this server is on" \
		"site:Not a token for a server"; do
	[ "${x%%:*}" = old ] && tok=$old || tok=$site
	BUILDAT_FP_STARPORT=$tok timeout 90 Build/bin/buildat -o launch_ui=launch_menu \
		-D "$tmp/cl" -w 800x600 -l 3 -s 127.0.0.1:$AN2 -c @"$tmp/cmds2.txt" \
		> "$tmp/cl2_${x%%:*}.log" 2>&1
	grep -q "Login refused: ${x#*:}" "$tmp/cl2_${x%%:*}.log" ||
		fail "the ${x%%:*} token was not refused (cl2_${x%%:*}.log)"
done
echo "ok: a token of the old format and a site's token refused by the server"

# 6: as the first server would announce a ban it reported
python3 - "$SP" "$tmp/an/apps/floorplanner" "$id" > "$tmp/ban.json" <<'PY' ||
import base64, json, sys, urllib.request
B = "http://127.0.0.1:%s/api/v1/" % sys.argv[1]
def call(w, **k):
    return json.loads(urllib.request.urlopen(B + w, json.dumps(k).encode()).read())
s = call("id/login", name="grown", password="secret1")["result"]["session"]
t = call("id/token", session=s, listing=sys.argv[3], name="grownup")["result"]["token"]
p = t.split(".")[0]
sub = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))["sub"]
conf = json.load(open(sys.argv[2] + "/starport.json"))
st = list(json.load(open(sys.argv[2] + "/starport_state.json")).values())[0]
del conf["starports"]
conf.update(app="floorplanner", version="x", port=29642, players=0,
		id=st["id"], secret=st["secret"],
		bans=[{"sub": sub, "reason": "harassment"}],
		kind="museum", colour="blue")
r = json.loads(urllib.request.urlopen(B + "announce",
		json.dumps(conf).encode()).read())
assert r["ok"], r
# [COMPAT_BREAK_07] 8d: a newer server's kind is "other", its unknown key
# passed on; a refusal has a code; the unversioned path asks for an upgrade
x = [x for x in call("list")["servers"] if x["id"] == st["id"]][0]
assert x["kind"] == "other" and x["colour"] == "blue", x
r = json.loads(urllib.request.urlopen(B + "announce",
		json.dumps(conf).encode()).read())
assert not r["ok"] and r["code"] == "too_often", r
r = json.loads(urllib.request.urlopen(B.replace("/v1/", "/") + "list").read())
assert not r["ok"] and r["code"] == "upgrade_required", r
print(json.dumps({"listing": st["id"]}))
PY
	fail "announcing a ban, a newer kind and key"
printf 'delay 8000\nquit\n' > "$tmp/cmds3.txt"
BUILDAT_SP_CREATE=1 BUILDAT_SP_NAME=admin BUILDAT_SP_PASSWORD=checkpass \
BUILDAT_SP_REQS='{"cmd":"blocklist_create","name":"Check list"}' \
	timeout 90 Build/bin/buildat -o launch_ui=launch_menu -D "$tmp/cl" -w 800x600 -l 3 \
	-s 127.0.0.1:$SP -c @"$tmp/cmds3.txt" > "$tmp/cl3.log" 2>&1
list=$(grep -o '"id":"[0-9a-f]*","name":"Check list"' "$tmp/cl3.log" |
	head -1 | cut -d'"' -f4)
[ -n "$list" ] || fail "no blocklist made (cl3.log)"
BUILDAT_SP_CREATE=1 BUILDAT_SP_NAME=admin BUILDAT_SP_PASSWORD=checkpass \
BUILDAT_SP_REQS="{\"cmd\":\"blocklist_publish\",\"list\":\"$list\",\"scope\":\"listing:$id\"}
{\"cmd\":\"blocklist_subscribe\",\"list\":\"$list\",\"scope\":\"fleet:${fleet%%:*}\"}
{\"cmd\":\"queue\"}" \
	timeout 90 Build/bin/buildat -o launch_ui=launch_menu -D "$tmp/cl" -w 800x600 -l 3 \
	-s 127.0.0.1:$SP -c @"$tmp/cmds3.txt" > "$tmp/cl3.log" 2>&1
grep -q '"id":"id:grown|harassment"' "$tmp/cl3.log" ||
	fail "the ban is not in the queue as a report about the ID (cl3.log)"
echo "ok: a reported ban is in the queue, about the ID; a newer kind listed as other, its unknown key passed on, codes too_often and upgrade_required"
# The fleet's server learns the list at its next announce: its start
kill "${pids[-1]}"
wait "${pids[-1]}" 2>/dev/null
start_server "$tmp/an2b.log" "Announcing to" 120 $AN2 \
	Build/bin/buildat_server -m apps/floorplanner -D "$tmp/an2" -l 3 ||
	fail "the fleet's server did not start again (an2b.log)"
pids+=($SERVER_PID)
sleep 3
BUILDAT_FP_STARPORT=$token timeout 90 Build/bin/buildat -o launch_ui=launch_menu -D "$tmp/cl" \
	-w 800x600 -l 3 -s 127.0.0.1:$AN2 -c @"$tmp/cmds2.txt" \
	> "$tmp/cl4.log" 2>&1
grep -q "Login refused: Banned by a blocklist" "$tmp/cl4.log" ||
	fail "the blocklist did not keep the ID out (cl4.log, an2b.log)"
echo "ok: the blocklist keeps the ID out of the fleet's server"

# 7
python3 - "$tmp/an2/apps/floorplanner/starport.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
c.update(unlisted=True, ids="approved")
c.pop("login", None)
json.dump(c, open(sys.argv[1], "w"))
PY
for _ in $(seq 30); do
	api "localhost:$SP/api/v1/list" | grep -q '"Check main"' || break
	sleep 1
done
api "localhost:$SP/api/v1/list" | grep -q '"Check main"' &&
	fail "an unlisted server is still in the list"
echo "ok: unlisted, out of the list, by the watched file alone"
tokens=$(python3 - "$SP" "$AN2" <<'PY'
import json, sys, urllib.request
B = "http://127.0.0.1:%s/api/v1/id/" % sys.argv[1]
def call(w, **k):
    return json.loads(urllib.request.urlopen(B + w, json.dumps(k).encode()).read())
out = []
for n in ("newbie",):
    s = call("register", name=n, password="secret1", adult=True)["result"]["session"]
    # By the address the client is on: the server is in no list now
    r = call("token", session=s, address="127.0.0.1:" + sys.argv[2], name=n)
    assert r["ok"], r
    out.append(r["result"]["token"])
print(" ".join(out))
PY
) || fail "an unlisted server's token, by address"
tnew=$tokens
BUILDAT_FP_STARPORT=$tnew timeout 90 Build/bin/buildat -o launch_ui=launch_menu -D "$tmp/cl" \
	-w 800x600 -l 3 -s 127.0.0.1:$AN2 -c @"$tmp/cmds2.txt" \
	> "$tmp/cl5.log" 2>&1
grep -q "Login refused: Your Starport ID waits" "$tmp/cl5.log" ||
	fail "a new ID did not wait for approval (cl5.log)"
echo "ok: approved only: a new ID waits"
python3 - "$tmp/an/apps/floorplanner/starport.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
c["starports"] = []
json.dump(c, open(sys.argv[1], "w"))
PY
for _ in $(seq 30); do
	api "localhost:$SP/api/v1/list" | grep -q '"Check house"' || break
	sleep 1
done
api "localhost:$SP/api/v1/list" | grep -q '"Check house"' &&
	fail "a removed Starport still lists the server"
grep -q "Withdrawn from" "$tmp/an.log" ||
	fail "no withdrawal in an.log"
echo "ok: a Starport removed from the file withdraws the listing at once"

# 8
sp_reqs(){ # account password requests log
	BUILDAT_SP_CREATE=1 BUILDAT_SP_NAME=$1 BUILDAT_SP_PASSWORD=$2 \
	BUILDAT_SP_REQS=$3 timeout 90 Build/bin/buildat -o launch_ui=launch_menu -D "$tmp/cl" \
		-w 800x600 -l 3 -s 127.0.0.1:$SP -c @"$tmp/cmds3.txt" > "$tmp/$4" 2>&1
}
BUILDAT_SP_ADMIN="add mod modpass1234" sp_reqs admin checkpass '{"cmd":"me"}' cl6a.log
sp_reqs admin checkpass "{\"cmd\":\"set_settings\",\"settings\":{\"notice\":{\"text\":\"Check notice\",\"priority\":\"high\"}}}
{\"cmd\":\"level\",\"name\":\"mod\",\"level\":30}
{\"cmd\":\"act\",\"listing\":\"$id\",\"action\":\"hide\",\"reason\":\"other\",\"text\":\"for the check\",\"days\":0}" cl6.log
[ "$(grep -c 'sp: {"id":[0-9]*,"ok":true' "$tmp/cl6.log")" -ge 3 ] ||
	fail "the notice, the moderator or the hide (cl6.log)"
sp_reqs mod modpass1234 '{"cmd":"me"}
{"cmd":"overview"}
{"cmd":"overview"}' cl7.log
python3 - "$tmp/cl7.log" <<'PY' || fail "mod's Overview (cl7.log)"
import json, re, sys
res = {}
for line in open(sys.argv[1], errors="replace"):
    m = re.search(r'sp: (\{.*\})\s*$', line)
    if m:
        r = json.loads(m.group(1))
        res[r["id"]] = r
me, first, second = res[1]["result"], res[2]["result"], res[3]["result"]
assert me["moderator"] and me["notice"] == {"text": "Check notice", "priority": "high"}, me
hide = [e for e in first["events"] if "admin hide" in e["text"]]
assert hide and hide[0]["ts"] > first["seen"], first
assert second["seen"] >= hide[0]["ts"], second
PY
echo "ok: the Overview: the notice, another's hide unseen, then seen"
# 9
sp_reqs admin checkpass '{"cmd":"me"}' cl8.log
st=$(grep -o '"id":"[0-9a-f]*","listing":"'"$id"'"' "$tmp/cl8.log" |
	head -1 | cut -d'"' -f4)
[ -n "$st" ] || fail "no statement of the hide (cl8.log)"
sp_reqs mod modpass1234 '{"cmd":"blocklist_create","name":"Mod list"}' cl9.log
list2=$(grep -o '"id":"[0-9a-f]*","name":"Mod list"' "$tmp/cl9.log" |
	head -1 | cut -d'"' -f4)
[ -n "$list2" ] || fail "no blocklist made (cl9.log)"
sp_reqs admin checkpass "{\"cmd\":\"appeal\",\"statement\":\"$st\",\"text\":\"one\"}
{\"cmd\":\"appeal\",\"statement\":\"$st\",\"text\":\"two\"}" cl10.log
sp_reqs mod modpass1234 "{\"cmd\":\"blocklist_accept\",\"list\":\"$list2\",\"scope\":\"listing:$id\"}" cl11.log
grep -Eq '"ok":true,"result":"[0-9a-f]{12}"' "$tmp/cl10.log" &&
	grep -q '"error":"this statement has an open appeal"' "$tmp/cl10.log" ||
	fail "an open appeal is not the only one (cl10.log)"
grep -q '"error":"no such offer"' "$tmp/cl11.log" ||
	fail "a list took a listing that was not offered (cl11.log)"
echo "ok: one open appeal a statement; a list takes only what is offered"
# 11: what the check of builtin/moderation adds ([MODERATION_MODULE])
ap=$(grep -Eo '"ok":true,"result":"[0-9a-f]{12}"' "$tmp/cl10.log" | cut -d'"' -f6)
sp_reqs mod modpass1234 "{\"cmd\":\"decide_appeal\",\"appeal\":\"$ap\",\"outcome\":\"reverse\",\"text\":\"fine\"}" cl13.log
sp_reqs admin checkpass '{"cmd":"set_settings","settings":{"thresholds":{"default":{"hide":0.005,"delist":8}}}}' cl14.log
key2=$(head -c32 /dev/urandom | od -An -tx1 | tr -d ' \n')
receipt2=$(api -d "{\"listing\":\"$id\",\"reason\":\"scam\",\"key\":\"$key2\"}" \
	"localhost:$SP/api/v1/report" | python3 -c \
	"import json,sys; print(json.load(sys.stdin)['receipt'])") ||
	fail "no receipt for the second report"
sp_reqs admin checkpass '{"cmd":"me"}' cl15.log
sp_reqs mod modpass1234 "{\"cmd\":\"decide\",\"group\":\"$id|scam\",\"decision\":\"uphold\",\"action\":\"delist\",\"text\":\"upheld\",\"days\":0}" cl16.log
sp_reqs admin checkpass '{"cmd":"me"}' cl17.log
python3 - "$tmp" "$id" <<'PY' || fail "the appeal, the automatic hide or the uphold (cl13 to cl17.log)"
import json, re, sys
def res(name):
    for line in open(sys.argv[1] + "/" + name, errors="replace"):
        m = re.search(r'sp: (\{.*\})\s*$', line)
        if m:
            return json.loads(m.group(1))
for n in ("cl13.log", "cl14.log", "cl16.log"):
    assert res(n)["ok"], (n, res(n))
def mine(name):
    me = res(name)["result"]
    l = [x for x in me["listings"] if x["id"] == sys.argv[2]][0]
    return l["status"], [(s["action"], s["by"]) for s in me["statements"]]
status, st = mine("cl15.log")
assert status == "hidden" and ("restored", "mod") in st and ("hidden", "") in st, (status, st)
status, st = mine("cl17.log")
assert status == "delisted" and ("delist", "mod") in st, (status, st)
PY
api -d "{\"key\":\"$key2\",\"receipts\":[\"$receipt2\"]}" \
	"localhost:$SP/api/v1/report_status" | grep -q '"state":"upheld"' ||
	fail "the second reporter does not see the report upheld"
echo "ok: an appeal reversed, a report past a threshold hides, the moderator's uphold delists"
# 10
addrs(){ sqlite3 "$tmp/sp/apps/starport/saves/starport/save.sqlite" "SELECT count(*) FROM
	store WHERE store IN ('ids', 'sessions') AND value LIKE '%\"address\":\"1%'"; }
[ "$(addrs)" -gt 0 ] || fail "no login addresses stored to clear"
sp_reqs admin checkpass '{"cmd":"set_settings","settings":{"retention_days":0}}' cl12.log
kill "${pids[0]}"
wait "${pids[0]}" 2>/dev/null
start_server "$tmp/sp2.log" "Daily:" 60 $SP \
	Build/bin/buildat_server -m apps/starport -D "$tmp/sp" -l 3 ||
	fail "the Starport did not start again (sp2.log)"
pids+=($SERVER_PID)
[ "$(addrs)" = 0 ] ||
	fail "$(addrs) login or session addresses kept past retention_days (sp2.log)"
echo "ok: the daily pass clears login and session addresses past the retention"
echo PASS
