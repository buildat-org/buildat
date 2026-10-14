#!/bin/bash
# tier: full
# cost: ~4 min (2026-10-12)
# covers: extensions/ui_utils/init.lua src/client/state.cpp client/api.lua src/client/web/index.html builtin/luanti/client_lua/client.lua apps/vanilla/main/client_lua/init.lua builtin/network/network.cpp
# [JOIN_STRIPES]: the join's wait on the client's two stripes, from the
# first announce to the game's world loading, and the web page's own wait
# in the same stripes. The minimal game's vanilla:
#   1. natively over a link of 300 KB/s (util/netsim.py), an empty cache:
#      a screenshot at the first "join: Files" line shows
#      the stripes (amber line, cyan name); the lines count files; vanilla
#      takes the screen over with no close between, and it closes when
#      the world is in;
#   2. again with the cache full: "Starting the game" on the stripes;
#   3. the floorplanner's join: the screen closes, nobody took it;
#   4. the web page in Chrome over 2.5 MB/s, as a desktop (1200x800) and
#      as a phone (400x800 at 2, a finger): the page's stripes count
#      buildat.wasm and buildat.data in MB (the two at once, the one that
#      moved last said), the line fits the width,
#      and they are where the client's join screen has its (a pixel and
#      a font's rendering apart), in the same colours.
# simplified: compared with the join's screen, not vanilla's: its F5 row
# is wider than a 1200 px window and the client fits the UI down for it
# simplified: the hand-over is read off the log, not from every frame
#   util/join_stripes_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp join_stripes; t=$CHECK_TMP
free_port(){ python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=js start_server "$t/srv.log" \
	"STATUS Listening" 120 auto "$here/Build/bin/buildat_server" -u launcher=1 \
	-A 127.0.0.1 -m "$here/apps/vanilla" -D "$t/srv" -C "$t/srv.cache" -l 3 \
	-W "$here/web" || fail "the server ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
VPORT=$SERVER_PORT
LINK=$(free_port)
# --delay is the link's latency, not a wait; then a poll for its port
python3 "$here/util/netsim.py" --listen "$LINK" --to "127.0.0.1:$VPORT" \
	--delay 0 --rate 2400 > "$t/netsim.log" 2>&1 &
CHECK_PIDS+=($!)
for _ in $(seq 25); do port_taken "$LINK" && break; sleep 0.2; done
port_taken "$LINK" || fail "netsim did not listen ($t/netsim.log)"
# client <n> <port> <commands>
client(){
	printf "%s\ndelay 300\nquit\n" "$3" > "$t/$1.cmds"
	run_client 60 "$t/$1.log" timeout 200 "$here/Build/bin/buildat" -C "$t/c" \
		-D "$t/u$1" -w 1100x800 -l 3 -o sound_mute=1 -s "127.0.0.1:$2" -c @"$t/$1.cmds"
	grep -aq "Command sequence complete" "$t/$1.log" || fail "join $1 ($t/$1.log)"
}
# 1, 2
client 1 "$LINK" "wait_log 120000 join: Files
screenshot $t/files.png
wait_log 120000 load: the world is in
delay 500"
client 2 "$VPORT" "wait_log 120000 load: the world is in
delay 500"
# 3
cd "$here/Build"
start_server "$t/fp.log" "STATUS Listening" 120 auto bin/buildat_server \
	-m ../apps/floorplanner -D "$t/fpsrv" -l 3 || fail "the floorplanner ($t/fp.log)"
CHECK_PIDS+=($SERVER_PID)
cd "$here"
client 3 "$SERVER_PORT" "wait_log 60000 load screen: closed
delay 1000"
python3 - "$t" <<'PY' || fail "the native joins ($t/1.log $t/2.log $t/3.log $t/files.png)"
import re, sys
from PIL import Image
t = sys.argv[1]
def screen(name):
    return [re.split(r" I (?:ui_utils|vanilla ): ", l, maxsplit=1)[1].strip()
            for l in open("%s/%s.log" % (t, name), errors="replace")
            if "I ui_utils: load screen" in l or "I ui_utils: join: " in l or
            "I vanilla : load: the world is in" in l]
one, two, three = screen("1"), screen("2"), screen("3")
for n, s in (("1", one), ("2", two)):
    print("join %s: %s ... %s" % (n, s[:2], s[-3:]))
    assert s[0] == "load screen: made for the join", s[0]
    took = s.index("load screen: taken over by the game")
    assert "load screen: closed" not in s[:took], "closed before the game took it"
    assert s[-2:] == ["load screen: closed", "load: the world is in"], s[took:]
files = [l for l in one if l.startswith("join: Files")]
counts = [int(re.search(r"Files (\d+) of \d+(?: -- \d+ KB/s)?\.\.\. \d+ s", l).group(1)) for l in files]
assert len(counts) >= 2 and max(counts) > counts[0], counts
assert any(l.startswith("join: Starting the game") for l in two), two
print("join 3: %s" % three)
assert three[0] == "load screen: made for the join" and "load screen: closed" in three and \
    "load screen: taken over by the game" not in three, three
im = Image.open(t + "/files.png").convert("RGB")
col = [im.getpixel((5, y)) for y in range(im.height)]
runs = []
for y, c in enumerate(col):
    if runs and runs[-1][0] == c:
        runs[-1][2] = y
    else:
        runs.append([c, y, y])
print("the screenshot's rows: %s" % [(c, b - a + 1) for c, a, b in runs])
assert [c for c, _, _ in runs] == [(21, 21, 26), (27, 27, 34), (21, 21, 26),
        (27, 27, 34), (21, 21, 26)], "not two stripes on the dark"
px = list(im.getdata())
amber = sum(1 for r, g, b in px if r - b > 80 and r > g > b)
cyan = sum(1 for r, g, b in px if g - r > 60 and b - r > 60)
assert amber > 20 and cyan > 20, (amber, cyan)
print("ok: stripes, amber %d and cyan %d pixels" % (amber, cyan))
PY

# 4: the page over 20 Mbit/s, the server's own port behind it
kill "$SERVER_PID"
FAST=$(free_port)
# --delay is the link's latency, not a wait; then a poll for its port
python3 "$here/util/netsim.py" --listen "$FAST" --to "127.0.0.1:$VPORT" \
	--delay 0 --rate 20000 > "$t/netsim_fast.log" 2>&1 &
CHECK_PIDS+=($!)
for _ in $(seq 25); do port_taken "$FAST" && break; sleep 0.2; done
port_taken "$FAST" || fail "netsim did not listen ($t/netsim_fast.log)"
look='["eval", "[document.getElementById(\"load1\").textContent, document.getElementById(\"load2\").textContent, document.getElementById(\"load\").style.display, document.getElementById(\"load1\").scrollWidth <= document.getElementById(\"load1\").clientWidth].join(\" | \")"]'
# The 400 ms waits sample the page's own stripes as the download goes
for v in desktop:1200x800@1:0 phone:400x800@2:1; do
	IFS=: read -r name vp touch <<< "$v"
	steps="[[\"nav\", \"\${URL}\"]"
	for i in 1 2 3 4 5 6; do
		steps="$steps, $look, [\"shot\", \"\${OUT}/page$i.png\"], [\"wait\", 400]"
	done
	steps="$steps, [\"waitlog\", \"load screen: made for the join\", 120], [\"shot\", \"\${OUT}/engine.png\"], $look]"
	echo "$steps" > "$t/$name.json"
	TOUCH=$touch WEB_DRIVE_VIEWPORT=$vp WEB_DRIVE_URL="http://127.0.0.1:$FAST/" \
		"$here/util/web_drive.sh" chrome vanilla "$t/$name.json" "$t/$name" \
		> "$t/$name.txt" 2>&1 || fail "the $name page ($t/$name.txt)"
done
python3 - "$t" <<'PY' || fail "the pages ($t/desktop $t/phone)"
import re, sys
from PIL import Image
t = sys.argv[1]
DARK, PAGE = (21, 21, 26), (27, 27, 34)
def stripes(path):
    im = Image.open(path).convert("RGB")
    col = [im.getpixel((2, y)) for y in range(im.height)]
    runs = []
    for y, c in enumerate(col):
        near = [k for k in (DARK, PAGE) if max(abs(a - b) for a, b in zip(c, k)) <= 2]
        c = near[0] if near else c
        if runs and runs[-1][0] == c:
            runs[-1][2] = y
        else:
            runs.append([c, y, y])
    return [(a, b) for c, a, b in runs if c == PAGE], [c for c, _, _ in runs]
named = set()
for name in ("desktop", "phone"):
    evals = [l.split("eval: ", 1)[1].strip().strip('"') for l in
             open("%s/%s.txt" % (t, name), errors="replace") if "eval: " in l]
    for e in evals:
        print("%s: %s" % (name, e))
    named.update(n for e in evals for n in ("buildat.wasm", "buildat.data")
            if n in e and " MB" in e)
    counts = [tuple(map(float, m.groups())) for m in
              (re.search(r"([\d.]+) of ([\d.]+) MB", e) for e in evals) if m]
    assert any(a < b for a, b in counts), "nothing counted up: %s" % counts
    assert all(e.endswith("true") for e in evals if "| none |" not in e), "a line wider than the page"
    page = None
    for i in range(1, 7):
        s, colors = stripes("%s/%s/page%d.png" % (t, name, i))
        if len(s) == 2:
            page = s
            break
    eng, colors = stripes("%s/%s/engine.png" % (t, name))
    print("%s: the page's stripes %s, the engine's %s" % (name, page, eng))
    assert page and len(eng) == 2, "not two stripes on both"
    # A CSS pixel: two of the phone's
    px = 2 if name == "phone" else 1
    for (a0, b0), (a1, b1) in zip(page, eng):
        assert abs(a0 - a1) <= px and abs(b0 - b1) <= px, "the stripes moved"
# The two come at once, and stripe two says the one that moved last
assert named == {"buildat.wasm", "buildat.data"}, named
print("ok: the page's stripes where the engine's are")
PY
echo "PASS: the join's wait on the client's stripes, taken over by vanilla, closed for the floorplanner; the page's in the same places"
