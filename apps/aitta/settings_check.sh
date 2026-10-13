#!/bin/bash
# tier: full
# cost: ~1 min (2026-10-12)
# covers: apps/aitta/main/client_lua/init.lua apps/aitta/main/main.cpp builtin/accounts/client_lua/accounts.lua
# [AITTA_SETTINGS_PAGE]: a local Aitta and a serverless release on it.
#   1. The admin's client: "Admin" > "Settings" lists every setting with
#      its line; a bad JSON in anon_weight is refused and said; play_url
#      typed into its field is saved, and the release's page then links
#      "Play in the browser" there.
#   2. A plain account: no Settings entry, and the request refused.
# Screenshots in $t (KEEP_TMP=1 keeps it).
#
#   apps/aitta/settings_check.sh
set -u
. "$(dirname "$0")/../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp aitta_settings; t=$CHECK_TMP
b="$here/Build/bin/buildat"

cd "$here/Build"
start_server "$t/srv.log" "setup code" 60 auto \
	bin/buildat_server -m ../apps/aitta -D "$t/srv" -l 3 ||
	fail "Aitta did not start"
CHECK_PIDS+=($SERVER_PID)
P=$SERVER_PORT
code=$(grep -ao "setup code [A-Z0-9]*" "$t/srv.log" | cut -d' ' -f3)
"$b" aitta keygen "$t/key" > "$t/pub" 2>/dev/null || fail "keygen"
admin(){ env BUILDAT_AITTA_CREATE=1 BUILDAT_AITTA_NAME=admin \
	BUILDAT_AITTA_PASSWORD=checkpass BUILDAT_AITTA_CODE=$code "$@"; }
plain(){ env BUILDAT_AITTA_NAME=plain BUILDAT_AITTA_PASSWORD=checkpass2 "$@"; }
client(){ # who log cmds
	$1 timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl_$1" \
		-w 1280x1000 -l 3 -s 127.0.0.1:$P -c @"$3" > "$2" 2>&1
}
# The admin script's answers and the two requests'
printf 'wait_log_any 30000 admin script: done\nwait_log_any 30000 "id":1,\nwait_log_any 30000 "id":2,\nquit\n' > "$t/reqs.cmds"
BUILDAT_AITTA_ADMIN="add plain checkpass2" \
	BUILDAT_AITTA_REQS="{\"cmd\":\"bind\",\"author\":\"tester\",\"key\":\"$(cat "$t/pub")\"}
{\"cmd\":\"set_settings\",\"settings\":{\"page_delay\":0}}" \
	client admin "$t/bind.log" "$t/reqs.cmds"
grep -aq 'ai: {"id":1,"ok":true' "$t/bind.log" || fail "the bind"
mkdir -p "$t/app"
cp -r ../apps/minigame/main ../apps/minigame/launcher "$t/app/"
printf '{"author": "tester", "name": "sl", "version": "1.0.0", "serverless": true,
	"engine_api": 2, "audience": "everyone", "license_code": "MIT", "license_media": "CC0-1.0",
	"description": "a settings check"}\n' > "$t/app/meta.json"
zip=$("$b" aitta pack "$t/app" "$t/key" "$t/out" 2>/dev/null) || fail "pack"
"$b" aitta publish "$zip" 127.0.0.1:$P 2>&1 | grep -q "listed: tester/sl" || fail "publish"
curl -s "http://127.0.0.1:$P/p/tester/sl" | grep -q "Play in the browser" &&
	fail "Play in the browser before play_url is set"

# 1. A field's whole text replaced: shift+Home from its end
replace(){ printf 'click LineEdit "%s"\ndelay 300\nkeypress End\nkeydown shift\nkeypress Home\nkeyup shift\ntext %s\nkeypress Return\n' "$1" "$2"; }
{
	# The ntfy question at the admin's second login, over the page
	echo "wait_log 30000 accounts: ntfy asked"
	printf 'delay 500\nclick Button "Later"\n'
	echo "wait_log 30000 aitta: row"
	echo 'click Button "Settings"'
	echo "wait_log 10000 aitta: settings page"
	echo "delay 1000"
	echo "screenshot $t/settings.png"
	replace 0.01 "0.0x"
	echo "wait_log 10000 aitta: settings page"
	echo "delay 1000"
	echo "screenshot $t/refused.png"
	# play_url two fields after max_size, by Tab: a label of '""' cannot be
	# clicked by its text
	echo 'click LineEdit "50000000"'
	printf 'delay 300\nkeypress Tab\nkeypress Tab\n'
	printf 'keypress End\nkeydown shift\nkeypress Home\nkeyup shift\n'
	echo 'text "https://play.example/"'
	echo "keypress Return"
	echo "wait_log 10000 aitta: setting play_url saved"
	echo "delay 1000"
	echo "screenshot $t/saved.png"
	echo quit
} > "$t/admin.cmds"
client admin "$t/admin.log" "$t/admin.cmds"
grep -aq "Command sequence complete" "$t/admin.log" ||
	fail "the admin's drive ($(grep -a "Command seq\|click\|aitta:" "$t/admin.log" | tail -3))"
for k in anon_weight app_hosting_provider key_weight licences max_size \
		page_delay play_url public_url thresholds update_delay; do
	grep -aq "settings row $k" "$t/admin.log" || fail "no row for $k"
done
grep -aq "setting anon_weight saved" "$t/admin.log" && fail "a bad JSON saved"
grep -aq "aitta: message anon_weight: " "$t/admin.log" || fail "the bad JSON not said"
curl -s "http://127.0.0.1:$P/p/tester/sl" |
	grep -q 'href="https://play.example/#run=tester/sl">Play in the browser' ||
	fail "no Play in the browser link after play_url was set"
echo "ok: the admin's Settings page: a bad JSON refused, play_url saved and linked"

# 2.
printf 'wait_log_any 30000 "id":1,\nwait_log_any 30000 aitta: row\nclick Button "Settings"\nquit\n' > "$t/plain.cmds"
BUILDAT_AITTA_REQS='{"cmd":"settings"}' client plain "$t/plain.log" "$t/plain.cmds"
grep -aq "only the admin reads settings" "$t/plain.log" ||
	fail "the request not refused to a plain account"
grep -aq 'click: no visible, uncovered Button "Settings"' "$t/plain.log" ||
	fail "a Settings entry for a plain account"
echo "PASS: Aitta's Settings page for the admin; none, and the request refused, for a plain account"
