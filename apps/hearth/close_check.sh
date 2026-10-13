#!/bin/bash
# tier: full
# cost: ~1 min (2026-10-10)
# covers: apps/hearth/main/client_lua/init.lua client/api.lua
# [HEARTH_CLOSE]: Hearth joined from the launcher, at its top:
#   1. Escape opens "Exit to launcher?" with Exit selected; Escape closes
#      it; Up and Enter (Cancel) closes it; Down and Enter opens My account.
#   2. The × then Q exits: the launcher back, the kept token empty.
#   3. Joined straight (-s, no launcher): no ×, Escape is My account.
# Screenshots in $t (KEEP_TMP=1 keeps it).
#
#   apps/hearth/close_check.sh
set -u
. "$(dirname "$0")/../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp hearth_close; t=$CHECK_TMP

cd "$here/Build"
start_server "$t/srv.log" "setup code" 60 auto \
	bin/buildat_server -m ../apps/hearth -D "$t/srv" -l 3 ||
	fail "Hearth did not start"
CHECK_PIDS+=($SERVER_PID)
P=$SERVER_PORT
code=$(grep -ao "setup code [A-Z0-9]*" "$t/srv.log" | cut -d' ' -f3)

drive(){ # log commands [client args...]
	local log=$1
	printf "$2" > "$t/cmds"
	shift 2
	env BUILDAT_HEARTH_NAME=admin BUILDAT_HEARTH_PASSWORD=checkpass12 \
		BUILDAT_HEARTH_CREATE=1 BUILDAT_HEARTH_CODE=$code \
		timeout 90 bin/buildat -m launch_menu -D "$t/cl" -w 800x600 -l 3 \
		-o sound_mute=1 -c @"$t/cmds" "$@" > "$log" 2>&1 ||
		fail "the drive $log: $(grep -a "Command sequence failed" "$log" | tail -1)"
	grep -aq "Lua runtime error" "$log" && fail "a Lua error in $log"
}
# The lines after the commands' echo, from the one matching $2 on
after(){ grep -av "command: \|wait_log" "$1" | sed -n "/$2/,\$p"; }
J="wait_log_any 30000 rows in\nevent join 127.0.0.1:$P\nwait_log 30000 hearth: frame\ndelay 1500\n"
# A dialog closed logs nothing: the 800 ms after its key is the time for a
# wrong turn (a leave) to show before the scan

# 1. The dialog's keys
drive "$t/keys.log" "${J}keypress Escape\nwait_log 5000 hearth: exit dialog\ndelay 800\nscreenshot $t/dialog.png\nkeypress Escape\ndelay 800\nevent scan closed1\nkeypress Escape\nwait_log 5000 hearth: exit dialog\ndelay 500\nkeypress Up\nkeypress Return\ndelay 800\nevent scan closed2\nkeypress Escape\ndelay 500\nkeypress Down\nkeypress Return\nwait_log 5000 server window: the page\ndelay 300\nscreenshot $t/account.png\nquit\n"
n=$(grep -av "command: \|wait_log" "$t/keys.log" | grep -ac "hearth: exit dialog")
[ "$n" = 3 ] || fail "the dialog opened $n times, not 3"
after "$t/keys.log" "closed1" | grep -aq "launch_menu: back to Home" &&
	fail "a key left Hearth"
after "$t/keys.log" closed2 | grep -aq "server window: " ||
	fail "Down+Enter did not open My account"
echo "ok: Escape opens it, Escape and Up+Enter close it, Down+Enter is My account"

# 2. The × then Q, a kept login: the launcher back, the token gone
# A local client is given no kept token (builtin/accounts): one put there,
# which the env's login goes before
tok="$t/cl/servers/127.0.0.1_$P/token"
[ -d "${tok%/*}" ] || fail "no server dir ${tok%/*}"
echo kept > "$tok"
drive "$t/x.log" "${J}click Button \"×\"\nwait_log 5000 hearth: exit dialog\ndelay 500\nkeypress Q\nwait_log 10000 launch_menu: back to Home\ndelay 1500\nscreenshot $t/home.png\nquit\n"
grep -aq "hearth: the × to the launcher" "$t/x.log" || fail "no × from the launcher"
grep -aq "close_glyph: closing" "$t/x.log" || fail "the × not clicked"
after "$t/x.log" "hearth: exit dialog" | grep -aq "launch_menu: back to Home" ||
	fail "Q did not leave: $(grep -a 'leave\|Home' "$t/x.log" | tail -2)"
[ ! -s "$tok" ] || fail "the kept token not emptied: $tok"
echo "ok: the × then Q exits, the launcher back and the kept token empty"

# 3. Joined straight, no launcher: no ×, Escape is My account
printf 'wait_log 30000 hearth: frame\ndelay 1500\nkeypress Escape\nwait_log 5000 server window: the page\nquit\n' > "$t/cmds"
env BUILDAT_HEARTH_NAME=admin BUILDAT_HEARTH_PASSWORD=checkpass12 \
	timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl2" -w 800x600 -l 3 -o sound_mute=1 \
	-s 127.0.0.1:$P -c @"$t/cmds" > "$t/straight.log" 2>&1 ||
	fail "the straight join's drive: $(grep -a "Command sequence failed" "$t/straight.log" | tail -1)"
grep -aq "hearth: frame" "$t/straight.log" || fail "the straight join"
grep -aq "hearth: the × to the launcher" "$t/straight.log" && fail "a × with no launcher"
grep -av "command: " "$t/straight.log" | grep -aq "hearth: exit dialog" &&
	fail "the dialog with no launcher"
grep -av "command: \|wait_log" "$t/straight.log" | grep -aq "server window: " ||
	fail "Escape did not open My account"
echo "ok: with no launcher, no × and Escape is My account"
echo PASS
