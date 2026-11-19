#!/bin/bash
# tier: full
# cost: ~3 min (2026-11-19)
# covers: src/impl/jam.cpp src/interface/jam.h src/lua_bindings/jam.cpp extensions/jam/** apps/jam_check/** apps/workbench/templates/brimstone_speedway/composition.json util/jam_capture.js
# [MUSIC_SYNTH]: apps/jam_check natively and in the web client (Chrome,
# skipped without web/ or Chrome): parse errors by line, jam1's hashes
# (the first 10 s of jam.songs, one in a mood) the same as committed and on
# both, the render's cost, a mood landing on a bar, the stream going on
# through a 1 s main-thread stall natively, stop; on the web (both
# clients) the music captured as played at a few frames a second, below.
# And Brimstone's music entities hold jam.songs' texts. Audio through
# SDL's dummy driver natively, a muted headless Chrome on the web.
#   util/jam_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
check_tmp jam; t=$CHECK_TMP
export SDL_AUDIODRIVER=dummy
# jam1's samples: a change here is a jam2 beside it, never an edit (a
# song's text changed is a new hash of its own: kit_plan 4z37h's tempo,
# repeats and -3 dB)
HASHES="scrap_heat:44bf220977ef7256 scrap_heat/calm:41c90017b27f284a yard_vamp:db6e26bc09b5eef6"
slow_limit cost_ms 120

# Brimstone's music is jam.songs' (one text, two places)
python3 - "$here" <<'PY' || fail "Brimstone's songs differ from extensions/jam/songs.lua"
import json, re, sys
root = sys.argv[1]
lua = open(root + "/extensions/jam/songs.lua").read()
songs = dict(re.findall(r"(\w+) = \[==\[\n(.*?)\]==\]", lua, re.S))
comp = json.load(open(root + "/apps/workbench/templates/brimstone_speedway/composition.json"))
found = set()
for e in comp["entities"]:
    for c in e.get("components", []):
        if c["type"] != "kit/music":
            continue
        name = [n for n, s in songs.items() if s == c["params"].get("song")]
        assert name, "entity %s's song is not one of jam.songs" % e["id"]
        found.add(name[0])
assert found == set(songs), found
PY

lines(){ grep -a "jam check:" "$1" | grep -av 'wait_log\|command' | sed 's/.*jam check: //'; }
judge() # <log> <where>
{
	local l=$1 w=$2
	lines "$l" | grep -q "FAILED" && fail "$w: $(lines "$l" | grep FAILED | head -1)"
	grep -aq "jam check: errors ok" "$l" || fail "$w: the errors"
	for h in $HASHES; do
		grep -aq "jam check: hash ${h%%:*} ${h#*:}," "$l" ||
			fail "$w: hash ${h%%:*} is not ${h#*:} ($(lines "$l" | grep "hash ${h%%:*} "))"
	done
	grep -aq "jam check: mood on a bar" "$l" || fail "$w: the mood"
	grep -aq "jam check: stopped" "$l" || fail "$w: stop"
	grep -aq "jam check: done" "$l" || fail "$w: not done"
}

printf 'wait_log_any 60000 jam check: done\nquit\n' > "$t/c.cmds"
(cd "$here/Build" && timeout 120 bin/buildat -C "$t/c" -D "$t/u" -w 320x240 \
	-l 3 -a app/jam_check/run -c @"$t/c.cmds" > "$t/native.log" 2>&1) ||
	fail "native ($t/native.log)"
echo "native:"; lines "$t/native.log"
judge "$t/native.log" native
went=$(lines "$t/native.log" | sed -n 's/^stall 1.00 s: the stream went on \([0-9.]*\) s$/\1/p')
awk -v w="${went:-0}" 'BEGIN { exit !(w >= 0.8) }' ||
	fail "native: the stream stopped in a main-thread stall (${went:-?} s of 1)"

if [ ! -f "$here/web/buildat.wasm" ] ||
		! command -v "${CHROME:-google-chrome}" > /dev/null; then
	echo "PASS: (native; the web SKIPPED: no web/ or Chrome)"; exit 0
fi
# [MUSIC_WEB_RING] Each web client: buildat_mt (the page isolated: the ring
# in shared memory, filled by jam's thread) and buildat (?isolated=0: the
# page's thread posting it). The app run whole, then its 12 s of Scrap
# Heat captured as played (util/jam_capture.js, on the audio thread) with
# the page's thread stalled 250 ms at a time (a few frames a second): no
# silence over 20 ms between the music's first and last sound, nothing
# played twice (SDL's way starved: its buffers replayed), and 11 s or more
# of it heard. WEB_DRIVE_WEB=<dir>: another build's files (to compare);
# JAM_WEB="st": that client alone.
web_run() # <name> <query>
{
	local w=$1 o=$t/web_$1
	python3 -I - "$here/util/jam_capture.js" "$2" > "$t/steps_$w.json" <<'PY'
import json, sys
print(json.dumps([
	["init", open(sys.argv[1]).read()],
	["nav", "${URL}" + sys.argv[2]],
	# a gesture: the browsers' autoplay rule
	["click", 5, 5],
	["waitlog", "jam check: long play started", 180],
	["eval", "__cap.start(250)"],
	["waitlog", "jam check: long play done", 60],
	["eval", "__cap.stop()"],
	["downloaded", "music.wav", 30],
	["waitlog", "jam check: done", 30],
]))
PY
	"$here/util/web_drive.sh" chrome jam_check "$t/steps_$w.json" "$o" > "$t/web_$w.log" 2>&1 ||
		fail "the web drive, $w ($t/web_$w.log)"
	echo "web, $w:"; lines "$o/page.log"
	python3 -I - "$o/page.log" "$cost_ms" <<'PY' || fail "web $w: over the budget ($cost_ms ms a second)"
import re, sys
log = open(sys.argv[1], errors="replace").read()
worst = max(float(x) for x in re.findall(r"jam check: hash \S+ \w+, ([\d.]+) ms per s", log))
assert worst < float(sys.argv[2]), worst
PY
	python3 -I - "$t/web_$w.log" "$o/music.wav" <<'PY' || fail "web $w: the music broke at a few frames a second ($o/music.wav)"
import json, re, struct, sys, wave
log = open(sys.argv[1], errors="replace").read()
cap = json.loads(re.findall(r"eval: (\{\"fps\".*)", log)[-1])
w = wave.open(sys.argv[2])
rate, n = w.getframerate(), w.getnframes()
raw = w.readframes(n)
x = struct.unpack("<%dh" % (2 * n), raw)
loud = [abs(x[2 * i]) > 1 or abs(x[2 * i + 1]) > 1 for i in range(n)]
first = loud.index(True) if True in loud else n
last = n - loud[::-1].index(True) if True in loud else 0
# A gap: silence (a worklet with nothing to play), or a stretch played
# again (a starved ScriptProcessorNode replays its last buffers): blocks
# of 1024 the same as one at least a block before
gaps, run = [], 0
for i in range(first, last):
    if loud[i]:
        if run:
            gaps.append(run)
        run = 0
    else:
        run += 1
B, seen, again = 1024, {}, 0
for i in range(first, last - B, B // 4):
    k = raw[4 * i:4 * (i + B)]
    if k in seen and i - seen[k] >= B:
        again += 1
    seen.setdefault(k, i)
long = [g for g in gaps if g > rate * 0.02]
heard = (last - first) / rate
print("  %.1f frames a second (%d stalls, %.0f %% of the time); %.2f s of music"
      " heard, from %.2f s; silences over 1 ms: %d, the longest %.1f ms, %d"
      " over 20 ms; %.2f s played again" % (cap["fps"], cap["stalls"],
      100 * cap["stalled"], heard, first / rate,
      len([g for g in gaps if g > rate * 0.001]), 1000.0 * max(gaps or [0]) /
      rate, len(long), again * B / 4.0 / rate))
assert cap["fps"] < 6, "the page was not slowed"
assert heard >= 11, "too little heard"
assert not long and not again, "gaps"
PY
	judge "$o/page.log" "web $w"
}
for w in ${JAM_WEB:-mt st}; do
	web_run "$w" "$([ "$w" = st ] && echo "?isolated=0")"
done
echo "PASS: jam1's hashes the same natively and on the web, a mood on a bar, the native stream through a stall, the web's music unbroken at a few frames a second (threads and not)"
# vim: set noet ts=4 sw=4:
