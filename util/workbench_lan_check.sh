#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min, more with a cold module cache (2026-11-03)
# covers: apps/workbench/main/** builtin/accounts/client_lua/accounts.lua builtin/world_menu/**
# [WB_LAN] Workbench opened to the LAN from its pause menu:
#   1. The launcher starts Workbench (-a app/workbench/new); its own user
#      is logged in without a dialog (as "lanowner", the launcher's
#      default name), makes a project, and opens the pause menu's
#      My account... > Open to LAN > its button: the server listens at
#      the machine's LAN address too, announced as the project
#      ("lanproject", [WB_LAN_NAME]).
#   2. A second client finds it in the connect screen's "This network"
#      (the announce heard on this machine's LAN address), joins and
#      makes an account (lanbob, the login the LAN joiner must pass), and
#      plays without edit rights; its pause menu's Server window has no
#      Open to LAN.
#   3. The owner makes lanbob a builder in My account... > Accounts
#      (Builder: no -> yes): lanbob's Kit editor gets the edit rights.
# Opened only for the run: both clients and the server go at its end.
# KEEP_TMP=1 keeps $t: o_lan.png (the owner's open page), b_menu.png.
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp workbench_lan; t=$CHECK_TMP
cd "$here/Build"
client(){ timeout 600 bin/buildat -o launch_ui=launch_menu -w 1024x700 -l 3 \
	-o sound_mute=1 "$@"; }

# 1, then 3 once lanbob is in; held up (a ceiling) until killed after 2
cat > "$t/o.cmds" <<C
wait_log_any 400000 world_menu: the name screen shown
frames 3
text lanproject
click Button "Create"
wait_log_any 120000 player physics enabled
delay 1000
keypress Escape
wait_log 5000 pause: the menu shown
click Button "My account (lanowner)..."
wait_log 5000 server window: the page account
wait_log_any 5000 server window: the sidebar Account, Pushes (ntfy), Open to LAN, Accounts
click Button "Open to LAN"
wait_log 5000 server window: the page lan
delay 500
click Button "Open to LAN" 900 0
wait_log 10000 Open to LAN: Open to the LAN at
delay 500
screenshot $t/o_lan.png
keypress Escape
wait_log 5000 pause: the menu shown
keypress Escape
wait_log 5000 pause: the menu closed
wait_log 300000 2 accounts listed
delay 2000
keypress Escape
wait_log 5000 pause: the menu shown
click Button "My account (lanowner)..."
wait_log 5000 server window: the page account
click Button "Accounts"
wait_log 5000 server window: the page accounts
delay 1000
click Button "Builder: no"
wait_log 10000 admin result: lanbob is a builder
delay 180000
quit
C
client -o default_username=lanowner -C "$t/co" -D "$t/uo" \
	-a app/workbench/new -c @"$t/o.cmds" > "$t/o.log" 2>&1 &
opid=$!
CHECK_PIDS+=($opid)
for _ in $(seq 3000); do
	grep -aq "accounts: Open to LAN: Open to the LAN at" "$t/o.log" && break
	kill -0 $opid 2>/dev/null ||
		fail "the owner's drive ended ($(grep -a "Command sequence failed" "$t/o.log" | tail -1); $t/o.log)"
	sleep 0.2
done
at=$(grep -ao "Open to the LAN at [0-9.]*:[0-9]*" "$t/o.log" | head -1 | cut -d' ' -f6)
[ -n "$at" ] || fail "not opened ($(grep -a "Open to LAN\|rror" "$t/o.log" | tail -3); $t/o.log)"
grep -aq "Logging in as lanowner on this computer" "$t/o.log" ||
	fail "the owner not logged in without the dialog ($t/o.log)"
grep -aq 'Announced to the LAN as "lanproject"' "$t/o.log" ||
	fail "not announced as the project, lanproject ($(grep -ao 'Announced to the LAN as "[^"]*"' "$t/o.log"); $t/o.log)"
echo "ok: opened at $at from the pause menu's My account..."

# 2, then 3's rights; the last click is to fail, there being no such
# button
cat > "$t/b.cmds" <<C
wait_log_any 60000 Join a Buildat server: shown
click Button "This network"
wait_log_any 10000 This network: 1 heard
delay 300
click Button "lanproject"
delay 300
click Button "Join"
wait_log_any 300000 player physics enabled
delay 2000
keypress Escape
wait_log 5000 pause: the menu shown
frames 3
screenshot $t/b_menu.png
click Button "My account (lanbob)..."
wait_log 5000 server window: the page account
wait_log 120000 kit editor: edit rights: yes
click Button "Open to LAN"
quit
C
BUILDAT_JOIN_NAME=lanbob BUILDAT_JOIN_PASSWORD=lanpass1234 BUILDAT_JOIN_CREATE=1 \
	client -C "$t/cb" -D "$t/ub" -a extension/launch_menu/connect \
	-c @"$t/b.cmds" > "$t/b.log" 2>&1
grep -aq "lanbob joined from ${at%:*}" "$t/o.log" ||
	fail "lanbob did not join over the LAN ($(grep -a "Command seq\|click:" "$t/b.log" | tail -3); $t/b.log)"
grep -aq "New account lanbob" "$t/o.log" || fail "lanbob made no account ($t/o.log)"
# None before the grant (the owner's wait for lanbob came after its menu)
awk '/kit editor: edit rights: yes/ { exit 1 } /pause: the menu shown/ { exit 0 }' \
	"$t/b.log" || fail "lanbob had edit rights before the grant ($t/b.log)"
grep -aq "kit editor: edit rights: yes" "$t/b.log" ||
	fail "lanbob not given edit rights ($(grep -a "Command seq" "$t/b.log" | tail -1); $t/o.log)"
grep -aq 'click: no visible, uncovered Button "Open to LAN"' "$t/b.log" ||
	fail "lanbob has Open to LAN ($t/b.log)"
echo "PASS: Workbench opened to the LAN at $at from the pause menu (the owner logged in without a dialog), found under This network and joined with a new account, which the owner made a builder in the Accounts page"
# vim: set noet ts=4 sw=4:
