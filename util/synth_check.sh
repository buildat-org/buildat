#!/bin/bash
# tier: full
# cost: ~1 min (2026-10-15)
# covers: src/lua_bindings/synth.cpp
# [SYNTH_BLOCKS]: the same samples everywhere. The synth's self-check
# (src/lua_bindings/synth.cpp: every block and curve feature at fixed
# inputs, hashed against the hashes committed with it) says "ok" in the
# native client and in the web client (Chrome, skipped without web/ or
# Chrome). The refusals from the sandbox are apps/sample_ui's.
# simplified: the package run's archives (Linux and Windows) are not read
# here; their smoke logs carry the same line.
#   util/synth_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
check_tmp synth; t=$CHECK_TMP
trap check_cleanup EXIT
line(){ grep -a "synth self-check:" "$1" | head -3; }
echo quit > "$t/c.cmds"
(cd "$here/Build" && timeout 60 bin/buildat -C "$t/c" -D "$t/u" -w 320x240 \
	-l 3 -o sound_mute=1 -c @"$t/c.cmds" > "$t/native.log" 2>&1)
echo "native: $(line "$t/native.log")"
grep -aq "synth self-check: ok" "$t/native.log" || fail "native ($t/native.log)"
if [ ! -f "$here/web/buildat.wasm" ] ||
		! command -v "${CHROME:-google-chrome}" > /dev/null; then
	echo "PASS: (native; the web SKIPPED: no web/ or Chrome)"; exit 0
fi
cat > "$t/steps.json" <<'J'
[
	["nav", "${URL}"],
	["waitlog", "synth self-check:", 120]
]
J
"$here/util/web_drive.sh" chrome sample_ui "$t/steps.json" "$t/web" > "$t/web.log" 2>&1 ||
	fail "the web drive ($t/web.log)"
echo "web: $(line "$t/web/page.log")"
grep -aq "synth self-check: ok" "$t/web/page.log" || fail "the web ($t/web/page.log)"
echo "PASS: the synth's hashes the same natively and on the web"
# vim: set noet ts=4 sw=4:
