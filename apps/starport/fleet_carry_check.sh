#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min (2026-10-14)
# [FLEET_SUB_CARRY]: a player's account on a server kept across the
# server's fleet moves, the IDs still unlinkable between fleets. A
# Starport, two floorplanner servers A and B listed on it with IDs on,
# claimed by its admin, and a fleet:
#   1. alice logs in to A and B, bob to B; A founds the fleet: alice's
#      sub on A is the same, and no prev_sub.
#   2. B joins the fleet: its tokens carry prev_sub; with no answer the
#      login is the question; alice keeps her account, bob says no and
#      is a new one. A's token for alice has no prev_sub.
#   3. B leaves: its own sub back, prev_sub the fleet's; alice keeps it.
#   4. B joins again, its third move in 30 days: nothing carried.
#   5. The subs are HMACs of the scopes the design says: A's own for the
#      fleet it founded, and "fleet:<id>" for a fleet that has no stored
#      scope (one from before this), as before.
#
#   KEEP_TMP=1 apps/starport/fleet_carry_check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "/tmp/buildat_fleetcarry.XXXXXX")
SP=29661
A=29662
B=29663
export BUILDAT_CONNECT_PORTS="$SP,$A,$B"
pids=()
cleanup() {
	for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
	[ -n "${KEEP_TMP:-}" ] && echo "kept $tmp" || rm -rf "$tmp"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; exit 1; }
cd "$here"

start_server "$tmp/sp.log" "setup code" 120 $SP \
	Build/bin/buildat_server -m apps/starport -D "$tmp/sp" -l 3 ||
	fail "the Starport did not start (sp.log)"
pids+=($SERVER_PID)
code=$(grep -o "setup code [A-Z0-9]*" "$tmp/sp.log" | cut -d' ' -f3)
for s in a b; do
	mkdir -p "$tmp/$s/apps/floorplanner"
	cat > "$tmp/$s/apps/floorplanner/starport.json" <<EOF
{"starports": ["http://127.0.0.1:$SP"], "name": "Carry $s", "ids": "anyone",
 "kind": "app", "audience": "everyone", "access": "open",
 "descriptors": {"violence": "none", "chat": "moderated", "ugc": "none",
  "language": "no", "sexual": "no", "drugs": "no", "purchases": "no",
  "gambling": "no", "personal_data": "no"}}
EOF
done
Build/bin/buildat_server -m apps/floorplanner -D "$tmp/a" -P $A -l 3 > "$tmp/a.log" 2>&1 &
pids+=($!)
Build/bin/buildat_server -m apps/floorplanner -D "$tmp/b" -P $B -l 3 > "$tmp/b.log" 2>&1 &
pids+=($!)
for _ in $(seq 300); do
	[ "$(grep -c "verified ok" "$tmp/sp.log")" -ge 2 ] && break
	sleep 0.2
done
[ "$(grep -c "verified ok" "$tmp/sp.log")" -ge 2 ] || fail "A and B not verified (sp.log)"
read -r _ _ ida _ _ ca < <(grep -v "^#" "$tmp/a/apps/floorplanner/starport_claim.txt")
read -r _ _ idb _ _ cb < <(grep -v "^#" "$tmp/b/apps/floorplanner/starport_claim.txt")
printf 'wait_log_any 30000 "id":5,"ok":\nquit\n' > "$tmp/cmds.txt"
BUILDAT_SP_CREATE=1 BUILDAT_SP_NAME=admin BUILDAT_SP_PASSWORD=checkpass BUILDAT_SP_CODE=$code \
BUILDAT_SP_REQS="{\"cmd\":\"set_settings\",\"settings\":{\"email_confirmation\":false}}
{\"cmd\":\"set_email\",\"email\":\"op@example.org\"}
{\"cmd\":\"claim\",\"listing\":\"$ida\",\"code\":\"$ca\"}
{\"cmd\":\"claim\",\"listing\":\"$idb\",\"code\":\"$cb\"}
{\"cmd\":\"fleet_create\",\"name\":\"Carry fleet\"}" \
	timeout 60 Build/bin/buildat -o launch_ui=launch_menu -D "$tmp/cl" -w 800x600 -l 3 \
	-s 127.0.0.1:$SP -c @"$tmp/cmds.txt" > "$tmp/cl.log" 2>&1
[ "$(grep -c 'sp: {"id":[0-9]*,"ok":true' "$tmp/cl.log")" -ge 5 ] ||
	fail "the admin's requests (cl.log)"
fleet=$(grep -o '"code":"[0-9a-f]*","description":"","id":"[0-9a-f]*"' \
	"$tmp/cl.log" | head -1 | sed 's/"code":"\([0-9a-f]*\)".*"id":"\([0-9a-f]*\)"/\2:\1/')
[ -n "$fleet" ] || fail "no fleet made (cl.log)"
echo "ok: A ($ida) and B ($idb) claimed, a fleet made"

# tok <ID> <listing> <name here>: "<sub> <prev_sub or -> <token>"
cat > "$tmp/tok.py" <<'PY'
import base64, json, sys, urllib.request
sp, idn, lid, name = sys.argv[1:]
B = "http://127.0.0.1:%s/api/v1/id/" % sp
def call(w, **k):
    return json.loads(urllib.request.urlopen(B + w, json.dumps(k).encode()).read())
r = call("login", name=idn, password="secret12")
if not r["ok"]:
    r = call("register", name=idn, password="secret12", adult=True)
s = r["result"]["session"]
r = call("token", session=s, listing=lid, name=name)
assert r["ok"], r
t = r["result"]["token"]
p = t.split(".")[0]
v = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
print(v["sub"], v.get("prev_sub", "-"), t)
PY
tok() { python3 "$tmp/tok.py" $SP "$@" || fail "a token for $*"; }
n=0
# join <port> <log> <token> <log line awaited> [env...]: one client, its
# log in $tmp/<log>
join() {
	local port=$1 log=$2 t=$3
	printf 'wait_log_any 30000 %s\nquit\n' "$4" > "$tmp/cmds_j.txt"
	shift 4
	n=$((n + 1))
	env BUILDAT_FP_STARPORT="$t" "$@" timeout 60 Build/bin/buildat \
		-o launch_ui=launch_menu -D "$tmp/cl$n" -w 800x600 -l 3 \
		-s 127.0.0.1:$port -c @"$tmp/cmds_j.txt" > "$tmp/$log" 2>&1
}
# moved <listing> <python condition on x, the list entry>
moved() {
	for _ in $(seq 60); do
		curl -s -m 5 "localhost:$SP/api/v1/list" | python3 -c "
import json, sys
x = [x for x in json.load(sys.stdin)['servers'] if x['id'] == '$1'][0]
sys.exit(0 if $2 else 1)" 2>/dev/null && return 0
		sleep 1
	done
	return 1
}
set_fleet() { # <a|b> <fleet line or "">
	python3 - "$tmp/$1/apps/floorplanner/starport.json" "$2" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
c["fleet"] = sys.argv[2]
json.dump(c, open(sys.argv[1], "w"))
PY
}
setup_a=$(grep -ao "setup code [A-Z0-9]*" "$tmp/a.log" | tail -1 | cut -d' ' -f3)
setup_b=$(grep -ao "setup code [A-Z0-9]*" "$tmp/b.log" | tail -1 | cut -d' ' -f3)

# 1
read -r sa1 _ t < <(tok alice "$ida" alice)
join $A j1.log "$t" "Joined as" BUILDAT_FP_CODE=$setup_a
grep -q "Joined as alice" "$tmp/j1.log" || fail "alice on A (j1.log, a.log)"
read -r sb1 _ t < <(tok alice "$idb" alice)
join $B j2.log "$t" "Joined as" BUILDAT_FP_CODE=$setup_b
grep -q "Joined as alice" "$tmp/j2.log" || fail "alice on B (j2.log, b.log)"
read -r bb1 _ t < <(tok bob "$idb" bob)
join $B j3.log "$t" "Joined as"
grep -q "Joined as bob" "$tmp/j3.log" || fail "bob on B (j3.log, b.log)"
set_fleet a "$fleet"
moved "$ida" "x.get('fleet', {}).get('name') == 'Carry fleet'" ||
	fail "A did not join the fleet (a.log, sp.log)"
read -r sa2 pa2 t < <(tok alice "$ida" alice)
[ "$sa2" = "$sa1" ] && [ "$pa2" = - ] ||
	fail "A founding the fleet changed alice's sub ($sa1 to $sa2, prev $pa2)"
[ "$sb1" != "$sa1" ] || fail "A and B, in no fleet, gave alice the same sub"
echo "ok: A founded the fleet: alice's sub there the same"

# 2
set_fleet b "$fleet"
moved "$idb" "x.get('fleet', {}).get('name') == 'Carry fleet'" ||
	fail "B did not join the fleet (b.log, sp.log)"
read -r sb2 pb2 t < <(tok alice "$idb" alice)
[ "$sb2" = "$sa1" ] && [ "$pb2" = "$sb1" ] ||
	fail "B in the fleet: alice's sub $sb2 (A's $sa1), prev $pb2 (B's was $sb1)"
join $B j4.log "$t" "Login refused"
grep -q "Login refused: MOVED:Carry b	the fleet Carry fleet	alice" "$tmp/j4.log" ||
	fail "no question with no answer (j4.log)"
join $B j5.log "$t" "Joined as" BUILDAT_FP_CARRY=1
grep -q "Joined as alice" "$tmp/j5.log" &&
	grep -aq "alice kept the account across its server's move" "$tmp/b.log" ||
	fail "alice did not keep her account on B (j5.log, b.log)"
read -r bb2 pbb2 t < <(tok bob "$idb" bob2)
[ "$pbb2" = "$bb1" ] || fail "bob's prev_sub $pbb2, not $bb1"
join $B j6.log "$t" "Joined as" BUILDAT_FP_CARRY=2
grep -q "Joined as bob2" "$tmp/j6.log" &&
	grep -aq "New account bob2 for a Starport ID" "$tmp/b.log" ||
	fail "bob's no was not a new account (j6.log, b.log)"
read -r _ pa3 _ < <(tok alice "$ida" alice)
[ "$pa3" = - ] || fail "A's token carries a prev_sub ($pa3)"
echo "ok: B joined: prev_sub carried, alice kept her account, bob's no a new one, A sees none"

# 3
set_fleet b ""
moved "$idb" "'fleet' not in x" || fail "B did not leave the fleet (b.log)"
read -r sb3 pb3 t < <(tok alice "$idb" alice)
[ "$sb3" = "$sb1" ] && [ "$pb3" = "$sa1" ] ||
	fail "B out: alice's sub $sb3 (was $sb1), prev $pb3 (the fleet's $sa1)"
join $B j7.log "$t" "Joined as" BUILDAT_FP_CARRY=1
grep -q "Joined as alice" "$tmp/j7.log" || fail "alice back on B (j7.log)"
echo "ok: B left: its own sub back, the fleet's carried"

# 4
set_fleet b "$fleet"
moved "$idb" "x.get('fleet', {}).get('name') == 'Carry fleet'" ||
	fail "B did not join again (b.log)"
read -r sb4 pb4 _ < <(tok alice "$idb" alice)
[ "$sb4" = "$sa1" ] && [ "$pb4" = - ] ||
	fail "the third move: sub $sb4, prev $pb4 (nothing carried expected)"
echo "ok: a third move in 30 days carries nothing"

# 5
db="$tmp/sp/apps/starport/saves/starport/save.sqlite"
python3 - "$db" "${fleet%%:*}" "$ida" "$sa1" <<'PY' || fail "the subs' scopes"
import hashlib, hmac, json, sqlite3, sys
db, fid, ida, sa = sys.argv[1:]
c = sqlite3.connect(db, timeout=10)
k = json.loads(c.execute("SELECT value FROM store WHERE store='settings' AND key='id_secret'").fetchone()[0])
sub = lambda s: hmac.new(bytes.fromhex(k), s.encode(), hashlib.sha256).hexdigest()[:24]
assert sub("alice|listing:" + ida) == sa, "A's founded fleet is not listing:A"
f = json.loads(c.execute("SELECT value FROM store WHERE store='fleets' AND key=?", (fid,)).fetchone()[0])
del f["scope"]
c.execute("UPDATE store SET value=? WHERE store='fleets' AND key=?", (json.dumps(f), fid))
c.commit()
PY
want=$(python3 - "$db" "${fleet%%:*}" <<'PY'
import hashlib, hmac, json, sqlite3, sys
c = sqlite3.connect(sys.argv[1], timeout=10)
k = json.loads(c.execute("SELECT value FROM store WHERE store='settings' AND key='id_secret'").fetchone()[0])
print(hmac.new(bytes.fromhex(k), ("alice|fleet:" + sys.argv[2]).encode(), hashlib.sha256).hexdigest()[:24])
PY
)
read -r sa5 _ _ < <(tok alice "$ida" alice)
[ "$sa5" = "$want" ] || fail "a fleet with no stored scope: sub $sa5, not fleet:<id>'s $want"
echo "ok: the founded fleet's scope is A's; a fleet from before has fleet:<id>"
echo PASS
# vim: set noet ts=4 sw=4:
