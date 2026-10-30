#!/bin/bash
# tier: full
# cost: ~45s (2026-10-30)
# covers: builtin/voxel_objects/client_lua/** builtin/voxel_objects/client_data/** 3rdparty/Urho3D/Source/Urho3D/Graphics/OpenGL/OGLTexture*.cpp
# [VOXEL_OBJECTS] on the web client: apps/sample_voxel_objects in headless
# Firefox (util/web_drive.sh, the web client from web/) meshes six chunks
# for 102 objects (105 chunk nodes: copies share a mesh), draws the
# hundred houses (WOOD_MIN (30000) roof pixels) in under DRAWS_MAX (200)
# draw calls (WebGL 2's instancing); E's edit reaches the page as the
# house's rev 2, shared to the 100 houses; the frames take under LIMIT_MS
# (200) on average; the far roofs have no fringe in one channel's colour
# (the atlas's mip levels past its own sampled, [WEB_ATLAS_MIP_LEVELS]:
# 2641 pure green pixels in houses.png before, 0 natively).
#   apps/sample_voxel_objects/web_check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
limit=${LIMIT_MS:-200}
draws_max=${DRAWS_MAX:-200}
check_tmp voxel_objects_web; t=$CHECK_TMP
bash "$here/util/web_drive.sh" firefox sample_voxel_objects \
	"$here/apps/sample_voxel_objects/web_check.json" "$t" > "$t/drive.log" 2>&1 ||
	fail "the drive ($(tail -3 "$t/drive.log" | tr '\n' ' '); $t/page.log)"
grep -a "voxel_objects: model\|frame .* ms average" "$t/page.log" | sed 's/^.*voxel_objects: //'
counts=$(grep -aoP "draw calls; \K[^\"]*?chunk nodes" "$t/page.log" | head -1)
[ "$counts" = "3 models, 6 meshes, 102 objects, 105 chunk nodes" ] ||
	fail "voxel_objects' counts: \"$counts\", not 6 meshes for 102 objects ($t/page.log)"
draws=$(grep -aoP "[0-9]+(?= draw calls; 3 models)" "$t/page.log" | head -1)
[ "${draws:-999}" -lt "$draws_max" ] ||
	fail "the houses took ${draws:-?} draw calls, not under $draws_max ($t/page.log)"
grep -aq "model house rev 2 chunk (0,0,0) meshed in [0-9.]* ms, shared to 100 objects" "$t/page.log" ||
	fail "the edit did not reach the page's houses ($t/page.log)"
wood=$(python3 - "$t/houses.png" <<'PY'
import sys
from PIL import Image
print(sum(1 for r, g, b in Image.open(sys.argv[1]).convert("RGB").getdata()
		if r > 1.25 * g and g > 1.15 * b and 60 < r < 200))
PY
)
echo "roof pixels: $wood"
[ "${wood:-0}" -ge "${WOOD_MIN:-30000}" ] || fail "the houses are not drawn: $wood roof pixels ($t/houses.png)"
fringe=$(python3 - "$t/houses.png" "$t/edited.png" <<'PY'
import sys
from PIL import Image
print(sum(1 for f in sys.argv[1:] for p in Image.open(f).convert("RGB").getdata()
		if sorted(p)[1] < 24 and max(p) > 70))
PY
)
[ "${fringe:-1}" -lt "${FRINGE_MAX:-50}" ] ||
	fail "far voxels fringed: $fringe pixels of one channel's colour ($t/houses.png, $t/edited.png)"
frame=$(grep -aoP "frame \K[0-9.]+(?= ms average)" "$t/page.log" | tail -1)
[ -n "$frame" ] || fail "no frame times ($t/page.log)"
awk -v f="$frame" -v l="$limit" 'BEGIN{exit !(f < l)}' ||
	fail "frames took $frame ms on average, not under $limit ($t/page.log)"
echo "PASS: the web client drew 102 objects of 6 meshes in $draws draw calls ($wood roof pixels), the edit reached its 100 houses, no fringe ($fringe), frames $frame ms on average"
# vim: set noet ts=4 sw=4:
