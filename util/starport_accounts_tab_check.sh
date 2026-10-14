#!/bin/bash
# tier: broken
# broken: back to full; the second Accounts open did not reopen (dev); no
#   acc1 shot (the branch) (local/runs/dev_baseline)
# cost: ~30s (2026-10-04)
# covers: apps/starport/main/client_lua/init.lua builtin/accounts/client_lua/accounts.lua
# [STARPORT_ACCOUNTS_TAB]: the Starport app's Accounts tab (the accounts
# module's page, opened through its own window) must open every time, from
# every tab. It used to open only once: a Starport-native page's open()
# removed the view element out from under the accounts module, whose M.page
# then pointed at a removed element; the next open of Accounts aborted in
# accounts' close_page ("UIElement was removed"), so the tab's button lit up
# but the view stayed the other tab's.
#
# The drive, as the Starport's admin: Accounts, Overview, Accounts. The same
# page drawn twice in one run is byte-identical, so acc1 == acc2 (Accounts
# both times) and != ov (Overview); and the abort's error must not appear.
#
#   util/starport_accounts_tab_check.sh    (SHOT=dir keeps the screenshots)
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
cd "$here/Build"
[ -x bin/buildat_server ] || { echo "FAIL: no bin/buildat_server"; exit 1; }
[ -x bin/buildat ] || { echo "FAIL: no bin/buildat"; exit 1; }
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }

check_tmp starport_tab; t=$CHECK_TMP
nolog(){ cat "$1"; }

port=29645
# The first start compiles the builtin modules (rccpp); allow for it
start_server "$t/sp.log" "setup code" 90 "$port" \
	bin/buildat_server -m ../apps/starport -D "$t/sp" -l 3 ||
	fail "the Starport did not start (sp.log)"
CHECK_PIDS+=($SERVER_PID)
code=$(grep -o "setup code [A-Z0-9]*" "$t/sp.log" | cut -d' ' -f3)
[ -n "$code" ] || fail "the Starport did not start (sp.log)"

# The sidebar buttons at a 1280x800 window: Overview at the top, Accounts the
# bottom Admin entry. The first with the setup code is the admin, so the
# Admin section (with Accounts) is there, once the users list is in. The
# delays: the sidebar made again the frame after the list, and a page's
# own request answered and drawn after its line
cat > "$t/cmds" <<EOF
wait_log_any 30000 accounts listed
delay 1000
mouse_pos 375 377
mouse_click left
wait_log 5000 server window: the page
delay 1000
screenshot $t/acc1.png
mouse_pos 375 96
mouse_click left
wait_log 5000 server window: the page
delay 1000
screenshot $t/ov.png
mouse_pos 375 377
mouse_click left
wait_log 5000 server window: the page
delay 1000
screenshot $t/acc2.png
quit
EOF
BUILDAT_SP_NAME=admin BUILDAT_SP_PASSWORD=checkpass BUILDAT_SP_CREATE=1 \
	BUILDAT_SP_CODE="$code" \
	timeout 60 bin/buildat -o launch_ui=launch_menu -D "$t/cl" -w 1280x800 -l 3 -o sound_mute=1 \
	-s "127.0.0.1:$port" -c @"$t/cmds" > "$t/cl.log" 2>&1
[ -n "${SHOT:-}" ] && cp "$t"/acc1.png "$t"/ov.png "$t"/acc2.png "$SHOT/" 2>/dev/null

for f in acc1 ov acc2; do
	[ -s "$t/$f.png" ] || fail "no $f screenshot ($(nolog "$t/cl.log" | tail -3))"
done
# The abort the bug raised, on the second Accounts open
nolog "$t/cl.log" | grep -qF 'UIElement "" was removed' &&
	fail "the Accounts page's close_page aborted on a removed element"
# Accounts drawn twice is the same; Overview between is not
cmp -s "$t/acc1.png" "$t/acc2.png" ||
	fail "the second Accounts open did not match the first (it did not reopen)"
cmp -s "$t/acc1.png" "$t/ov.png" &&
	fail "Accounts and Overview look the same -- the tabs did not switch"

echo "PASS: the Accounts tab opens again after another tab"
