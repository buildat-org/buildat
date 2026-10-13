#!/bin/bash
# tier: full
# cost: ~5 min (2026-10-07)
# covers: src/server/main.cpp src/impl/linux/os.cpp builtin/starport_announce/** builtin/accounts/accounts.cpp apps/starport/main/main.cpp apps/hearth/main/main.cpp apps/aitta/main/main.cpp
# [SIM_CLOCK]: a Starport, a Hearth listed on it and an Aitta, run with
# --sim-clock and moved together through 183 days and then 5 years. What
# runs on the calendar, and a few scripted attacks:
#   0. day 0: Starport IDs (an adult, a teen of 14), five from one /24
#      and the sixth refused; five new listings from one address, the
#      sixth refused, the first claimed; ten wrong logins of alice from a
#      /24 do not keep her out, and 30 keep that /24 out of any login;
#      Hearth's patient spammer, sam, a new account: his link held, two
#      threads a day; he reads five threads and posts three replies; the
#      admin's file under a budget of 0; a kept login; open registration,
#      five untrusted accounts from one network and the sixth refused
#      until the admin trusts one ([TRUST_LADDER]); Aitta: a release, not
#      yet on the public page;
#   1. +1 hour: the /24 logs in again; the release is on the page;
#   2. +1 day to +5 days: the sixth listing; sam active a day at a time,
#      a new account (his link waiting) until five days are over, then a
#      member and his link spam goes in; carol reports it, the admin hides
#      it, and sam is a new account again;
#   3. +8 days: alice's login addresses are gone (retention_days 7); her
#      first session used;
#   4. +31 days: the session not used since day 0 ended, the one used on
#      day 8 not; the unclaimed listings, never announced again, are
#      gone, the claimed one is not; Hearth's, announced after each jump,
#      is not; the network's untrusted accounts no longer count;
#   5. +183 days: the file, unused, deleted; sam's hidden message no
#      longer counts against him; alice's session unused since day 31
#      ended; the kept login, used every 29 days, still logs in;
#   6. +5 years, the Starport first: the teen is an adult; the claimed
#      listing gone after its year; Hearth's listing gone and Hearth
#      listed again under a new id.
#   util/sim_clock_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
t=$(mktemp -d "/tmp/buildat_sim_clock.XXXXXX")
pids=()
cleanup(){
	for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
	[ -n "${KEEP_TMP:-}" ] && echo "kept $t" || rm -rf "$t"
}
trap cleanup EXIT
fail(){ echo "FAIL: $*"; KEEP_TMP=1; exit 1; }
cd "$here/Build"

start_server "$t/sp.log" "setup code" 60 auto \
	bin/buildat_server --sim-clock -m ../apps/starport -D "$t/sp" -l 3 ||
	fail "the Starport did not start"
pids+=($SERVER_PID)
SP=$SERVER_PORT
export BUILDAT_CONNECT_PORTS=$SP
mkdir -p "$t/hearth/apps/hearth"
cat > "$t/hearth/apps/hearth/starport.json" <<EOF
{"starports": ["http://127.0.0.1:$SP"], "name": "Sim hearth",
 "kind": "app", "audience": "everyone", "access": "open",
 "descriptors": {"violence": "none", "chat": "moderated", "ugc": "none",
  "language": "no", "sexual": "no", "drugs": "no", "purchases": "no",
  "gambling": "no", "personal_data": "no"}}
EOF
start_server "$t/hearth.log" "setup code" 60 auto \
	bin/buildat_server --sim-clock -m ../apps/hearth -D "$t/hearth" -l 3 ||
	fail "Hearth did not start"
pids+=($SERVER_PID)
HP=$SERVER_PORT
hcode=$(grep -ao "setup code [A-Z0-9]*" "$t/hearth.log" | cut -d' ' -f3)
start_server "$t/aitta.log" "setup code" 60 auto \
	bin/buildat_server --sim-clock -m ../apps/aitta -D "$t/aitta" -l 3 ||
	fail "Aitta did not start"
pids+=($SERVER_PID)
AP=$SERVER_PORT
acode=$(grep -ao "setup code [A-Z0-9]*" "$t/aitta.log" | cut -d' ' -f3)

# advance <seconds> [servers]: the calendar T seconds further, on each
# server named (all by default), each seen to take it
T=0
advance(){
	T=$((T + $1))
	local s _i
	for s in ${2:-sp hearth aitta}; do
		echo $T > "$t/$s/sim_clock"
		for _i in $(seq 100); do
			grep -aq "sim clock: ${T}s ahead" "$t/$s.log" && break
			sleep 0.1
		done
		grep -aq "sim clock: ${T}s ahead" "$t/$s.log" || fail "$s did not take the clock to $T"
	done
	# The modules' ticks after it: a settle, as each reads the clock on its
	# next tick
	sleep 1
}
H=3600 D=86400

# Starport: sp <address> <call> <json>
sp(){ curl -s -m 10 -H "X-Forwarded-For: $1" -d "$3" "http://127.0.0.1:$SP/api/v1/$2"; }
# listed <id>: whether the Starport has it (a report without a reason is
# refused, and first for a listing it does not have)
probe=0
listed(){
	probe=$((probe + 1))
	! sp 10.7.$((probe / 250)).$((probe % 250)) report "{\"listing\":\"$1\"}" | grep -q "no such listing"
}
field(){ grep -o "\"$1\":\"[^\"]*\"" | head -1 | cut -d'"' -f4; }
# Hearth: hc <name> <password> <log> <requests> [env...]. The client runs
# until the last request's answer (they are numbered from 1001) and the
# admin script's end; with neither, until the join's outcome, JOIN_WAIT
# ("Joined as" by default)
hc(){
	local n=$1 pw=$2 log=$3 reqs=$4 nreq e
	shift 4
	nreq=$(printf '%s\n' "$reqs" | grep -c .)
	{
		echo "wait_log_any 20000 ${JOIN_WAIT:-Joined as}"
		[ "$nreq" -gt 0 ] && echo "wait_log_any 20000 \"id\":$((1000 + nreq)),"
		for e in "$@"; do
			case $e in BUILDAT_HEARTH_ADMIN=*) echo "wait_log_any 20000 admin script: done";; esac
		done
		echo quit
	} > "$t/cmds_$n"
	env BUILDAT_HEARTH_NAME=$n BUILDAT_HEARTH_PASSWORD=$pw BUILDAT_HEARTH_CREATE=1 \
		BUILDAT_HEARTH_CODE=$hcode BUILDAT_HEARTH_REQS="$reqs" "$@" \
		timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl_$n" -w 800x600 -l 3 \
		-o sound_mute=1 -s 127.0.0.1:$HP -c @"$t/cmds_$n" > "$t/$log" 2>&1
}
ans(){ grep -ao "hr: {.*\"id\":$2,.*" "$t/$1" | head -1; }
level(){ ans "$1" "$2" | grep -o '"level":[0-9]*' | cut -d: -f2; }
# A kept login's client: kl <log>, joined by its token alone
kl(){
	printf '%s\n' 'wait_log_any 20000 "id":1001,' quit > "$t/cmds_kl"
	BUILDAT_HEARTH_REQS='{"cmd":"me"}' timeout 90 bin/buildat -o launch_ui=launch_menu \
		-D "$t/cl_keeper" -w 800x600 -l 3 -o sound_mute=1 -s 127.0.0.1:$HP \
		-c @"$t/cmds_kl" > "$t/$1" 2>&1
	grep -aq "Joined as keeper" "$t/$1"
}
# A new account by open registration, no code: reg <name>
reg(){ hc $1 regpass1234 h_reg_$1.log '' BUILDAT_HEARTH_CODE=; }

# 0. Day 0
wait_for_log "$t/hearth.log" "Listed on http://127.0.0.1:$SP as" 30
hid=$(grep -ao "Listed on http://127.0.0.1:$SP as [0-9a-f]*" "$t/hearth.log" | tail -1 | cut -d' ' -f5)
[ -n "$hid" ] || fail "Hearth was not listed (hearth.log)"
r=$(sp 10.0.0.1 id/register '{"name":"alice","password":"alicepass1","adult":true}')
sa1=$(echo "$r" | field session)
[ -n "$sa1" ] || fail "alice's ID: $r"
sa3=$(sp 10.0.0.1 id/login '{"name":"alice","password":"alicepass1"}' | field session)
[ -n "$sa3" ] || fail "alice's second session"
y=$(date -u +%Y)
r=$(sp 10.0.0.2 id/register "{\"name\":\"teen\",\"password\":\"teenpass1\",\"birth_year\":$((y - 15))}")
st=$(echo "$r" | field session)
echo "$r" | grep -q '"band":"13-17"' || fail "the teen's ID: $r"
for i in 3 4 5; do
	sp 10.0.0.$i id/register "{\"name\":\"u$i\",\"password\":\"upass1234\",\"adult\":true}" |
		grep -q '"ok":true' || fail "registration $i from 10.0.0.0/24"
done
sp 10.0.0.6 id/register '{"name":"u6","password":"upass1234","adult":true}' |
	grep -q "too many new IDs" || fail "a sixth ID from 10.0.0.0/24 in a day"
sp 10.1.0.1 id/register '{"name":"u7","password":"upass1234","adult":true}' |
	grep -q '"ok":true' || fail "an ID from another /24"
desc='"descriptors": {"violence": "none", "chat": "moderated", "ugc": "none", "language": "no", "sexual": "no", "drugs": "no", "purchases": "no", "gambling": "no", "personal_data": "no"}'
listing(){ echo "{\"name\":\"Spam $1\",\"kind\":\"app\",\"audience\":\"everyone\",\"access\":\"open\",$desc,\"port\":9,\"address\":\"127.0.0.1\"${2:+,$2}}"; }
lids=() lsecrets=()
for i in 1 2 3 4 5; do
	r=$(sp 10.9.0.1 announce "$(listing $i)")
	lids+=("$(echo "$r" | field id)") lsecrets+=("$(echo "$r" | field secret)")
	[ -n "${lids[-1]}" ] || fail "new listing $i: $r"
done
sp 10.9.0.1 announce "$(listing 6)" | grep -q "too many new listings" ||
	fail "a sixth new listing from one address in a day"
for i in $(seq 10); do
	sp 10.6.0.$i id/login '{"name":"alice","password":"guess'$i'"}' > /dev/null
done
sp 10.0.0.1 id/login '{"name":"alice","password":"alicepass1"}' | grep -q '"ok":true' ||
	fail "alice kept out by ten wrong logins from another network"
for i in $(seq 20); do
	sp 10.6.0.$((i + 10)) id/login '{"name":"u'$i'","password":"guess"}' > /dev/null
done
sp 10.6.0.99 id/login '{"name":"u3","password":"upass1234"}' | grep -q "too many wrong logins" ||
	fail "a /24 with 30 wrong logins in an hour not held back"
sp 10.0.0.1 id/login '{"name":"u3","password":"upass1234"}' | grep -q '"ok":true' ||
	fail "another /24 held back by 10.6.0.0/24's wrong logins"
# The first listing claimed by the Starport's admin
scode=$(grep -ao "setup code [A-Z0-9]*" "$t/sp.log" | cut -d' ' -f3)
ccode=$(python3 -c 'import hmac,hashlib,sys; print(hmac.new(bytes.fromhex(sys.argv[1]), b"buildat-claim-1\n", hashlib.sha256).hexdigest()[:16])' "${lsecrets[0]}")
printf '%s\n' 'wait_log_any 20000 sp: {"id":3,' quit > "$t/cmds_sp"
BUILDAT_SP_CREATE=1 BUILDAT_SP_NAME=admin BUILDAT_SP_PASSWORD=checkpass BUILDAT_SP_CODE=$scode \
BUILDAT_SP_REQS="{\"cmd\":\"set_settings\",\"settings\":{\"email_confirmation\":false}}
{\"cmd\":\"set_email\",\"email\":\"op@example.org\"}
{\"cmd\":\"claim\",\"listing\":\"${lids[0]}\",\"code\":\"$ccode\"}" \
	timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl_sp" -w 800x600 -l 3 \
	-o sound_mute=1 -s 127.0.0.1:$SP -c @"$t/cmds_sp" > "$t/sp_admin.log" 2>&1
[ "$(grep -ac 'sp: {"id":[0-9]*,"ok":true' "$t/sp_admin.log")" -ge 3 ] ||
	fail "the claim (sp_admin.log)"
echo "ok: day 0 on the Starport"

hc admin adminpass12 h_admin0.log '{"cmd":"new_topic","name":"Lounge","about":"Talk"}
{"cmd":"new_thread","topic":1,"title":"One","body":"first"}
{"cmd":"new_thread","topic":1,"title":"Two","body":"second"}
{"cmd":"new_thread","topic":1,"title":"Three","body":"third"}
{"cmd":"new_thread","topic":1,"title":"Four","body":"fourth"}
{"cmd":"new_thread","topic":1,"title":"Five","body":"fifth"}
{"cmd":"upload","name":"notes.txt","data":"68656c6c6f"}
{"cmd":"file_settings","budget":0}' "BUILDAT_HEARTH_ADMIN=add sam sampass1234
add keeper keeperpass12"
for i in 1001 1002 1003 1004 1005 1006 1007 1008; do
	ans h_admin0.log $i | grep -q '"ok":true' || fail "the admin's request $i: $(ans h_admin0.log $i)"
done
hc admin adminpass12 h_admin0b.log '' "BUILDAT_HEARTH_ADMIN=add carol carolpass1234"
hc sam sampass1234 h_sam0.log '{"cmd":"me"}
{"cmd":"new_thread","topic":1,"title":"Deals","body":"see https://spam.example"}
{"cmd":"thread","thread":1}
{"cmd":"thread","thread":2}
{"cmd":"thread","thread":3}
{"cmd":"thread","thread":4}
{"cmd":"thread","thread":5}
{"cmd":"reply","thread":1,"body":"nice"}
{"cmd":"reply","thread":2,"body":"agreed"}
{"cmd":"reply","thread":3,"body":"thanks"}
{"cmd":"new_thread","topic":1,"title":"Hi","body":"hello all"}
{"cmd":"new_thread","topic":1,"title":"Again","body":"hello again"}
{"cmd":"new_thread","topic":1,"title":"Third","body":"and again"}
{"cmd":"me"}'
[ "$(level h_sam0.log 1001)" = 0 ] || fail "sam is not a new account: $(ans h_sam0.log 1001)"
ans h_sam0.log 1002 | grep -q '"ok":true' || fail "sam's link on day 0: $(ans h_sam0.log 1002)"
curl -s "http://127.0.0.1:$HP/" | grep -q "Deals" && fail "sam's held thread on the portal"
# The held thread is one of his two today
ans h_sam0.log 1011 | grep -q '"ok":true' || fail "sam's second thread: $(ans h_sam0.log 1011)"
ans h_sam0.log 1012 | grep -q "2 new threads a day" || fail "sam's third thread: $(ans h_sam0.log 1012)"
[ "$(level h_sam0.log 1014)" = 0 ] || fail "sam stood on day 0: $(ans h_sam0.log 1014)"
hc keeper keeperpass12 h_keeper0.log '' BUILDAT_HEARTH_KEEP=1
grep -aq "is kept logged in" "$t/hearth.log" || fail "the kept login (h_keeper0.log)"
hc admin adminpass12 h_admin0c.log '' "BUILDAT_HEARTH_ADMIN=setting open_registration on"
for n in n1 n2 n3 n4 n5; do
	reg $n
	grep -aq "Joined as $n" "$t/h_reg_$n.log" || fail "$n by open registration: $(grep -a "Login refused" "$t/h_reg_$n.log")"
done
JOIN_WAIT="Login refused" reg n6
grep -aq "Login refused: This network has 5 new accounts waiting" "$t/h_reg_n6.log" ||
	fail "a sixth untrusted account from one network: $(grep -a "Login refused\|Joined as" "$t/h_reg_n6.log")"
hc admin adminpass12 h_admin0d.log '{"cmd":"trust","name":"n1","on":true}'
ans h_admin0d.log 1001 | grep -q '"ok":true' || fail "the admin trusting n1: $(ans h_admin0d.log 1001)"
reg n6
grep -aq "Joined as n6" "$t/h_reg_n6.log" || fail "n6 after n1 was trusted: $(grep -a "Login refused" "$t/h_reg_n6.log")"
echo "ok: day 0 on Hearth"

b="$here/Build/bin/buildat"
mkdir -p "$t/app/main"
echo 'int x;' > "$t/app/main/main.cpp"
printf '{"author": "tester", "name": "demo", "version": "1.0.0", "engine_api": 2,
	"license_code": "MIT", "license_media": "CC0-1.0", "description": "sim",
	"audience": "everyone"}\n' > "$t/app/meta.json"
"$b" aitta keygen "$t/key" > "$t/pub" 2>/dev/null || fail "keygen"
printf '%s\n' 'wait_log_any 20000 ai: {"id":1,' quit > "$t/cmds_ai"
BUILDAT_AITTA_CREATE=1 BUILDAT_AITTA_NAME=admin BUILDAT_AITTA_PASSWORD=checkpass \
BUILDAT_AITTA_CODE=$acode \
BUILDAT_AITTA_REQS="{\"cmd\":\"bind\",\"author\":\"tester\",\"key\":\"$(cat "$t/pub")\"}" \
	timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl_ai" -w 800x600 -l 3 \
	-o sound_mute=1 -s 127.0.0.1:$AP -c @"$t/cmds_ai" > "$t/ai.log" 2>&1
grep -aq 'ai: {"id":1,"ok":true' "$t/ai.log" || fail "the Aitta bind (ai.log)"
zip=$("$b" aitta pack "$t/app" "$t/key" "$t/rel" 2>/dev/null) || fail "pack"
"$b" aitta publish "$zip" 127.0.0.1:$AP 2>&1 | grep -q "listed: tester/demo/1.0.0" || fail "publish"
curl -s "http://127.0.0.1:$AP/" | grep -q "demo" && fail "the release on the public page at once"
echo "ok: day 0 on Aitta"

# 1. +1 hour
advance $((H + 60))
r=$(sp 10.6.0.99 id/login '{"name":"alice","password":"alicepass1"}')
sa2=$(echo "$r" | field session)
[ -n "$sa2" ] || fail "10.6.0.0/24's login an hour later: $r"
curl -s "http://127.0.0.1:$AP/" | grep -q "demo" || fail "the release not on the public page after page_delay"
echo "ok: +1 hour"

# 2. +1 day to +5 days
advance $D
sp 10.9.0.1 announce "$(listing 6)" | grep -q '"ok":true' || fail "a new listing the next day"
for day in 1 2 3 4; do
	[ $day = 1 ] || advance $D
	hc sam sampass1234 h_sam_d$day.log '{"cmd":"me"}
{"cmd":"thread","thread":1}
{"cmd":"thread","thread":2}
{"cmd":"reply","thread":1,"body":"cheap deals at https://spam.example"}'
	[ "$(level h_sam_d$day.log 1001)" = 0 ] ||
		fail "sam stood on day $day: $(ans h_sam_d$day.log 1001)"
	ans h_sam_d$day.log 1004 | grep -q "waiting for approval already" ||
		fail "sam's link on day $day: $(ans h_sam_d$day.log 1004)"
done
advance $D
hc sam sampass1234 h_sam5.log '{"cmd":"me"}
{"cmd":"reply","thread":1,"body":"cheap deals at https://spam.example"}'
[ "$(level h_sam5.log 1001)" = 10 ] || fail "sam did not stand after five active days: $(ans h_sam5.log 1001)"
spam=$(ans h_sam5.log 1002 | grep -o '"result":[0-9]*' | cut -d: -f2)
[ -n "$spam" ] || fail "sam's link after five days: $(ans h_sam5.log 1002)"
hc carol carolpass1234 h_carol1.log "{\"cmd\":\"report\",\"message\":$spam,\"reason\":\"spam\"}"
rep=$(ans h_carol1.log 1001 | grep -o '"result":[0-9]*' | cut -d: -f2)
[ -n "$rep" ] || fail "carol's report: $(ans h_carol1.log 1001)"
hc admin adminpass12 h_admin1.log "{\"cmd\":\"moderate\",\"report\":$rep,\"action\":\"hide\",\"statement\":\"Spam\"}"
ans h_admin1.log 1001 | grep -q '"ok":true' || fail "the hide: $(ans h_admin1.log 1001)"
hc sam sampass1234 h_sam1b.log '{"cmd":"me"}
{"cmd":"reply","thread":2,"body":"more at https://spam.example"}'
[ "$(level h_sam1b.log 1001)" = 0 ] || fail "sam still stands with a message hidden: $(ans h_sam1b.log 1001)"
ans h_sam1b.log 1002 | grep -q "waiting for approval already" || fail "sam's link after the hide: $(ans h_sam1b.log 1002)"
echo "ok: +1 to +5 days"

# 3. +8 days: the daily pass after the retention
advance $((3 * D))
r=$(sp 10.0.0.1 id/sessions "{\"session\":\"$sa1\"}")
echo "$r" | grep -q '"ok":true' || fail "alice's sessions: $r"
echo "$r" | grep -q "10.0.0.1" && fail "alice's addresses kept past retention_days: $r"
echo "ok: +8 days"

# 4. +31 days, in jumps the announcer keeps up with
advance $((23 * D))
sp 10.0.0.1 id/me "{\"session\":\"$sa3\"}" | grep -q '"ok":true' &&
	fail "a session unused for 31 days"
sp 10.0.0.1 id/me "{\"session\":\"$sa1\"}" | grep -q '"ok":true' ||
	fail "a session used on day 8 ended on day 31"
r=$(sp 10.9.0.1 announce "$(listing 2 "\"id\":\"${lids[1]}\",\"secret\":\"${lsecrets[1]}\"")")
echo "$r" | grep -q "no such listing" || fail "a listing unannounced for 31 days: $r"
listed "${lids[0]}" || fail "the claimed listing gone after 31 days"
listed "$hid" || fail "Hearth's listing gone at 31 days, though announced after each jump"
grep -aq "file [0-9]* deleted" "$t/hearth.log" && fail "the file deleted before lod2_after"
reg n7
grep -aq "Joined as n7" "$t/h_reg_n7.log" || fail "the network's untrusted accounts after 30 days: $(grep -a "Login refused" "$t/h_reg_n7.log")"
kl h_kl31.log || fail "the kept login on day 31 (h_kl31.log)"
echo "ok: +31 days"

# 5. To +183 days
for i in 1 2 3 4 5; do
	advance $((29 * D))
	kl h_kl_$i.log || fail "the kept login, used every 29 days, at day $((31 + 29 * i)) (h_kl_$i.log)"
done
advance $((7 * D))
wait_for_log "$t/hearth.log" "file [0-9]* deleted, unused|files no message names deleted" 10 || fail "the unused file not deleted after 183 days (hearth.log)"
listed "$hid" || fail "Hearth's listing gone by 183 days"
sp 10.0.0.1 id/me "{\"session\":\"$sa1\"}" | grep -q '"ok":true' &&
	fail "a session unused since day 31 on day 183"
hc sam sampass1234 h_sam183.log '{"cmd":"me"}'
[ "$(level h_sam183.log 1001)" = 10 ] || fail "sam after his hidden message's 30 days: $(ans h_sam183.log 1001)"
echo "ok: +183 days, Hearth listed all along as $hid"

# 6. +5 years, the Starport first: its daily pass drops Hearth's listing
advance $((5 * 365 * D)) sp
T=$((T - 5 * 365 * D))
advance $((5 * 365 * D)) "hearth aitta"
listed "$hid" && fail "Hearth's listing kept 5 years unheard"
listed "${lids[0]}" && fail "the claimed listing kept 5 years unheard"
r=$(sp 10.0.0.2 id/login '{"name":"teen","password":"teenpass1"}')
echo "$r" | grep -q '"adult":true' || fail "the teen not an adult after 5 years: $r"
# Hearth's second listing, polled
for _ in $(seq 300); do
	[ "$(grep -ac "Listed on http://127.0.0.1:$SP as" "$t/hearth.log")" -ge 2 ] && break
	sleep 0.2
done
[ "$(grep -ac "Listed on http://127.0.0.1:$SP as" "$t/hearth.log")" -ge 2 ] ||
	fail "Hearth not listed again after its listing went: $(grep -a 'Announce to' "$t/hearth.log" | tail -1)"
echo "ok: +5 years"
echo "PASS: a calendar moved by --sim-clock: limits per hour and day and per /24, wrong logins held back by network and not by name, retention, sessions kept by use, listings (a claimed one a year), a release's page delay, a new account's trust by active days, its link held, untrusted accounts per network, a kept login by use, a file's sweep, an age; Hearth listed through it and again after its listing went"
