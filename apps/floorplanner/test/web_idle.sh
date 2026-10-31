#!/bin/bash
# tier: full
# cost: 110s (2026-10-04)
# covers: src/client/app.cpp src/client/web/index.html
# [WEB_IDLE_FPS]: the web client draws at web_idle_fps (5) while the page is
# unfocused or has had no input for a minute, and at full rate on input.
# Headless Chrome, floorplanner's login screen; web_idle.json counts the
# canvas's WebGL clears (one a frame) over windows of five seconds: at load
# (no focus yet), while the mouse moves (the focus with it), after 65 s
# with no input, and moving again. Chrome, because headless Firefox never
# has the focus. Needs web/ from util/build_web.sh.
#   apps/floorplanner/test/web_idle.sh [out dir]
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
out=${1:-$here/local/web_idle/check}
mkdir -p "$(dirname "$out")"
"$here/util/web_drive.sh" chrome floorplanner "$here/apps/floorplanner/test/web_idle.json" \
		"$out" > "$out.txt" 2>&1 || { tail -5 "$out.txt"; echo "FAIL: the drive"; exit 1; }
n(){ grep -a "eval: \"$1: clears" "$out.txt" | sed 's/.*clears \([0-9]*\).*/\1/'; }
load=$(n load) moving=$(n moving) idle=$(n idle) again=$(n "after input, moving")
echo "clears in 5 s: load $load, moving $moving, idle $idle; moving again (3 s) $again"
fail=0
# 5 a second is 25; a full rate is 60 a second or the display's
[ "${load:-999}" -le 40 ] || { echo "FAIL: not slow before the focus"; fail=1; }
[ "${moving:-0}" -ge 150 ] || { echo "FAIL: not full rate while the mouse moves"; fail=1; }
[ "${idle:-999}" -le 40 ] || { echo "FAIL: not slow after a minute without input"; fail=1; }
[ "${again:-0}" -ge 90 ] || { echo "FAIL: not full rate again on input"; fail=1; }
[ $fail = 0 ] && echo "PASS: slow when unfocused or idle, full on input"
exit $fail
