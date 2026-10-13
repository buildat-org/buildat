#!/bin/bash
# tier: full
# cost: ~3 min (2026-10-12)
# covers: builtin/luanti/client_lua/module.lua
# [CREATIVE_PAGES]: a game that changes the player's inventory formspec
# while it is open has it redrawn. VoxeLibre in creative, the inventory
# open (I); a first run finds the page buttons below the "1 / N" label and
# the search field in a scan, a second clicks them:
#   1. next: "2 / N", other items in the first slot, the form still open;
#   2. prev: "1 / N" again;
#   3. "wool" typed into the search, then next: the field still says it.
# simplified: a survival inventory changed by its game (a crafting result)
# is the same handler and not driven.
# Needs mineclone2 in the desk's games.
#   util/creative_pages_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
G="$BUILDAT_USER_PATH/shared/vanilla/games/mineclone2"
[ -d "$G" ] || skip "no mineclone2"
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp creative_pages; t=$CHECK_TMP
mkdir -p "$t/srv/apps/vanilla/saves/cp/luanti" "$t/srv/shared/vanilla/games"
cp -r "$G" "$t/srv/shared/vanilla/games/"
printf "creative_mode = true\nenable_damage = false\n" > "$t/srv/apps/vanilla/saves/cp/luanti/world.mt"
BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE=cp start_server "$t/srv.log" \
	"STATUS Listening" 120 auto "$here/Build/bin/buildat_server" -u launcher=1 \
	-A 127.0.0.1 -m "$here/apps/vanilla" -D "$t/srv" -C "$t/srv.cache" -l 3 ||
	fail "the server ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
# A VoxeLibre server answers a click seconds late for a while after a
# join (2.5 s seen): a page's answer is waited for up to 15 s. The delays
# of 300 ms: the pointer read where it was put before the click; of 500
# ms, the form drawn in the frames after its line
open="wait_log 120000 load: the world is in
wait_log_any 120000 form: the game set the inventory
keypress i
wait_log 5000 form: the inventory opened
delay 500
event scan 1 p1"
# drive <n> <commands>
drive(){
	printf "%s\nquit\n" "$2" > "$t/$1.cmds"
	run_client 60 "$t/$1.log" timeout 300 "$here/Build/bin/buildat" -C "$t/c" \
		-D "$t/u" -w 1000x700 -l 3 -o sound_mute=1 -s "127.0.0.1:$SERVER_PORT" \
		-c @"$t/$1.cmds" ||
		fail "drive $1 ($t/$1.log: $(grep -a "Command sequence failed\|run_client:" "$t/$1.log" | tail -1))"
	grep -aq "Command sequence complete" "$t/$1.log" || fail "drive $1 ($t/$1.log)"
}

drive 1 "$open"
# The label, the two images below it nearest under it (each button is a
# box and an image at one place), and the search field
at=$(python3 - "$t/1.log" <<'PY'
import re, sys
log = open(sys.argv[1], errors="replace").read()
ui = re.findall(r'scan p1: ui +(\w+) at (-?\d+),(-?\d+) size (\d+)x(\d+)(.*)', log)
lab = [u for u in ui if u[0] == "Text" and re.search(r'text "1 / \d+"', u[5])]
edit = [u for u in ui if u[0] == "LineEdit"]
assert lab and edit, "no label or no field"
lx, ly = int(lab[0][1]), int(lab[0][2])
imgs = sorted({(int(u[2]), int(u[1]), int(u[3]), int(u[4])) for u in ui
        if "image" in u[5] and ly < int(u[2]) < ly + 300 and abs(int(u[1]) - lx) < 60})
assert len(imgs) >= 2, imgs
c = lambda u: "%d %d" % (u[1] + u[3] // 2, u[0] + u[2] // 2)
e = edit[0]
print(c(imgs[0]), c(imgs[1]), int(e[1]) + int(e[3]) // 2, int(e[2]) + int(e[4]) // 2)
PY
) || fail "the buttons not found ($t/1.log)"
set -- $at
prev="$1 $2" next="$3 $4" search="$5 $6"
echo "prev at $prev, next at $next, the search at $search"

# The 300 ms: the click's frames, the hover read before the press, the
# field's focus before the typing and the typing before the next click
drive 2 "$open
mouse_pos $next
delay 300
mouse_click left
wait_log 15000 form: the inventory drawn again
delay 500
event scan 1 p2
screenshot $t/p2.png
mouse_pos $prev
delay 300
mouse_click left
wait_log 15000 form: the inventory drawn again
delay 500
event scan 1 p3
mouse_pos $search
delay 300
mouse_click left
delay 300
text wool
delay 300
mouse_pos $next
delay 300
mouse_click left
wait_log 15000 form: the inventory drawn again
delay 500
event scan 1 p4
screenshot $t/p4.png"
python3 - "$t/2.log" <<'PY' || fail "the pages ($t/2.log, $t/p2.png, $t/p4.png)"
import re, sys
log = open(sys.argv[1], errors="replace").read()
bad = []
def page(l):
    m = re.search(r'scan %s: ui +Text .* text "(\d+) / (\d+)"' % l, log)
    return m and m.group(1)
def first(l):
    # The list starts at the page's first item
    m = re.search(r'scan %s: slot detached:creative_singleplayer:main:\d+ .* item (\S+)' % l, log)
    return m and m.group(1)
for l in ("p1", "p2", "p3", "p4"):
    if not re.search(r'scan %s: form "" open' % l, log):
        bad.append(l + ": no form open")
print("pages %s %s %s, the first slot %s then %s" % (page("p1"), page("p2"),
        page("p3"), first("p1"), first("p2")))
if (page("p1"), page("p2"), page("p3")) != ("1", "2", "1"):
    bad.append("not 1, 2, 1")
if first("p1") is None or first("p1") == first("p2"):
    bad.append("the same first slot on page 2")
m = re.search(r'scan p4: ui +LineEdit .* text "([^"]*)"', log)
print("the search after next: %s" % (m and m.group(1)))
if not m or m.group(1) != "wool":
    bad.append("the search's text not kept")
for b in bad:
    print("FAIL: " + b)
sys.exit(1 if bad else 0)
PY
echo "PASS: VoxeLibre's creative inventory turns its pages while open, the search kept"
