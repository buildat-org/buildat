#!/bin/bash
# tier: full
# cost: ~1 min (2026-10-15)
# covers: extensions/blip apps/blip_check
# [BLIP]: blip1's formats and imports in plain Lua
# (extensions/blip/test/gen_test.lua); apps/blip_check's self-check,
# plays, WAV header and speed runner natively and in the web client
# (Chrome, skipped without web/ or Chrome), the web held to the budget
# (8 voices mixed under 20 ms a second of audio, the slowest preset made
# in under 4 ms); and the designer opened from its tile, a sound made and
# saved as a WAV whose header is read back; its Import... dialog
# ([BLIP_IMPORT_DIALOG]): a paste that does not read keeps it open with
# the reason, Cancel changes nothing, and the user's blip.play("blip1:...")
# pasted and imported closes it and is the designer's sound. -c runs are
# muted.
#   util/blip_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
check_tmp blip; t=$CHECK_TMP
(cd "$here" && luajit extensions/blip/test/gen_test.lua) || fail "gen_test.lua"
lines(){ grep -a "blip check:" "$1" | grep -av 'wait_log\|command' | sed 's/.*blip check: //'; }
printf 'wait_log_any 150000 blip check: done\nquit\n' > "$t/c.cmds"
(cd "$here/Build" && timeout 200 bin/buildat -C "$t/c" -D "$t/u" -w 320x240 \
	-l 3 -a app/blip_check/run -c @"$t/c.cmds" > "$t/native.log" 2>&1) ||
	fail "native ($t/native.log)"
echo "native:"; lines "$t/native.log"
grep -aq "blip check: self-check ok" "$t/native.log" || fail "native self-check"

# The designer: laser, Save WAV, the file's header; the import dialog
BLIP_USER=blip1:DKQJcEhPmjsAAWJdHAAg0gzGkFVgRAAgZoMLf7dwZLFd8gAfstafl1sAAAA
cat > "$t/d.cmds" <<C
wait_log_any 30000 designer shown
click Button "laser"
wait_log 5000 designer: laser
click Button "Save WAV"
wait_log 5000 designer: saved
click Button "Import..."
wait_log 5000 designer: the import dialog shown
delay 300
text {wave = "sine", os.exit()}
click Button "Import"
wait_log 5000 designer: the import dialog: not a sound table
delay 300
click Button "Cancel"
wait_log 5000 designer: the import dialog closed, cancelled
click Button "Import..."
wait_log 5000 designer: the import dialog shown
delay 300
text blip.play("$BLIP_USER")
screenshot $t/import.png
click Button "Import"
wait_log 5000 designer: imported blip1: $BLIP_USER
delay 500
screenshot $t/imported.png
quit
C
(cd "$here/Build" && timeout 120 bin/buildat -C "$t/c" -D "$t/u" -w 800x600 \
	-l 3 -m launch_menu -a extension/blip/designer -c @"$t/d.cmds" \
	> "$t/designer.log" 2>&1) || fail "the designer drive ($t/designer.log)"
python3 - "$t"/u/exports/blip_*.wav <<'PY' || fail "the designer's WAV"
import struct, sys
d = open(sys.argv[1], "rb").read()
riff, size, wave, fmt, n16, pcm, ch, rate, bps, align, bits, data, dlen = \
	struct.unpack("<4sI4s4sIHHIIHH4sI", d[:44])
assert (riff, wave, fmt, data) == (b"RIFF", b"WAVE", b"fmt ", b"data")
assert (n16, pcm, ch, rate, bps, align, bits) == (16, 1, 1, 44100, 88200, 2, 16)
assert size == len(d) - 8 and dlen == len(d) - 44 and dlen > 0
print("designer: %s, %.3f s" % (sys.argv[1].rsplit("/", 1)[1], dlen / 88200))
PY
# Cancel imported nothing: the one import is the user's
[ "$(grep -ac "I blip *: designer: imported" "$t/designer.log")" = 1 ] &&
	grep -aq "designer: the import dialog closed, imported" "$t/designer.log" ||
	fail "the import dialog ($t/designer.log)"

if [ ! -f "$here/web/buildat.wasm" ] ||
		! command -v "${CHROME:-google-chrome}" > /dev/null; then
	echo "PASS (native; the web SKIPPED: no web/ or Chrome)"; exit 0
fi
cat > "$t/steps.json" <<'J'
[
	["nav", "${URL}"],
	["waitlog", "blip check: done", 180]
]
J
"$here/util/web_drive.sh" chrome blip_check "$t/steps.json" "$t/web" > "$t/web.log" 2>&1 ||
	fail "the web drive ($t/web.log)"
echo "web:"; lines "$t/web/page.log"
grep -aq "blip check: self-check ok" "$t/web/page.log" || fail "the web self-check"
python3 - "$t/web/page.log" <<'PY' || fail "the web is over the budget"
import re, sys
log = open(sys.argv[1], errors="replace").read()
slowest = float(re.search(r"made in ([\d.]+) ms", log).group(1))
mix8 = float(re.search(r"8 voices, ([\d.]+) ms", log).group(1))
assert slowest < 4 and mix8 < 20, (slowest, mix8)
PY
echo "PASS: blip's hashes the same natively and on the web, the web in its budget"
# vim: set noet ts=4 sw=4:
