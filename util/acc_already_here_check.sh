#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~3 min (2026-11-18)
# covers: builtin/accounts/accounts.cpp builtin/accounts/client_lua/accounts.lua
# [ACC_ALREADY_HERE] A login of an account that is here on another client
# already, on a fresh Workbench save (guests off). The admin (kitboss),
# kept logged in, places a spawner of players, a giver of kit/pickaxe,
# kit/player_state (remember) and kit/game_rules, and Runs it. Then:
#   1. kitbob (A) takes the pickaxe and walks; a second kitbob (G) is
#      asked, and logs in as a guest: guest<n>, the log tying it to kitbob;
#      a third (B) kicks out the other clients: A is gone with "Logged in
#      from another client" and logs in no more, G stays, and B is kitbob
#      where A stood with the pickaxe (Kit saved A at the leave first);
#   2. kitboss kicks kitbob: B and kitbob's guest G both go;
#   3. kitboss here (K0): a wrong password for kitboss is told so, with
#      no question; the kept login (a copy of kitboss's storage) is asked,
#      chooses Leave, gets the login form with no sign-in of its own and
#      logs in there as kitbob; a fourth client kicks out K0 and has the
#      admin's rights (Kit's edit rights).
#   util/acc_already_here_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp acc_already_here; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12
start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
	fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
# client <log name> <user dir> <cmds file> [env...]: in the background,
# its pid in $cpid
client()
{
	local n=$1 d=$2 f=$3
	shift 3
	( [ $# = 0 ] || export "$@"
	run_client 90 "$t/$n.log" timeout 300 \
		bin/buildat -C "$t/client_cache" -D "$t/$d" \
		-s localhost:$SERVER_PORT -w 800x600 -l 3 -c @"$f" ) &
	cpid=$!
	CHECK_PIDS+=($cpid)
}
# Each client's own wait, by its exit status
done_ok() # <log name> <pid>
{
	wait "$2" || fail "client $1 failed ($t/$1.log, $t/srv.log)"
}
want() # <log> <text>...
{
	local log=$1 w
	shift
	for w in "$@"; do
		grep -aqF -- "$w" "$log" || fail "no \"$w\" in $log"
	done
}
# A drive's line logged once it runs ("command: event <name>") marks how
# far it got; a wait for a line it waits for itself would match its own
# "command: wait_log ..." line
await() # <log> <seconds> <regex>
{
	wait_for_log "$1" "$3" "$2" || fail "no \"$3\" in $1 in $2 s"
}
kept() # <log>: the last place kitbob was kept at, "x, y, z"
{
	grep -aoP 'kitbob kept at \(\K[^)]*' "$1" | tail -1
}
# The question, and a button of it
choose()
{
	printf '%s\n' "wait_log_any 60000 is here already: choose" "frames 3" \
		"click Button \"$1\""
}
n=0
edit() { n=$((n + 1)); printf 'event kit_edit %s\nwait_log 10000 entities, %d to undo\n' "$1" "$n"; }
set_() { edit "{\"op\": \"set\", \"id\": $1, \"comp\": 0, \"param\": \"$2\", \"value\": $3}"; }
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log 10000 kit editor: state: 1 entities, 0 to undo
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by kitboss)
EOF
	edit '{"op": "place", "type": "kit/spawner", "pos": [0, 1, -4]}'
	set_ 3 players true
	edit '{"op": "place", "type": "kit/item_giver", "pos": [1, 1, -3]}'
	set_ 4 item '"kit/pickaxe"'
	edit '{"op": "place", "type": "kit/player_state", "pos": [0, 1, 0]}'
	set_ 5 remember true
	edit '{"op": "place", "type": "kit/game_rules", "pos": [0, 1, 0]}'
	set_ 6 building '"creative"'
	cat <<'EOF'
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running (by kitboss)
sync 1000
quit
EOF
} > "$t/boss.cmds"
client boss cu_boss "$t/boss.cmds" BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_KEEP=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on"
done_ok boss $cpid
want "$t/srv.log" "kitboss is kept logged in"
# Its admin script answered, though Workbench's own copy of accounts.lua
# took the answer
want "$t/boss.log" "admin script: done"
# An account made by password is said to join so, not by a kept login
grep -aqE "kitboss joined from \S+ by password and setup code$" "$t/srv.log" ||
	fail "kitboss's join not by password and setup code ($t/srv.log)"

# 1. A, then G a guest of kitbob's, then B kicking A out
cat > "$t/a.cmds" <<'EOF'
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 the server put the player at (0, 1.4, -4)
wait_log_any 60000 player physics enabled
event kit_use 4
wait_log 10000 kit: items: kit/pickaxe x1
keydown W
delay 800
keyup W
sync 2000
event acc_check_walked
wait_log 120000 Logged in from another client
wait_log 10000 leave: Left the server
EOF
client a cu_a "$t/a.cmds" BUILDAT_JOIN_NAME=kitbob BUILDAT_JOIN_CREATE=1
apid=$cpid
await "$t/a.log" 120 "acc_check_walked"
grep -aqE "kitbob joined from \S+ by password$" "$t/srv.log" ||
	fail "kitbob's first join not by password ($t/srv.log)"
{
	choose "Log in as guest"
	echo "wait_log_any 60000 accounts: logged in as guest"
	echo "wait_log 120000 kicked by kitboss"
	echo "wait_log 10000 leave: Left the server"
} > "$t/g.cmds"
client g cu_g "$t/g.cmds" BUILDAT_JOIN_NAME=kitbob
gpid=$cpid
await "$t/g.log" 60 "logged in as guest[0-9]+ by guest"
gname=$(grep -aoP 'Joined as \Kguest[0-9]+' "$t/g.log" | head -1)
[ -n "$gname" ] || fail "G joined as no guest<n> ($t/g.log)"
want "$t/srv.log" "joined as a guest, $gname, from" \
	"proved as kitbob, which is here already"
grep -aq "Left the server" "$t/a.log" && fail "a guest's login kicked A ($t/a.log)"
echo "ok: a second kitbob logged in as $gname, guests off on the server"
{
	choose "Kick out the other clients"
	cat <<'EOF'
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit: items: kit/pickaxe x1
sync 2000
event acc_check_back
wait_log 120000 kicked by kitboss
wait_log 10000 leave: Left the server
EOF
} > "$t/b.cmds"
client b cu_b "$t/b.cmds" BUILDAT_JOIN_NAME=kitbob
bpid=$cpid
await "$t/b.log" 120 "acc_check_back"
wait "$apid"
want "$t/a.log" "Logged in from another client" \
	"leave: Left the server: Logged in from another client"
[ "$(grep -ac 'accounts: Logging in as' "$t/a.log")" = 1 ] ||
	fail "A logged in again by itself ($t/a.log)"
want "$t/srv.log" "kicks out its other clients (1)" \
	"kitbob kicked: Logged in from another client"
p=$(kept "$t/srv.log")
[ -n "$p" ] && [ "$p" != "0, 1, -4" ] || fail "A was not kept where he walked to ($p, $t/srv.log)"
want "$t/srv.log" "kitbob back where they were at ($p) in world"
# Kept at the kick's leave, then put back (Kit's own two lines, in its
# order), and the account's join only after the kick
python3 -I - "$t/srv.log" <<'PY' || fail "kitbob was put back before A's leave was kept ($t/srv.log)"
import sys
lines = open(sys.argv[1], errors="replace").read().splitlines()
at = lambda s: [i for i, l in enumerate(lines) if s in l]
kick = at("kitbob kicked: Logged in from another")[-1]
kept = [i for i in at("kitbob kept at") if i > kick]
back = [i for i in at("kitbob back where they were") if i > kick]
join = [i for i in at("kitbob joined from") if i > kick]
assert kept and back and join and kept[0] < back[0], (kept[:1], back[:1], join[:1])
PY
kill -0 "$gpid" 2>/dev/null || fail "kicking out kitbob's clients took the guest too ($t/g.log)"
echo "ok: B kicked A out (A said why and stayed out); B is kitbob at ($p) with the pickaxe"

# 2. The account's kick reaches its guest
cat > "$t/k0.cmds" <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 admin result: kitbob was kicked
event acc_check_kicked
wait_log 300000 Logged in from another client
wait_log 10000 leave: Left the server
EOF
client k0 cu_k0 "$t/k0.cmds" BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_ADMIN="kick kitbob"
k0pid=$cpid
await "$t/k0.log" 60 "acc_check_kicked"
wait "$bpid"; wait "$gpid"
want "$t/b.log" "kicked by kitboss"
want "$t/g.log" "kicked by kitboss"
want "$t/srv.log" "$gname kicked: kicked by kitboss"
echo "ok: kitboss's kick of kitbob reached kitbob and $gname"

# 3. kitboss here: a wrong password, Leave from a kept login, a kick
printf '%s\n' "wait_log_any 60000 Login refused" "frames 3" quit > "$t/w.cmds"
client w cu_w "$t/w.cmds" BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_PASSWORD=wrongpass99
done_ok w $cpid
want "$t/w.log" "Login refused: Wrong password"
grep -aq "is here already" "$t/w.log" && fail "a wrong password was asked to choose ($t/w.log)"
echo "ok: a wrong password with kitboss here: told so, not asked"
cp -a "$t/cu_boss" "$t/cu_l"
{
	echo "wait_log_any 60000 Logging in as kitboss with the kept login"
	choose "Leave"
	echo "wait_log 10000 accounts: the login page shown"
	echo "frames 3"
	for i in $(seq 12); do echo "keypress Backspace"; done
	cat <<'EOF'
text kitbob
delay 300
keypress Return
delay 300
text checkpass12
delay 300
keypress Return
wait_log_any 60000 Joined as kitbob
sync 1000
quit
EOF
} > "$t/l.cmds"
# The failure's wait (1 s) first
sleep 1
client l cu_l "$t/l.cmds"
done_ok l $cpid
[ "$(grep -ac 'accounts: Logging in as' "$t/l.log")" = 1 ] ||
	fail "the Leave signed in again by itself ($t/l.log)"
want "$t/l.log" "accounts: chose Leave" "accounts: logged in as kitbob by password"
want "$t/srv.log" "left the choice: back to the login"
echo "ok: the kept login was asked, chose Leave, and logged in as kitbob from the form"
{
	choose "Kick out the other clients"
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 kit editor: edit rights: yes
sync 1000
quit
EOF
} > "$t/k.cmds"
client k cu_k "$t/k.cmds" BUILDAT_JOIN_NAME=kitboss
done_ok k $cpid
wait "$k0pid"
want "$t/k0.log" "leave: Left the server: Logged in from another client"
[ "$(grep -ac 'accounts: Logging in as' "$t/k0.log")" = 1 ] ||
	fail "K0 logged in again by itself ($t/k0.log)"
echo "ok: a new client kicked out kitboss's and has the admin's rights"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
echo "PASS: an account here already: asked once proved; kick (the state saved and loaded across), guest (tied to the account) and Leave (no automatic sign-in); a wrong password not asked; a kicked client stays out"
# vim: set noet ts=4 sw=4:
