#!/bin/bash
# tier: broken
# broken: back to long; the drive stopped (dev) (local/runs/dev_baseline)
# cost: ~45 s (2026-10-09)
# covers: apps/hearth/main/client_lua/init.lua
# [HEARTH_NEW_IMAGES] in the native client: a new account posts a thread
# with its image; a helper (the admin) opens it and sees the image with
# the line that it is not shown to everyone yet, presses "Show to
# everyone", and the thread is drawn again with "Take back". The client
# logs no error on the way (a kept thumbnail was once taken for the list
# of those waiting for it).
#   apps/hearth/test/helper_image.sh
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
t=$(mktemp -d)
pid=
trap '[ -n "$pid" ] && kill $pid 2>/dev/null; [ -n "${KEEP_TMP:-}" ] && echo "kept $t" || rm -rf "$t"' EXIT
fail(){ echo "FAIL: $*"; exit 1; }
P=29899

cd "$here/Build"
start_server "$t/srv.log" "setup code" 120 $P \
	bin/buildat_server -m ../apps/hearth -D "$t/srv" -l 3 ||
	fail "Hearth did not start"
pid=$SERVER_PID
code=$(grep -ao "setup code [A-Z0-9]*" "$t/srv.log" | cut -d' ' -f3)
[ -n "$code" ] || fail "no setup code (srv.log: $(tail -3 "$t/srv.log"))"

client(){ # name password log cmds [env...]
	local n=$1 pw=$2 log=$3 cmds=$4
	shift 4
	env BUILDAT_HEARTH_NAME=$n BUILDAT_HEARTH_PASSWORD=$pw BUILDAT_HEARTH_CREATE=1 \
		BUILDAT_HEARTH_CODE=$code "$@" \
		timeout 120 bin/buildat -o launch_ui=launch_menu -D "$t/cl_$n" -w 1280x720 \
		-l 3 -o sound_mute=1 -s 127.0.0.1:$P -c @"$cmds" > "$log" 2>&1
}
answer(){ # log id
	grep -ao "hr: {.*\"id\":$2,.*" "$1" | head -1
}
# Until the request's answer is in, and the admin script's
printf 'wait_log_any 20000 "id":1001,\nquit\n' > "$t/wait"
printf 'wait_log_any 20000 "id":1001,\nwait_log_any 20000 admin script: done\nquit\n' > "$t/wait_admin"
client admin checkpass12 "$t/admin.log" "$t/wait_admin" \
	BUILDAT_HEARTH_REQS='{"cmd":"new_topic","name":"Help","about":"Questions"}' \
	"BUILDAT_HEARTH_ADMIN=add newbie newbiepass12" ||
	fail "the admin's client: $(grep -a "Command sequence failed" "$t/admin.log" | tail -1)"
answer "$t/admin.log" 1001 | grep -q '"ok":true' || fail "the topic: $(answer "$t/admin.log" 1001)"
hex=$(xxd -p "$here/3rdparty/Urho3D/bin/Data/Textures/LogoLarge.png" | tr -d '\n')
client newbie newbiepass12 "$t/up.log" "$t/wait" BUILDAT_HEARTH_CREATE= \
	BUILDAT_HEARTH_REQS="{\"cmd\":\"upload\",\"name\":\"lamp.png\",\"data\":\"$hex\"}"
id=$(answer "$t/up.log" 1001 | grep -o '"id":[0-9]*,"image"' | grep -o '[0-9]*')
[ -n "$id" ] || fail "a new account's image: $(answer "$t/up.log" 1001 | head -c 300)"
client newbie newbiepass12 "$t/post.log" "$t/wait" BUILDAT_HEARTH_CREATE= \
	BUILDAT_HEARTH_REQS="{\"cmd\":\"new_thread\",\"topic\":1,\"title\":\"Newbie lamp\",\"body\":\"look [![lamp.png](/f/$id/thumb)](/f/$id/lamp.png)\"}"
answer "$t/post.log" 1001 | grep -q '"ok":true' || fail "the thread: $(answer "$t/post.log" 1001)"

# The 1.5 s on the thread: its thumbnail, a request after the page
cat > "$t/cmds" <<C
wait_log_any 20000 hearth: page
delay 300
click Button "Help"
wait_log 10000 hearth: page Help
delay 300
click Button "Newbie lamp"
wait_log 10000 hearth: page Newbie lamp
delay 1500
screenshot $t/before.png
click Button "Show to everyone"
wait_log 10000 hearth: page Newbie lamp
delay 1000
screenshot $t/after.png
click Button "Take back"
wait_log 10000 hearth: page Newbie lamp
quit
C
client admin checkpass12 "$t/helper.log" "$t/cmds" BUILDAT_HEARTH_CREATE=
grep -aq "Command sequence complete" "$t/helper.log" ||
	fail "the drive stopped: $(grep -a "Command sequence\|rror" "$t/helper.log" | tail -2)"
! grep -a "Lua runtime error\|Runtime error\|the thumbnail of file" "$t/helper.log" ||
	fail "the client failed on the way"
grep -aq "admin showed everyone image $id" "$t/srv.log" || fail "not shown to everyone"
grep -aq "admin took back image $id" "$t/srv.log" || fail "not taken back"
echo "PASS: a helper saw a new account's image, showed it to everyone and took it back, no error"
