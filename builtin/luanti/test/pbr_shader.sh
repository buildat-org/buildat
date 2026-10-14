#!/bin/bash
# tier: broken
# broken: back to full; a different picture than the stored reference set;
#   the same on dev (local/runs/dev_baseline)
# cost: 120s (this desk, 2026-09-28)
# covers: extensions/luanti_client/res/*.glsl builtin/voxel_shading/client_lua/** builtin/luanti/client_lua/client.lua apps/vanilla/main/client_lua/init.lua
#
# **Nothing in this tree could fail on a change to the shader the Luanti
# clients draw with** (user, 2026-09-25; [UNDERGROUND_LIGHT] (3)).
# apps/sample_lighting_scene/check.sh guards its own game's look and reads
# builtin/voxel_shading's shader; `extensions/luanti_client/res/
# PBRVoxel.glsl` -- the one apps/vanilla actually draws with -- had no
# runner at all, and the light terms, the gray ramp and the zone the
# ambient comes from were all changed in a week with nothing able to go
# red.
#
# **Three views at 13:00 and one at 20:30 against the stored set**, by RMSE, the same
# shape apps/sample_lighting_scene/check.sh uses: vp1 (the open surface the
# ambient is fitted to), vp8 (a lamp in a cave) and vp10 (a chamber with
# no sky of its own), and **vp1 again at 20:30**.
#
# **The night view is what makes this able to fail.** Broken on purpose
# 2026-09-28 -- the sky ambient multiplied by 1.5 in PBRVoxel.glsl --
# the three noon views read 5.22, 3.66 and 2.51 against a noise floor of
# about 3: **the check passed a fifty percent change to the term it
# exists to guard**, because at 13:00 the sun is most of the picture and
# the ambient is a sliver of it. At 20:30 the ambient is the picture.
# One mode, four states: two minutes rather than [PROBE_CYCLE]'s ten.
#
# The reference is local/reference_shots/module_pbr_r150, which
# reference_shots/shoot_buildat_server.sh writes; this shoots into a
# scratch directory of its own and never touches it.
#
#   builtin/luanti/test/pbr_shader.sh
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
me="$here/builtin/luanti/test/reference_shots"
ref="$here/local/reference_shots/module_pbr_r150"
out="$here/local/pbr_shader"; mkdir -p "$out"
. "$here/util/check_lib.sh" 2>/dev/null || true
if check_pgrep buildat >/dev/null; then
	echo "SKIP: a buildat client is already running" >&2; exit 77
fi
if [ ! -d "$ref" ]; then
	echo "SKIP: no reference set at $ref -- take one with" \
			"reference_shots/shoot_buildat_server.sh pbr" >&2
	exit 77
fi
built=$(mktemp -d /tmp/pbr_shader_build.XXXXXX)
"$me/build.sh" "$built" >/dev/null || { echo "FAIL: build.sh"; exit 1; }
. "$built/env.sh"
rm -rf "$out/shot"; mkdir -p "$out/shot"
REFSHOT_SHOTS_DIR="$out/shot" STATES="1:1300 8:1300 10:1300 1:2030" \
	timeout 900 bash "$me/shoot_buildat_server.sh" pbr > "$out/shoot.log" 2>&1
shot="$out/shot/module_pbr_r${REFSHOT_RANGE}"
# **The bar is measured, not picked** ([CHECK_BASELINE]): two shoots of
# one unchanged tree differ by the sky-visibility sweep, whose rays are
# not the same rays twice. Read on this desk 2026-09-28, an unchanged
# tree against a set shot minutes before it: **2.92, 3.98 and 2.45** for
# vp1, vp8 and vp10. Twenty is well above that and well below a real
# change -- apps/sample_lighting_scene measures those at 72 to 868.
# **Two readings per view, because one of them is blunt.** The RMSE
# catches a change of shape -- a term that moved somewhere and not
# elsewhere -- and its floor is the sky-visibility sweep, whose rays are
# not the same rays twice: measured on this desk 2026-09-28, an
# unchanged tree against a set shot minutes before it, 2.89 / 3.94 /
# 2.46 at noon and 3.89 at night. Twenty is well above that.
#
# **But RMSE could not see a fifty percent change to the sky ambient**
# (broken on purpose, 2026-09-28: 5.22 at vp1 13:00 against a floor of
# 3), so the frame's **mean level** carries the assertion and the RMSE
# is the backstop.
#
# **Only two of the four get a mean assertion**, and which two was
# measured rather than picked -- the first two guesses were both wrong
# and both cost a run. Across the shoots of one unchanged tree taken
# that day:
#
#     vp1  13:00   120.72 / 120.69 / 121.44 / 120.69   spread 0.75
#     vp8  13:00   125.22 / 125.17 / 125.26 / 124.98   spread 0.28
#     vp10 13:00    80.02 / 80.02 / 80.02 / 80.02      spread 0.00
#     vp1  20:30    16.09 / 16.13 / 16.08              spread 0.05
#
# The open surfaces wander with the sky-visibility sweep and the break
# moved vp1 13:00 by only 1.04, so no tolerance separates them there.
# vp10 and vp1 20:30 are steady, and the same break moved vp1 20:30 by
# 0.78 -- fifteen times its own spread. So those two carry the level
# and the open noon views are read by RMSE alone.
bar=20
mean_tol=0.3
python3 - "$shot" "$ref" "$REFSHOT_SEED" "$bar" "$mean_tol" <<'PY' | tee "$out/read.txt"
import sys, os, math
from PIL import Image, ImageChops
shot, ref, seed = sys.argv[1], sys.argv[2], sys.argv[3]
bar, mean_tol = float(sys.argv[4]), float(sys.argv[5])
bad = 0
for vp, hour in (("vp1", "1300"), ("vp8", "1300"), ("vp10", "1300"),
        ("vp1", "2030")):
    name = "%s_%s_%s_none.png" % (seed, vp, hour)
    a, b = os.path.join(shot, name), os.path.join(ref, name)
    if not (os.path.exists(a) and os.path.exists(b)):
        print("%-5s %s missing (%s)" % (vp, hour,
                "shot" if not os.path.exists(a) else "reference"))
        bad += 1
        continue
    ia, ib = Image.open(a).convert("RGB"), Image.open(b).convert("RGB")
    if ia.size != ib.size:
        print("%-5s %s size differs" % (vp, hour)); bad += 1; continue
    pa, pb = list(ia.getdata()), list(ib.getdata())
    n = len(pa) * 3
    ma = sum(sum(t) for t in pa) / n
    mb = sum(sum(t) for t in pb) / n
    px = list(ImageChops.difference(ia, ib).getdata())
    rmse = math.sqrt(sum(r*r+g*g+bb*bb for r, g, bb in px) / n)
    over = ""
    # Only where the mean is steady enough to mean something; see above
    if (vp, hour) in (("vp10", "1300"), ("vp1", "2030")) and \
            abs(ma - mb) > mean_tol:
        over += "  MEAN"
    if rmse > bar:
        over += "  RMSE"
    print("%-5s %s  mean %7.2f against %7.2f   RMSE %6.2f%s"
            % (vp, hour, ma, mb, rmse, over))
    if over:
        bad += 1
print("BAD=%d" % bad)
PY
bad=$(sed -n 's/^BAD=//p' "$out/read.txt")
if [ "${bad:-1}" != "0" ]; then
	echo "FAIL: the Luanti clients' pbr shader draws a different picture" \
			"than the stored set; if the change was meant, re-take the set" \
			"with reference_shots/shoot_buildat_server.sh pbr"
	exit 1
fi
echo "PASS: vp1, vp8 and vp10 at 13:00 and vp1 at 20:30 are the stored" \
		"set's, within the noise this scene has"
exit 0
