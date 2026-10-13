#!/bin/bash
# tier: full
# cost: 3 min (2026-10-08)
# covers: apps/floorplanner/main/main.cpp apps/floorplanner/main/client_lua/init.lua
# [FP_GROUPS]: groups, invites, shares and the storage limit, as the plan
# says it is done. Clients a, b, c and d, one after another or two at
# once; read from their logs and the server's. The invite's buttons are
# clicked by label ([SEQ_CLICK]), and a covered one refused.
#   apps/floorplanner/groups_check.sh
set -u
. "$(dirname "$0")/../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "/tmp/buildat_fpgroups.XXXXXX")
port=29875
export BUILDAT_CONNECT_PORTS=$port
pids=()
cleanup() {
	for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
	[ -n "${KEEP_TMP:-}" ] && echo "kept $tmp" || rm -rf "${tmp:?}"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; KEEP_TMP=1; exit 1; }
cd "$here"

server() {
	local from=$(($(cat "$tmp/fp.log" 2>/dev/null | wc -l) + 1))
	Build/bin/buildat_server -m apps/floorplanner -D "$tmp/fp" -P $port -l 3 \
		>> "$tmp/fp.log" 2>&1 &
	spid=$!
	pids+=($spid)
	for _ in $(seq 300); do
		tail -n +$from "$tmp/fp.log" | grep -q "groups$" && return
		kill -0 $spid 2>/dev/null || break
		sleep 0.2
	done
	fail "the server did not start ($tmp/fp.log)"
}
# name log waits [env...]: a client of `name` that quits once its log has
# each of `waits` (lines of text, anywhere in the run), or runs the
# command file $CMDS; a failed drive fails the check unless MAY_FAIL
client() {
	local n=$1 log=$2 waits=$3 w; shift 3
	local cmds=${CMDS:-}
	if [ -z "$cmds" ]; then
		cmds="$tmp/c_$(basename "$log" .log)"
		while IFS= read -r w; do
			echo "wait_log_any 20000 $w"
		done <<< "$waits" > "$cmds"
		echo quit >> "$cmds"
	fi
	env BUILDAT_FP_NAME=$n BUILDAT_FP_PASSWORD=${n}pass1234 "$@" \
		timeout 120 Build/bin/buildat -o launch_ui=launch_menu -s 127.0.0.1:$port \
		-D "$tmp/cl_$n" -w 640x400 -l 3 -o sound_mute=1 -c @"$cmds" \
		> "$tmp/$log" 2>&1 || [ -n "${MAY_FAIL:-}" ] ||
		fail "the client $n's drive ($tmp/$log)"
}
# until file has a line matching regex, polled while pid lives
until_in() {
	local f=$1 re=$2 pid=$3
	for _ in $(seq 150); do
		grep -aq "$re" "$f" 2>/dev/null && return
		kill -0 "$pid" 2>/dev/null || break
		sleep 0.2
	done
	fail "no \"$re\" in $f"
}
# The app's own lines, not the drive's commands and waits that quote them
last() { grep -a "$2" "$tmp/$1" | grep -av " __app   : " | tail -1; }

server
code=$(grep -ao "setup code [A-Z0-9]*" "$tmp/fp.log" | tail -1 | awk '{print $3}')
client adm adm.log "admin script: done" BUILDAT_FP_CODE=$code BUILDAT_FP_CREATE=1 BUILDAT_FP_PASSWORD=adminpass12 \
	BUILDAT_FP_NAME=adm "BUILDAT_FP_ADMIN=$(printf 'add a apass1234\nadd b bpass1234\nadd c cpass1234\nadd d dpass1234')"

# a makes a plan and a group
client a a1.log "$(printf 'Entered the plan pa\nGroup script: done')" \
	BUILDAT_FP_PLAN=pa "BUILDAT_FP_GROUP=create 0 friends"
grep -q "a made the group 1 (friends)" "$tmp/fp.log" || fail "no group ($tmp/a1.log)"
# A new account sees no plans
client d d1.log "Plans: "
last d1.log "Plans:" | grep -q "Plans: $" || fail "d sees plans: $(last d1.log Plans:)"
echo "ok: a new account sees no plans"

# b online: the invite's dialog at once, accepted; c offline
# The 500 ms after the invite's line: the page's buttons laid out
printf 'wait_log 30000 Invited to the group friends\ndelay 500\nclick Button "Accept" 283 154\nwait_log 10000 invites to me: 0\nquit\n' > "$tmp/cb"
CMDS="$tmp/cb" client b b1.log "" &
cb=$!
# b on its plans page before the invite
until_in "$tmp/b1.log" "Plans: " $cb
client a a2.log "Group script: done" \
	"BUILDAT_FP_GROUP=$(printf 'invite 1 b\ninvite 1 c\nshare 1 pa viewer')"
wait $cb || exit 1
grep -q "b accepted the invite to the group 1" "$tmp/fp.log" || fail "b did not accept ($tmp/b1.log)"
echo "ok: b, online, accepted at once"
printf 'wait_log 30000 Invited to the group friends\ndelay 500\nclick Button "Decline" 356 154\nwait_log 10000 invites to me: 0\nquit\n' > "$tmp/cc"
CMDS="$tmp/cc" client c c1.log ""
grep -q "c declined the invite to the group 1" "$tmp/fp.log" || fail "c did not decline ($tmp/c1.log)"
echo "ok: c, at the next join, declined"

# b reads pa and cannot edit it; b's copy is b's alone
client b b2.log "Entered the plan pb" BUILDAT_FP_PLAN=pa BUILDAT_FP_COPY=pb
grep -a "Entered the plan pa" -A3 "$tmp/b2.log" | grep -a "Privileges:" | head -1 |
	grep -q "can_edit" && fail "b can edit a read-only share"
grep -q "b copied the plan pa as pb" "$tmp/fp.log" || fail "no copy ($tmp/b2.log)"
client a a3.log "Plans: "
last a3.log "Plans:" | grep -q "pb" && fail "a sees b's copy: $(last a3.log Plans:)"
echo "ok: b reads a's plan, cannot edit it, and b's copy is b's alone"

# Editable: b edits; then removed, b is out of the plan and the group
# The 1 s after the privileges' line: the editor's buttons laid out
printf 'wait_log 40000 Privileges: can_edit\ndelay 1000\nclick Button "Start editing"\nwait_log 20000 no longer let into\nquit\n' > "$tmp/cb3"
CMDS="$tmp/cb3" client b b3.log "" BUILDAT_FP_PLAN=pa &
cb=$!
until_in "$tmp/b3.log" "Entered the plan pa" $cb
client a a4.log "Group script: done" "BUILDAT_FP_GROUP=share 1 pa editor"
until_in "$tmp/fp.log" "b ([0-9]*) is editing pa" $cb
client a a5.log "Group script: done" "BUILDAT_FP_GROUP=remove 1 b"
wait $cb || exit 1
grep -q "b ([0-9]*) is editing pa" "$tmp/fp.log" || fail "b did not edit ($tmp/b3.log)"
echo "ok: an editable share, and b edits"
grep -q "no longer let into" "$tmp/b3.log" || fail "b stayed in pa ($tmp/b3.log)"
client b b4.log "$(printf 'Plans: \nGroups: ')"
last b4.log "Plans:" | grep -q "pa" && fail "b still sees pa"
last b4.log "Groups:" | grep -q "Groups: 0" || fail "b still in the group"
echo "ok: removed, b sees neither a's plan nor the group"

# Past 5 MB: d's plan with 6 MB of pictures, counted from its files
client d d2.log "Entered the plan pd" BUILDAT_FP_PLAN=pd
kill -INT $spid; wait $spid 2>/dev/null
dir=$(find "$tmp/fp" -type d -name pd | head -1)
[ -n "$dir" ] || fail "no directory of pd"
head -c 6000000 /dev/zero > "$dir/images/big.png"
server
client d d3.log "Plan refused: " BUILDAT_FP_PLAN=pe
grep -a "Plan refused: Your plans use" "$tmp/d3.log" ||
	fail "d was not refused ($tmp/d3.log)"

# [SEQ_CLICK]: a click on a button under an open dropdown's list fails and
# names what covers it (the menu's Mode list over "Plan settings...")
# The delays after the two lines are settles (the plan's and the menu's
# layout). simplified: the 800 ms is for the Mode list to open after the
# click, which logs nothing; a line where the dropdown opens would do.
# The click is refused on purpose, which fails the drive (MAY_FAIL).
printf 'wait_log 30000 Entered the plan\ndelay 1500\nkeypress Escape\nwait_log 5000 Pause menu shown\ndelay 500\nmouse_pos 320 145\nmouse_click left\ndelay 800\nclick Button "Plan settings..."\nquit\n' > "$tmp/cd4"
MAY_FAIL=1 CMDS="$tmp/cd4" client d d4.log "" BUILDAT_FP_PLAN=pd
grep -aq 'Button "Plan settings..." at .*: covered by Text "" "dropdown_[0-9]*: Viewing"' "$tmp/d4.log" ||
	fail "a covered click not refused ($tmp/d4.log)"
echo "PASS"
