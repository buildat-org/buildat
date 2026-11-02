#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~3 min (2026-11-02)
# covers: builtin/kit/** builtin/heightmap/** apps/workbench/**
# [KIT_HEIGHTMAP_REGEN_LOSS] A heightmap World's terrain-tool edits kept
# over regenerations, on Workbench, the admin (kitboss) Ended in edit mode:
#   1. A fresh save: the World a noise grassland heightmap (64x64); a raise
#      stroke at (10,10), a decorate stroke at (20,20); the map made 128
#      wide (a resize) and its height 10 (its generated shape): the raised
#      sample's height the same each time, an unedited one's (40,40)
#      changed, the decorate stroke's decorations kept.
#   2. A restart: the same heights and the builder's decorations; "Regenerate
#      all" (discarding the edits) and its undo (the previous heightmap
#      back); the reset brush on the raised samples (the generator's again).
#   3. A copy of the save whose World row says other parameters (as a code
#      change would make them): the save's heightmap kept, with a warning.
#   util/kit_heightmap_edits_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_WORKBENCH_STONE=1
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_heightmap_edits; t=$CHECK_TMP
cd "$here/Build"

server(){ # <n> <user dir>
	start_server "$t/srv$1.log" "Listening at" 300 auto \
		bin/buildat_server -m ../apps/workbench -D "$2" -l 3 ||
		fail "the server did not come up ($t/srv$1.log)"
	CHECK_PIDS+=($SERVER_PID)
}
client(){ # <name>: its commands in $t/<name>.cmds
	run_client 60 "$t/$1.log" timeout 240 bin/buildat -C "$t/client_cache" \
		-D "$t/cu" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
		-c @"$t/$1.cmds" ||
		fail "client $1 failed ($t/$1.log, $t/srv*.log)"
}
stop(){
	kill -INT "$SERVER_PID" 2>/dev/null
	wait "$SERVER_PID" 2>/dev/null
}
want(){ # <log> <text>...
	local log=$1 w
	shift
	for w in "$@"; do
		grep -aqF -- "$w" "$log" || fail "no \"$w\" in $log"
	done
}
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_NAME=kitboss
n=0
set_w(){ # <param> <json value>
	n=$((n + 1))
	printf 'event kit_edit {"op": "set", "id": 3, "comp": 0, "param": "%s", "value": %s}\nwait_log 20000 entities, %d to undo\n' "$1" "$2" "$n"
}
terrain(){ # <tool> <x> <z> <size> <strength> <stroke>
	printf 'event kit_edit {"op": "terrain", "tool": "%s", "x": %s, "y": 0, "z": %s, "size": %s, "strength": %s, "stroke": %s}\nwait_log 5000 kit editor: terrain: %s\n' \
		"$1" "$2" "$3" "$4" "$5" "$6" "$1"
}
column(){ # <x> <z>
	printf 'event kit_edit {"op": "terrain", "tool": "column", "x": %s, "y": 0, "z": %s}\nwait_log 5000 kit editor: terrain: column at (%s,\n' "$1" "$2" "$1"
}
joined(){
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log 10000 kit editor: state:
EOF
}
# A sample's heights, in order, as the column reads logged them
heights(){ # <log> <x> <z>
	grep -aoP "column at \\($2,$3\\) .*\\($2,$3\\) at \\K[-0-9.]+" "$1"
}

# 1. Edits, a resize, a change of shape
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
EOF
	joined
	cat <<'EOF'
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by kitboss)
event kit_edit {"op": "place", "type": "kit/world", "pos": [0, 1, 0]}
wait_log 10000 entities, 1 to undo
EOF
	n=1
	set_w biome '"grassland"'
	set_w generator '"noise"'
	set_w height 3
	set_w surface '"heightmap"'
	echo "wait_log_any 20000 heightmap: terrain built"
	column 10 10
	column 40 40
	for i in 1 2 3; do terrain raise 10 10 2 5 1; done
	n=$((n + 1))
	terrain decorate 20 20 3 5 2
	n=$((n + 1))
	column 10 10
	set_w width 128
	column 10 10
	column 40 40
	column 100 10
	set_w height 10
	column 10 10
	column 40 40
	echo quit
} > "$t/boss1.cmds"
server 1 "$t/user"
wait_for_log "$t/srv1.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv1.log" | head -1)
BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 client boss1
stop
s=$t/srv1.log
grep -a "Terrain by\|World by\|World: .*edited\|decorations on the heightmap" "$s" | sed 's/^.*kit *: /  /' | cut -c1-200
e=$(heights "$s" 10 10)
g=$(heights "$s" 40 40)
he=$(echo "$e" | sed -n 2p)
[ -n "$he" ] && [ "$he" != "$(echo "$e" | sed -n 1p)" ] || fail "the raise did not raise (10,10): $e ($s)"
[ "$(echo "$e" | sed -n 3p)" = "$he" ] && [ "$(echo "$e" | sed -n 4p)" = "$he" ] ||
	fail "the raised sample not kept over the resize and the height: $e ($s)"
[ "$(echo "$g" | sed -n 1p)" = "$(echo "$g" | sed -n 2p)" ] &&
	[ "$(echo "$g" | sed -n 2p)" != "$(echo "$g" | sed -n 3p)" ] ||
	fail "the unedited sample (40,40): the resize changed it or the height did not: $g ($s)"
heights "$s" 100 10 | grep -q . || fail "no sample at (100,10) after the resize ($s)"
dec=$(grep -aoP 'decorate at \(20,20\) .*, \K\d+(?= decorations \()' "$s" | head -1)
[ "${dec:-0}" -gt 0 ] || fail "the decorate stroke placed none ($s)"
[ "$(grep -ac "decorations on the heightmap (generated), $dec of them a builder's" "$s")" = 2 ] ||
	fail "the decorate stroke's $dec decorations not kept over the resize and the height ($s)"
want "$s" "edited heightmap samples kept over the generated map" \
	"World: the heightmap kept as the previous one"
g1=$(echo "$g" | sed -n 3p)
echo "ok: a raised sample kept at $he over a resize and a change of height, an unedited one generated again, $dec builder's decorations kept"

# 2. A restart; regenerate all and its undo; the reset brush
{
	joined
	column 10 10
	column 40 40
	cat <<'EOF'
event kit_edit {"op": "regenerate_heightmap"}
wait_log 10000 kit editor: state:
EOF
	column 10 10
	cat <<'EOF'
event kit_edit {"op": "undo"}
wait_log 10000 kit editor: state:
EOF
	column 10 10
	terrain reset 10 10 3 2 5
	column 10 10
	echo quit
} > "$t/boss2.cmds"
server 2 "$t/user"
client boss2
stop
s2=$t/srv2.log
grep -a "Terrain by\|World by\|World: .*edited\|decorations on the heightmap\|An undo" "$s2" | sed 's/^.*kit *: /  /' | cut -c1-200
e2=$(heights "$s2" 10 10)
[ "$(echo "$e2" | sed -n 1p)" = "$he" ] || fail "the raised sample after a restart: $e2, not $he ($s2)"
[ "$(heights "$s2" 40 40 | sed -n 1p)" = "$g1" ] || fail "(40,40) after a restart: not $g1 ($s2)"
want "$s2" "decorations on the heightmap (the save's), $dec of them a builder's" \
	"the heightmap generated anew, " "edited samples discarded" \
	"the previous heightmap restored"
[ "$(echo "$e2" | sed -n 2p)" != "$he" ] || fail "regenerate all kept the edit: $e2 ($s2)"
[ "$(echo "$e2" | sed -n 3p)" = "$he" ] || fail "the undo did not bring the edit back: $e2 ($s2)"
r=$(echo "$e2" | sed -n 4p)
[ -n "$r" ] && [ "$r" != "$he" ] || fail "the reset brush left the edit: $e2 ($s2)"
hash2=$(grep -aoP 'column at \(10,10\) .* map hash \K\d+' "$s2" | tail -1)
echo "ok: kept over a restart; regenerate all discarded the edits and its undo brought them back; the reset brush made (10,10) generated again ($r)"

# 3. The World row's parameters changed as code would: the map kept
cp -a "$t/user" "$t/user3"
db=
for f in $(find "$t/user3" -name save.sqlite); do
	[ "$(sqlite3 "$f" "SELECT count(*) FROM store WHERE store = 'kit' AND key = 'world'")" = 1 ] && db=$f
done
[ -n "$db" ] || fail "no save with the World's row in $t/user3"
python3 -I -c '
import json, sqlite3, sys
c = sqlite3.connect(sys.argv[1])
v, = c.execute("SELECT value FROM store WHERE store = ? AND key = ?", ("kit", "world")).fetchone()
r = json.loads(v)
r["params"]["spread"] = r["params"].get("spread", 48) + 7
c.execute("UPDATE store SET value = ? WHERE store = ? AND key = ?", (json.dumps(r), "kit", "world"))
c.commit()' "$db"
{
	joined
	column 10 10
	echo quit
} > "$t/boss3.cmds"
server 3 "$t/user3"
client boss3
stop
s3=$t/srv3.log
want "$s3" "the save's heightmap kept, though the World's parameters differ" \
	"decorations on the heightmap (the save's)" "map hash $hash2"
echo "PASS: a heightmap's terrain-tool edits and a builder's decorations kept over a resize, a change of shape and a restart; regenerate all discarding them, undone; the reset brush; the save's map kept where the World's parameters changed under it"
