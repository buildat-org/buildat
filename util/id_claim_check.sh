#!/bin/bash
# tier: full
# cost: ~3 min (2026-10-11)
# covers: builtin/accounts/accounts.cpp builtin/accounts/client_lua/accounts.lua
# [ID_CLAIM_ACCOUNT]: "That's my account" links a Starport ID to the account
# that has its name here, by one login with the account's password. Hearth
# listed on two Starports (a Starport is its host name: 127.0.0.1 and
# localhost), accounts erin and finn (finn with TOTP, the RFC
# 6238 test secret), IDs made by the Starports' API; scripted clients:
#   - erin's ID logs in: refused, the name taken;
#   - erin with a wrong password and the ID: refused, nothing linked;
#   - erin with the password and the ID: joined, linked; the ID alone then
#     joins as erin; the admin's password with erin's ID: refused, the ID
#     another account's;
#   - finn with the password and its ID, the code asked after and typed
#     on the code page: joined, linked;
#   - erin's ID of the other Starport: linked too, both listed, each joins
#     as erin;
#   - erin banned (to the Starports): each Starport has the report;
#   - finn's link in the single key of before is read as its Starport's.
# simplified: the dialogs' "That's my account" buttons are not pressed
# here; util/web_id_window_check.sh drives the web's window, and the
# native name prompt's is not driven (it needs the client logged in to a
# Starport). My account's link rows and their Unlink are not driven.
#   util/id_claim_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
check_tmp id_claim; t=$CHECK_TMP
trap check_cleanup EXIT
SP1=29681
SP2=29682
AN=29683
export BUILDAT_CONNECT_PORTS="$SP1,$SP2,$AN"
cd "$here"
for n in 1 2; do
	p=$(eval echo \$SP$n)
	start_server "$t/sp$n.log" "setup code" 120 $p \
		Build/bin/buildat_server -m apps/starport -D "$t/sp$n" -l 3 ||
		fail "Starport $n did not start"
	CHECK_PIDS+=($SERVER_PID)
done
mkdir -p "$t/h/apps/hearth"
cat > "$t/h/apps/hearth/starport.json" <<J
{"starports": ["http://127.0.0.1:$SP1", "http://localhost:$SP2"],
 "name": "Claim hearth", "login": "both",
 "kind": "app", "audience": "everyone", "access": "auto",
 "descriptors": {"violence": "none", "chat": "moderated", "ugc": "moderated",
  "language": "no", "sexual": "no", "drugs": "no", "purchases": "no",
  "gambling": "no", "personal_data": "no"}}
J
hearth(){ # log
	start_server "$1" "STATUS Listening" 120 $AN \
		Build/bin/buildat_server -m apps/hearth -D "$t/h" -l 3 ||
		fail "Hearth did not start ($1)"
	CHECK_PIDS+=($SERVER_PID)
}
hearth "$t/h1.log"
for _ in $(seq 180); do
	[ "$(cat "$t/sp1.log" "$t/sp2.log" | grep -c "verified ok")" -ge 2 ] && break
	sleep 1
done
[ "$(cat "$t/sp1.log" "$t/sp2.log" | grep -c "verified ok")" -ge 2 ] ||
	fail "not listed on both ($t/h1.log)"
# A client: name, then env; the sequence in $t/cmds unless one is given
seq_default='delay 6000
quit'
join(){ # log name, env...
	local n=$1; shift
	printf '%s\n' "${CMDS:-$seq_default}" > "$t/$n.cmds"
	env "$@" timeout 90 Build/bin/buildat -o launch_ui=launch_menu -D "$t/c_$n" \
		-w 800x600 -l 3 -s 127.0.0.1:$AN -c @"$t/$n.cmds" > "$t/$n.log" 2>&1
	grep -a "Command sequence failed" "$t/$n.log" && fail "$n: the drive ($t/$n.log)"
	true
}
has(){ # log name, text
	grep -aqF "$2" "$t/$1.log" || fail "$1: no \"$2\" ($t/$1.log)"
}
setup=$(grep -ao "setup code [A-Z0-9]*" "$t/h1.log" | tail -1 | cut -d' ' -f3)
join admin BUILDAT_HEARTH_NAME=admin BUILDAT_HEARTH_PASSWORD=adminpass1 \
	BUILDAT_HEARTH_CREATE=1 BUILDAT_HEARTH_CODE=$setup \
	BUILDAT_HEARTH_ADMIN="add erin erinpass123
add finn finnpass123"
has admin "Joined as admin"
has admin "The account finn was added"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
db=$(find "$t/h" -path '*_server*' -name save.sqlite | head -1)
[ -n "$db" ] || fail "no _server save.sqlite under $t/h"
python3 - "$db" <<'PY' || fail "the TOTP secret"
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("INSERT INTO store(store, key, value) VALUES('accounts', 'totp/finn', ?)",
        (b"12345678901234567890",))
c.commit()
PY
hearth "$t/h2.log"
# The IDs' tokens: erin's and finn's on the first Starport, erin's on the
# second
read -r tok_a tok_c tok_b < <(python3 - "$SP1" "$SP2" "$t/h/apps/hearth/starport_claim.txt" <<'PY'
import json, sys, time, urllib.request
by = {l.split()[0]: l.split()[2] for l in open(sys.argv[3]) if l.strip() and not l.startswith("#")}
ids = [by["http://127.0.0.1:" + sys.argv[1]], by["http://localhost:" + sys.argv[2]]]
def call(sp, w, **k):
    return json.loads(urllib.request.urlopen("http://127.0.0.1:%s/api/id/%s" %
            (sp, w), json.dumps(k).encode()).read())
out = []
for sp, listing, user, name in ((sys.argv[1], ids[0], "ida", "erin"),
        (sys.argv[1], ids[0], "idc", "finn"), (sys.argv[2], ids[1], "idb", "erin")):
    r = call(sp, "register", name=user, password="secret1",
            birth_year=time.gmtime().tm_year - 40)
    assert r["ok"], r
    r = call(sp, "token", session=r["result"]["session"], listing=listing, name=name)
    assert r["ok"], r
    out.append(r["result"]["token"])
print(" ".join(out))
PY
)
[ -n "${tok_b:-}" ] || fail "the IDs' tokens ($t/h/apps/hearth/starport_claim.txt)"
join id_a BUILDAT_HEARTH_STARPORT=$tok_a
has id_a "Login refused: The name erin is taken on this server"
join wrong BUILDAT_HEARTH_NAME=erin BUILDAT_HEARTH_PASSWORD=wrongpass1 \
	BUILDAT_HEARTH_STARPORT=$tok_a
has wrong "Login refused: Wrong password"
join claim BUILDAT_HEARTH_NAME=erin BUILDAT_HEARTH_PASSWORD=erinpass123 \
	BUILDAT_HEARTH_STARPORT=$tok_a
has claim "Joined as erin"
has claim "link result: The Starport ID is linked"
has claim "linked Starport IDs: 127.0.0.1"
join id_a2 BUILDAT_HEARTH_STARPORT=$tok_a
has id_a2 "Joined as erin"
join other BUILDAT_HEARTH_NAME=admin BUILDAT_HEARTH_PASSWORD=adminpass1 \
	BUILDAT_HEARTH_STARPORT=$tok_a
has other "Login refused: That Starport ID is another account's here"
echo "ok: refused by name, a wrong password links nothing, the password links, the ID then joins, another account's password refused"
# finn: the code asked after the password, typed on the code page
code=$(python3 - <<'PY'
import hmac, hashlib, struct, time
h = hmac.new(b"12345678901234567890", struct.pack(">Q", int(time.time()) // 30),
        hashlib.sha1).digest()
o = h[19] & 15
print("%06d" % ((struct.unpack(">I", h[o:o + 4])[0] & 0x7fffffff) % 1000000))
PY
)
CMDS="wait_log 30000 Login refused: TOTP: enter
delay 1000
text $code
keypress Return
delay 4000
quit" join totp BUILDAT_HEARTH_NAME=finn BUILDAT_HEARTH_PASSWORD=finnpass123 \
	BUILDAT_HEARTH_STARPORT=$tok_c
has totp "Joined as finn"
has totp "link result: The Starport ID is linked"
echo "ok: with TOTP, the code page's code links"
join claim_b BUILDAT_HEARTH_NAME=erin BUILDAT_HEARTH_PASSWORD=erinpass123 \
	BUILDAT_HEARTH_STARPORT=$tok_b
has claim_b "linked Starport IDs: 127.0.0.1 localhost"
join id_b BUILDAT_HEARTH_STARPORT=$tok_b
has id_b "Joined as erin"
join id_a3 BUILDAT_HEARTH_STARPORT=$tok_a
has id_a3 "Joined as erin"
echo "ok: a second Starport's ID linked beside the first, each joins"
join ban BUILDAT_HEARTH_NAME=admin BUILDAT_HEARTH_PASSWORD=adminpass1 \
	BUILDAT_HEARTH_ADMIN="ban erin on"
has ban "admin result: erin was banned"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
# finn's link as a store from before had it
python3 - "$db" "127.0.0.1" <<'PY' || fail "the old key"
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
k = "starport_of/finn/" + sys.argv[2]
n = c.execute("UPDATE store SET key = 'starport_of/finn' WHERE store = 'accounts' AND key = ?",
        (k,)).rowcount
assert n == 1, n
c.commit()
PY
# A start announces at once, with the bans
hearth "$t/h3.log"
join id_c BUILDAT_HEARTH_STARPORT=$tok_c
has id_c "Joined as finn"
has id_c "linked Starport IDs: 127.0.0.1"
echo "ok: a single link of before read as its Starport's"
for n in 1 2; do
	ok=
	for _ in $(seq 60); do
		for f in $(find "$t/sp$n" -name save.sqlite); do
			[ "$(python3 -c "import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute(\"SELECT count(*) FROM store WHERE store='ban_reported'\").fetchone()[0])" "$f" 2>/dev/null)" -ge 1 ] && ok=1
		done
		[ -n "$ok" ] && break
		sleep 1
	done
	[ -n "$ok" ] || fail "Starport $n has no ban report ($t/h3.log)"
done
echo "PASS: \"That's my account\" links a Starport ID by the account's password (and code), one link per Starport, each joins, a ban reported to both, an old link kept"
