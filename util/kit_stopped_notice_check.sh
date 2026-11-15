#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~15 s (2026-11-15)
# covers: builtin/kit/client_lua/ui.lua
# [KIT_STOPPED_NOTICE] Workbench's world project. kitboss (a builder) ends
# it in edit mode: no notice there; out of it, the notice with a builder's
# line (Esc, then Run). kitbob (no edit rights) joins by finger at 412x915
# while Ended: the notice without it. kitboss's pause menu Run takes both
# away, its End brings both back; in edit mode again, kitboss's is gone,
# out of it back. kitboss again by finger at 412x915: Menu, then Run.
# Screenshots: boss_1024x700.png, boss_menu.png (Run in the menu over it),
# bob_412x915.png, boss_412x915.png
#   util/kit_stopped_notice_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_stopped_notice; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1
start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
	fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
# kitboss by a pipe: each step after kitbob's client has seen the last
mkfifo "$t/cmd"
sleep 600 > "$t/cmd" &
CHECK_PIDS+=($!)
check_build
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code \
	BUILDAT_JOIN_ADMIN="setting open_registration on" \
	timeout 300 bin/buildat -C "$t/client_cache" -D "$t/cu_boss" \
	-s localhost:$SERVER_PORT -w 1024x700 -l 3 -c - < "$t/cmd" > "$t/boss.log" 2>&1 &
CLIENT=$!
CHECK_PIDS+=($CLIENT)
exec 3> "$t/cmd"
cmd() { printf '%s\n' "$@" >&3; }
mark() { wc -c < "$1"; }
await() # <log> <offset> <seconds> <regex>
{
	local i
	for i in $(seq $(($3 * 5))); do
		tail -c +$(($2 + 1)) "$1" | grep -qaE "$4" && return 0
		kill -0 $CLIENT 2>/dev/null || fail "kitboss's client is gone ($t/boss.log)"
		sleep 0.2
	done
	fail "no \"$4\" in $1 in $3 s ($t/srv.log, $t/boss.log, $t/bob.log)"
}
# (the notice's own lines, not a drive's echo of them)
SHOWN="I kit +: kit: the stopped notice shown: " HIDDEN="I kit +: kit: the stopped notice hidden"
menu() # <item> [<screenshot>]: pressed in kitboss's pause menu
{
	local m
	m=$(mark "$t/boss.log")
	cmd "keypress Escape"
	await "$t/boss.log" "$m" 10 "pause: the menu shown"
	cmd "frames 3" ${2:+"screenshot $t/$2.png"} "click Button \"$1\""
}
cmd "wait_log_any 60000 Joined as kitboss" \
	"wait_log_any 30000 server window: the page ntfy" "frames 3" \
	'click Button "Don'"'"'t add"' "wait_log_any 60000 player physics enabled" \
	"wait_log_any 10000 kit editor: edit rights: yes" \
	'event kit_edit {"op": "mode", "on": true}' \
	"wait_log_any 10000 kit editor: edit mode on" 'event kit_edit {"op": "stop"}'
await "$t/boss.log" 0 120 "the server is Ended \(by kitboss\)"
m=$(mark "$t/boss.log")
cmd 'event kit_edit {"op": "mode", "on": false}'
await "$t/boss.log" "$m" 10 "${SHOWN}Stopped: the game is being built\. \| It starts when a builder runs it\. \| You may run it: Esc, then Run$"
cmd "frames 10" "screenshot $t/boss_1024x700.png"
cat > "$t/bob.cmds" <<EOF
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
wait_log_any 30000 kit: the stopped notice shown: Stopped
frames 10
screenshot $t/bob_412x915.png
wait_log_any 60000 kit: the stopped notice hidden
wait_log 60000 kit: the stopped notice shown: Stopped
quit
EOF
BUILDAT_TOUCH=1 BUILDAT_JOIN_NAME=kitbob run_client 60 "$t/bob.log" timeout 240 \
	bin/buildat -C "$t/client_cache_bob" -D "$t/cu_bob" -s localhost:$SERVER_PORT \
	-w 412x915 -l 3 -c @"$t/bob.cmds" &
bob=$!
await "$t/bob.log" 0 120 "${SHOWN}Stopped: the game is being built\. \| It starts when a builder runs it\.$"
m=$(mark "$t/boss.log") b=$(mark "$t/bob.log")
menu Run boss_menu
await "$t/boss.log" "$m" 10 "the server is Running \(by kitboss\)"
await "$t/bob.log" "$b" 10 "$HIDDEN"
m=$(mark "$t/boss.log") b=$(mark "$t/bob.log")
menu End
await "$t/boss.log" "$m" 10 "the server is Ended \(by kitboss\)"
await "$t/bob.log" "$b" 10 "${SHOWN}Stopped"
await "$t/boss.log" "$m" 10 "${SHOWN}Stopped"
m=$(mark "$t/boss.log")
cmd 'event kit_edit {"op": "mode", "on": true}'
await "$t/boss.log" "$m" 10 "$HIDDEN"
m=$(mark "$t/boss.log")
cmd 'event kit_edit {"op": "mode", "on": false}'
await "$t/boss.log" "$m" 10 "${SHOWN}Stopped"
cmd quit
exec 3>&-
wait $CLIENT 2>/dev/null
wait $bob || fail "kitbob's client failed ($t/bob.log)"
cat > "$t/boss2.cmds" <<EOF
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 kit: the stopped notice shown: Stopped
frames 10
screenshot $t/boss_412x915.png
quit
EOF
BUILDAT_TOUCH=1 BUILDAT_JOIN_NAME=kitboss run_client 60 "$t/boss2.log" timeout 120 \
	bin/buildat -C "$t/client_cache" -D "$t/cu_boss" -s localhost:$SERVER_PORT \
	-w 412x915 -l 3 -c @"$t/boss2.cmds" || fail "kitboss's touch client ($t/boss2.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
grep -aE "$SHOWN|$HIDDEN" "$t/boss.log" "$t/bob.log" "$t/boss2.log" |
	sed 's/^.*\/\([a-z0-9]*\)\.log:.*kit: /  \1: /'
grep -aqE "${SHOWN}.* \| You may run it: Menu, then Run$" "$t/boss2.log" ||
	fail "no builder's line by finger ($t/boss2.log)"
# Never in edit mode
awk -v s="$SHOWN" '/I kit +: kit editor: edit mode on/ { e = 1 }
	/I kit +: kit editor: edit mode off/ { e = 0 }
	e && $0 ~ s { bad = 1 } END { exit bad }' "$t/boss.log" ||
	fail "the notice shown in edit mode ($t/boss.log)"
for p in boss_1024x700 boss_menu bob_412x915 boss_412x915; do
	[ -s "$t/$p.png" ] || fail "no screenshot $t/$p.png"
done
echo "PASS: stopped notice: a player's and a builder's while Ended, out of edit mode only, gone at Run, back at End; screenshots in $t"
# vim: set noet ts=4 sw=4:
