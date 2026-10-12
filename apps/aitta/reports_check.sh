#!/bin/bash
# tier: full
# cost: 90s (2026-10-09)
# covers: apps/aitta/main/main.cpp apps/aitta/main/client_lua/init.lua client/extensions/starport/init.lua client/extensions/aitta/init.lua client/launch_grid.lua
# [AITTA_REPORTS]: a local Aitta with its admin, a second moderator (mod2)
# and an author (author1, bound to tester); tester/pk and tester/pk2
# published, pk installed on a launcher.
#   1. Reports on pk: one anonymous, one from the launcher's Aitta page
#      (Report..., its reason, Send) with its key; weighed 0.01 and 0.1,
#      one network so the group weighs 0.1, past the hide threshold (0.05
#      here): pk is out of the list. A web form's report on pk2 is taken.
#   2. The admin upholds pk's group as a delist: the author's statement;
#      the author appeals; the admin may not decide it, mod2 reverses it:
#      pk listed again. The key's receipt reads upheld. The statement
#      is not appealed twice; the admin's own delist and relist are in
#      the audit log and stated to the author.
#   3. While pk is delisted, the launcher's Aitta page notes it on the
#      installed tile: "Delisted by its Aitta" and why.
#   4. A bar: tester's next release refused.
# Screenshots in $t (KEEP_TMP=1 keeps it).
#
#   apps/aitta/reports_check.sh
set -u
. "$(dirname "$0")/../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
b="$here/Build/bin/buildat"
t=$(mktemp -d)
pid=
trap '[ -n "$pid" ] && kill $pid 2>/dev/null; [ -n "${KEEP_TMP:-}" ] && echo "kept $t" || rm -rf "${t:?}"' EXIT
fail(){ echo "FAIL: $*"; KEEP_TMP=1; exit 1; }

cd "$here/Build"
start_server "$t/srv.log" "setup code" 120 auto \
	bin/buildat_server -m ../apps/aitta -D "$t/srv" -l 3 ||
	fail "Aitta did not start"
pid=$SERVER_PID
P=$SERVER_PORT
A=http://127.0.0.1:$P
code=$(grep -ao "setup code [A-Z0-9]*" "$t/srv.log" | cut -d' ' -f3)
[ -n "$code" ] || fail "no setup code"
"$b" aitta keygen "$t/key" > "$t/pub" 2>/dev/null || fail "keygen"

admin(){ env BUILDAT_AITTA_CREATE=1 BUILDAT_AITTA_NAME=admin \
	BUILDAT_AITTA_PASSWORD=checkpass BUILDAT_AITTA_CODE=$code "$@"; }
author1(){ env BUILDAT_AITTA_NAME=author1 BUILDAT_AITTA_PASSWORD=authpass12 "$@"; }
mod2(){ env BUILDAT_AITTA_NAME=mod2 BUILDAT_AITTA_PASSWORD=modpass123 "$@"; }
reqs(){ # who log requests...
	local who=$1 log=$2; shift 2
	printf 'delay 8000\nquit\n' > "$t/reqs.cmds"
	$who BUILDAT_AITTA_REQS="$(printf '%s\n' "$@")" \
		timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl_$who" \
		-w 800x600 -l 3 -s 127.0.0.1:$P -c @"$t/reqs.cmds" > "$log" 2>&1
}
ans(){ grep -a "ai: {\"id\":$2,\"ok\":true" "$1"; }
listed(){ curl -s "$A/api/v1/aitta/list" | python3 -c 'import json,sys
sys.exit(0 if any(r["name"] == sys.argv[1] for r in json.load(sys.stdin)["releases"]) else 1)' "$1"; }

BUILDAT_AITTA_ADMIN="$(printf 'add author1 authpass12\nadd mod2 modpass123\nlevel mod2 30')" \
	reqs admin "$t/setup.log" \
	'{"cmd":"set_settings","settings":{"thresholds":{"default":{"hide":0.05,"delist":100}}}}'
ans "$t/setup.log" 1 > /dev/null || fail "the settings: $(grep -a 'ai: ' "$t/setup.log")"
reqs author1 "$t/bind.log" \
	"{\"cmd\":\"bind\",\"author\":\"tester\",\"key\":\"$(cat "$t/pub")\"}"
ans "$t/bind.log" 1 > /dev/null || fail "the bind: $(grep -a 'ai: \|refused' "$t/bind.log")"
mkdir -p "$t/app"
cp -r ../apps/minigame/main ../apps/minigame/launcher "$t/app/"
publish(){
	printf '{"author": "tester", "name": "%s", "version": "1.0.0",
		"engine_api": 2, "license_code": "MIT", "license_media": "CC0-1.0",
		"description": "a reports check"}\n' "$1" > "$t/app/meta.json"
	zip=$("$b" aitta pack "$t/app" "$t/key" "$t/out" 2>/dev/null) || fail "pack $1"
	"$b" aitta publish "$zip" 127.0.0.1:$P > "$t/publish_$1.log" 2>&1
}
publish pk; grep -q "listed: tester/pk" "$t/publish_pk.log" || fail "publish pk"
cp "$zip" "$t/pk.zip"; cp "${zip%.zip}.sig" "$t/pk.sig"
publish pk2; grep -q "listed: tester/pk2" "$t/publish_pk2.log" || fail "publish pk2"
# pk installed on the launcher's client, as from the Aitta page
"$b" aitta install "$t/pk.zip" "$t/cl_lnch" > "$t/install.log" 2>&1 ||
	fail "install: $(tail -2 "$t/install.log")"

# 1. The reports
key=$(printf '%064d' 7)
curl -s -X POST -d '{"release":"tester/pk/1.0.0","reason":"broken","text":"anonymous"}' \
	"$A/api/v1/aitta/report" | grep -q '"ok":true' || fail "the anonymous report"
curl -s -X POST --data-urlencode "release=tester/pk2/1.0.0" -d reason=other \
	--data-urlencode "text=from the web" "$A/api/v1/aitta/report" |
	grep -q "Sent; a moderator will look" || fail "the web form's report"
echo "{\"aittas\": [\"$A\"]}" > "$t/managed.json"
cat > "$t/report.cmds" <<C
delay 4000
text apps from aitta
delay 1000
keypress Return
wait_log 10000 Asking the user about $A
delay 1000
click Button "Accept"
wait_log 15000 aitta page: tester/pk 1.0.0
delay 1000
click Button "Report..."
wait_log 10000 aitta report: tester/pk/1.0.0
delay 800
click Button "Broken"
delay 500
click Button "Send"
wait_log 10000 aitta report: sent tester/pk/1.0.0 broken
delay 1000
screenshot $t/report.png
quit
C
BUILDAT_STARPORT_MANAGED="$t/managed.json" timeout 90 bin/buildat \
	-m launch_menu -D "$t/cl_lnch" -w 1024x700 -l 3 -c @"$t/report.cmds" \
	> "$t/report.log" 2>&1
# Not the wait_log's own echo of the line
mine(){ grep -a "$1" "$2" | grep -av "command: \|wait_log: "; }
mine "aitta report: sent tester/pk/1.0.0 broken" "$t/report.log" > /dev/null ||
	fail "the launcher's report ($(grep -a "aitta report\|Command seq\|click" "$t/report.log" | tail -3))"
# And one by a key the check knows, for its receipt's outcome
receipt=$(curl -s -X POST -d "{\"release\":\"tester/pk/1.0.0\",\"reason\":\"broken\",\"key\":\"$key\"}" \
	"$A/api/v1/aitta/report" | grep -o '"receipt":"[0-9a-f]*"' | cut -d'"' -f4)
[ -n "$receipt" ] || fail "the keyed report"
listed pk && fail "pk still listed past the hide threshold"
gid='tester/pk/1.0.0|broken'
reqs admin "$t/queue.log" '{"cmd":"mod_queue"}' \
	"{\"cmd\":\"mod_group\",\"group\":\"$gid\"}"
g=$(ans "$t/queue.log" 2)
echo "$g" | grep -q '"weight":0.01' && echo "$g" | grep -q '"weight":0.1' ||
	fail "the reports' weights: $g"
echo "$g" | grep -q '"auto":"hide"' || fail "the group did not hide: $g"
ans "$t/queue.log" 1 | grep -q 'tester/pk2/1.0.0|other' || fail "no web report in the queue"

# 2. The delist, the statement, the appeal
reqs admin "$t/decide.log" \
	"{\"cmd\":\"mod_decide\",\"group\":\"$gid\",\"decision\":\"uphold\",\"action\":\"delist\",\"text\":\"it does not start\"}"
ans "$t/decide.log" 1 > /dev/null || fail "the uphold: $(grep -a 'ai: ' "$t/decide.log")"
curl -s "$A/api/v1/aitta/list" | grep -q '"why":"broken: it does not start"' ||
	fail "no why in the list's delisted"

# 3. The launcher's tile note, while delisted
cat > "$t/note.cmds" <<C
delay 4000
text apps from aitta
delay 1000
keypress Return
wait_log 15000 aitta page: tester/pk2
delay 1000
keypress Escape
delay 1000
text minigame 1.0.0
delay 1500
screenshot $t/note.png
quit
C
BUILDAT_STARPORT_MANAGED="$t/managed.json" timeout 90 bin/buildat \
	-m launch_menu -D "$t/cl_lnch" -w 1024x700 -l 3 -c @"$t/note.cmds" \
	> "$t/note.log" 2>&1
mine "aitta page: delisted tester.pk@1.0.0: broken: it does not start" "$t/note.log" > /dev/null ||
	fail "no note on the installed one ($(grep -a "aitta page\|Command seq" "$t/note.log" | tail -3))"

reqs author1 "$t/st.log" '{"cmd":"statements"}'
st=$(ans "$t/st.log" 1 | grep -o '"id":"[0-9a-f]*","listing":"tester/pk/1.0.0"' | head -1 | cut -d'"' -f4)
ans "$t/st.log" 1 | grep -q '"action":"delisted"' && [ -n "$st" ] ||
	fail "no statement to the author: $(grep -a 'ai: ' "$t/st.log")"
reqs author1 "$t/appeal.log" \
	"{\"cmd\":\"appeal\",\"statement\":\"$st\",\"text\":\"it starts here\"}"
ans "$t/appeal.log" 1 > /dev/null || fail "the appeal: $(grep -a 'ai: ' "$t/appeal.log")"
reqs admin "$t/ap1.log" '{"cmd":"mod_appeals"}'
ap=$(ans "$t/ap1.log" 1 | grep -o '"by":"author1"[^}]*' | head -1)
apid=$(ans "$t/ap1.log" 1 | grep -o '"id":"[0-9a-f]*"' | head -1 | cut -d'"' -f4)
[ -n "$apid" ] || fail "no appeal open: $(grep -a 'ai: ' "$t/ap1.log")"
reqs admin "$t/ap2.log" \
	"{\"cmd\":\"mod_decide_appeal\",\"appeal\":\"$apid\",\"outcome\":\"reverse\",\"text\":\"mine\"}"
grep -aq 'another moderator than the one who acted' "$t/ap2.log" ||
	fail "the admin decided their own: $(grep -a 'ai: ' "$t/ap2.log")"
reqs mod2 "$t/ap3.log" \
	"{\"cmd\":\"mod_decide_appeal\",\"appeal\":\"$apid\",\"outcome\":\"reverse\",\"text\":\"it starts\"}"
ans "$t/ap3.log" 1 > /dev/null || fail "mod2's reverse: $(grep -a 'ai: \|refused' "$t/ap3.log")"
listed pk || fail "pk not relisted"
# [SEC_RUN4_LEFTOVERS]: the admin's delist and relist in the audit log
# and told to the owner; a decided appeal closes its statement
reqs admin "$t/adm.log" \
	'{"cmd":"delist","release":"tester/pk/1.0.0","text":"a check"}' \
	'{"cmd":"relist","release":"tester/pk/1.0.0"}' '{"cmd":"mod_audit"}'
ans "$t/adm.log" 3 | grep -q '"action":"delist","auto":false,"by":"admin"' &&
	ans "$t/adm.log" 3 | grep -q '"action":"relist","auto":false,"by":"admin"' ||
	fail "the admin's delist and relist not audited: $(grep -a 'ai: {"id":[12]' "$t/adm.log")"
listed pk || fail "pk not relisted by the admin"
reqs author1 "$t/again.log" \
	"{\"cmd\":\"appeal\",\"statement\":\"$st\",\"text\":\"again\"}" \
	'{"cmd":"statements"}'
grep -aq "this statement was appealed already" "$t/again.log" ||
	fail "a decided statement appealed again: $(grep -a 'ai: {"id":1' "$t/again.log")"
ans "$t/again.log" 2 | grep -q '"action":"relisted"[^}]*"reason":"the admin' &&
	ans "$t/again.log" 2 | grep -q '"action":"delisted"[^}]*"reason":"the admin' ||
	fail "no statement of the admin's delist and relist: $(ans "$t/again.log" 2 | head -c 600)"
curl -s -X POST -d "{\"key\":\"$key\",\"receipts\":[\"$receipt\"]}" \
	"$A/api/v1/aitta/report_status" | grep -q '"state":"upheld"' ||
	fail "the receipt's outcome"

# 4. A bar
reqs admin "$t/bar.log" \
	'{"cmd":"mod_decide","group":"tester/pk2/1.0.0|other","decision":"uphold","action":"bar","text":"a check"}'
ans "$t/bar.log" 1 > /dev/null || fail "the bar: $(grep -a 'ai: ' "$t/bar.log")"
sed -i 's/"1.0.0"/"1.0.1"/' "$t/app/meta.json"
zip=$("$b" aitta pack "$t/app" "$t/key" "$t/out" 2>/dev/null) || fail "pack 1.0.1"
"$b" aitta publish "$zip" 127.0.0.1:$P 2>&1 | grep -q "barred from publishing" ||
	fail "a barred author published"
echo "PASS: weighed reports, the automatic hide, a web report; delist, statement, appeal decided by another moderator, once; the admin's delist and relist audited and stated; the tile note; a bar"
