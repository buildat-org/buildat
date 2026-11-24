#!/bin/bash
# tier: quick
# cost: ~40 s (2026-11-24)
# covers: apps/hearth/main/main.cpp apps/hearth/main/commands.h
# [HEARTH_POST_API]: a topic only a moderator starts threads in. The admin
# makes "Claude", a moderator, and "mem", a member, each with an API token,
# by the commands, without logging in as either: the token is in the
# answer once and not in the list. curl posts a thread there with Claude's
# token and a reply; the page and the client's thread show both "via
# API". mem's token is refused the thread; a page's request (an Origin),
# a GET and a bad token are refused. New token makes the old one fail and
# the new one work; a revoked one is refused with 403. bob, not the admin,
# is refused Make.
#
#   apps/hearth/post_api_check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
check_tmp hearth_post_api; t=$CHECK_TMP

cd "$here/Build"
start_server "$t/srv.log" "setup code" 60 auto \
	bin/buildat_server -m ../apps/hearth -D "$t/srv" -l 3 ||
	fail "Hearth did not start"
CHECK_PIDS+=($SERVER_PID)
P=$SERVER_PORT
code=$(grep -ao "setup code [A-Z0-9]*" "$t/srv.log" | cut -d' ' -f3)

client(){ # name password requests [env...]
	local n=$1 pw=$2 reqs=$3 i=0 w
	shift 3
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
answer(){ grep -ao "hr: {.*\"id\":$2,.*" "$t/$1.log" | head -1; }
token(){ answer "$1" $2 | grep -o '"token":"hrt_[0-9a-f]*"' | cut -d'"' -f4; }
post(){ # json [curl args...]: the status, the answer in $t/out
	local j=$1
	shift
	curl -s -o "$t/out" -w '%{http_code}' "$@" -H 'Content-Type: application/json' \
		-d "$j" "http://127.0.0.1:$P/api/v1/post"
}

client admin checkpass12 '{"cmd":"new_topic","name":"Release notes"}
{"cmd":"topic_mod_threads","topic":1,"on":true}
{"cmd":"api_token","name":"Claude","level":30}
{"cmd":"api_token","name":"mem","level":10}
{"cmd":"api_tokens"}' "BUILDAT_HEARTH_ADMIN=add bob bobpass1234"
answer admin 1002 | grep -q '"ok":true' || fail "the topic: $(answer admin 1002)"
answer admin 1003 | grep -q '"created_account":true' || fail "Claude's token: $(answer admin 1003)"
T1=$(token admin 1003); TM=$(token admin 1004)
[ ${#T1} = 68 ] && [ ${#TM} = 68 ] || fail "the tokens: $T1 $TM"
L=$(answer admin 1005)
echo "$L" | grep -q '"level":30,"name":"Claude"' && echo "$L" | grep -q '"name":"mem"' ||
	fail "the list: $L"
echo "$L" | grep -q hrt_ && fail "the list shows a token: $L"
grep -raq "$T1" "$t/srv.log" "$t/srv" &&
	fail "the token is kept or logged as it is"

curl -s "http://127.0.0.1:$P/api/v1/topics" | grep -q '"id":1,"name":"Release notes","parent":0' ||
	fail "/api/v1/topics: $(curl -s "http://127.0.0.1:$P/api/v1/topics")"
s=$(post "{\"token\":\"$T1\",\"topic\":1,\"title\":\"0.7.110\",\"body\":\"The **notes**.\"}")
[ "$s" = 200 ] && grep -q '"ok":true' "$t/out" || fail "the thread: $s $(cat "$t/out")"
TH=$(grep -o '"id":[0-9]*' "$t/out" | cut -d: -f2)
grep -q "\"url\":\"http://127.0.0.1:$P/t/$TH\"" "$t/out" || fail "its url: $(cat "$t/out")"
s=$(post "{\"token\":\"$T1\",\"thread\":$TH,\"body\":\"A fix after.\"}")
[ "$s" = 200 ] && grep -q "/t/$TH#m" "$t/out" || fail "the reply: $s $(cat "$t/out")"
curl -s "http://127.0.0.1:$P/t/$TH" > "$t/page"
n=$(grep -o '>Claude</a></b> <span title="[^"]*">(via API)</span>' "$t/page" | wc -l)
[ "$n" = 2 ] && grep -q "<strong>notes</strong>" "$t/page" && grep -q "A fix after." "$t/page" ||
	fail "the page marks $n of 2: $(grep -o 'class="meta">.\{0,200\}' "$t/page")"
s=$(post "{\"token\":\"$TM\",\"topic\":1,\"title\":\"x\",\"body\":\"y\"}")
[ "$s" = 400 ] && grep -q '"error":"only a [A-Za-z]* starts a thread in Release notes' "$t/out" ||
	fail "the member's thread: $s $(cat "$t/out")"
s=$(post "{\"token\":\"$T1\",\"thread\":$TH,\"body\":\"z\"}" -H 'Origin: https://evil.example')
[ "$s" = 403 ] || fail "a page's request: $s $(cat "$t/out")"
s=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$P/api/v1/post")
[ "$s" = 405 ] || fail "a GET: $s"
s=$(post "{\"token\":\"hrt_00\",\"thread\":$TH,\"body\":\"z\"}")
[ "$s" = 403 ] && grep -q '"ok":false' "$t/out" || fail "a bad token: $s $(cat "$t/out")"

client admin checkpass12 "{\"cmd\":\"thread\",\"thread\":$TH}
{\"cmd\":\"api_token\",\"name\":\"Claude\"}"
n=$(answer admin 1001 | grep -o '"api":true' | wc -l)
[ "$n" = 2 ] || fail "the client's thread marks $n of 2: $(answer admin 1001 | head -c 400)"
T2=$(token admin 1002)
[ ${#T2} = 68 ] && [ "$T2" != "$T1" ] || fail "New token: $(answer admin 1002)"
s=$(post "{\"token\":\"$T1\",\"thread\":$TH,\"body\":\"old\"}")
[ "$s" = 403 ] || fail "the old token after New token: $s $(cat "$t/out")"
s=$(post "{\"token\":\"$T2\",\"thread\":$TH,\"body\":\"new\"}")
[ "$s" = 200 ] || fail "the new token: $s $(cat "$t/out")"

client admin checkpass12 '{"cmd":"api_token_revoke","name":"Claude"}
{"cmd":"api_tokens"}'
answer admin 1001 | grep -q '"ok":true' || fail "the revoke: $(answer admin 1001)"
answer admin 1002 | grep -q '"name":"Claude"' && fail "revoked, still listed: $(answer admin 1002)"
s=$(post "{\"token\":\"$T2\",\"thread\":$TH,\"body\":\"revoked\"}")
[ "$s" = 403 ] || fail "the revoked token: $s $(cat "$t/out")"

client bob bobpass1234 '{"cmd":"api_token","name":"bob2","level":10}
{"cmd":"api_tokens"}'
answer bob 1001 | grep -q '"error":"only the [A-Za-z]* makes API tokens"' &&
	answer bob 1002 | grep -q '"error":"only the [A-Za-z]* sees' ||
	fail "bob's Make: $(answer bob 1001)"
echo "PASS: API tokens made by the admin, shown once; a thread and a reply by token in a moderators' topic, marked via API; a member's, a page's, a GET's, a bad, an old and a revoked token refused; bob's Make refused"
