#!/bin/bash
# tier: full
# cost: ~5 min (2026-10-08)
# covers: apps/floorplanner/main/main.cpp apps/floorplanner/main/client_lua/init.lua builtin/accounts/accounts.cpp
# [FP_ABUSE]: floorplanner with open registration, on a --sim-clock server
# moved a day at a time ([SIM_CLOCK]):
#   1. trust: c, in the admin's group, edits on three days and is trusted
#      on the third; b, in a's group of untrusted admins, edits on the
#      same days and is not; with untrusted a made an admin of the admin's
#      group, a vouch there is refused, and with a no longer one it goes;
#   2. invites: 20 waiting a group, and the 21st refused; 50 an inviter a
#      day, and the 51st refused until the next day; after a decline none
#      from that group for 7 days; after "no invites from this group"
#      none at all;
#   3. counts: 10 groups made an account, and the 11th refused; 50 plans
#      an account (49 copied on disk), and the 51st refused;
#   4. the budget at 0: an untrusted account makes no plan, a trusted one
#      does;
#   5. k deleted: k's plan goes, k's group goes to c (trusted) before m1
#      (in it longer), and k's group with nobody else in it is deleted.
#   apps/floorplanner/abuse_check.sh
set -u
. "$(dirname "$0")/../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "/tmp/buildat_fpabuse.XXXXXX")
pids=()
cleanup() {
	for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
	[ -n "${KEEP_TMP:-}" ] && echo "kept $tmp" || rm -rf "${tmp:?}"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; KEEP_TMP=1; exit 1; }
cd "$here"

LOG=$tmp/fp.log
server() {
	start_server "$LOG" "groups$" 180 ${port:-auto} \
		Build/bin/buildat_server --sim-clock -m apps/floorplanner -D "$tmp/fp" \
		-l 3 || fail "the server did not start"
	pids+=($SERVER_PID)
	port=$SERVER_PORT
	export BUILDAT_CONNECT_PORTS=$port
}
# name log [env...]: a client of `name` that quits once its scripts are
# answered (the group's, the admin's, the edit) and WAIT, if set, logged
client() {
	local n=$1 log=$2 e; shift 2
	{
		for e in "$@"; do
			case $e in
			BUILDAT_FP_GROUP=*) echo "wait_log_any 20000 Group script: done";;
			BUILDAT_FP_ADMIN=*) echo "wait_log_any 20000 admin script: done";;
			BUILDAT_FP_EDIT=*) echo "wait_log_any 20000 Scripted edit:";;
			esac
		done
		[ -n "${WAIT:-}" ] && echo "wait_log_any 20000 $WAIT"
		echo quit
	} > "$tmp/c_$log"
	env BUILDAT_FP_NAME=$n BUILDAT_FP_PASSWORD=${n}pass1234 "$@" \
		timeout 120 Build/bin/buildat -o launch_ui=launch_menu -s 127.0.0.1:$port \
		-D "$tmp/cl_$n" -w 640x400 -l 3 -o sound_mute=1 -c @"$tmp/c_$log" \
		> "$tmp/$log.log" 2>&1 ||
		fail "the client $log ($tmp/$log.log): $(grep -a "Command sequence failed\|an error the drive" "$tmp/$log.log" | tail -2)"
}
has() { grep -qa "$1" "$LOG"; }
# The calendar a day (or n days) on, the server seen to take it
T=0
advance() {
	T=$((T + ${1:-1} * 86400))
	echo $T > "$tmp/fp/sim_clock"
	for _ in $(seq 100); do
		has "sim clock: ${T}s ahead" && break
		sleep 0.1
	done
	has "sim clock: ${T}s ahead" || fail "the server did not take the clock to $T"
}
gid() { grep -ao "$1 made the group [0-9]* ($2)" "$LOG" | tail -1 | awk '{print $5}'; }
lines() { local p=$1 i; shift; for i in "$@"; do echo "$p $i"; done; }

server
code=$(grep -ao "setup code [A-Z0-9]*" "$LOG" | tail -1 | awk '{print $3}')
users="a b c d e f g h k m1 $(seq -f 'u%g' 1 50)"
client adm adm0 BUILDAT_FP_CODE=$code BUILDAT_FP_CREATE=1 \
	BUILDAT_FP_PASSWORD=admpass1234 \
	"BUILDAT_FP_ADMIN=$(for u in $users; do echo "add $u ${u}pass1234"; done)"
has "added the account u50" || fail "the accounts ($tmp/adm0.log)"
adm() { client adm "$@" BUILDAT_FP_PASSWORD=admpass1234; }

# 1. Trust
client a a1 "BUILDAT_FP_GROUP=$(printf 'create 0 free\ninvite 1 b')"
adm adm1 "BUILDAT_FP_GROUP=$(printf 'create 0 trusted\ninvite 2 c\ninvite 2 d\ninvite 2 a')"
[ "$(gid a free)" = 1 ] && [ "$(gid adm trusted)" = 2 ] || fail "the groups' ids"
for u in c d a; do client $u ${u}0 "BUILDAT_FP_GROUP=accept 2"; done
client b b0 "BUILDAT_FP_GROUP=accept 1"
edits() {
	client c c$1 BUILDAT_FP_PLAN=pc BUILDAT_FP_EDIT=1
	client b b$1 BUILDAT_FP_PLAN=pb BUILDAT_FP_EDIT=1
	grep -q "Scripted edit: done" "$tmp/c$1.log" || fail "c's edit ($tmp/c$1.log)"
	grep -q "Scripted edit: done" "$tmp/b$1.log" || fail "b's edit ($tmp/b$1.log)"
}
edits 1
has "c edited on a day in a trusted group (1 of 3)" || fail "c's first day"
advance; edits 2
has "c edited on a day in a trusted group (2 of 3)" || fail "c's second day"
has "c is trusted" && fail "c trusted after two days"
advance; edits 3
has "c is trusted: edits on 3 days" || fail "c not trusted on the third day"
has "b edited on a day" && fail "b's days in a's untrusted group counted"
echo "ok: trusted on the third edit day in a trusted group, not in an untrusted one"
adm adm2 "BUILDAT_FP_GROUP=$(printf 'admin 2 a 1\nvouch 2 d')"
grep -qa "Group: Only a trusted group's admins vouch" "$tmp/adm2.log" ||
	fail "a vouch in a group with an untrusted admin ($tmp/adm2.log)"
adm adm3 "BUILDAT_FP_GROUP=$(printf 'admin 2 a 0\nvouch 2 d')"
has "adm vouched for d in the group 2" || fail "the vouch ($tmp/adm3.log)"
echo "ok: a group with an untrusted admin vouches for nobody; a trusted one does"

# 2. Invites: 20 waiting a group, 50 an inviter a day
client a a2 "BUILDAT_FP_GROUP=$(lines 'invite 1' $(seq -f 'u%g' 1 21))"
has "a's invite of u21 to the group 1 refused: This group has 20 invites" ||
	fail "the 21st invite waiting"
client a a3 "BUILDAT_FP_GROUP=$(echo 'create 0 g3'; lines 'invite 3' $(seq -f 'u%g' 21 40))"
g3=$(gid a g3)
client a a4 "BUILDAT_FP_GROUP=$(echo 'create 0 g4'; lines "invite 4" $(seq -f 'u%g' 41 50) e)"
[ "$(gid a g4)" = 4 ] && [ "$g3" = 3 ] || fail "g3 and g4's ids"
has "a's invite of e to the group 4 refused: You have invited 50 today" ||
	fail "the 51st invite of a day"
advance
client a a5 "BUILDAT_FP_GROUP=$(printf 'invite 4 e\ninvite 4 f')"
has "a invited e to the group 4" || fail "the next day's invite"
client e e1 "BUILDAT_FP_GROUP=decline 4"
client f f1 "BUILDAT_FP_GROUP=block 4"
client a a6 "BUILDAT_FP_GROUP=$(printf 'invite 4 e\ninvite 4 f')"
has "invite of e to the group 4 refused: e declined" || fail "the decline's wait"
has "invite of f to the group 4 refused: f takes no invites" || fail "the block"
advance 7
client a a7 "BUILDAT_FP_GROUP=$(printf 'invite 4 e\ninvite 4 f')"
[ "$(grep -ac "a invited e to the group 4" "$LOG")" = 2 ] ||
	fail "e not invited again after 7 days"
[ "$(grep -ac "invite of f to the group 4 refused: f takes" "$LOG")" = 2 ] ||
	fail "f invited after the block"
echo "ok: 20 waiting a group, 50 a day, a decline's 7 days, a block"

# 3. Counts: a has made 3 groups (free, g3, g4)
client a a8 "BUILDAT_FP_GROUP=$(lines 'create 0' $(seq -f 'x%g' 1 8))"
grep -qa "Group: You have made 10 groups" "$tmp/a8.log" || fail "the 11th group ($tmp/a8.log)"
[ "$(grep -ac "a made the group" "$LOG")" = 10 ] || fail "not 10 groups of a"
WAIT="Entered the plan g0" client g g1 BUILDAT_FP_PLAN=g0
grep -qa "Entered the plan g0" "$tmp/g1.log" || fail "g's first plan"
kill -INT $SERVER_PID; wait $SERVER_PID 2>/dev/null
dir=$(find "$tmp/fp" -type d -name g0 | head -1)
[ -n "$dir" ] || fail "no directory of g0"
for i in $(seq 1 49); do cp -r "$dir" "$(dirname "$dir")/g$i"; done
mv "$LOG" "$tmp/fp_1.log"
server
WAIT="Plan refused" client g g2 BUILDAT_FP_PLAN=g50
grep -qa "Plan refused: You have 50 plans" "$tmp/g2.log" || fail "the 51st plan ($tmp/g2.log)"
echo "ok: 10 groups and 50 plans an account"

# 4. The budget
adm adm4 "BUILDAT_FP_ADMIN=setting storage_budget 0"
grep -qa "set the storage budget to 0 MB" "$LOG" || fail "the budget ($tmp/adm4.log)"
WAIT="Plan refused" client h h1 BUILDAT_FP_PLAN=ph
grep -qa "Plan refused: This server's storage for new accounts is full" "$tmp/h1.log" ||
	fail "an untrusted plan past the budget ($tmp/h1.log)"
WAIT="Entered the plan pc2" client c c4 BUILDAT_FP_PLAN=pc2
grep -qa "Entered the plan pc2" "$tmp/c4.log" || fail "a trusted plan past the budget"
adm adm5 "BUILDAT_FP_ADMIN=setting storage_budget 2048"
echo "ok: past the budget an untrusted account makes no plan, a trusted one does"

# 5. k deleted
WAIT="Entered the plan pk" client k k1 BUILDAT_FP_PLAN=pk "BUILDAT_FP_GROUP=$(printf 'create 0 kg\ncreate 0 kalone')"
kg=$(gid k kg); ka=$(gid k kalone)
client k k2 "BUILDAT_FP_GROUP=$(printf "invite $kg m1\ninvite $kg c")"
client m1 m1 "BUILDAT_FP_GROUP=accept $kg"
advance
client c c5 "BUILDAT_FP_GROUP=accept $kg"
adm adm6 "BUILDAT_FP_ADMIN=delete k"
has "The plan pk of the deleted account k deleted" || fail "k's plan stayed"
has "The group $kg (kg) of the deleted account k goes to c" || fail "kg's heir"
has "The group $ka (kalone) deleted with its last member k" || fail "kalone stayed"
echo "PASS: trust through trusted groups, the invite caps, the counts, the budget and a deleted owner"
