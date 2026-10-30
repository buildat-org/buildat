#!/bin/bash
# tier: full
# cost: ~60s (2026-10-30)
# covers: builtin/heightmap/client_lua/** builtin/heightmap/client_data/**
# [HEIGHTMAP_TERRAIN], [HEIGHTMAP_REST] on the web client:
# apps/sample_heightmap in headless Firefox (util/web_drive.sh, the web
# client from web/) builds the 1024x1024 terrain of five materials and
# draws the pad's gravel; a crater dug with C reaches the page's terrain
# as four rectangles under EDIT_BYTES (2000) bytes and draws its dirt
# (WebGL 2's texture array and the partial texture upload); the frames take
# under LIMIT_MS (200) on average.
#   apps/sample_heightmap/web_check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
limit=${LIMIT_MS:-200}
check_tmp heightmap_web; t=$CHECK_TMP
bash "$here/util/web_drive.sh" firefox sample_heightmap \
	"$here/apps/sample_heightmap/web_check.json" "$t" > "$t/drive.log" 2>&1 ||
	fail "the drive ($(tail -3 "$t/drive.log" | tr '\n' ' '); $t/page.log)"
grep -a "heightmap: terrain built\|heightmap: terrain updated\|the crater\|frame .* ms average" "$t/page.log" |
	sed 's/^.*sample_heightmap: //;s/^.*heightmap: /heightmap: /'
grep -aq "heightmap: terrain built: 1024x1024 samples, 5 materials" "$t/page.log" ||
	fail "no terrain of five materials ($t/page.log)"
edit=$(grep -aoP "heightmap: terrain updated: \K[0-9]+ regions, [0-9]+ bytes, [0-9.]+ ms" "$t/page.log" | tail -1)
regions=$(echo "$edit" | awk '{print $1}')
bytes=$(echo "$edit" | awk '{print $3}')
[ "$regions" = 4 ] && [ "${bytes:-99999}" -lt "${EDIT_BYTES:-2000}" ] ||
	fail "the crater's edit: \"$edit\", not 4 regions under ${EDIT_BYTES:-2000} bytes ($t/page.log)"
# The ground's colours, as check.sh counts them: dirt (brown) and gravel
# (light grey) pixels
read hills_dirt hills_grey crater_dirt crater_grey < <(python3 - "$t/hills.png" "$t/crater.png" <<'PY'
import sys
from PIL import Image
out = []
for p in sys.argv[1:]:
	dirt = grey = 0
	for r, g, b in Image.open(p).convert("RGB").getdata():
		if r > 1.3 * g and g > 1.2 * b and r > 50:
			dirt += 1
		if abs(r - g) < 12 and abs(g - b) < 12 and r > 120:
			grey += 1
	out += [dirt, grey]
print(*out)
PY
)
echo "ground pixels (dirt grey): before the crater $hills_dirt $hills_grey, after $crater_dirt $crater_grey"
[ "${hills_grey:-0}" -ge 20000 ] || fail "no gravel pad drawn ($t/hills.png)"
[ "${hills_dirt:-1}" -lt 200 ] && [ "${crater_dirt:-0}" -ge 1000 ] ||
	fail "no dirt drawn in the crater ($t/hills.png, $t/crater.png)"
frame=$(grep -aoP "frame \K[0-9.]+(?= ms average)" "$t/page.log" | tail -1)
[ -n "$frame" ] || fail "no frame times ($t/page.log)"
awk -v f="$frame" -v l="$limit" 'BEGIN{exit !(f < l)}' ||
	fail "frames took $frame ms on average, not under $limit ($t/page.log)"
echo "PASS: the web client built the terrain of five materials, a crater reached it in $edit, frames $frame ms on average"
# vim: set noet ts=4 sw=4:
