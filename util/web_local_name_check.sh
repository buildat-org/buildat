#!/bin/bash
# tier: full
# cost: ~1 min (2026-10-28)
# covers: src/client/web/index.html src/server/web/pre.js builtin/accounts/accounts_web.cpp
# [WEB_LOCAL_PLAYER_NAME]: a ?local=<app> page (hillclimb, served by
# apps/play's server, headless Chrome) asks the player's name, and the
# page's server has the player in as it; a reload asks nothing and is in as
# the kept name; "change" forgets it, asks again, and the server has the
# new one, which hillclimb's car goes by. A name the server would refuse is
# refused by the page.
# Needs web/ (util/build_web.sh) and web/local/hillclimb
# (util/build_web_server.sh hillclimb).
#   util/web_local_name_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$here/web/local/hillclimb/buildat_server.wasm" ] ||
	skip "no web/local/hillclimb (util/build_web_server.sh hillclimb)"
check_tmp web_local_name; t=$CHECK_TMP
export BUILDAT_STARPORT_DEFAULT=https://127.0.0.1:9

cd "$here/Build"
BUILDAT_LUANTI_LIST=http://127.0.0.1:9 start_server "$t/play.log" \
		"STATUS Listening" 120 auto bin/buildat_server -m ../apps/play \
		-D "$t/play" -C "$t/play.cache" -W "$here/web" -l 3 ||
	fail "the page's server ($t/play.log)"
CHECK_PIDS+=($SERVER_PID)
cat > "$t/steps.json" <<'EOF'
[
	["nav", "${URL}"],
	["waitlog", "local: asking the player's name", 60],
	["type", "a b"],
	["key", "Enter"],
	["eval", "'refused: ' + document.getElementById('name_why').textContent"],
	["selall"],
	["type", "Ann_1"],
	["key", "Enter"],
	["waitlog", "local: playing as Ann_1", 10],
	["waitlog", "server: .*accounts: Ann_1 is in, the page's player", 120],
	["eval", "'kept ' + localStorage.getItem('buildat_local_name')"],
	["nav", "${URL}"],
	["waitlog", "local: (asking|playing as)", 60],
	["waitlog", "server: .*accounts: Ann_1 is in, the page's player", 120],
	["eval", "document.getElementById('name_change').click(), 'change'"],
	["waitlog", "local: asking the player's name", 60],
	["type", "Bob"],
	["key", "Enter"],
	["waitlog", "server: .*accounts: Bob is in, the page's player", 120],
	["waitlog", "W starts your laps", 120],
	["holdkey", "w", 1000],
	["waitlog", "server: .*hillclimb: round: Bob's drive starts the clock", 30]
]
EOF
WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/?local=hillclimb" \
	"$here/util/web_drive.sh" chrome hillclimb "$t/steps.json" "$t/web" > "$t/drive.log" 2>&1 ||
	{ tail -20 "$t/drive.log"; fail "the drive failed ($t/web)"; }
page=$t/web/page.log
grep -a "eval:" "$t/drive.log" | cut -c 1-200
grep -a "local: \(asking\|playing\)\|accounts: .* is in" "$page" | sed 's/.*\(local: \|accounts: \)/\1/' | cut -c1-100
grep -q 'eval: "refused: 1 to 20 letters, digits, - and _"' "$t/drive.log" ||
	fail "a name with a space was not refused"
grep -q 'eval: "kept Ann_1"' "$t/drive.log" || fail "the name was not kept"
# Asked on the first load and after the change, not on the reload
[ "$(grep -ac "local: asking the player's name" "$page")" = 2 ] ||
	fail "asked $(grep -ac "local: asking the player's name" "$page") times, not 2"
[ "$(grep -ac "local: playing as Ann_1" "$page")" = 2 ] || fail "the reload did not play as Ann_1"
grep -a "hillclimb: round: Bob's drive" "$page" | head -1 | sed 's/.*hillclimb: /hillclimb: /'
echo "PASS: the page asks the name once, the server has the player in as it, the reload uses it, and it can be changed"
