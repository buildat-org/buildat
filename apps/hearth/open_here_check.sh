#!/bin/bash
# tier: quick
# ci
# cost: ~1 min (2026-10-09)
# covers: apps/hearth/main/** src/client/web/index.html
# [HEARTH_OPEN_HERE]: a local Hearth with a thread of two messages about
# tester/pt.
#   1. The web pages' "in the browser": /app#open=<the page's path> on a
#      topic's, a thread's, a message's, a package's and an account's page,
#      a plain /app on home.
#   2. A scripted client with BUILDAT_OPEN set as the web page sets it:
#      each kind opens its page ("hearth: page" lines); a bad shape stays
#      home, a missing thread says so on home. A screenshot of the message
#      opened.
#   3. The web page's shape test, read off index.html by node if there.
#
#   apps/hearth/open_here_check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp hearth_open_here; t=$CHECK_TMP

cd "$here/Build"
start_server "$t/srv.log" "setup code" 60 auto \
	bin/buildat_server -m ../apps/hearth -D "$t/srv" -l 3 ||
	fail "Hearth did not start"
CHECK_PIDS+=($SERVER_PID)
P=$SERVER_PORT
code=$(grep -ao "setup code [A-Z0-9]*" "$t/srv.log" | cut -d' ' -f3)

client(){ # log requests commands [env...]
	local log=$1 reqs=$2
	printf "$3" > "$t/cmds"
	shift 3
	env BUILDAT_HEARTH_NAME=admin BUILDAT_HEARTH_PASSWORD=checkpass12 \
		BUILDAT_HEARTH_CREATE=1 BUILDAT_HEARTH_CODE=$code \
		BUILDAT_HEARTH_REQS="$reqs" "$@" \
		timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl" \
		-w 800x600 -l 3 -o sound_mute=1 -s 127.0.0.1:$P \
		-c @"$t/cmds" > "$log" 2>&1 ||
		fail "the drive $log: $(grep -a "Command sequence failed" "$log" | tail -1)"
}
pages(){ grep -a "hearth: page " "$1" | grep -av "command: \|wait_log: " |
	sed 's/.*hearth: page //'; }
# The three requests answered
Q='wait_log_any 20000 "id":1001,\nwait_log_any 20000 "id":1002,\nwait_log_any 20000 "id":1003,\nquit\n'

client "$t/post.log" '{"cmd":"new_topic","name":"Help"}
{"cmd":"new_thread","topic":1,"title":"Lamp flickers","body":"first","subject":"tester/pt 0123abcd"}
{"cmd":"reply","thread":1,"body":"second"}' "$Q"
grep -aq 'hr: {.*"id":1003,"ok":true' "$t/post.log" ||
	fail "the posts: $(grep -a 'hr: {' "$t/post.log" | head -3)"
M=$(grep -ao 'hr: {.*"id":1003,.*' "$t/post.log" | grep -o '"result":[0-9]*' | cut -d: -f2)
[ -n "$M" ] || M=2

# 1. The links
link(){ curl -s "http://127.0.0.1:$P$1" | grep -o 'href="/app[^"]*"' | head -1; }
for p in /topic/1 /t/1 /m/$M /p/tester/pt /u/admin; do
	[ "$(link "$p")" = "href=\"/app#open=$p\"" ] || fail "$p's link: $(link "$p")"
done
[ "$(link /)" = 'href="/app"' ] || fail "home's link: $(link /)"
echo "ok: the pages' links"

# 2. Opened by the client
# Until the request is answered and the line the open ends on (its page,
# or what it said) is logged; the half second after it is the page laid
# out for the screenshot
open(){ # path text: the pages drawn
	client "$t/open.log" '{"cmd":"me"}' "wait_log_any 20000 \"id\":1001,\nwait_log_any 20000 $2\ndelay 500\nscreenshot $t/open${1//\//_}.png\nquit\n" \
		BUILDAT_OPEN="$1"
	grep -aq "Lua runtime error" "$t/open.log" && fail "a Lua error opening $1"
	pages "$t/open.log" | tr '\n' '|'
}
has(){ echo "$1" | grep -q "$2" || fail "$3: $1"; }
has "$(open /topic/1 "hearth: page Help")" "|Help|$" "the topic"
has "$(open /t/1 "hearth: page Lamp flickers")" "|Lamp flickers|$" "the thread"
a=$(open /m/$M "hearth: action m$M ")
has "$a" "|Lamp flickers|$" "the message's thread"
grep -a "hearth: action m$M " "$t/open.log" | grep -aqv "command: \|wait_log" ||
	fail "the message not drawn"
has "$(open /p/tester/pt "hearth: page tester/pt on this Hearth")" \
	"|tester/pt on this Hearth|$" "the package"
has "$(open /u/admin "hearth: page admin")" "|admin|$" "the account"
a=$(open /t/1x "not a place to open: /t/1x")
echo "$a" | grep -q "Lamp" && fail "a bad shape opened: $a"
grep -av "command: \|wait_log" "$t/open.log" | grep -aq "not a place to open: /t/1x" || fail "a bad shape not said"
a=$(open /t/99 "no such thread")
echo "$a" | grep -q "Lamp" && fail "a missing thread: $a"
grep -a "hearth: said" "$t/open.log" | grep -aq "no such thread" ||
	fail "a missing thread not said: $(grep -a 'hearth: said' "$t/open.log" | head -2)"
echo "ok: each kind opened, a bad shape and a missing thread home"

# 3. The web page's pattern
if command -v node > /dev/null; then
	re=$(grep -o "/^#open=.*\$/" "$here/src/client/web/index.html")
	node -e "var re=$re; var ok=['#open=/t/12','#open=/p/a/b','#open=/u/x.y'],
		bad=['#open=/u/x y','#open=/x/1','#open=/t/','#open=javascript:1','#open=/t/1\"'];
		ok.forEach(function(h){ if(!re.exec(h)) throw h; });
		bad.forEach(function(h){ if(re.exec(h)) throw h; });" ||
		fail "the web page's pattern"
	echo "ok: the web page's pattern"
fi
echo "PASS: the web pages link to their place in the web client; the client opens a topic, a thread, a message, a package and an account by BUILDAT_OPEN, a bad shape or a missing thread home (see $t/open_m_$M.png)"
