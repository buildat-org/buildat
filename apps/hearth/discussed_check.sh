#!/bin/bash
# tier: quick
# cost: ~100 s (2026-10-08)
# covers: apps/hearth/main/main.cpp
# [HEARTH_DISCUSSED_API]: GET /api/v1/discussed. Empty first ({}). Then bob, a
# member, writes two days ago and today; carol, a new account, twice today;
# eve, a helper, today, and that one hidden. Neither carol's nor eve's
# counts, so today has one and the week two: span "this week", a message of
# bob's, its excerpt plain (no markup, the link as its text), its URL
# opening its thread at it ([HEARTH_VISITOR_FLOW]), and the CORS header
# there. Then a message past the thread's first page: /m/ links the page
# it is on.
#
#   apps/hearth/discussed_check.sh
set -u
. "$(dirname "$0")/../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
check_tmp hearth_discussed; t=$CHECK_TMP
P=29887
API=http://127.0.0.1:$P/api/v1/discussed

cd "$here/Build"
start_server "$t/srv.log" "setup code" 120 $P \
	bin/buildat_server --sim-clock -m ../apps/hearth -D "$t/srv" -l 3 ||
	fail "Hearth did not start"
CHECK_PIDS+=($SERVER_PID)
code=$(grep -ao "setup code [A-Z0-9]*" "$t/srv.log" | cut -d' ' -f3)

client(){ # name password requests [env...]
	local n=$1 pw=$2 reqs=$3
	shift 3
	# Done at the answer to the last request (numbered from 1001), and to
	# the admin script's last when there is one
	{ case "$*" in *BUILDAT_HEARTH_ADMIN=*)
			echo "wait_log_any 30000 admin script: done" ;; esac
		printf 'wait_log_any 30000 "id":%d,"ok":\nquit\n' \
			$((1000 + $(grep -c . <<< "$reqs"))); } > "$t/cmds_$n"
	env BUILDAT_HEARTH_NAME=$n BUILDAT_HEARTH_PASSWORD=$pw \
		BUILDAT_HEARTH_CREATE=1 BUILDAT_HEARTH_CODE=$code \
		BUILDAT_HEARTH_REQS="$reqs" "$@" \
		timeout 60 bin/buildat -o launch_ui=launch_menu -D "$t/cl_$n" \
		-w 800x600 -l 3 -o sound_mute=1 -s 127.0.0.1:$P \
		-c @"$t/cmds_$n" >> "$t/$n.log" 2>&1
}
T=0
advance(){
	T=$((T + $1))
	echo $T > "$t/srv/sim_clock"
	for _i in $(seq 100); do
		grep -aq "sim clock: ${T}s ahead" "$t/srv.log" && return
		sleep 0.1
	done
	fail "the server did not take the clock to $T"
}

[ "$(curl -s "$API")" = "{}" ] || fail "not {} with nothing written"

client admin checkpass12 '{"cmd":"new_topic","name":"Main","about":"x"}
{"cmd":"trust","name":"bob","on":true}
{"cmd":"level","name":"eve","level":20}' \
	"BUILDAT_HEARTH_ADMIN=add bob bobpass1234
add carol carolpass1234
add eve evepass12345"
grep -aq 'hr: {"id":1003,"ok":true' "$t/admin.log" || fail "the setup"
MD='First **one** with [the site](https://example.com/x) and <b>raw</b> `code` here'
client bob bobpass1234 "{\"cmd\":\"new_thread\",\"topic\":1,\"title\":\"Week\",\"body\":\"$MD\"}"
advance $((2 * 86400))
client bob bobpass1234 "{\"cmd\":\"reply\",\"thread\":1,\"body\":\"$MD\"}"
client carol carolpass1234 '{"cmd":"new_thread","topic":1,"title":"C1","body":"carol one"}
{"cmd":"new_thread","topic":1,"title":"C2","body":"carol two"}'
client eve evepass12345 '{"cmd":"new_thread","topic":1,"title":"E","body":"eve hidden"}'
# Eve's message, 5, reported and hidden by the admin
client admin checkpass12 '{"cmd":"report","message":5,"reason":"x"}
{"cmd":"moderate","report":1,"action":"hide","statement":"x"}'
grep -aq 'hr: {"id":1002,"ok":true' "$t/admin.log" || fail "the hide"
for f in bob carol eve; do
	grep -aq '"ok":false' "$t/$f.log" &&
		fail "$f: $(grep -ao '"error":"[^"]*"' "$t/$f.log" | head -1)"
done
# The last pick was {} at T 0; ten minutes on, a new one
advance 600

curl -s -D "$t/headers" "$API" > "$t/api.json" || fail "the request"
cat "$t/api.json"; echo
grep -qi '^access-control-allow-origin: \*' "$t/headers" || fail "no CORS header"
python3 - "$t/api.json" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1]))
def fail(s):
    print("FAIL: " + s); sys.exit(1)
if d.get("span") != "this week":
    fail("span %r, not this week" % d.get("span"))
m = d["message"]
if m["author"] != "bob" or m["id"] not in (1, 2):
    fail("picked %s's %s" % (m["author"], m["id"]))
e = m["excerpt"]
want = "First one with the site and <b>raw</b> code here"
if e != want:
    fail("excerpt %r, not %r" % (e, want))
if not m["url"].endswith("/t/1#m%d" % m["id"]) or "/t/1" not in m["thread"]["url"] \
        or "/topic/1" not in m["topic"]["url"]:
    fail("the links")
PY
url=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["message"]["url"])' "$t/api.json")
curl -s "${url%#*}" | grep -q "id=\"${url#*#}\".*the site" ||
	fail "$url does not open the thread at the message"
[ "$(curl -s "$API")" = "$(cat "$t/api.json")" ] || fail "the pick changed within ten minutes"
# A message past the thread's first page (256 KiB): /m/'s way to its
# thread is the page it is on
big=$(head -c 19000 /dev/zero | tr '\0' x)
# Five at a time: an environment string is 128 KiB at most
reqs=
for _i in $(seq 5); do
	reqs+="{\"cmd\":\"reply\",\"thread\":1,\"body\":\"$big\"}"$'\n'
done
for _i in 1 2 3; do client admin checkpass12 "$reqs"; done
client admin checkpass12 '{"cmd":"reply","thread":1,"body":"the last"}'
last=21 # after the five above and the fifteen
in=$(curl -s "http://127.0.0.1:$P/m/$last" | grep -o 'In <a href="[^"]*"' | cut -d'"' -f2)
case "$in" in /t/1\?after=*"#m$last") ;; *) fail "/m/$last's thread link is $in" ;; esac
curl -s "http://127.0.0.1:$P${in%#*}" | grep -q "id=\"m$last\"" ||
	fail "$in is not the page with the message"
echo "PASS: /api/v1/discussed: this week's pick, a member's, plain, its links open at it, CORS"
