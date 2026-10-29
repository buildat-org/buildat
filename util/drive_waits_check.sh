#!/bin/bash
# tier: quick
# cost: ~1 min (2026-10-29)
# covers: src/client/command_seq.cpp src/client/command_seq_run.h src/client/state.cpp builtin/network/network.cpp builtin/network/network_web.cpp src/server/state.cpp client/api.lua util/web_drive.js apps/drive_waits_check/**
# [DRIVE_WAITS]: a drive's frames, idle and sync against
# apps/drive_waits_check, whose client asks the server to act (answered
# half a second later, in the module's own thread) and drains a queue of
# 300 five a frame, registered as the idle source "dwc queue".
# Natively: the answer is not in at once, and is after a sync; frames 30
# is 30 of the client's Update; idle 100 fails naming the queue, and idle
# passes with the queue empty. Then in headless Chrome (web_drive.js's
# steps; skipped without web/ or Chrome): the answer in after sync, 30
# frames about as many of the page's animation frames, idle failing and
# passing the same.
#   util/drive_waits_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
export BUILDAT_STARPORT_DEFAULT=https://127.0.0.1:9
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp drive_waits; t=$CHECK_TMP
start_server "$t/srv.log" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -A 127.0.0.1 \
	-m "$here/apps/drive_waits_check" -D "$t/s" -C "$t/s.cache" -l 3 \
	-W "$here/web" || fail "the server ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
client(){ # log, commands
	printf "$2" > "$t/cmds"
	run_client 60 "$1" timeout 90 "$here/Build/bin/buildat" -C "$t/c" \
		-D "$t/u" -w 320x240 -l 3 -o sound_mute=1 \
		-s "127.0.0.1:$SERVER_PORT" -c @"$t/cmds"
}
check(){ # log, n: the nth "event check" line
	grep -a "dwc: check:" "$1" | sed -n "$2p"
}

client "$t/a.log" 'wait_log_any 60000 dwc: started\nevent check\nsync 5000
event check\nevent mark\nframes 30\nevent mark\nidle 20000\nevent check\n' ||
	fail "the native drive ($t/a.log)"
check "$t/a.log" 1 | grep -q "acted no" ||
	fail "the answer was in before the sync: no test of it ($t/a.log)"
check "$t/a.log" 2 | grep -q "acted yes" ||
	fail "the answer not in after sync ($t/a.log)"
marks=($(grep -ao "dwc: mark: frame [0-9]*" "$t/a.log" | grep -o "[0-9]*$"))
n=$((${marks[1]:-0} - ${marks[0]:-0}))
[ ${#marks[@]} = 2 ] && [ $n -ge 30 ] && [ $n -le 31 ] ||
	fail "frames 30 was $n Updates ($t/a.log)"
check "$t/a.log" 3 | grep -q "queue 0$" ||
	fail "idle passed with the queue not empty ($t/a.log)"

client "$t/b.log" 'wait_log_any 60000 dwc: started\nidle 100\n' &&
	fail "idle 100 passed with the queue full ($t/b.log)"
grep -aq "Command sequence failed: idle: not in 100 ms: .*dwc queue [0-9]" "$t/b.log" ||
	fail "idle failed without naming the queue ($t/b.log)"
echo "native: sync waited for the answer, frames 30 = $n Updates, idle: $(grep -ao "idle: not in 100 ms: .*" "$t/b.log" | head -1)"

if [ ! -f "$here/web/buildat.wasm" ] ||
		! command -v "${CHROME:-google-chrome}" > /dev/null; then
	echo "PASS: (native; the web SKIPPED: no web/ or Chrome)"; exit 0
fi
cat > "$t/steps.json" <<'J'
[
	["nav", "${URL}"],
	["waitlog", "dwc: started", 120],
	["sync", 5000],
	["waitlog", "dwc: acted", 0.3],
	["eval", "window.dwcRaf = 0, (function f(){ window.dwcRaf++; requestAnimationFrame(f); })(), 1"],
	["frames", 30],
	["eval", "window.dwcRaf"],
	["until", "window.dwcRaf >= 25 && window.dwcRaf <= 40", 0.5],
	["idle", 20000],
	["waitlog", "dwc: drained", 0.3]
]
J
WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/" "$here/util/web_drive.sh" chrome \
	drive_waits_check "$t/steps.json" "$t/web" > "$t/web.log" 2>&1 ||
	fail "the web drive ($t/web.log)"
cat > "$t/steps2.json" <<'J'
[
	["nav", "${URL}"],
	["waitlog", "dwc: started", 120],
	["idle", 100]
]
J
WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/" "$here/util/web_drive.sh" chrome \
	drive_waits_check "$t/steps2.json" "$t/web2" > "$t/web2.log" 2>&1 &&
	fail "web: idle 100 passed with the queue full ($t/web2.log)"
grep -aq "idle: not in 100 ms: .*dwc queue [0-9]" "$t/web2.log" ||
	fail "web: idle failed without naming the queue ($t/web2.log)"
echo "PASS: sync, frames and idle, native and web ($(grep -ao "eval: [0-9]*" "$t/web.log" | tail -1 | sed 's/eval:/page frames for 30:/'))"
