#!/bin/bash
# tier: full
# cost: ~60s (2026-10-30)
# covers: builtin/heightmap/client_lua/** builtin/heightmap/client_data/**
# [HEIGHTMAP_TERRAIN] on the web client: apps/sample_heightmap in headless
# Firefox (util/web_drive.sh, the web client from web/) builds the
# 1024x1024 terrain, a crater dug with C reaches the page's terrain, and
# the frames take under LIMIT_MS (200) on average.
#   apps/sample_heightmap/web_check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
limit=${LIMIT_MS:-200}
check_tmp heightmap_web; t=$CHECK_TMP
bash "$here/util/web_drive.sh" firefox sample_heightmap \
	"$here/apps/sample_heightmap/web_check.json" "$t" > "$t/drive.log" 2>&1 ||
	fail "the drive ($(tail -3 "$t/drive.log" | tr '\n' ' '); $t/page.log)"
grep -a "heightmap: terrain built\|the crater\|frame .* ms average" "$t/page.log" |
	sed 's/^.*sample_heightmap: //;s/^.*heightmap: /heightmap: /'
frame=$(grep -aoP "frame \K[0-9.]+(?= ms average)" "$t/page.log" | tail -1)
[ -n "$frame" ] || fail "no frame times ($t/page.log)"
awk -v f="$frame" -v l="$limit" 'BEGIN{exit !(f < l)}' ||
	fail "frames took $frame ms on average, not under $limit ($t/page.log)"
echo "PASS: the web client built the terrain, a crater reached it, frames $frame ms on average"
# vim: set noet ts=4 sw=4:
