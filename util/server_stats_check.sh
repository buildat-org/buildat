#!/bin/bash
# tier: full
# cost: ~70 s (2026-10-10)
# covers: builtin/accounts/accounts.cpp builtin/accounts/client_lua/accounts.lua
# [SERVER_STATS]: an Aitta (its admin by first_admin) with a moderator and
# a helper.
#   1. The admin's stats: the hour in progress has max 1, the admin's
#      seen has made and last joined; the Statistics page drawn
#      (stats.png).
#   2. The moderator's stats answered, the helper's not.
#
#   util/server_stats_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp server_stats; t=$CHECK_TMP
trap check_cleanup EXIT
cd "$here/Build"
mkdir -p "$t/srv"
echo "name admin checkpass0" > "$t/srv/first_admin"
start_server "$t/srv.log" "Listening at" 120 auto \
	bin/buildat_server -m ../apps/aitta -D "$t/srv" -l 3 || fail "Aitta did not start"
CHECK_PIDS+=($SERVER_PID)
P=$SERVER_PORT
client(){ # <name> <password> <admin lines> <cmds...>
	local n=$1 pw=$2 adm=$3; shift 3
	printf '%s\n' "$@" quit > "$t/$n.cmds"
	BUILDAT_AITTA_NAME=$n BUILDAT_AITTA_PASSWORD=$pw BUILDAT_AITTA_ADMIN="$adm" \
		timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl_$n" -w 1000x700 -l 3 \
		-o sound_mute=1 -s 127.0.0.1:$P -c @"$t/$n.cmds" > "$t/$n.log" 2>&1 ||
		fail "the $n drive ($t/$n.log): $(grep -ao 'Command sequence failed.*' "$t/$n.log" | head -1)"
}
# The answer's line, not the drive's own wait for it
said(){ grep -a "stats: " "$t/$1.log" | grep -v wait_log; }

# 1. The window up, its sidebar laid out in the half second (the ntfy
# question may come in it); the hover's second is the graph's tooltip
client admin checkpass0 "$(printf 'add mod modpass1234\nadd helper helppass12\nlevel mod 30\nlevel helper 20\nstats')" \
	"wait_log 20000 stats: " "wait_log_any 10000 server window: the page" "delay 500" \
	"click Button \"Statistics\"" "wait_log 5000 server window: the page stats" "delay 300" \
	"mouse_pos 650 210" "delay 500" "mouse_pos 745 210" "delay 1000" "screenshot $t/stats.png"
line=$(said admin | tail -1)
echo "$line" | grep -q "the hour in progress max 1; top admin made [1-9][0-9]* last [1-9]" ||
	fail "the admin's stats: ${line:-none} ($t/admin.log)"
[ -s "$t/stats.png" ] || fail "no screenshot"
echo "ok: the hour has its player, the admin's seen is set ($t/stats.png)"

# 2.
client mod modpass1234 stats "wait_log 20000 stats: "
[ -n "$(said mod)" ] || fail "the moderator's stats ($t/mod.log)"
# The server says nothing to a helper's request: two seconds of no answer
client helper helppass12 stats "wait_log_any 20000 admin request: stats" "wait_log_absent 2000 stats: "
grep -a "admin request: stats" "$t/helper.log" | grep -qv wait_log && [ -z "$(said helper)" ] ||
	fail "the helper's stats ($t/helper.log)"
echo "ok: a moderator's answered, a helper's refused"
echo "PASS"
