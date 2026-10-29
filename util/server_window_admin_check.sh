#!/bin/bash
# tier: full
# cost: ~2 min (2026-10-29)
# covers: builtin/accounts/client_lua/accounts.lua apps/skeldat/main/client_lua/pause.lua apps/hillclimb/main/client_lua/init.lua apps/vanilla/main/client_lua/pause.lua
# [SKELDAT_STARPORT_SETTINGS]: on a public skeldat and hillclimb server
# (starport_announce loaded), the admin made by the setup code opens the
# pause menu's Settings..., then Server...: the Server window's sidebar has
# Starports, Listing and ID logins. The window is the game's own
# accounts.lua instance, which the join's hello did not reach.
# Screenshots in $t (KEEP_TMP=1 keeps it).
#   util/server_window_admin_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp server_window_admin; t=$CHECK_TMP
trap check_cleanup EXIT
export BUILDAT_STARPORT_DEFAULT=https://127.0.0.1:9

# <app> <in-game log line> [VAR=value ...]
admin_sees()
{
	local app=$1 placed=$2; shift 2
	start_server "$t/$app.srv.log" "STATUS Listening" 300 auto env "$@" \
		"$here/Build/bin/buildat_server" -m "$here/apps/$app" \
		-D "$t/$app/srv" -C "$t/$app/srv.cache" -l 3 ||
		fail "$app: the server ($t/$app.srv.log)"
	CHECK_PIDS+=($SERVER_PID)
	local code
	code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/$app.srv.log" | head -1)
	[ -n "$code" ] || fail "$app: no setup code ($t/$app.srv.log)"
	# The setup code's admin is asked for a ntfy topic first
	cat > "$t/$app.cmds" <<C
wait_log 30000 accounts: ntfy asked
wait_log_any 5000 server window: the page ntfy
delay 300
click Button "Don't add"
wait_log 5000 server window: closed
wait_log_any 120000 $placed
delay 1000
keypress Escape
wait_log 5000 pause: the menu shown
delay 500
click Button "Settings..."
wait_log 5000 Game settings shown
delay 1000
mouse_pos 550 500
$(for _ in $(seq 20); do echo "mouse_wheel -1"; done)
delay 500
click Button "Server..."
wait_log 5000 Statistics, Health
delay 1000
screenshot $t/$app.server.png
quit
C
	BUILDAT_JOIN_NAME=boss BUILDAT_JOIN_PASSWORD=secret123 BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_CODE="$code" run_client 60 "$t/$app.cli.log" timeout 300 \
		"$here/Build/bin/buildat" -C "$t/$app/c" -D "$t/$app/u" -w 1100x1000 \
		-l 3 -o sound_mute=1 -s "127.0.0.1:$SERVER_PORT" -c @"$t/$app.cmds" ||
		fail "$app: the drive ($t/$app.cli.log)"
	kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
	local last
	last=$(grep -a "server window: the sidebar" "$t/$app.cli.log" | tail -1)
	echo "  $app: ${last#*the sidebar }"
	[[ $last == *"Starports, Listing, ID logins"* ]] ||
		fail "$app: the admin's Server window has no Starport entries ($t/$app.cli.log)"
}

admin_sees skeldat "skeldat: placed at" BUILDAT_SKELDAT_WORLD=w \
	BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="1 -1 0" \
	BUILDAT_SKELDAT_INTRO=0 BUILDAT_SKELDAT_STARTER=0
admin_sees hillclimb "hillclimb: this client's car is" BUILDAT_HILLCLIMB_FEATURES=0
echo "PASS: skeldat's and hillclimb's admin sees Starports, Listing and ID logins in Settings... > Server..."
