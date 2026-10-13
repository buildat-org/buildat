#!/bin/bash
# tier: quick
# cost: ~60 s (2026-10-09)
# covers: apps/hearth/main/main.cpp
# [HEARTH_THANKS]: bob, a member, starts a thread. carol, a new account, is
# refused a thanks, and so is bob on his own message. The admin thanks it,
# takes it back and gives it again; dave and erin thank it too. bob has one
# notification for the three, erin's name and "2" others in it; once he has
# looked, frank's thanks is a new one. The message carries 4 and the
# admin's "thanked", and its page shows "+4".
#
#   apps/hearth/thanks_check.sh
set -u
. "$(dirname "$0")/../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
check_tmp hearth_thanks; t=$CHECK_TMP
P=29886

cd "$here/Build"
start_server "$t/srv.log" "setup code" 60 $P \
	bin/buildat_server -m ../apps/hearth -D "$t/srv" -l 3 ||
	fail "Hearth did not start"
CHECK_PIDS+=($SERVER_PID)
code=$(grep -ao "setup code [A-Z0-9]*" "$t/srv.log" | cut -d' ' -f3)

client(){ # name password requests [env...]
	local n=$1 pw=$2 reqs=$3 i=0 w
	shift 3
	# Each request's answer, and the admin script's end
	{ while IFS= read -r w; do
			[ -n "$w" ] && i=$((i + 1)) && echo "wait_log_any 20000 \"id\":$((1000 + i)),"
		done <<< "$reqs"
		case "$*" in *BUILDAT_HEARTH_ADMIN=*)
			echo "wait_log_any 20000 admin script: done";; esac
		echo quit
	} > "$t/cmds_$n"
	: > "$t/$n.log"
	env BUILDAT_HEARTH_NAME=$n BUILDAT_HEARTH_PASSWORD=$pw \
		BUILDAT_HEARTH_CREATE=1 BUILDAT_HEARTH_CODE=$code \
		BUILDAT_HEARTH_REQS="$reqs" "$@" \
		timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl_$n" \
		-w 800x600 -l 3 -o sound_mute=1 -s 127.0.0.1:$P \
		-c @"$t/cmds_$n" > "$t/$n.log" 2>&1 ||
		fail "the client $n ($t/$n.log): $(grep -a "Command sequence failed" "$t/$n.log" | tail -1)"
}
answer(){ # name id
	grep -ao "hr: {.*\"id\":$2,.*" "$t/$1.log" | head -1
}

client admin checkpass12 '{"cmd":"new_topic","name":"Main","about":"x"}
{"cmd":"trust","name":"bob","on":true}
{"cmd":"trust","name":"dave","on":true}
{"cmd":"trust","name":"erin","on":true}
{"cmd":"trust","name":"frank","on":true}' \
	"BUILDAT_HEARTH_ADMIN=add bob bobpass1234
add carol carolpass1234
add dave davepass1234
add erin erinpass1234
add frank frankpass1234"
answer admin 1005 | grep -q '"ok":true' || fail "the setup: $(answer admin 1005)"
client bob bobpass1234 '{"cmd":"new_thread","topic":1,"title":"Lamps","body":"use a lamp"}
{"cmd":"thank","message":1,"on":true}'
answer bob 1002 | grep -q '"error":"not your own message"' ||
	fail "bob thanked his own: $(answer bob 1002)"
client carol carolpass1234 '{"cmd":"thank","message":1,"on":true}'
answer carol 1001 | grep -q '"error":"thanks are a ' ||
	fail "a new account thanked: $(answer carol 1001)"
client admin checkpass12 '{"cmd":"thank","message":1,"on":true}
{"cmd":"thank","message":1,"on":false}
{"cmd":"thank","message":1,"on":true}'
for i in 1001 1002 1003; do
	answer admin $i | grep -q '"ok":true' || fail "the admin's thanks: $(answer admin $i)"
done
answer admin 1002 | grep -q '"result":0' || fail "taken back: $(answer admin 1002)"
client dave davepass1234 '{"cmd":"thank","message":1,"on":true}'
client erin erinpass1234 '{"cmd":"thank","message":1,"on":true}'
answer erin 1001 | grep -q '"result":3' || fail "three thanks: $(answer erin 1001)"
client bob bobpass1234 '{"cmd":"notifications"}'
n=$(answer bob 1001 | grep -o '"kind":"thanks"' | wc -l)
[ "$n" = 1 ] || fail "$n notifications for three thanks: $(answer bob 1001)"
answer bob 1001 | grep -q '"by":"erin"' && answer bob 1001 | grep -q '"note":"2"' ||
	fail "not gathered: $(answer bob 1001)"
client frank frankpass1234 '{"cmd":"thank","message":1,"on":true}'
client bob bobpass1234 '{"cmd":"notifications"}'
n=$(answer bob 1001 | grep -o '"kind":"thanks"' | wc -l)
[ "$n" = 2 ] || fail "$n notifications after a fourth thanks once seen: $(answer bob 1001)"
client admin checkpass12 '{"cmd":"thread","thread":1}'
answer admin 1001 | grep -q '"thanked":true,"thanks":4' ||
	fail "the message: $(answer admin 1001)"
curl -s "http://127.0.0.1:$P/t/1" | grep -q '<span style="float:right">+4</span>' ||
	fail "the page has no +4"
echo "PASS: thanks: refused below member and on one's own, taken back, gathered for the author, +4 on the page"
