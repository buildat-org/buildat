#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# [FORM_ENTER]: the same enter check as form_enter.sh, for
# extensions/luanti_client against official Luanti's server -- the same
# worldmod, the same four rows filtered on Enter. Needs the Luanti checkout
# the way ext_error.sh does.
#
#   builtin/luanti/test/form_enter_ext.sh
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/form_enter_ext"; mkdir -p "$out"
luanti=~/projects/luanti
bin=${LUANTI_BIN:-$luanti/bin/luanti-refshots}
if check_pgrep buildat >/dev/null || pgrep -x luanti-refshots >/dev/null; then
	echo "SKIP: a client or a Luanti server is already running"; exit 77
fi
work="$out/luanti_world"
rm -rf "$work"; mkdir -p "$work/worldmods/form_enter"
cat > "$work/world.mt" <<MT
gameid = mineclone2
backend = sqlite3
player_backend = sqlite3
auth_backend = sqlite3
mod_storage_backend = sqlite3
world_name = form_enter
creative_mode = false
server_announce = false
MT
cp "$me/form_enter.lua" "$work/worldmods/form_enter/init.lua"
printf 'name = form_enter\n' > "$work/worldmods/form_enter/mod.conf"
{ echo "fixed_map_seed = 5"; echo "time_speed = 0"; echo "enable_damage = false"
	echo "mute_sound = true"; } > "$out/luanti.conf"
port=30030
( cd "$luanti" && exec "$bin" --server --world "$work" --port "$port" \
	--config "$out/luanti.conf" > "$out/luanti_srv.log" 2>&1 ) &
srv=$!
trap 'kill "$srv" 2>/dev/null' EXIT
# Up to two minutes for VoxeLibre to load, while the server lives
for i in $(seq 1 600); do
	grep -q "Server for gameid" "$out/luanti_srv.log" 2>/dev/null && break
	kill -0 "$srv" 2>/dev/null || break
	sleep 0.2
done
grep -q "Server for gameid" "$out/luanti_srv.log" 2>/dev/null ||
	{ echo "FAIL: the Luanti server did not come up ($out/luanti_srv.log)"; exit 1; }
fifo="$out/cmds.fifo"; rm -f "$fifo"; mkfifo "$fifo"
BUILDAT_LUANTI_ADDRESS="127.0.0.1:$port" BUILDAT_LUANTI_NAME=fe \
	BUILDAT_LUANTI_CONNECT=1 \
	"$here/Build/bin/buildat" -m luanti_client -w 1280x720 -l 3 -c - \
	< "$fifo" > "$out/cli.log" 2>&1 &
cli=$!
exec 3> "$fifo"
python3 - "$out/cli.log" "$fifo" "$out/luanti_srv.log" <<'PY'
import re, sys, time
log, fifo, srv = sys.argv[1:4]
w = open(fifo, "w")
seen = 0
def write(*cmds):
    for c in cmds:
        w.write(c + "\n")
    w.flush()
UI = re.compile(r'(\w+) at (-?\d+),(-?\d+) size (\d+)x(\d+)(?: text "(.*)")?')
# The settle before a scan: the form drawn in the frames after the
# "opened" line waited for
def scan():
    global seen
    write("delay 800", "event scan a")
    t0 = time.time()
    while time.time() - t0 < 40:
        data = open(log, "rb").read()[seen:].decode("utf-8", "replace")
        if "scan a: done" in data:
            seen = len(open(log, "rb").read())
            els = []
            for line in data.splitlines():
                m = UI.search(line)
                if m and "scan a:" in line:
                    els.append((m.group(1), int(m.group(2)), int(m.group(3)),
                                int(m.group(4)), int(m.group(5)),
                                m.group(6) or ""))
            return els
        time.sleep(0.3)
    return None
def rows(els):
    for e in els or []:
        if e[5].startswith("rows "):
            return e[5]
    return None
def fail(why):
    print("FAIL: " + why); write("quit"); sys.exit(1)
# The client says each time it opens the form (the server shows it again
# on each search): up to <secs> for the <n>th time
def opened(n, secs):
    t0 = time.time()
    while time.time() - t0 < secs:
        if open(log, "rb").read().count(b"form form_enter opened") >= n:
            return True
        time.sleep(0.2)
    return False
# The world's load and the fixture's three seconds after the join
if not opened(1, 120):
    fail("the form was not opened on the client")
els = scan()
before = rows(els)
if before is None:
    fail("no form on the screen; saw " +
         ", ".join("%r" % e[5] for e in els or [])[:300])
edits = [e for e in els if e[0] == "LineEdit" and e[3] > 0]
if not edits:
    fail("no field on the screen")
e = edits[0]
# A few frames for the focus between the steps
write("mouse_pos %d %d" % (e[1] + e[3] // 2, e[2] + e[4] // 2), "delay 200",
      "mouse_click left", "delay 300", "text ap", "delay 300",
      "keypress Return")
# The search's answer, the form shown again; on a timeout the scan below
# says what is there
opened(2, 10)
els = scan()
after = rows(els)
got = [l for l in open(srv, "rb").read().decode("utf-8", "replace").splitlines()
       if "form_enter: fields " in l]
last = got[-1].split("form_enter: fields ")[-1] if got else "nothing"
print("the server received " + last)
print("the form said %r before and %r after" % (before, after))
ok = ("key_enter=true" in last and "key_enter_field=q" in last and
      "q=ap" in last and "quit=nil" in last and
      after == "rows 2: apple apricot")
print("PASS: enter searched and the form stayed open" if ok else
      "FAIL: the enter path is not what a search needs")
write("quit")
sys.exit(0 if ok else 1)
PY
status=$?
exec 3>&-
# The client out first, up to ten seconds
for i in $(seq 1 50); do kill -0 "$cli" 2>/dev/null || break; sleep 0.2; done
kill "$cli" "$srv" 2>/dev/null
for i in $(seq 1 30); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
exit $status
