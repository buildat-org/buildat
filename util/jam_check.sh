#!/bin/bash
# tier: full
# cost: ~1 min (2026-11-19)
# covers: src/impl/jam.cpp src/interface/jam.h src/lua_bindings/jam.cpp extensions/jam/** apps/jam_check/** apps/workbench/templates/brimstone_speedway/composition.json
# [MUSIC_SYNTH]: apps/jam_check natively and in the web client (Chrome,
# skipped without web/ or Chrome): parse errors by line, jam1's hashes
# (the first 10 s of jam.songs, one in a mood) the same as committed and on
# both, the render's cost, a mood landing on a bar, the stream going on
# through a 1 s main-thread stall natively (the web's audio runs on its
# main thread: it reports what it did), stop. And Brimstone's music
# entities hold jam.songs' texts. Audio through SDL's dummy driver.
#   util/jam_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
check_tmp jam; t=$CHECK_TMP
export SDL_AUDIODRIVER=dummy
# jam1's samples: a change here is a jam2 beside it, never an edit
HASHES="scrap_heat:db30bc7da2a922b3 scrap_heat/calm:9390afdf184e4487 yard_vamp:c29b0760973a9d16"
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
cat > "$t/steps.json" <<'J'
[
	["nav", "${URL}"],
	["waitlog", "jam check: done", 180]
]
J
"$here/util/web_drive.sh" chrome jam_check "$t/steps.json" "$t/web" > "$t/web.log" 2>&1 ||
	fail "the web drive ($t/web.log)"
echo "web:"; lines "$t/web/page.log"
judge "$t/web/page.log" web
python3 - "$t/web/page.log" "$cost_ms" <<'PY' || fail "the web is over the budget ($cost_ms ms a second)"
import re, sys
log = open(sys.argv[1], errors="replace").read()
worst = max(float(x) for x in re.findall(r"jam check: hash \S+ \w+, ([\d.]+) ms per s", log))
assert worst < float(sys.argv[2]), worst
PY
echo "PASS: jam1's hashes the same natively and on the web, a mood on a bar, the native stream through a stall"
# vim: set noet ts=4 sw=4:
