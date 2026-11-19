#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min (2026-11-19)
# covers: extensions/jam/app.lua extensions/jam/init.lua extensions/jam/launcher/init.lua extensions/jam/music_edit.lua extensions/jam/songs.lua src/impl/jam.cpp src/lua_bindings/jam.cpp
# drives: extensions/jam/app.lua
# [JAM_APP] The jam app from its tile, on a headless weston's Xwayland, the
# audio SDL's dummy driver:
#   1. each template (New from template): a step placed in a pattern, Save
#      (<song>.jam in the exports), Export WAV (<song>.wav), Open... the
#      saved file from the picker, Save again (<song>_2.jam): the saved
#      text is the template's with that one line changed, the reopened
#      one's the same; each WAV 44.1 kHz 16-bit stereo, the play order's
#      length, not silent and not clipped;
#   2. a changed song asks before a template replaces it;
#   3. the web (Chrome, from the launch menu): Launch Room's step placed,
#      Save and Export WAV are downloads byte for byte the native's, and
#      the native's saved Slow Tide uploaded through Open... saves the same
#      text again. Skipped without web/ or Chrome.
# Screenshots, kept with KEEP_TMP=1: $t/<song>.png, $t/web/web.png
#   util/jam_app_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
command -v weston > /dev/null || skip "no weston"
check_build
check_tmp jam_app; t=$CHECK_TMP
export SDL_AUDIODRIVER=dummy
sock=buildat-jamapp-$$
weston --backend=headless --xwayland --socket=$sock --width=1100 \
	--height=800 > "$t/weston.log" 2>&1 &
CHECK_PIDS+=($!)
d=
for _ in $(seq 50); do
	d=$(grep -ao "xserver listening on display :[0-9]*" "$t/weston.log" | grep -o ":[0-9]*$")
	[ -n "$d" ] && break
	sleep 0.2
done
[ -n "$d" ] || fail "weston's Xwayland ($t/weston.log)"

# <label> <file stem> <pattern> <lane>; the step placed is the lane's second
SONGS="Launch_Room launch_room beat kick
Slow_Tide slow_tide bells bell
Yard_Vamp yard_vamp drA kick
Scrap_Heat scrap_heat beat kick"
{
	echo "wait_log_any 30000 app: opened Launch Room, "
	echo "frames 3"
	while read -r label f pat lane; do
		label=${label//_/ }
		cat <<C
click DropDownList "jam template"
frames 3
click Text "jam template: $label"
wait_log 5000 app: opened $label,
frames 2
click Button "music view pattern"
wait_log 5000 app: view pattern
frames 2
click DropDownList "music pattern"
frames 3
click Text "music pattern: $pat (*"
wait_log 5000 app: view pattern $pat
frames 2
click BorderImage "music step $lane 2"
wait_log 5000 at $pat $lane step 2: parses
frames 3
screenshot $t/$f.png
click Button "jam save"
wait_log 5000 app: saved $f.jam
frames 2
click Button "jam wav"
wait_log 60000 app: exported $f.wav
frames 2
click Button "jam open"
wait_log 5000 The file picker at
frames 3
click Button "$f.jam"
wait_log 5000 app: opened $label,
frames 2
click Button "jam save"
wait_log 5000 app: saved ${f}_2.jam
frames 2
C
	done <<< "$SONGS"
	# 2. A change, then a template: asked first (no "Discard" button fails it);
	# Escape on the question is Cancel, not the editor's Close
	cat <<C
click Button "music view pattern"
wait_log 5000 app: view pattern
frames 2
click DropDownList "music pattern"
frames 3
click Text "music pattern: beat (*"
wait_log 5000 app: view pattern beat
frames 2
click BorderImage "music step kick 3"
wait_log 5000 at beat kick step 3: parses
frames 2
click DropDownList "jam template"
frames 3
click Text "jam template: Yard Vamp"
frames 5
keypress Escape
frames 5
click DropDownList "jam template"
frames 3
click Text "jam template: Yard Vamp"
frames 5
click Button "Discard"
wait_log 5000 app: opened Yard Vamp,
frames 3
screenshot $t/asked.png
quit
C
} > "$t/app.cmds"
(cd "$here/Build" && DISPLAY=$d WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11 \
	timeout 300 bin/buildat -C "$t/c" -D "$t/u" -w 1100x760 -l 3 \
	-o sound_mute=1 -m launch_menu -a extension/jam/app -c @"$t/app.cmds" \
	> "$t/app.log" 2>&1) || fail "the app's drive ($t/app.log)"

# The files: one line changed, the reopened text saved the same; the WAVs
# (seconds: the play order's, bars x beats x 60 / tempo)
python3 -I - "$here" "$t/u/exports" "$SONGS" <<'PY' || fail "the saved files ($t/u/exports)"
import struct, subprocess, sys
root, ex, songs = sys.argv[1], sys.argv[2], sys.argv[3]
SECONDS = {"launch_room": 96 * 4 * 60 / 116, "slow_tide": 16 * 4 * 60 / 60,
           "yard_vamp": 21 * 4 * 60 / 82, "scrap_heat": 80 * 4 * 60 / 156}
for line in songs.splitlines():
    label, f, pat, lane = line.split()
    tpl = subprocess.run(["luajit", "-e", 'io.write(dofile("' + root + '/extensions/jam/songs.lua").' + f + ')'],
                         capture_output=True,
                         check=True).stdout.decode()
    a = open(ex + "/" + f + ".jam").read()
    b = open(ex + "/" + f + "_2.jam").read()
    assert a == b, f + ": reopened and saved again, not the same"
    ta, tb = tpl.split("\n"), a.split("\n")
    assert len(ta) == len(tb), f + ": lines added or taken"
    diff = [(x, y) for x, y in zip(ta, tb) if x != y]
    assert len(diff) == 1 and diff[0][1].startswith(lane + ":"), (f, diff)
    d = open(ex + "/" + f + ".wav", "rb").read()
    riff, size, wave, fmt, n16, pcm, ch, rate, bps, align, bits, data, dlen = \
        struct.unpack("<4sI4s4sIHHIIHH4sI", d[:44])
    assert (riff, wave, fmt, data) == (b"RIFF", b"WAVE", b"fmt ", b"data")
    assert (n16, pcm, ch, rate, bps, align, bits) == (16, 1, 2, 44100, 176400, 4, 16)
    assert size == len(d) - 8 and dlen == len(d) - 44
    s = dlen / 176400
    if SECONDS[f] is not None:
        assert abs(s - SECONDS[f]) < 0.01, (f, s, SECONDS[f])
    pcm = memoryview(d)[44:].cast("h")
    peak = max(max(pcm), -min(pcm)) / 32768
    assert 0.1 < peak < 0.999, (f, "peak", peak)
    print("%s: one line changed (%s), the same reopened; %s.wav %.2f s, peak %.2f"
          % (f, diff[0][1].split(":")[0], f, s, peak))
PY

[ -s "$here/web/index.html" ] && command -v "${CHROME:-google-chrome}" > /dev/null || {
	echo "PASS: (native; the web SKIPPED: no web/ or Chrome)"; exit 0; }
# 3. The web: the tile found by a search in the launch menu
cat > "$t/steps.json" <<J
[
	["nav", "\${URL}"],
	["waitlog", "launch_menu: [0-9]+ rows in", 120],
	["wait", 500],
	["type", "jam"],
	["waitlog", "launch_menu: [0-9]+ rows for \"jam\".*first jam music maker", 20],
	["wait", 300],
	["key", "Enter"],
	["waitlog", "app: opened Launch Room, ", 20],
	["click", "Button", "music view pattern"],
	["waitlog", "app: view pattern", 10],
	["click", "DropDownList", "music pattern"],
	["wait", 300],
	["click", "Text", "music pattern: beat (*"],
	["waitlog", "app: view pattern beat", 10],
	["click", "BorderImage", "music step kick 2"],
	["waitlog", "at beat kick step 2: parses", 10],
	["click", "Button", "jam save"],
	["downloaded", "launch_room.jam"],
	["click", "Button", "jam wav"],
	["waitlog", "app: exported launch_room.wav", 120],
	["downloaded", "launch_room.wav", 60],
	["file", "$t/u/exports/slow_tide.jam"],
	["click", "Button", "jam open"],
	["waitlog", "app: opened Slow Tide, ", 20],
	["wait", 300],
	["shot", "\${OUT}/web.png"],
	["click", "Button", "jam save"],
	["downloaded", "slow_tide.jam"]
]
J
timeout 400 "$here/util/web_drive.sh" chrome play "$t/steps.json" "$t/web" \
	> "$t/web.log" 2>&1 || fail "the web drive ($t/web.log)"
for f in launch_room.jam launch_room.wav slow_tide.jam; do
	cmp -s "$t/web/$f" "$t/u/exports/$f" || fail "the web's $f is not the native's"
done
echo "web: launch_room.jam and .wav the native's, slow_tide.jam uploaded and saved the same"
echo "PASS: the four templates edited, saved, exported and reopened; the web's files the native's"
# vim: set noet ts=4 sw=4:
