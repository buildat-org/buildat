#!/bin/bash
# tier: full
# cost: ~4 min (2026-10-26)
# covers: builtin/voxelworld/client_lua/module.lua apps/skeldat/main/client_lua/init.lua apps/skeldat/main/bones_growth.h apps/skeldat/main/main.cpp
# [SKELDAT_SPAWN_STUCK_2]: a player walking a minute on the bones' edge
# while they grow fast (seed 2, full bones at x >= 0, an expansion every
# 0.3 s) is never held in open air nor inside a voxel, natively and in
# Firefox. The client logs "stuck at ..." when a walking key is held 1 s
# with no move or the box is inside a voxel for 1 s, with what its feet's
# voxel read; the server a walkable voxel set inside a player's box.
# Before: a chunk whose new node came before its old one went read as no
# node for good (every voxel id 0, solid), the player boxed in where the
# world drew open air; and the growth set bone blocks into the player.
#   apps/skeldat/edge_walk_check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp sk_edge_walk; t=$CHECK_TMP
trap check_cleanup EXIT
export BUILDAT_SKELDAT_WORLD=edge BUILDAT_SKELDAT_SEED=2 \
	BUILDAT_SKELDAT_SIZE="1 -1 0" BUILDAT_SKELDAT_FILL=half \
	BUILDAT_SKELDAT_EXPAND=0.3 BUILDAT_SKELDAT_SKELETONS=0
server(){ # <name> [args]
	start_server "$t/$1.log" "STATUS Listening" 300 auto \
		"$here/Build/bin/buildat_server" -u launcher=1 -m "$here/apps/skeldat" \
		-D "$t/$1" -C "$t/srv.cache" -l 3 "${@:2}" || fail "the server ($t/$1.log)"
	CHECK_PIDS+=($SERVER_PID)
}
# What a run must not have; and it walked off the placing
judge(){ # <what> <client log> <server log>
	grep -aq "walked 2 from the placing" "$2" || fail "$1: never walked 2 ($2)"
	# Solid with no node there: read so, not loaded or not known (a node
	# stood on, a skull's half, is its own cell too)
	local air="the feet's voxel SOLID: \\(nil\\|id 0\\|id [0-9]* with no definition\\)"
	! grep -aq "stuck at .*$air" "$2" ||
		fail "$1: held in open air: $(grep -a "stuck at .*$air" "$2" | head -1 | sed 's/.*stuck at/at/') ($2)"
	! grep -aq "stuck at .*inside a voxel" "$2" ||
		fail "$1: inside a voxel: $(grep -a "inside a voxel" "$2" | head -1 | sed 's/.*stuck at/at/') ($2)"
	! grep -aq "set inside .*'s box" "$3" ||
		fail "$1: $(grep -a "set inside" "$3" | head -1 | sed 's/.*skeldat: //') ($3)"
}

# Native: the how-to-play closed, then W, A, S, D in turn with jumps and a
# turn, six times (each delay at most 1 s)
server native
{
	echo "wait_log 240000 pause: how to play shown"
	echo "click Button \"Close\""; echo "wait_log 10000 pause: the menu closed"
	for i in 1 2 3 4 5 6; do
		for k in w a s d; do
			echo "keydown $k"; echo "delay 1000"; echo "keypress Space"
			echo "delay 1000"; echo "keyup $k"
		done
		echo "mouse_move 120 0"; echo "delay 300"
	done
	echo "quit"
} > "$t/seq"
run_client 60 "$t/c.log" timeout 300 "$here/Build/bin/buildat" \
	-s 127.0.0.1:$SERVER_PORT -D "$t/c" -C "$t/c.cache" -w 1200x800 -l 3 \
	-o sound_mute=1 -c @"$t/seq" || fail "the native client ($t/c.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
judge native "$t/c.log" "$t/native.log"
native=$(grep -ac "stuck at" "$t/c.log")

# Firefox at 1200x800: the page's pointer lock as web_spawn_check.sh's
# The how-to-play closed by its Escape: a click at Close's place missed
# it once the dialog grew ([SKELDAT_EDGE_WALK_CLICK])
command -v "${FIREFOX:-firefox}" > /dev/null && [ -f "$here/web/buildat.wasm" ] || {
	echo "PASS: native walked the bones' edge a minute ($native stuck lines, none in open air or a voxel); Firefox skipped (no Firefox or web/)"
	exit 0
}
server web -A 127.0.0.1 -W "$here/web"
stub="(function(){ var held = null; Object.defineProperty(document, 'pointerLockElement', {configurable: true, get: function(){ return held; }}); function set(e){ held = e; document.dispatchEvent(new Event('pointerlockchange')); } HTMLCanvasElement.prototype.requestPointerLock = function(){ if(held !== this) set(this); return Promise.resolve(); }; document.exitPointerLock = function(){ if(held) set(null); }; return 'stub'; })()"
python3 - "$stub" "$t/steps.json" <<'PY'
import json, sys
s = [["nav", "${URL}"], ["eval", sys.argv[1]],
	["waitlog", "pause: how to play shown", 240], ["wait", 1000],
	["key", "Escape"], ["waitlog", "pause: the menu closed", 10]]
for i in range(6):
	for k in "wasd":
		s += [["holdkey", k, 1000], ["key", "Space"], ["holdkey", k, 1000]]
	s += [["mouse", 600 + 60 * (i + 1), 400]]
json.dump(s, open(sys.argv[2], "w"))
PY
WEB_DRIVE_VIEWPORT=1200x800 WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/" \
	"$here/util/web_drive.sh" firefox skeldat "$t/steps.json" "$t/drive" \
	> "$t/drive.txt" 2>&1 || fail "the drive ($(tail -2 "$t/drive.txt"))"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
judge Firefox "$t/drive/page.log" "$t/web.log"
echo "PASS: a minute on the bones' edge natively ($native stuck lines) and in Firefox ($(grep -ac "stuck at" "$t/drive/page.log")), none in open air or inside a voxel, nothing grown into the player"
