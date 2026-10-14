#!/bin/bash
# tier: quick
# cost: ~40 s (2026-10-08)
# covers: apps/hearth/main/client_lua/init.lua builtin/accounts/**
# [HEARTH_RESUME_2]: a client with BUILDAT_HEARTH_RESUME=1 opens a topic's
# new-thread page, types a title and a two-line message and quits; started
# again, it is on that page with both fields back.
# simplified: native only; the kept state is client Lua, the same on the
# web, whose storage ([HEARTH_RESUME]) is the one difference left undriven.
# There is no new-thread page without a topic to keep.
# [SERVER_VERSION]: the first client's Server window shows the server's
# Buildat and the client's, the same build here.
#
#   apps/hearth/resume_check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
check_tmp hearth_resume; t=$CHECK_TMP
P=29884

cd "$here/Build"
start_server "$t/srv.log" "setup code" 120 $P \
	bin/buildat_server -m ../apps/hearth -D "$t/srv" -l 3 ||
	fail "Hearth did not start"
CHECK_PIDS+=($SERVER_PID)
code=$(grep -ao "setup code [A-Z0-9]*" "$t/srv.log" | cut -d' ' -f3)

client(){ # commands log [env...]
	local c=$1 log=$2
	shift 2
	printf "$c" > "$t/cmds"
	env BUILDAT_HEARTH_NAME=admin BUILDAT_HEARTH_PASSWORD=checkpass12 \
		BUILDAT_HEARTH_CREATE=1 BUILDAT_HEARTH_CODE=$code "$@" \
		timeout 60 bin/buildat -o launch_ui=launch_menu -D "$t/cl" -w 800x600 \
		-l 3 -o sound_mute=1 -s 127.0.0.1:$P -c @"$t/cmds" > "$log" 2>&1
}

client 'wait_log_any 30000 "id":1001,"ok":\nwait_log_any 10000 server window: This client\nquit\n' "$t/topic.log" \
	BUILDAT_HEARTH_REQS='{"cmd":"new_topic","name":"Help","about":"x"}' \
	BUILDAT_HEARTH_OPEN=server:account
grep -aq 'hr: {"id":1001,"ok":true' "$t/topic.log" || fail "the topic"
v=$(cat ../VERSION)
for w in Server "This client"; do
	grep -aq "server window: $w Buildat $v-[0-9a-f]" "$t/topic.log" ||
		fail "the Server window's $w version: $(grep -a 'server window' "$t/topic.log")"
done

# The page's title field has the focus; the message field clicked. The
# 300 ms are settles: what Escape left drawn, the title typed into, the
# field's focus after the click. The preview comes a second after the last
# change, which is after the kept state is written (a second at most)
client 'wait_log_any 30000 hearth: page \ndelay 300\nkeypress Escape\ndelay 300
click Button "Help"\nwait_log 5000 hearth: page Help
click Button "New thread..."\nwait_log 5000 hearth: page A new thread\ndelay 300
text My title\ndelay 300
mouse_pos 450 200\nmouse_click left\ndelay 300\ntext first line
keypress Return\ntext second line\nwait_log 10000 hearth: preview\nquit\n' \
	"$t/type.log" BUILDAT_HEARTH_RESUME=1
client 'wait_log_any 30000 hearth: fields\nquit\n' "$t/back.log" BUILDAT_HEARTH_RESUME=1

page=$(grep -ao "hearth: page .*" "$t/back.log" | tail -1)
[ "$page" = "hearth: page A new thread" ] ||
	fail "the page after a restart: $page (typed: $(grep -ao 'hearth: page .*' "$t/type.log" | tail -1))"
fields=$(grep -ao "hearth: fields .*" "$t/back.log" | tail -1)
want='hearth: fields {"body":"first line\nsecond line","title":"My title"}'
[ "$fields" = "$want" ] ||
	fail "the fields after a restart: $fields"
echo "PASS: the new-thread page and its title and message come back after a restart; the Server window has both versions"
