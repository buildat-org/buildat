#!/bin/bash
# tier: broken
# broken: back to full; the exit dialog opened 0 times, not 2; the same on
#   the branch (local/runs/dev_baseline)
# cost: ~1.5 min (2026-10-10)
# covers: apps/starport/main/client_lua/init.lua apps/aitta/main/client_lua/init.lua builtin/accounts/client_lua/accounts.lua
# [STARPORT_CLOSE]: a Starport and an Aitta joined from the launcher.
#   1. Starport, at the top: Escape opens "Exit to launcher?" with Exit
#      selected; Escape closes it; Up and Enter (Cancel) closes it; the ×
#      then Q exits, the launcher back and the kept token empty.
#   2. Aitta: the × then Enter exits.
#   3. Starport joined straight (-s, no launcher): no ×, Escape is Account.
# Screenshots in $t (KEEP_TMP=1 keeps it).
#
#   apps/starport/close_check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp starport_close; t=$CHECK_TMP

cd "$here/Build"
serve(){ # app: $P and $code of it
	start_server "$t/$1.log" "setup code" 60 auto \
		bin/buildat_server -m ../apps/$1 -D "$t/$1" -l 3 ||
		fail "$1 did not start"
	CHECK_PIDS+=($SERVER_PID)
	P=$SERVER_PORT
	code=$(grep -ao "setup code [A-Z0-9]*" "$t/$1.log" | cut -d' ' -f3)
}
drive(){ # prefix log commands [client args...]
	local pre=$1 log=$2
	printf "$3" > "$t/cmds"
	shift 3
	env ${pre}_NAME=admin ${pre}_PASSWORD=checkpass12 ${pre}_CREATE=1 \
		${pre}_CODE=$code timeout 90 bin/buildat -o launch_ui=launch_menu \
		-w 800x600 -l 3 -o sound_mute=1 -c @"$t/cmds" "$@" > "$log" 2>&1 ||
		fail "the drive ($log): $(grep -a "Command sequence failed" "$log" | tail -1)"
	grep -aq "Lua runtime error" "$log" && fail "a Lua error in $log"
}
dialogs(){ grep -av "command: \|wait_log" "$1" | grep -ac "accounts: exit dialog"; }
left(){ grep -av "command: \|wait_log" "$1" | grep -aq "launch_menu: back to Home"; }
# The launcher's Home up, the join, and logged in; the 500 ms here and
# before a screenshot or a key on a dialog is for the frames after the line
join(){ printf 'wait_log_any 20000 rows in\\nevent join 127.0.0.1:%s\\nwait_log 30000 server window: This client\\nwait_log_any 20000 Joined as admin\\ndelay 500\\n' $P; }

# 1. Starport
serve starport
drive BUILDAT_SP "$t/keys.log" "$(join)keypress Escape\nwait_log 5000 accounts: exit dialog\ndelay 500\nscreenshot $t/sp_dialog.png\nkeypress Escape\nwait_log 5000 accounts: the exit cancelled\nkeypress Escape\nwait_log 5000 accounts: exit dialog\ndelay 500\nkeypress Up\nkeypress Return\nwait_log 5000 accounts: the exit cancelled\ndelay 500\nscreenshot $t/sp_after.png\nquit\n" -D "$t/cl"
[ "$(dialogs "$t/keys.log")" = 2 ] || fail "the dialog opened $(dialogs "$t/keys.log") times, not 2"
left "$t/keys.log" && fail "a key left the Starport"
echo "ok: Escape opens it, Escape and Up+Enter close it"
tok="$t/cl/servers/127.0.0.1_$P/token"
mkdir -p "${tok%/*}"
# A local client is given no kept token (builtin/accounts): one put there
echo kept > "$tok"
drive BUILDAT_SP "$t/x.log" "$(join)click Button \"×\"\nwait_log 5000 accounts: exit dialog\ndelay 500\nkeypress Q\nwait_log 10000 launch_menu: back to Home\nquit\n" -D "$t/cl"
grep -aq "close_glyph: closing" "$t/x.log" || fail "the × not clicked"
left "$t/x.log" || fail "Q did not leave"
[ ! -s "$tok" ] || fail "the kept token not emptied"
echo "ok: the × then Q exits, the launcher back and the kept token empty"

# 3. Straight, while the Starport is up
printf 'wait_log 30000 server window: This client\nwait_log_any 20000 Joined as admin\ndelay 500\nkeypress Escape\nwait_log 5000 server window: the page account\ndelay 500\nscreenshot %s\nquit\n' "$t/sp_straight.png" > "$t/cmds"
env BUILDAT_SP_NAME=admin BUILDAT_SP_PASSWORD=checkpass12 timeout 90 \
	bin/buildat -D "$t/cl2" -w 800x600 -l 3 -o sound_mute=1 -s 127.0.0.1:$P \
	-c @"$t/cmds" > "$t/straight.log" 2>&1 ||
	fail "the straight join's drive: $(grep -a "Command sequence failed" "$t/straight.log" | tail -1)"
grep -aq "server window: This client" "$t/straight.log" || fail "the straight join"
grep -aq "close_glyph" "$t/straight.log" && fail "a × with no launcher"
[ "$(dialogs "$t/straight.log")" = 0 ] || fail "the dialog with no launcher"
echo "ok: with no launcher, no dialog"

# 2. Aitta
serve aitta
drive BUILDAT_AITTA "$t/aitta.log" "$(join)click Button \"×\"\nwait_log 5000 accounts: exit dialog\ndelay 500\nscreenshot $t/aitta_dialog.png\nkeypress Return\nwait_log 10000 launch_menu: back to Home\nquit\n" -D "$t/cl3"
left "$t/aitta.log" || fail "Aitta's × and Enter did not leave"
echo "ok: Aitta's × then Enter exits"
echo PASS
