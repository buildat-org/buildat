#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# [THIRD_PERSON]: the camera key cycled through the three views and each
# shot: local/camera/first.png, behind.png, front.png. The stage is
# camera.lua's floor with a wall two nodes behind the player, and then a
# second floor with nothing behind them at all. Prints the
# chat lines the client logged for the modes.
#
#   builtin/luanti/test/camera.sh
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/camera"
mkdir -p "$out"
save=buildat_test_camera
cd "$here/Build"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "a buildat server or client is already running" >&2; exit 2
fi
rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
# SHOULDER=1 runs with the back view over the shoulder ([OVER_SHOULDER]).
# The client takes it from the settings the module pushes at join, not
# from a key, so it goes into the same file the settings screen writes --
# which is the user's own, hence the copy back on the way out.
settings="$BUILDAT_USER_PATH/shared/vanilla/settings.json"
if [ -n "${SHOULDER:-}" ]; then
	# The backup's path is fixed here and not left to $out, which is
	# reassigned two lines down: a trap body in single quotes expands at
	# exit, so it looked for the copy in the directory that did not have
	# it and the user's own settings kept the flag (2026-09-22)
	bak="$out/settings.json.bak"
	cp "$settings" "$bak"
	trap "cp '$bak' '$settings'" EXIT
	python3 - "$settings" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["third_person_shoulder"] = "1"
json.dump(d, open(p, "w"))
PY
	out="$out/shoulder"; mkdir -p "$out"; rm -f "$out"/*.png
fi
BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$me/camera.lua" \
	start_server "$out/srv.log" "Mods loaded" 400 29778 \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla \
	-l 3 ||
	{ echo "FAIL: the server did not start"; exit 1; }
srv=$SERVER_PID
trap "kill -INT $srv 2>/dev/null${bak:+; cp '$bak' '$settings'}" EXIT
# A look_dir ends when the camera is aimed; the second or so after it is
# the third-person camera settling against the wall. A C is said in the
# chat as the view it turned to.
# The walled stage is camera.lua's, six seconds after the join, said in
# the chat; the 2 s after it is a settle for the stage's nodes
cat > "$out/cmds.txt" <<CMDS
wait_log 60000 the server put the player
wait_log_any 60000 chat: camera: the floor and the wall are placed
delay 2000
look_dir 0 -0.6 1
# a settle: first person is aimed at once, the view drawn after it
delay 500
screenshot $out/first.png
keypress C
wait_log 5000 chat (local): Third person view
delay 1500
screenshot $out/behind.png
event scan
look_dir 1 -0.3 0
# the camera easing to the aim, a second or so of its own (timing)
delay 1200
event scan
screenshot $out/behind_turned.png
look_dir 0 0.8 1
# the camera easing to the aim, a second or so of its own (timing)
delay 1200
screenshot $out/behind_up.png
look_dir 0 -0.8 1
# the camera easing to the aim, a second or so of its own (timing)
delay 1200
screenshot $out/behind_down.png
look_dir 0 -0.1 1
# the camera easing to the aim, a second or so of its own (timing)
delay 1200
event scan
screenshot $out/behind_centred.png
keypress C
wait_log 5000 chat (local): Third person view (front)
delay 1500
screenshot $out/front.png
keypress C
wait_log 5000 chat (local): First person view
# And the same back view on a floor with nothing behind the player, which
# is what says how the third-person camera frames them when no wall is
# pulling it in ([OVER_SHOULDER]). The stage is asked for by chat so it
# cannot land in the middle of the shots above.
keypress T
wait_log 5000 chat: the line opened
text open
keypress Return
wait_log 30000 chat: camera: the open stage is ready
delay 2000
look_dir 0 -0.1 1
# a settle: first person is aimed at once, the view drawn after it
delay 500
event scan
screenshot $out/open_first.png
keypress C
wait_log 5000 chat (local): Third person view
# the camera easing out from the eye with no wall to stop it, the model
# hidden until it is out (timing; 2026-10-13: at 1.2 s it was not drawn)
delay 1500
look_dir 0 -0.1 1
# the camera easing to the aim, a second or so of its own (timing)
delay 1200
event scan
screenshot $out/open_behind.png
keypress C
wait_log 5000 chat (local): Third person view (front)
keypress C
wait_log 5000 chat (local): First person view
quit
CMDS
bin/buildat -s localhost:29778 -w 1280x720 -l 3 -c @"$out/cmds.txt" \
	> "$out/cli.log" 2>&1 ||
	{ echo "FAIL: the drive ($out/cli.log): $(grep -ao 'Command sequence failed.*' "$out/cli.log" | head -1)"; exit 1; }
kill -INT "$srv" 2>/dev/null
# The server's exit, polled
for i in $(seq 1 300); do kill -0 "$srv" 2>/dev/null || break; sleep 0.2; done
grep -aE "self model at|camera at" "$out/cli.log" | sed 's/.*: scan/scan/'
# The back view's pitch follows the look ([BOX_PLAYTEST_4] 3): looking up
# the sky is the top of the frame, looking down the ground is the bottom
python3 - "$out" "${SHOULDER:-}" <<'PY'
import sys, statistics
from PIL import Image
out = sys.argv[1]
r = {}
for n in ("behind_up", "behind_down"):
	im = Image.open("%s/%s.png" % (out, n)).convert("L")
	w, h = im.size
	r[n] = (statistics.mean(list(im.crop((0, 0, w, h // 3)).getdata())),
			statistics.mean(list(im.crop((0, 2 * h // 3, w, h)).getdata())))
print("behind, looking up: top %.0f bottom %.0f; down: top %.0f bottom %.0f" %
		(r["behind_up"][0], r["behind_up"][1], r["behind_down"][0], r["behind_down"][1]))
# And where the model is in the frame: centred it covers the crosshair,
# over the shoulder it does not ([OVER_SHOULDER]; the setting's row in
# user/shared/vanilla/settings.json says which this run drew)
# Which view this run drew ([OVER_SHOULDER]): the patch at the crosshair
# on the open stage, and how much of it is the model rather than the
# world. The share is what to read and not the mean -- the mean moves
# with whatever ground is behind, and read 131 one run and 94 the next
# on the same view, where the share held at about a half (2026-09-22).
# The model is what differs from the first-person shot of the same look
# (2026-10-13: "dark" pixels read 0% centred for a skin with grey hair)
def patch(name):
	im = Image.open("%s/%s.png" % (out, name)).convert("RGB")
	w, h = im.size
	return list(im.crop((w // 2 - 24, h // 2 - 24, w // 2 + 24,
			h // 2 + 24)).getdata())
dark = sum(1 for a, b in zip(patch("open_behind"), patch("open_first"))
		if max(abs(x - y) for x, y in zip(a, b)) > 20) / float(48 * 48)
shoulder = len(sys.argv) > 2 and sys.argv[2] != ""
print("the crosshair's patch is %.0f%% model (centred reads 93, over the "
		"shoulder about 50)" % (dark * 100))
view_ok = (dark < 0.7) if shoulder else (dark > 0.8)
if shoulder:
	print("PASS: the crosshair points past the model" if view_ok
			else "FAIL: the model still covers the crosshair")
else:
	print("PASS: the centred view puts the model under the crosshair"
			if view_ok else "FAIL: the centred view is not centred")
pitch_ok = (r["behind_up"][0] > r["behind_up"][1] and
		r["behind_down"][0] < r["behind_down"][1])
print("PASS: the back view's pitch follows the look" if pitch_ok
		else "FAIL: the back view's pitch is inverted")
sys.exit(0 if (pitch_ok and view_ok) else 1)
PY
verdict_keep
grep "person view\|camera:\| E " "$out/cli.log" | sed 's/.*: //'
ls "$out"/*.png
verdict_exit
