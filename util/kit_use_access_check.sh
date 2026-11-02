#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min (2026-11-02)
# covers: builtin/kit/kit.cpp builtin/kit/api.h builtin/kit/types/region.lua builtin/kit/client_lua/module.lua
# [KIT_USE_ACCESS] who may use an object, in apps/sample_kit (kitbob at
# (0, 1, 0), no edit rights; kitboss builds in Kit's editor). Placed: a
# kit/door D (17, use nobody); kit/buttons 18, 20 and 22, each linked to
# D's toggle; 1x1x1 kit/regions round each button: 19 owned by kitbob,
# 21 owned by kitalice with its use rule owners, 23 owned by kitalice.
# Button 18 and 22 have use owners. kitboss selects D (the inspector's
# use row: $t/inspector.png). End, Run. kitbob uses:
#   D: refused, told "Locked: used through its links only";
#   18: its region's owner, so used: D opens through the link;
#   20: its region's use rule refuses him ("Protected: no using things
#       here");
#   22: not its region's owner ("Locked: its owners' only").
#
#   util/kit_use_access_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_use_access; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1

client() # <name> <log name>: its commands in $t/<log name>.cmds
{
	sed -i "s|@T@|$t|g" "$t/$2.cmds"
	run_client 60 "$t/$2.log" timeout 240 bin/buildat -C "$t/client_cache" \
		-D "$t/cu_$1" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
		-c @"$t/$2.cmds" || fail "client $2 failed ($t/$2.log, $t/srv.log)"
}

{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 10000 admin script: done
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
frames 3
wait_log_any 60000 kit editor: edit rights: yes
click Button "Edit"
wait_log 10000 kit editor: state: 15 entities, 0 to undo
EOF
	n=0; c=15
	edit() { echo "event kit_edit $1"; n=$((n + 1)); echo "wait_log 10000 kit editor: state: $c entities, $n to undo"; }
	place() { c=$((c + 1)); edit "{\"op\": \"place\", \"type\": \"$1\", \"pos\": $2}"; }
	setp() { edit "{\"op\": \"set\", \"id\": $1, \"comp\": 0, \"param\": \"$2\", \"value\": $3}"; }
	link() { edit "{\"op\": \"link\", \"id\": $1, \"comp\": 0, \"output\": \"pressed\", \"to\": 17, \"input\": \"toggle\"}"; }
	region() # <id> <pos> <owner>
	{
		place kit/region "$2"
		setp $1 size '[1, 1, 1]'
		setp $1 owner '"players"'
		setp $1 owners "\"$3\""
	}
	place kit/door '[2, 1, -2]'
	setp 17 use '"nobody"'
	place kit/button '[1, 1, 1]'
	setp 18 use '"owners"'
	link 18
	region 19 '[1, 1, 1]' kitbob
	place kit/button '[-1, 1, 1]'
	link 20
	region 21 '[-1, 1, 1]' kitalice
	setp 21 use '"owners"'
	place kit/button '[-1, 1, -1]'
	setp 22 use '"owners"'
	link 22
	region 23 '[-1, 1, -1]' kitalice
	cat <<'EOF'
event kit_select 17
wait_log_any 5000 kit editor: selected 17
frames 5
screenshot @T@/inspector.png
click Button "End"
wait_log 10000 kit editor: the server is Ended (by kitboss)
click Button "Run"
wait_log 10000 kit editor: the server is Running (by kitboss)
quit
EOF
} > "$t/boss.cmds"
cat > "$t/bob.cmds" <<'EOF'
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 replicated: entity 23 owners = ["kitalice"]
wait_log_any 60000 replicated: entity 17 open = false
event kit_use 17
wait_log 10000 kit: warning: Locked: used through its links only
event kit_use 18
wait_log 10000 replicated: entity 17 open = true
event kit_use 20
wait_log 10000 kit: warning: Protected: no using things here
event kit_use 22
wait_log 10000 kit: warning: Locked: its owners' only
sync 5000
quit
EOF

start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/sample_kit -D "$t/user_kit" -l 3 ||
	fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client kitboss boss
BUILDAT_JOIN_NAME=kitbob client kitbob bob
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
s=$t/srv.log
grep -a "kit/door 17\|A use of entity" "$s" | sed 's/^.* I [a-z_]* *: /  /' |
	cut -c1-150 | tail -8
opened=$(grep -ac "kit/door 17: opened" "$s")
[ "$opened" = 1 ] || fail "door 17 opened $opened times, not once ($s)"
for w in "used through its links only" "Protected: no using things here" \
		"its owners' only"; do
	grep -aqF -- "refused: Locked: $w" "$s" || grep -aqF -- "refused: $w" "$s" ||
		fail "no refusal \"$w\" in $s"
done
[ -s "$t/inspector.png" ] || fail "no screenshot of the inspector ($t)"
echo "PASS: Kit's use access: an object used by nobody refused and told, opened through a link; a region's use rule and an object's owners-only use refuse; screenshot $t/inspector.png"
