#!/bin/bash
# tier: full
# cost: ~1 min (2026-10-04)
# covers: apps/hearth/main/main.cpp apps/aitta/main/main.cpp
# [PACKAGE_SUBJECT], the first slice: **a release is a thread in its home
# Hearth**. An Aitta and a Hearth side by side; tester publishes demo 1.0.0
# naming the Hearth its home, with a changelog, and other/elsewhere 1.0.0
# naming another. Hearth's admin sets the release sources (the Aitta, and
# the Hearth's own address): demo 1.0.0 becomes one thread in "Releases",
# by "tester (Aitta)", with the changelog; elsewhere does not; a restart
# makes no second thread. "Feedback..." on the installed demo's tile
# opens the composer there with the package and versions; its thread is a
# problem reported in 1.0.0, which the admin marks fixed in 1.1.0; demo 1.1.0's
# release thread links it and its reporter is told.
#
#   util/release_thread_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
b="$here/Build/bin/buildat"
t=$(mktemp -d)
pa= ph=
trap 'kill $pa $ph 2>/dev/null; [ -n "${KEEP_TMP:-}" ] && echo "kept $t" || rm -rf "${t:?}"' EXIT
fail(){ echo "FAIL: $*"; KEEP_TMP=1; exit 1; }
A=29882 H=29883
cd "$here/Build"
start(){ # app port log
	BUILDAT_CONNECT_PORTS=$A bin/buildat_server -m ../apps/$1 -D "$t/srv_$1" -P $2 -l 3 > "$3" 2>&1 &
	echo $!
}
code_of(){ # log pid
	for _ in $(seq 300); do
		grep -q "setup code" "$1" && break
		kill -0 "$2" 2>/dev/null || break
		sleep 0.2
	done
	grep -ao "setup code [A-Z0-9]*" "$1" | cut -d' ' -f3
}
# answers <n> <file>: a drive that quits once the Hearth's answers to the
# requests 1001.. 1000+n are in
answers(){
	{ for i in $(seq "$1"); do echo "wait_log_any 20000 \"id\":$((1000 + i)),"; done
		echo quit; } > "$2"
}
# Why a client's drive stopped
why(){ grep -a "Command sequence failed" "$1" | tail -1 | cut -c 1-300; }
pa=$(start aitta $A "$t/aitta.log")
ph=$(start hearth $H "$t/hearth.log")
ca=$(code_of "$t/aitta.log" $pa)
ch=$(code_of "$t/hearth.log" $ph)
[ -n "$ca" ] || fail "Aitta did not start ($(tail -3 "$t/aitta.log"))"
[ -n "$ch" ] || fail "Hearth did not start ($(tail -3 "$t/hearth.log"))"

# Aitta: tester bound to a key; demo 1.0.0 at home in this Hearth, elsewhere
# in another
"$b" aitta keygen "$t/key" > "$t/pub" 2>/dev/null || fail "keygen"
printf 'wait_log_any 20000 ai: {"id":1,\nquit\n' > "$t/cmds"
BUILDAT_AITTA_CREATE=1 BUILDAT_AITTA_NAME=admin BUILDAT_AITTA_PASSWORD=checkpass \
BUILDAT_AITTA_CODE=$ca \
BUILDAT_AITTA_REQS="{\"cmd\":\"bind\",\"author\":\"tester\",\"key\":\"$(cat "$t/pub")\"}" \
	timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl_a" -w 800x600 -l 3 -o sound_mute=1 \
	-s 127.0.0.1:$A -c @"$t/cmds" > "$t/cl_a.log" 2>&1 || fail "the Aitta client: $(why "$t/cl_a.log")"
grep -aq 'ai: {"id":1,"ok":true' "$t/cl_a.log" || fail "the bind did not go through"
publish(){ # name home [version]
	local v=${3:-1.0.0}
	mkdir -p "$t/$1/main"
	echo 'int x;' > "$t/$1/main/main.cpp"
	mkdir -p "$t/$1/launcher"
	echo "return function(ctx) return {{id = 'play', label = '$1',
		run = function() ctx.launch{} end}} end" > "$t/$1/launcher/init.lua"
	printf '# %s\r\n\r\n- the first **release** of %s\r\n' "$v" "$1" > "$t/$1/CHANGELOG.md"
	printf '{"author": "tester", "name": "%s", "version": "'$v'",
		"engine_api": 2, "license_code": "MIT", "license_media": "CC0-1.0",
		"description": "a check", "home_hearth": "%s",
		"changelog": "CHANGELOG.md"}\n' "$1" "$2" > "$t/$1/meta.json"
	local zip
	zip=$("$b" aitta pack "$t/$1" "$t/key" "$t/out_$1" 2>/dev/null) || fail "pack $1"
	"$b" aitta publish "$zip" 127.0.0.1:$A 2>&1 | grep -q "listed: tester/$1/$v" ||
		fail "publish $1"
	zips="$zips $zip"
}
zips=
publish demo "http://127.0.0.1:$H/"
publish elsewhere "https://forum.example"
curl -s "http://127.0.0.1:$A/api/v1/aitta/release?id=tester/demo/1.0.0" |
	grep -q 'first \*\*release\*\* of demo' || fail "Aitta does not serve the changelog"

# Hearth: the admin sets the sources
answers 1 "$t/cmds_h"
BUILDAT_HEARTH_CREATE=1 BUILDAT_HEARTH_NAME=admin BUILDAT_HEARTH_PASSWORD=checkpass12 \
BUILDAT_HEARTH_CODE=$ch \
BUILDAT_HEARTH_REQS="{\"cmd\":\"release_sources\",\"aittas\":[\"http://127.0.0.1:$A\"],\"addresses\":[\"http://127.0.0.1:$H\"]}" \
	timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl_h" -w 800x600 -l 3 -o sound_mute=1 \
	-s 127.0.0.1:$H -c @"$t/cmds_h" > "$t/cl_h.log" 2>&1 || fail "the Hearth client: $(why "$t/cl_h.log")"
grep -aq 'hr: {.*"ok":true' "$t/cl_h.log" ||
	fail "release_sources: $(grep -a 'hr: ' "$t/cl_h.log" | head -2)"

for _ in $(seq 150); do
	grep -q "is the thread" "$t/hearth.log" && break
	sleep 0.2
done
grep -q "The release tester/demo/1.0.0 .* is the thread" "$t/hearth.log" ||
	fail "no release thread ($(grep -a "elease" "$t/hearth.log" | tail -3))"
page=$(curl -s "http://127.0.0.1:$H/t/1")
echo "$page" | grep -q "demo 1.0.0" || fail "the thread's title: $page"
echo "$page" | grep -q "tester (Aitta)" || fail "the thread's author"
echo "$page" | grep -q "<strong>release</strong> of demo" || fail "the changelog is not in it"
curl -s "http://127.0.0.1:$H/" | grep -q "Releases" || fail "no Releases topic"
grep -q "tester/elsewhere" "$t/hearth.log" && fail "a release of another Hearth got a thread"

# "Feedback..." on the installed demo's tile: the client connects to its
# home Hearth, and the composer there has the package and versions
for z in $zips; do
	"$b" aitta install "$z" "$t/user" > /dev/null 2>&1 || fail "install $z"
done
answers 4 "$t/cmds_f"
BUILDAT_HEARTH_NAME=admin BUILDAT_HEARTH_PASSWORD=checkpass12 \
BUILDAT_HEARTH_REQS='{"cmd":"new_thread","feedback":true,"subject":"tester/demo '"$(cat "$t/pub")"'","title":"It hums","body":"a check","kind":"problem","version":"1.0.0"}
{"cmd":"status","thread":2,"status":"fixed","fixed_in":"1.1.0"}
{"cmd":"status","thread":1,"status":"fixed"}
{"cmd":"new_thread","topic":1,"title":"x","body":"x","kind":"bug"}' \
	timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/user" -C "$t/cache_f" -w 800x600 -l 3 \
	-o sound_mute=1 -a installed/tester.demo@1.0.0/feedback -c @"$t/cmds_f" \
	> "$t/cl_f.log" 2>&1 || fail "the feedback client: $(why "$t/cl_f.log")"
f=$(grep -a "hr feedback: " "$t/cl_f.log")
[ -n "$f" ] || fail "no feedback composer ($(grep -a "ERROR\|WARNING" "$t/cl_f.log" | tail -3))"
for want in '"package":"tester/demo"' '"version":"1.0.0"' \
		"\"subject\":\"tester/demo $(cat "$t/pub")\"" '"platform":"'; do
	echo "$f" | grep -qF "$want" || fail "the composer lacks $want: $f"
done
grep -aq 'hr: {"id":1001,"ok":true' "$t/cl_f.log" || fail "the feedback thread: $(grep -a 'hr: ' "$t/cl_f.log" | tail -1)"
curl -s "http://127.0.0.1:$H/" | grep -q "Feedback" || fail "no Feedback topic"
# A problem: its status the admin's, its version the report's; a release
# has no status, and a kind is one of four
grep -aq 'hr: {"id":1002,"ok":true' "$t/cl_f.log" || fail "the status: $(grep -a '"id":1002' "$t/cl_f.log")"
grep -aq '"id":1003,"ok":false' "$t/cl_f.log" || fail "a release took a status"
grep -aq '"id":1004,"ok":false' "$t/cl_f.log" || fail "a kind \"bug\" was taken"
page=$(curl -s "http://127.0.0.1:$H/t/2")
echo "$page" | grep -q "problem, fixed in 1.1.0, reported in 1.0.0" || fail "the problem's page: $page"

# demo 1.1.0 comes out: its release thread links the problem it fixes, and
# whoever reported it is told
publish demo "http://127.0.0.1:$H/" 1.1.0
# Hearth reads the Aittas once a minute (nothing kicks it here): up to 90 s
for _ in $(seq 450); do
	grep -q "tester/demo/1.1.0 .* is the thread" "$t/hearth.log" && break
	kill -0 $ph 2>/dev/null || break
	sleep 0.2
done
n=$(grep -o "tester/demo/1.1.0 .* is the thread [0-9]*" "$t/hearth.log" | grep -o "[0-9]*$")
[ -n "$n" ] || fail "no thread for demo 1.1.0"
curl -s "http://127.0.0.1:$H/t/$n" | grep -q 'It hums <a class="ref" href="/t/2">' ||
	fail "the 1.1.0 release thread does not link the problem it fixes"
answers 6 "$t/cmds_n"
BUILDAT_HEARTH_NAME=admin BUILDAT_HEARTH_PASSWORD=checkpass12 \
BUILDAT_HEARTH_REQS='{"cmd":"notifications"}
{"cmd":"subject","subject":"tester/demo '"$(cat "$t/pub")"'"}
{"cmd":"new_thread","topic":1,"title":"Started elsewhere","body":"x"}
{"cmd":"link","thread":4,"subject":"tester/demo '"$(cat "$t/pub")"'"}
{"cmd":"link","thread":4,"subject":"tester/nothing k"}
{"cmd":"new_thread","topic":1,"title":"Same name","body":"x","subject":"tester/demo otherkey"}' \
	timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl_h" -w 800x600 -l 3 -o sound_mute=1 \
	-s 127.0.0.1:$H -c @"$t/cmds_n" > "$t/cl_n.log" 2>&1 || fail "the Hearth client: $(why "$t/cl_n.log")"
grep -a '"id":1001' "$t/cl_n.log" | grep -q '"kind":"fixed","message":0,"note":"1.1.0"' ||
	fail "the reporter was not told: $(grep -a '"id":1001' "$t/cl_n.log")"
# The package's place ("Discuss" on Aitta's list): its two releases and
# the problem
n=$(grep -a '"id":1002' "$t/cl_n.log" | grep -o '"subject":"tester/demo ' | wc -l)
[ "$n" = 3 ] || fail "the package's place has $n threads, not 3"
# A thread started elsewhere, linked afterwards; only to a released package
grep -aq '"id":1003,"ok":true,"result":4' "$t/cl_n.log" || fail "the thread to link: $(grep -a '"id":1003' "$t/cl_n.log")"
grep -aq '"id":1004,"ok":true' "$t/cl_n.log" || fail "the link: $(grep -a '"id":1004' "$t/cl_n.log")"
grep -aq '"id":1005,"ok":false' "$t/cl_n.log" || fail "a link to a package not released here was taken"
page=$(curl -s "http://127.0.0.1:$H/p/tester/demo")
for want in "It hums" "demo 1.1.0" "demo 1.0.0" "Started elsewhere"; do
	echo "$page" | grep -q "$want" || fail "/p/tester/demo lacks $want: $page"
done
# A poster names a thread's subject: only a release's key counts as
# another key under the name
echo "$page" | grep -q "Same name" || fail "/p/tester/demo lacks the thread named after it"
echo "$page" | grep -q "Published under" && fail "a poster's subject counted as a second key"
curl -s "http://127.0.0.1:$H/t/2" | grep -q 'About <a href="/p/tester/demo">' ||
	fail "the problem's page does not link its package's place"
[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$H/p/tester/demo/x")" = 404 ] ||
	fail "/p/ took a path of three parts"

# A restart reads the Aitta again and makes no second thread
# start() ran in $(...): the server is not this shell's child to wait for
kill $ph
while kill -0 $ph 2>/dev/null; do sleep 0.2; done
ph=$(start hearth $H "$t/hearth2.log")
for _ in $(seq 300); do
	grep -q "STATUS Listening" "$t/hearth2.log" && break
	kill -0 $ph 2>/dev/null || break
	sleep 0.2
done
grep -q "STATUS Listening" "$t/hearth2.log" || fail "Hearth did not start again ($(tail -3 "$t/hearth2.log"))"
# simplified: 5 s for the restarted Hearth to read the Aitta and not make a
# thread, as there is no line for "read, nothing new"
sleep 5
grep -q "is the thread" "$t/hearth2.log" && fail "a second thread after the restart"
n=$(curl -s "http://127.0.0.1:$H/t/6" | grep -c "demo 1\.")
[ "$n" = 0 ] || fail "a second thread after the restart (/t/6)"
echo "PASS: demo 1.0.0 is one release thread with its changelog; elsewhere is not; Feedback... reaches the composer"
