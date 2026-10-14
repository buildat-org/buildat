#!/bin/bash
# tier: broken
# broken: back to full; vanilla let op in twice (dev); the admin's client
#   (the branch) (local/runs/dev_baseline)
# cost: 3 min (two floorplanner rounds and a vanilla one, 2026-10-03)
# covers: builtin/accounts/** apps/floorplanner/main/main.cpp
# [FP_TWO_CLIENTS]: **one user, two clients at once**. An admin makes the
# account "pl"; two clients log in as pl into the same plan.
#   1. A switches to editing, B stays viewing: one connection editing.
#   2. A leaves, B carries on and switches to editing: a second one.
#   3. Both again, and the admin kicks pl: both are kicked.
#   4. Both again, and the admin resets pl's password: both are ended.
#   5. vanilla refuses the second login of a name.
# Read from the server's log ("is editing", "kicked:") and the clients'.
#
#   apps/floorplanner/two_clients.sh
set -u
. "$(dirname "$0")/../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
out="$here/local/two_clients"
rm -rf "$out"; mkdir -p "$out"
cd "$here/Build"
port=29891
fail=0
pids=()
trap 'for p in "${pids[@]}"; do kill -INT "$p" 2>/dev/null; done' EXIT

server() { # app user_dir log
	start_server "$3" "setup code" 90 $port bin/buildat_server -m ../apps/$1 -D "$2" -l 3 ||
		{ echo "FAIL: the $1 server ($3)"; exit 1; }
	pids+=($SERVER_PID)
}
# cmds: a file, or - for standard input
client() { # env_prefix name password code cmds log [extra env]
	local p=$1 n=$2 pw=$3 c=$4 cmds=$5 log=$6; shift 6
	[ "$cmds" = - ] || cmds=@$cmds
	env "${p}_NAME=$n" "${p}_PASSWORD=$pw" "${p}_CODE=$c" "$@" \
		timeout 150 bin/buildat -o launch_ui=launch_menu -s localhost:$port -D "$out/cli_$(basename "$log" .log)" \
		-w 640x400 -l 3 -c "$cmds" > "$log" 2>&1
}
cmds() { local n=$1; shift; printf '%s\n' "$@" > "$out/$n.txt"; }
# log_wait <log> <regex> <seconds> <pid>: the line, while the pid lives
log_wait() {
	local i
	for i in $(seq $(($3 * 5))); do
		grep -aqE "$2" "$1" 2>/dev/null && return 0
		kill -0 "$4" 2>/dev/null || break
		sleep 0.2
	done
	grep -aqE "$2" "$1" 2>/dev/null
}

server floorplanner "$out/fp" "$out/fp.log"
code=$(grep -ao "setup code [A-Z0-9]*" "$out/fp.log" | tail -1 | awk '{print $3}')
cmds adm "wait_log_any 20000 admin script: done" "quit"
client BUILDAT_FP adm adminpass12 "$code" "$out/adm.txt" "$out/adm.log" \
	"BUILDAT_FP_ADMIN=add pl plpass1234" ||
	{ echo "FAIL: the admin's client ($out/adm.log)"; exit 1; }
grep -a "admin result" "$out/adm.log" | sed 's/.*accounts: /admin: /'

# 1 and 2. "Start editing" is the toolbar's last button. A and B read
# their drives from fifos, fed as the other gets on: B joins while A
# edits, and edits once A is gone
edit="mouse_pos 230 12"
mkfifo "$out/a.fifo" "$out/b.fifo"
client BUILDAT_FP pl plpass1234 "" - "$out/a.log" BUILDAT_FP_PLAN=p1 < "$out/a.fifo" &
ca=$!
exec 3> "$out/a.fifo"
# A settle after the line: the toolbar drawn before the click
printf '%s\n' "wait_log_any 30000 Entered the plan" "delay 500" "$edit" "mouse_click left" >&3
log_wait "$out/a.log" "Privileges: .*\<edit\>" 40 $ca ||
	{ echo "FAIL: the first client of pl did not start editing ($out/a.log)"; exit 1; }
client BUILDAT_FP pl plpass1234 "" - "$out/b.log" BUILDAT_FP_PLAN=p1 < "$out/b.fifo" &
cb=$!
exec 4> "$out/b.fifo"
log_wait "$out/b.log" "Entered the plan|Login refused" 40 $cb
echo quit >&3; exec 3>&-
wait $ca
printf '%s\n' "$edit" "mouse_click left" "wait_log 10000 Privileges:" "quit" >&4; exec 4>&-
wait $cb
grep -a "is editing" "$out/fp.log" | sed 's/.*main *: //'
ids=$(grep -a "pl (.*) is editing p1" "$out/fp.log" | sed 's/.*(\([0-9]*\)).*/\1/' | sort -u | wc -l)
if ! grep -aq "Joined as pl" "$out/b.log"; then
	echo "FAIL: the second client of pl was refused: $(grep -a "Login refused" "$out/b.log" | head -1)"; fail=1
elif [ "$ids" -ne 2 ]; then
	echo "FAIL: $ids connections editing, not one and then the other"; fail=1
else
	echo "ok: one client edits while the other views; the other carries on and edits"
fi

# 3 and 4: the admin acts on both
for act in "kick pl|kicked by adm" "password pl newpass1234|the password was reset by adm"; do
	req=${act%%|*} why=${act##*|}
	# Both in the plan until the admin's act reaches them; the drop after
	# it is theirs
	cmds a "expect_error Disconnected from server" "wait_log_any 30000 Entered the plan" \
		"wait_log 60000 $why" "quit"
	client BUILDAT_FP pl plpass1234 "" "$out/a.txt" "$out/a2.log" BUILDAT_FP_PLAN=p1 &
	ca=$!
	client BUILDAT_FP pl plpass1234 "" "$out/a.txt" "$out/b2.log" BUILDAT_FP_PLAN=p1 &
	cb=$!
	log_wait "$out/a2.log" "Entered the plan" 40 $ca && log_wait "$out/b2.log" "Entered the plan" 40 $cb ||
		{ echo "FAIL: pl's two clients are not both in the plan ($out/a2.log, $out/b2.log)"; exit 1; }
	client BUILDAT_FP adm adminpass12 "" "$out/adm.txt" "$out/adm2.log" \
		"BUILDAT_FP_ADMIN=$req" ||
		{ echo "FAIL: the admin's client ($out/adm2.log)"; exit 1; }
	wait $ca $cb
	n=$(grep -ac "pl kicked: $why" "$out/fp.log")
	[ "$n" -ge 2 ] && echo "ok: '$req' reached both connections" ||
		{ echo "FAIL: '$req' reached $n of 2"; fail=1; }
done
kill -INT "${pids[@]}" 2>/dev/null
wait "${pids[@]}" 2>/dev/null

# 5. vanilla: one name, one connection
server vanilla "$out/va" "$out/va.log"
vcode=$(grep -ao "setup code [A-Z0-9]*" "$out/va.log" | tail -1 | awk '{print $3}')
# The first in from a fifo, there until the second is answered
mkfifo "$out/v.fifo"
client BUILDAT_JOIN op adminpass12 "$vcode" - "$out/v1.log" < "$out/v.fifo" &
cv=$!
exec 3> "$out/v.fifo"
log_wait "$out/v1.log" "Joined as op" 60 $cv ||
	{ echo "FAIL: op did not join vanilla ($out/v1.log)"; exit 1; }
cmds v "wait_log_any 30000 Login refused" "quit"
client BUILDAT_JOIN op adminpass12 "" "$out/v.txt" "$out/v2.log"
echo quit >&3; exec 3>&-
wait $cv
if grep -aq "Login refused: op is already here" "$out/v2.log"; then
	echo "ok: vanilla refuses a second login of a name"
else
	echo "FAIL: vanilla let op in twice"; fail=1
fi
[ $fail = 0 ] && echo "PASS: one user from two clients, both live, and the admin reaches both"
exit $fail
# vim: set noet ts=4 sw=4:
